# build-exe.ps1 — 把 5 个 ps1 内嵌进桌面 EXE 控制台(暗色主题 + 动效 + token 监控)
$ErrorActionPreference = 'Stop'
$homeDir = $env:USERPROFILE
$desktop = [Environment]::GetFolderPath('Desktop')
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

$scripts = @(
    @{ name='codex-desktop-drive.ps1';      file=Join-Path $homeDir 'codex-desktop-drive.ps1' },
    @{ name='codex-watch-background.ps1';   file=Join-Path $homeDir 'codex-watch-background.ps1' },
    @{ name='codex-desktop-feeder.ps1';     file=Join-Path $homeDir 'codex-desktop-feeder.ps1' },
    @{ name='codex-relay-switch.ps1';       file=Join-Path $homeDir 'codex-relay-switch.ps1' },
    @{ name='codex-session-health.ps1';     file=Join-Path $homeDir 'codex-session-health.ps1' }
)
foreach ($s in $scripts) { if (-not (Test-Path $s.file)) { throw "缺少 $($s.file)" } }
$b64Lines = foreach ($s in $scripts) {
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($s.file))
    "        internal const string SCRIPT_$($s.name -replace '[^A-Za-z0-9]','_') = `"$b64`";"
}

$cs = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

public class CodexWatchApp : Form {
    internal const string SCRIPT_codex_desktop_drive_ps1 = "";
    internal const string SCRIPT_codex_watch_background_ps1 = "";
    internal const string SCRIPT_codex_desktop_feeder_ps1 = "";
    internal const string SCRIPT_codex_relay_switch_ps1 = "";
    internal const string SCRIPT_codex_session_health_ps1 = "";
    __B64_ENTRIES__

    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();

    // ---- 调色板(暗色, 取自 Codex 桌面端 accent #339cff) ----
    static readonly Color BG      = Color.FromArgb(13, 15, 20);
    static readonly Color CARD    = Color.FromArgb(23, 26, 33);
    static readonly Color ACCENT  = Color.FromArgb(51, 156, 255);
    static readonly Color TEXT    = Color.FromArgb(230, 233, 240);
    static readonly Color MUTED   = Color.FromArgb(122, 130, 148);
    static readonly Color GREEN   = Color.FromArgb(64, 201, 119);
    static readonly Color RED     = Color.FromArgb(255, 94, 94);

    // ---- token 监控状态 ----
    long ctx = 0, limit = 258000, cum = 0; int compacts = 0; bool watchRunning = false;
    double ringTarget = 0, ringCurrent = 0; float breathe = 0; int breatheDir = 1;
    // ---- 工作状态(右上角) ----
    string workState = "检测中"; Color workColor = Color.FromArgb(122, 130, 148);

    // TokenPanel 用到的公开只读属性
    public double RingCurrent { get { return ringCurrent; } }
    public long Ctx { get { return ctx; } }
    public long Limit { get { return limit; } }
    public long Cum { get { return cum; } }
    public int Compacts { get { return compacts; } }
    public bool WatchRunning { get { return watchRunning; } }

    GlowButton btnStart, btnStop;
    TokenPanel tokenPanel;
    TextBox log;
    Timer animT, pollT, logT;
    long logOffset = 0;
    string Home;
    Font titleFont = null, statusFont = null;

    public CodexWatchApp() {
        Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        ExtractScripts();
        Text = "Codex 守护控制台";
        Font = new Font("Microsoft YaHei UI", 9f);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(520, 440);
        MinimumSize = new Size(470, 380);
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;

        // 布局由 LayoutUI() 统一按缩放系数 k 计算(所有内容跟随窗口缩放)
        tokenPanel = new TokenPanel(this) { Location = new Point(16, 56), Size = new Size(488, 122) };
        btnStart = MakeBtn("启动守护", 70, 194, 180);
        btnStop  = MakeBtn("停止守护", 270, 194, 180);
        btnStart.IconGlyph = "\uE768";   // Segoe MDL2: 播放
        btnStop.IconGlyph  = "\uE71A";   // Segoe MDL2: 停止
        btnStart.Accent = Color.FromArgb(51, 156, 255); btnStart.Effect = "shine";
        btnStop.Accent  = Color.FromArgb(255, 94, 94);  btnStop.Effect  = "rise";
        log = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, ReadOnly = true,
                            BackColor = Color.FromArgb(17, 20, 26), ForeColor = Color.FromArgb(190, 196, 210),
                            BorderStyle = BorderStyle.None };
        Controls.AddRange(new Control[] { tokenPanel, btnStart, btnStop, log });

        btnStart.Click += (s, e) => Run("启动守护", "codex-watch-background.ps1", "start -Loop -AutoMinimize");
        btnStop.Click  += (s, e) => Run("停止守护", "codex-watch-background.ps1", "stop");
        btnStart.Primary = true;   // 启动守护 = 主按钮(流光+渐变边框+呼吸光)

        animT = new Timer { Interval = 30 };  animT.Tick += (s, e) => AnimTick(); animT.Start();
        pollT = new Timer { Interval = 3000 }; pollT.Tick += (s, e) => { PollTokens(); PollWatch(); PollWork(); };
        logT  = new Timer { Interval = 2000 }; logT.Tick += (s, e) => PollLog();
        Shown += (s, e) => { LayoutUI(); PollTokens(); PollWatch(); PollWork(); PollLog(); pollT.Start(); logT.Start(); };
    }
    GlowButton MakeBtn(string text, int x, int y, int w) {
        var b = new GlowButton { Text = text, Location = new Point(x, y), Size = new Size(w, 36) };
        return b;
    }
    // 统一缩放布局: 所有控件位置/尺寸/字体 = 基准 × k
    void LayoutUI() {
        if (tokenPanel == null) return;
        int W = ClientSize.Width, H = ClientSize.Height;
        float k = Math.Min(W / 520f, H / 440f);
        if (k < 0.7f) k = 0.7f; if (k > 2.2f) k = 2.2f;
        float m = 16f * k;
        if (titleFont != null) { titleFont.Dispose(); statusFont.Dispose(); }
        titleFont  = new Font("Microsoft YaHei UI", 12f * k, FontStyle.Bold);
        statusFont = new Font("Microsoft YaHei UI", 8.5f * k);
        tokenPanel.SetBounds((int)m, (int)(56f * k), (int)(W - 2 * m), (int)(122f * k));
        tokenPanel.ScaleK = k;
        int bw = (int)(180f * k), bh = (int)(36f * k);
        int total = bw * 2 + (int)(20f * k);
        int bx = (W - total) / 2;
        btnStart.SetBounds(bx, (int)(194f * k), bw, bh);
        btnStop.SetBounds(bx + bw + (int)(20f * k), (int)(194f * k), bw, bh);
        btnStart.Font = new Font("Microsoft YaHei UI", 9f * k);
        btnStop.Font  = new Font("Microsoft YaHei UI", 9f * k);
        log.SetBounds((int)m, (int)(246f * k), (int)(W - 2 * m), (int)(H - 246f * k - m));
        log.Font = new Font("Consolas", 11f * k);
        Invalidate();
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutUI(); }
    void AnimTick() {
        ringCurrent += (ringTarget - ringCurrent) * 0.12;
        if (Math.Abs(ringTarget - ringCurrent) < 0.001) ringCurrent = ringTarget;
        breathe += 0.06f * breatheDir;
        if (breathe > 1) { breathe = 1; breatheDir = -1; } else if (breathe < 0) { breathe = 0; breatheDir = 1; }
        btnStart.Step(); btnStop.Step();   // 按钮动效
        tokenPanel.Invalidate();
        Invalidate(new Rectangle(ClientSize.Width - 40, 13, 22, 22));
    }
    void PollWatch() {
        try {
            string pf = Path.Combine(Home, ".codex-watch.pid");
            if (!File.Exists(pf)) { watchRunning = false; return; }
            string[] lines = File.ReadAllLines(pf);
            bool any = false;
            foreach (string l in lines) {
                int id; if (int.TryParse(l.Trim(), out id)) {
                    Process pr = Process.GetProcessById(id);
                    if (pr != null) { any = true; break; }
                }
            }
            watchRunning = any;
        } catch { watchRunning = false; }
        SetGuardButtons();   // 联动按钮可用态
        Invalidate(new Rectangle(ClientSize.Width - 260, 12, 260, 32));   // 状态区立即重绘
    }
    // 防重复启动: 守护运行中 -> 启动置灰只留停止; 停止后恢复
    void SetGuardButtons() {
        if (btnStart == null) return;
        btnStart.Enabled = !watchRunning;
        btnStop.Enabled = watchRunning;
    }
    void PollTokens() {
        try {
            string dir = Path.Combine(Home, ".codex", "sessions");
            if (!Directory.Exists(dir)) return;
            string newest = null; DateTime newestT = DateTime.MinValue;
            foreach (string f in Directory.GetFiles(dir, "*.jsonl", SearchOption.AllDirectories)) {
                DateTime t = File.GetLastWriteTime(f);
                if (t > newestT) { newestT = t; newest = f; }
            }
            if (newest == null) return;
            long len = new FileInfo(newest).Length;
            int tail = (int)Math.Min(len, 262144);
            byte[] buf = new byte[tail];
            using (var fs = new FileStream(newest, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                fs.Seek(len - tail, SeekOrigin.Begin); fs.Read(buf, 0, tail);
            }
            string txt = Encoding.UTF8.GetString(buf);
            string[] lines = txt.Split('\n');
            ctx = 0; cum = 0; compacts = 0;
            foreach (string ln in lines) {
                if (ln.IndexOf("token_count", StringComparison.Ordinal) >= 0) {
                    Match m1 = Regex.Match(ln, "\"last_token_usage\":\\{\"input_tokens\":(\\d+)");
                    if (m1.Success) ctx = long.Parse(m1.Groups[1].Value);
                    Match m2 = Regex.Match(ln, "\"total_tokens\":(\\d+)");
                    if (m2.Success) cum = long.Parse(m2.Groups[1].Value);
                }
                if (ln.IndexOf("compact", StringComparison.Ordinal) >= 0) compacts++;
            }
            Match mL = Regex.Match(txt, "\"model_context_window\":(\\d+)");
            if (mL.Success) limit = long.Parse(mL.Groups[1].Value);
            if (limit <= 0) limit = 258000;
            ringTarget = (double)ctx / limit;
            if (ringTarget > 1) ringTarget = 1;
        } catch { }
    }
    void PollWork() {
        try {
            var root = System.Windows.Automation.AutomationElement.RootElement;
            var cond = new System.Windows.Automation.PropertyCondition(System.Windows.Automation.AutomationElement.ProcessIdProperty, 26424);
            var win = root.FindFirst(System.Windows.Automation.TreeScope.Children, cond);
            if (win == null) { workState = "桌面未运行"; workColor = Color.FromArgb(140, 140, 140); Invalidate(new Rectangle(ClientSize.Width - 220, 12, 220, 32)); return; }
            var all = win.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition);
            bool cap = false, paused = false, running = false;
            foreach (System.Windows.Automation.AutomationElement el in all) {
                string n = el.Current.Name; if (string.IsNullOrEmpty(n) || el.Current.IsOffscreen) continue;
                if (n == "停止") running = true;
                else if ((n.IndexOf("停滞", StringComparison.Ordinal) >= 0 || n.IndexOf("暂停", StringComparison.Ordinal) >= 0) && n.IndexOf("目标", StringComparison.Ordinal) >= 0) paused = true;
                else if (n.IndexOf("capacity", StringComparison.OrdinalIgnoreCase) >= 0 || n.IndexOf("at capacity", StringComparison.OrdinalIgnoreCase) >= 0) cap = true;
            }
            string s; Color c;
            string guard = watchRunning ? "守护中" : "守护停";
            if (cap) { s = guard + " · 容量错误"; c = RED; }
            else if (paused) { s = guard + " · 目标暂停"; c = Color.FromArgb(255, 190, 90); }
            else if (running) { s = guard + " · 运行中"; c = GREEN; }
            else { s = guard + " · 空闲"; c = Color.FromArgb(122, 130, 148); }
            if (!watchRunning) c = Color.FromArgb(150, 150, 150);
            workState = s; workColor = c;
            Invalidate(new Rectangle(ClientSize.Width - 260, 12, 260, 32));
        } catch { }
    }
    void PollLog() {
        string path = Path.Combine(Home, ".codex-watch.log");
        try {
            if (!File.Exists(path)) return;
            long len = new FileInfo(path).Length;
            if (len <= logOffset) { if (len < logOffset) logOffset = 0; return; }
            byte[] buf;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                fs.Seek(logOffset, SeekOrigin.Begin);
                buf = new byte[len - logOffset];
                int got = 0;
                while (got < buf.Length) { int n = fs.Read(buf, got, buf.Length - got); if (n <= 0) break; got += n; }
                logOffset = len;
                int roll = 0;
                for (int k = Math.Min(3, got); k >= 1; k--) {
                    byte b = buf[got - k];
                    if (b >= 0x80) { roll = k; break; }
                    if (b < 0x80) break;
                }
                if (roll > 0 && got - roll >= 0) { logOffset -= roll; got -= roll; }
                if (got > 0) {
                    string t2 = Encoding.UTF8.GetString(buf, 0, got);
                    if (!string.IsNullOrWhiteSpace(t2)) Append(t2.TrimEnd());
                }
            }
        } catch { }
    }
    protected override void OnPaintBackground(PaintEventArgs e) {
        using (var b = new LinearGradientBrush(ClientRectangle, Color.FromArgb(13, 15, 20), Color.FromArgb(21, 25, 33), 45f))
            e.Graphics.FillRectangle(b, ClientRectangle);
        using (var p = new Pen(Color.FromArgb(70, ACCENT), 1)) e.Graphics.DrawLine(p, 0, 0, ClientSize.Width, 0);
        // 标题(副标题已移除; 字段字体不 Dispose, 由 LayoutUI 统一管理)
        using (var b = new SolidBrush(TEXT)) {
            Font tf = titleFont != null ? titleFont : new Font("Microsoft YaHei UI", 12f, FontStyle.Bold);
            e.Graphics.DrawString("CODEX 守护", tf, b, 16, 14);
            if (titleFont == null) tf.Dispose();
        }
        // 工作状态呼吸灯(右上角, 随窗口宽度)
        int alpha = 110 + (int)(90 * breathe);
        float k = Math.Min(ClientSize.Width / 520f, ClientSize.Height / 440f); if (k < 0.7f) k = 0.7f; if (k > 2.2f) k = 2.2f;
        float dotX = ClientSize.Width - 36 * k, dotY = 17 * k, dotR = 6 * k;
        using (var gb = new SolidBrush(Color.FromArgb(alpha, workColor))) e.Graphics.FillEllipse(gb, dotX, dotY, dotR * 2, dotR * 2);
        using (var gp = new Pen(Color.FromArgb(alpha / 2, workColor), 3f * k)) e.Graphics.DrawEllipse(gp, dotX - 2 * k, dotY - 2 * k, dotR * 2 + 4 * k, dotR * 2 + 4 * k);
        using (var b2 = new SolidBrush(workColor)) {
            Font sf = statusFont != null ? statusFont : new Font("Microsoft YaHei UI", 8.5f);
            SizeF sz = e.Graphics.MeasureString(workState, sf);
            e.Graphics.DrawString(workState, sf, b2, dotX - 8 * k - sz.Width, dotY + k);
            if (statusFont == null) sf.Dispose();
        }
    }
    private void Run(string label, string script, string args) {
        Append("===== " + label + " =====");
        try {
            var psi = new ProcessStartInfo("pwsh",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Home, script) + "\" " + args) {
                RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Home,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            using (var p = Process.Start(psi)) {
                p.OutputDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) Append(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) Append("[err] " + e.Data); };
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                if (!p.WaitForExit(90000)) { try { p.Kill(); } catch { } Append("[timeout] 命令超时, 已强制结束"); }
            }
            PollWatch();
        } catch (Exception ex) { Append("[exception] " + ex.Message); }
    }
    private void Append(string s) {
        if (InvokeRequired) { BeginInvoke(new Action<string>(Append), s); return; }
        log.AppendText(s + Environment.NewLine);
        log.SelectionStart = log.TextLength; log.ScrollToCaret();
    }
    private static void ExtractScripts() {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        WriteScript(home, "codex-desktop-drive.ps1", SCRIPT_codex_desktop_drive_ps1);
        WriteScript(home, "codex-watch-background.ps1", SCRIPT_codex_watch_background_ps1);
        WriteScript(home, "codex-desktop-feeder.ps1", SCRIPT_codex_desktop_feeder_ps1);
        WriteScript(home, "codex-relay-switch.ps1", SCRIPT_codex_relay_switch_ps1);
        WriteScript(home, "codex-session-health.ps1", SCRIPT_codex_session_health_ps1);
    }
    private static void WriteScript(string dir, string name, string b64) {
        if (string.IsNullOrEmpty(b64)) return;
        string p = Path.Combine(dir, name);
        try {
            if (!File.Exists(p) || new FileInfo(p).Length == 0)
                File.WriteAllText(p, Encoding.UTF8.GetString(Convert.FromBase64String(b64)), new UTF8Encoding(false));
        } catch (Exception ex) { MessageBox.Show("写入脚本失败 " + name + ": " + ex.Message); }
    }
    [STAThread]
    public static void Main() {
        try { SetProcessDpiAwarenessContext((IntPtr)(-4)); }
        catch { try { SetProcessDPIAware(); } catch { } }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // 全局异常兜底: 弹窗显示错误而不是静默崩溃
        Application.ThreadException += (s, e) => {
            try { MessageBox.Show("发生错误: " + e.Exception.Message, "Codex 守护", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
        };
        AppDomain.CurrentDomain.UnhandledException += (s, e) => {
            try { MessageBox.Show("未处理错误: " + ((Exception)e.ExceptionObject).Message, "Codex 守护", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
        };
        Application.Run(new CodexWatchApp());
    }
}

// ---- 动效按钮(每个按钮独立动效: shine 流光 / rise 上升填充 / sonar 声呐波纹) ----
class GlowButton : Button {
    bool hover = false; bool primary = false;
    float shine = -0.35f;          // shine: 流光位置(主按钮)
    float hoverGlow = 0f;          // 悬停辉光 0..1 缓动
    float risePos = 0f;            // rise: 底部上升填充 0..1
    float sonarPhase = 0f;         // sonar: 声呐相位 0..1
    bool sonarOn = false;
    bool rippling = false; float rippleT = 1f; Point ripplePt;
    static readonly Color CYAN = Color.FromArgb(80, 200, 255);

    public string IconGlyph = "";      // Segoe MDL2 图标
    public string Effect = "shine";    // shine | rise | sonar
    public Color Accent = Color.FromArgb(51, 156, 255);
    public bool Primary { get { return primary; } set { primary = value; Invalidate(); } }

    public GlowButton() {
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
        BackColor = Color.FromArgb(23, 26, 33); ForeColor = Color.FromArgb(230, 233, 240);
        Font = new Font("Microsoft YaHei UI", 9f); Cursor = Cursors.Hand; TabStop = false;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { ripplePt = e.Location; rippleT = 0f; rippling = true; Invalidate(); base.OnMouseDown(e); }
    public void Step() {
        if (!Enabled) return;   // 禁用态不动画
        bool dirty = false;
        if (primary) { shine += 0.013f; if (shine > 1.25f) shine = -0.25f; dirty = true; }
        if (rippling && rippleT < 1f) { rippleT += 0.08f; if (rippleT >= 1f) { rippleT = 1f; rippling = false; } dirty = true; }
        float target = hover ? 1f : 0f;
        if (Math.Abs(hoverGlow - target) > 0.02f) { hoverGlow += (target - hoverGlow) * 0.28f; dirty = true; } else hoverGlow = target;
        if (Effect == "rise") {
            float rt = hover ? 1f : 0f;
            if (Math.Abs(risePos - rt) > 0.02f) { risePos += (rt - risePos) * 0.12f; dirty = true; } else risePos = rt;
        }
        if (Effect == "sonar") {
            if (hover) { sonarPhase += 0.06f; if (sonarPhase > 1f) sonarPhase -= 1f; sonarOn = true; dirty = true; }
            else sonarOn = false;
        }
        if (dirty) Invalidate();
    }
    protected override void OnPaint(PaintEventArgs pe) {
        Graphics g = pe.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(2, 2, Width - 4, Height - 4);
        GraphicsPath path = Rounded(r, 10);
        // 禁用态: 灰底灰字, 无任何动效
        if (!Enabled) {
            using (var b = new SolidBrush(Color.FromArgb(28, 31, 38))) g.FillPath(b, path);
            using (var p = new Pen(Color.FromArgb(44, 49, 60), 1f)) g.DrawPath(p, path);
            if (!string.IsNullOrEmpty(IconGlyph)) {
                using (var f = new Font("Segoe MDL2 Assets", 12f * (Height / 36f)))
                using (var b = new SolidBrush(Color.FromArgb(96, 102, 118)))
                    g.DrawString(IconGlyph, f, b, 13f * (Height / 36f), (Height - 16f * (Height / 36f)) / 2f);
            }
            Rectangle tr2 = IconGlyph.Length > 0 ? new Rectangle(r.X + 16, r.Y, r.Width - 16, r.Height) : r;
            TextRenderer.DrawText(g, Text, Font, tr2, Color.FromArgb(100, 106, 120),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            return;
        }
        // 背景: 纵向渐变(强调色晕染, 悬停加重) + 顶部玻璃高光
        Color fillTop = Lerp(Color.FromArgb(33, 38, 50), Accent, 0.16f + 0.32f * hoverGlow);
        Color fillBot = Lerp(Color.FromArgb(20, 23, 30), Accent, 0.05f + 0.20f * hoverGlow);
        using (var lb = new LinearGradientBrush(r, fillTop, fillBot, 90f)) g.FillPath(lb, path);
        // 外发光(悬停 + 主按钮常驻)
        if (hoverGlow > 0.05f || primary) {
            float ga = 28f + 55f * hoverGlow + (primary ? 10f + 8f * (float)Math.Sin(shine * 12f) : 0f);
            using (var p = new Pen(Color.FromArgb((int)ga, Accent), 5))
                g.DrawPath(p, Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 12));
        }
        using (var clip = new Region(path)) {
            g.Clip = clip;
            // 玻璃光泽: 顶部 55% 白色渐变反光
            using (var gloss = new LinearGradientBrush(new RectangleF(r.X, r.Y, r.Width, r.Height * 0.55f),
                Color.FromArgb(primary ? 115 : 70, 255, 255, 255), Color.FromArgb(0, 255, 255, 255), 90f))
                g.FillRectangle(gloss, r.X, r.Y, r.Width, r.Height * 0.55f);
            // 主按钮顶部细亮线
            if (primary) {
                using (var p = new Pen(Color.FromArgb(130, 255, 255, 255), 1.2f))
                    g.DrawLine(p, r.X + 8, r.Y + 2, r.Right - 8, r.Y + 2);
            }
            // rise: 底部上升填充(停止按钮)
            if (Effect == "rise" && risePos > 0.02f) {
                using (var b = new SolidBrush(Color.FromArgb((int)(46 + 44 * hoverGlow), Accent)))
                    g.FillRectangle(b, r.X, r.Bottom - (int)(risePos * r.Height), r.Width, (int)(risePos * r.Height) + 1);
            }
            // sonar: 声呐波纹(恢复按钮)
            if (Effect == "sonar" && sonarOn) {
                float cxx = r.X + r.Width / 2f, cyy = r.Y + r.Height / 2f;
                float maxR = r.Width * 0.72f;
                for (int k = 0; k < 2; k++) {
                    float ph = sonarPhase - k * 0.5f; if (ph < 0) ph += 1f;
                    float rr = maxR * ph;
                    int a = (int)(95 * (1 - ph));
                    using (var p = new Pen(Color.FromArgb(a, Accent), 1.6f))
                        g.DrawEllipse(p, cxx - rr, cyy - rr, rr * 2, rr * 2);
                }
            }
            // shine: 主按钮流光扫过
            if (primary) {
                float x = shine * Width;
                using (var lb = new LinearGradientBrush(new RectangleF(x - 40, 0, 80, Height), Color.Transparent, Color.White, LinearGradientMode.Horizontal)) {
                    ColorBlend cb = new ColorBlend(3);
                    cb.Colors = new Color[] { Color.Transparent, Color.FromArgb(85, 255, 255, 255), Color.Transparent };
                    cb.Positions = new float[] { 0f, 0.5f, 1f };
                    lb.InterpolationColors = cb;
                    g.FillRectangle(lb, x - 40, 0, 80, Height);
                }
            }
            // 点击波纹(Ripple)
            if (rippling && rippleT < 1f) {
                float maxR = (float)Math.Sqrt(Width * Width + Height * Height);
                float rad = maxR * rippleT;
                int a = (int)(110 * (1 - rippleT));
                using (var b = new SolidBrush(Color.FromArgb(a, 255, 255, 255)))
                    g.FillEllipse(b, ripplePt.X - rad, ripplePt.Y - rad, rad * 2, rad * 2);
            }
            g.ResetClip();
        }
        // 边框: 主按钮渐变, 其余用各自强调色
        if (primary) {
            using (var lb = new LinearGradientBrush(r, Accent, CYAN, 90f))
            using (var p = new Pen(lb, 1.4f)) g.DrawPath(p, path);
        } else {
            using (var p = new Pen(Lerp(Color.FromArgb(52, 62, 82), Accent, hoverGlow), hover ? 1.4f : 1f)) g.DrawPath(p, path);
        }
        // 图标(Segoe MDL2, 随按钮高度缩放)
        if (!string.IsNullOrEmpty(IconGlyph)) {
            float ik = Height / 36f;
            using (var f = new Font("Segoe MDL2 Assets", 12f * ik))
            using (var b = new SolidBrush(primary || hover ? Accent : Lerp(Color.FromArgb(150, 160, 180), Color.White, hoverGlow)))
                g.DrawString(IconGlyph, f, b, 13f * ik, (Height - 16f * ik) / 2f);
        }
        Color tc = Lerp(Color.FromArgb(230, 233, 240), Color.White, hoverGlow);
        Rectangle tr = IconGlyph.Length > 0 ? new Rectangle(r.X + 16, r.Y, r.Width - 16, r.Height) : r;
        TextRenderer.DrawText(g, Text, Font, tr, tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
    static Color Lerp(Color a, Color b, float t) {
        return Color.FromArgb((int)(a.A + (b.A - a.A) * t), (int)(a.R + (b.R - a.R) * t),
                              (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
    static GraphicsPath Rounded(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath(); int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}

// ---- token 监控面板(动画环形仪表, 内容随 ScaleK 缩放) ----
class TokenPanel : Panel {
    CodexWatchApp app;
    public float ScaleK = 1f;
    public TokenPanel(CodexWatchApp a) {
        app = a; DoubleBuffered = true;
        BackColor = Color.FromArgb(18, 21, 28);
    }
    protected override void OnPaint(PaintEventArgs pe) {
        Graphics g = pe.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        float k = ScaleK; if (k <= 0) k = 1f;
        // 卡片圆角底
        Rectangle cr = new Rectangle(1, 1, Width - 2, Height - 2);
        using (var b = new SolidBrush(Color.FromArgb(18, 21, 28))) g.FillPath(b, Rounded(cr, (int)(12 * k)));
        using (var p = new Pen(Color.FromArgb(45, 56, 76))) g.DrawPath(p, Rounded(cr, (int)(12 * k)));
        // 环形仪表
        int cx = (int)(62 * k), cy = (int)(56 * k), r = (int)(40 * k);
        using (var pt = new Pen(Color.FromArgb(42, 52, 70), 8f * k)) { pt.StartCap = LineCap.Round; pt.EndCap = LineCap.Round; g.DrawArc(pt, cx - r, cy - r, 2 * r, 2 * r, 0, 360); }
        float sweep = (float)(app.RingCurrent * 360);
        if (sweep > 1) {
            using (var pv = new Pen(Color.FromArgb(120, 51, 156, 255), 16f * k)) { pv.StartCap = LineCap.Round; pv.EndCap = LineCap.Round; g.DrawArc(pv, cx - r, cy - r, 2 * r, 2 * r, -90, sweep); }
            using (var pv = new Pen(Color.FromArgb(255, 51, 156, 255), 8f * k)) { pv.StartCap = LineCap.Round; pv.EndCap = LineCap.Round; g.DrawArc(pv, cx - r, cy - r, 2 * r, 2 * r, -90, sweep); }
        }
        using (var b = new SolidBrush(Color.White)) {
            using (var f = new Font("Segoe UI", 14f * k, FontStyle.Bold))
                g.DrawString(((int)(app.RingCurrent * 100)).ToString() + "%", f, b, cx - 24 * k, cy - 18 * k);
            using (var f2 = new Font("Microsoft YaHei UI", 7.5f * k))
                g.DrawString("上下文占用", f2, new SolidBrush(Color.FromArgb(122, 130, 148)), cx - 26 * k, cy + 10 * k);
        }
        // 统计行
        int x = (int)(130 * k), y = (int)(16 * k), row = (int)(28 * k), vx = (int)(92 * k);
        DrawStat(g, x, y, "当前上下文", FormatK(app.Ctx) + " / " + FormatK(app.Limit), AccentOf(app.RingCurrent), k);
        DrawStat(g, x, y + row, "累计消耗", FormatM(app.Cum) + " tokens", Color.FromArgb(230, 233, 240), k);
        DrawStat(g, x, y + row * 2, "压缩次数", app.Compacts.ToString() + " 次", app.Compacts > 0 ? Color.FromArgb(255, 190, 90) : Color.FromArgb(122, 130, 148), k);
        DrawStat(g, x, y + row * 3, "守护状态", app.WatchRunning ? "运行中 (sol)" : "已停止", app.WatchRunning ? Color.FromArgb(64, 201, 119) : Color.FromArgb(255, 94, 94), k);
    }
    void DrawStat(Graphics g, int x, int y, string kk, string v, Color vc, float k) {
        using (var b = new SolidBrush(Color.FromArgb(122, 130, 148)))
            g.DrawString(kk, new Font("Microsoft YaHei UI", 8f * k), b, x, y);
        using (var b = new SolidBrush(vc))
            g.DrawString(v, new Font("Consolas", 9.5f * k, FontStyle.Bold), b, x + (int)(92 * k), y - (int)(1 * k));
    }
    Color AccentOf(double r2) {
        if (r2 > 0.85) return Color.FromArgb(255, 94, 94);
        if (r2 > 0.6) return Color.FromArgb(255, 190, 90);
        return Color.FromArgb(51, 156, 255);
    }
    static string FormatK(long v) { return (v / 1000.0).ToString("0.0") + "K"; }
    static string FormatM(long v) { return (v / 1000000.0).ToString("0.0") + "M"; }
    static GraphicsPath Rounded(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath(); int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}
'@
$cs = $cs -replace 'internal const string SCRIPT_[a-z_0-9]+ = "";\r?\n', ''
$cs = $cs -replace '__B64_ENTRIES__', ($b64Lines -join "`r`n")

$csPath = Join-Path $env:TEMP 'CodexWatchApp.cs'
[System.IO.File]::WriteAllText($csPath, $cs, (New-Object System.Text.UTF8Encoding($true)))

$outExe = Join-Path $desktop 'Codex守护.exe'
if (Test-Path $outExe) { Remove-Item $outExe -Force -ErrorAction SilentlyContinue }   # 失败时不留旧文件误报
$manifest = Join-Path $env:TEMP 'CodexWatchApp.manifest'
@'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
'@ | Set-Content $manifest -Encoding ASCII
& $csc /nologo /target:winexe /optimize /win32manifest:"$manifest" /out:"$outExe" `
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
  /r:C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationClient.dll `
  /r:C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationTypes.dll "$csPath" 2>&1 | ForEach-Object { Write-Host "csc: $_" }
if (Test-Path $outExe) {
    $b = [System.IO.File]::ReadAllBytes($outExe)
    "编译成功: $outExe  ($($b.Length) 字节, 魔数 $([char]$b[0])$([char]$b[1]))"
} else { Write-Host "编译失败" }
