# codex-desktop-drive.ps1 — Codex 桌面端 UI 自动化驱动(Windows UIAutomation)
# 直接驱动 ChatGPT/Codex 桌面窗口(pid 动态发现): 读状态 / 发消息 / 切模型 / 点"继续" / 检测容量错误
# 思路: 不碰 CLI、不碰管道——桌面端自己就是个可自动化的 UI。
# 命令:
#   status            只读: 窗口/输入框/运行状态/容量提示/模型/线程(安全)
#   send -Text "..."  聚焦输入框 -> 剪贴板粘贴 -> Enter 发送
#   model -Name <id>  打开模型选择 -> 点目标模型
#   click -Name <词>  按名称正则点任意可点击控件
#   watch             永续: 检测 at-capacity -> 切模型重发; 检测"继续" -> 点击; 检测完成串 -> 退出
<#
.SYNOPSIS
  Codex 桌面端 UIA 驱动。
.PARAMETER Command
  status|send|model|click|watch
.PARAMETER Text — send 的消息文本
.PARAMETER Name — model/click 的目标名称(正则)
.PARAMETER ConfirmText — watch 的完成检测串
.PARAMETER RetryModel — 容量错误时切换的模型(默认 gpt-5.2-codex)
.EXAMPLE
  .\codex-desktop-drive.ps1 -Command status
  .\codex-desktop-drive.ps1 -Command send -Text "继续完成剩余任务"
  .\codex-desktop-drive.ps1 -Command watch -ConfirmText "CONFIRMED: all tasks completed"
#>
[CmdletBinding()]
param(
    [ValidateSet('status','send','model','click','watch','goal')]
    [string]$Command = 'status',
    [string]$Text,
    [string]$Name,
    [string]$ConfirmText = 'CONFIRMED: all tasks completed',
    [string]$RetryModel = 'gpt-5.6-sol',   # 固定 sol: 不切模型, 容量只退避
    [switch]$AutoMinimize,
    [int]$WatchSeconds = 7200
)
$ErrorActionPreference = 'Stop'

[System.Reflection.Assembly]::LoadFrom('C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationClient.dll') | Out-Null
[System.Reflection.Assembly]::LoadFrom('C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationTypes.dll') | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
}
'@

$script:autoMin = $AutoMinimize
$script:wasMin = $false
$script:hwnd = [IntPtr]::Zero

function Mouse-Click([int]$x, [int]$y) {
    [Win32]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 120
    [Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
    Start-Sleep -Milliseconds 80
    [Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
}

function Log([string]$m) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $m"
    Write-Host $line
    # 直接以 UTF-8 写日志文件(后台隐藏进程 stdout 重定向是 GBK 会乱码, 改直写)
    try {
        $script:logFile = Join-Path $env:USERPROFILE '.codex-watch.log'
        [System.IO.File]::AppendAllText($script:logFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Get-CodexWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($w in $wins) {
        if ($w.Current.Name -match 'ChatGPT|Codex' -and $w.Current.ClassName -eq 'Chrome_WidgetWin_1') { return $w }
    }
    return $null
}

function Get-All([System.Windows.Automation.AutomationElement]$win) {
    return $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}

function Find-Elements($win, [string]$nameRegex) {
    return @(Get-All $win | Where-Object { $_.Current.Name -match $nameRegex })
}

function Get-Composer($win) {
    $edit = Find-Elements $win '使用 ChatGPT Work' | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit } | Select-Object -First 1
    return $edit
}

function Get-StopButton($win) {
    $b = Find-Elements $win '^停止$' | Select-Object -First 1
    return $b
}

function Get-ContinueButtons($win) {
    return @(Find-Elements $win '^继续$' | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button })
}

function Invoke-Element($el) {
    try {
        $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $ip.Invoke(); return $true
    } catch { return $false }
}

function Click-Element($el) {
    if (Invoke-Element $el) { return $true }
    # 回退: 取中点真实鼠标点击(SendInput)
    $r = $el.Current.BoundingRectangle
    if ($r.Width -le 0) { return $false }
    Mouse-Click ([int]($r.X + $r.Width/2)) ([int]($r.Y + $r.Height/2))
    return $true
}

function Send-ToComposer($win, [string]$text) {
    $edit = Get-Composer $win
    if (-not $edit) { throw '未找到输入框' }
    $hwnd = New-Object System.IntPtr($win.Current.NativeWindowHandle)
    [Win32]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE
    [Win32]::SetForegroundWindow($hwnd) | Out-Null
    $edit.SetFocus() | Out-Null
    Start-Sleep -Milliseconds 300
    Set-Clipboard -Value $text
    $ws = New-Object -ComObject WScript.Shell
    $ws.SendKeys('^a'); Start-Sleep -Milliseconds 100
    $ws.SendKeys('^v'); Start-Sleep -Milliseconds 300
    $ws.SendKeys('{ENTER}')   # 发送(桌面端 Enter=发送)
    Log "已发送: $($text.Substring(0,[Math]::Min(60,$text.Length)))..."
    Keep-Minimized
}

# 若 watch 启动时窗口是最小化的, 动作后重新最小化(挂机不打扰)
function Keep-Minimized {
    if ($script:autoMin -and $script:wasMin -and $script:hwnd -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 800
        [Win32]::ShowWindow($script:hwnd, 6) | Out-Null   # SW_MINIMIZE
    }
}

function Find-CapacityBanner($win) {
    $els = Find-Elements $win 'capacity|at capacity|容量|过载|繁忙|try a different model|选择其他模型'
    return @($els | Where-Object { $_.Current.Name -match 'capacity|容量|过载|繁忙|different model|其他模型' })
}

function Get-ModelButton($win) { return (Find-Elements $win '^\d|Sol|Codex' | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^\d|Sol|Codex' } | Select-Object -First 1) }

function Test-ModelMatch([string]$buttonName, [string]$target) {
    $a = ($buttonName -replace '[^a-z0-9]', '').ToLower()
    $b = ($target -replace '[^a-z0-9]', '').ToLower()
    return ($a -and $b) -and ($a.Contains($b) -or $b.Contains($a))
}

# ================= status =================
if ($Command -eq 'status') {
    $win = Get-CodexWindow
    if (-not $win) { Log 'E1 未找到 Codex 桌面窗口(应用没开?)'; exit 10 }
    Log "窗口: '$($win.Current.Name)' pid=$($win.Current.ProcessId) class=$($win.Current.ClassName)"
    $composer = Get-Composer $win
    Log "输入框: $(if($composer){'存在 @'+$composer.Current.BoundingRectangle}else{'未找到'})"
    $stop = Get-StopButton $win
    Log "运行状态: $(if($stop){'TURN RUNNING(停止按钮可见)'}else{'idle(无停止按钮)'})"
    $cont = Get-ContinueButtons $win
    Log "继续按钮: $($cont.Count) 个 -> $((@($cont | ForEach-Object { $_.Current.BoundingRectangle }) | ForEach-Object { "@$($_.X),$($_.Y)" }) -join ' ')"
    $cap = Find-CapacityBanner $win
    if ($cap.Count -gt 0) { Log "容量提示: 检测到 $($cap.Count) 处 -> $((@($cap | ForEach-Object { $_.Current.Name.Substring(0,[Math]::Min(50,$_.Current.Name.Length)) }) -join ' | '))" }
    else { Log "容量提示: 无" }
    $mb = Get-ModelButton $win
    Log "模型按钮: $(if($mb){$mb.Current.Name}else{'未找到'})"
    # 线程列表
    $threads = Find-Elements $win '^WYD|^杂项|^instruct' | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button } | Select-Object -First 6
    Log "侧栏线程: $((@($threads | ForEach-Object { $_.Current.Name.Substring(0,[Math]::Min(30,$_.Current.Name.Length)) }) -join ' | '))"
    exit 0
}

# ================= send =================
if ($Command -eq 'send') {
    if (-not $Text) { throw 'send 需要 -Text' }
    $win = Get-CodexWindow; if (-not $win) { Log 'E1 未找到窗口'; exit 10 }
    Send-ToComposer $win $Text
    exit 0
}

# ================= click =================
if ($Command -eq 'click') {
    if (-not $Name) { throw 'click 需要 -Name' }
    $win = Get-CodexWindow; if (-not $win) { Log 'E1 未找到窗口'; exit 10 }
    $els = Find-Elements $win $Name
    if ($els.Count -eq 0) { Log "未找到匹配 '$Name' 的控件"; exit 2 }
    $el = $els[0]; Click-Element $el
    Log "已点击 '$($el.Current.Name)'"
    exit 0
}

# ================= model(坐标开菜单 + InvokePattern 选模型, UIA 回读验证) =================
if ($Command -eq 'model') {
    if (-not $Name) { throw 'model 需要 -Name(目标模型名)' }
    $win = Get-CodexWindow; if (-not $win) { Log 'E1 未找到窗口'; exit 10 }
    $hwnd = New-Object System.IntPtr($win.Current.NativeWindowHandle)
    [Win32]::ShowWindow($hwnd, 9) | Out-Null; [Win32]::SetForegroundWindow($hwnd) | Out-Null
    foreach ($attempt in 1..3) {
        $mb = Get-ModelButton $win
        if (-not $mb) { Log "模型按钮未找到(尝试#$attempt)"; Start-Sleep -Seconds 1; continue }
        if (Test-ModelMatch $mb.Current.Name $Name) { Log "已是目标模型: $($mb.Current.Name)"; exit 0 }
        # 1) 真实鼠标点模型按钮
        $r = $mb.Current.BoundingRectangle
        $bx = [int]($r.X + $r.Width/2); $by = [int]($r.Y + $r.Height/2)
        Mouse-Click $bx $by; Start-Sleep -Seconds 1
        # 2) 点 '模型' 行(坐标相对按钮: 菜单在按钮左上, 模型行≈(bx-71, by-93))
        $mrow = @(Find-Elements $win '^模型 5\.6|^模型 ') | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem } | Select-Object -First 1
        if ($mrow) { $mr = $mrow.Current.BoundingRectangle; Mouse-Click ([int]($mr.X+$mr.Width/2)) ([int]($mr.Y+$mr.Height/2)) }
        else { Mouse-Click ($bx - 71) ($by - 93) }
        Start-Sleep -Seconds 2
        # 3) 子菜单项 InvokePattern 选目标模型
        $item = @(Find-Elements $win '5\.6|5\.5|5\.2') | Where-Object { -not $_.Current.IsOffscreen -and ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem) -and (Test-ModelMatch $_.Current.Name $Name) } | Select-Object -First 1
        if ($item) {
            try { ($item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke() | Out-Null } catch { $ir = $item.Current.BoundingRectangle; Mouse-Click ([int]($ir.X+$ir.Width/2)) ([int]($ir.Y+$ir.Height/2)) }
            Start-Sleep -Seconds 1
        } else { Log "尝试#$attempt 子菜单未找到目标项"; (New-Object -ComObject WScript.Shell).SendKeys('{ESC}'); Start-Sleep -Seconds 1; continue }
        # 4) 验证
        $mb2 = Get-ModelButton $win
        if ($mb2 -and (Test-ModelMatch $mb2.Current.Name $Name)) { Log "已切换模型 -> $($mb2.Current.Name)"; exit 0 }
        Log "尝试#$attempt 未命中, 当前: '$(if($mb2){$mb2.Current.Name}else{'?'})'"
    }
    Log "3 次尝试未命中 '$Name'"; exit 2
}

# ================= goal(目标恢复: 只做一件事 = 点"恢复目标") =================
# 用户确认: 目标报错自动暂停 -> 点"恢复目标"即恢复执行(零输入, 不花 token)。
if ($Command -eq 'goal') {
    $win = Get-CodexWindow; if (-not $win) { Log 'E1 未找到窗口'; exit 10 }
    $script:hwnd = New-Object System.IntPtr($win.Current.NativeWindowHandle)
    [Win32]::ShowWindow($script:hwnd, 9) | Out-Null; [Win32]::SetForegroundWindow($script:hwnd) | Out-Null
    $restore = @(Find-Elements $win '^恢复目标$') | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button } | Select-Object -First 1
    if (-not $restore) {
        $restore = @(Find-Elements $win '恢复目标') | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button } | Select-Object -First 1
    }
    if (-not $restore) { Log "未找到'恢复目标'按钮(目标栏不可见?)"; exit 2 }
    $r = $restore.Current.BoundingRectangle
    Mouse-Click ([int]($r.X+$r.Width/2)) ([int]($r.Y+$r.Height/2))
    Log "已点'恢复目标' -> 目标恢复执行(零输入)"
    Keep-Minimized
    exit 0
}

# ================= watch(永续桌面喂料) =================
if ($Command -eq 'watch') {
    $win = Get-CodexWindow; if (-not $win) { Log 'E1 未找到窗口'; exit 10 }
    $script:hwnd = New-Object System.IntPtr($win.Current.NativeWindowHandle)
    $script:wasMin = [Win32]::IsIconic($script:hwnd)
    Log "== 桌面 watch 启动 confirm=$ConfirmText retryModel=$RetryModel autoMinimize=$AutoMinimize 最长 ${WatchSeconds}s =="
    if ($script:wasMin) { Log "窗口当前最小化 -> 动作时自动弹回, 动作后重新最小化(挂机模式)" }
    # ---- 上下文预算护栏 ----
    $contextLimit = 258000          # model_context_window
    $contextGate = 200000           # 超此阈值不再发"继续", 转 fresh 建议
    $lastSendHash = ''              # 去重: 上次发送内容哈希
    $lastSendTime = $null           # 发送冷却
    $capacityBackoff = 30           # 容量重试退避: 30s 起, 指数翻倍, 封顶 300s
    $maxSendsPerHour = 12
    $sendWindow = New-Object System.Collections.Generic.Queue[datetime]

    function Get-LatestContextTokens {
        # 从最新会话 JSONL 快速取最后一次调用的窗口占用(last_token_usage.input_tokens)
        $roll = Get-ChildItem "$env:USERPROFILE\.codex\sessions" -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $roll) { return -1 }
        try {
            $fs = [System.IO.File]::Open($roll.FullName, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs); $last = -1
            while (($line = $sr.ReadLine()) -ne $null) {
                if ($line -match 'token_count') {
                    $m = [regex]::Match($line, '"last_token_usage":\{"input_tokens":(\d+)')
                    if ($m.Success) { $last = [long]$m.Groups[1].Value }
                }
            }
            $fs.Close(); return $last
        } catch { return -1 }
    }

    function Get-LatestRolloutSize {
        # 当前活跃回合的会话文件大小(判断模型是否在产出)
        $roll = Get-ChildItem "$env:USERPROFILE\.codex\sessions" -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $roll) { return -1 }
        return (Get-Item $roll.FullName).Length
    }

    function Test-SendGate([string]$promptText) {
        # 三道闸: 频率 / 去重 / 上下文预算 -> 返回 $true 放行, $false 拦截
        $now = [DateTime]::UtcNow
        if ($lastSendTime -and ($now - $lastSendTime).TotalSeconds -lt 20) { Log "闸1-冷却: 距上次发送 <20s, 跳过"; return $false }
        $h = ($promptText | ConvertTo-Json -Compress) | ForEach-Object { $_.GetHashCode() }
        if ($h -eq $lastSendHash) { Log "闸2-去重: 与上次发送内容相同, 跳过(回合未完成不重复喂)"; return $false }
        while ($sendWindow.Count -gt 0 -and ($now - $sendWindow.Peek()).TotalHours -gt 1) { [void]$sendWindow.Dequeue() }
        if ($sendWindow.Count -ge $maxSendsPerHour) { Log "闸3-频率: 1 小时内已发 $($sendWindow.Count) 次(上限 $maxSendsPerHour), 暂停喂料"; return $false }
        $ctx = Get-LatestContextTokens
        if ($ctx -lt 0) { Log "闸4-上下文: 读取失败(未知) -> fail-closed 拦截, 不花钱投喂"; return $false }
        if ($ctx -gt $contextGate) {
            Log "闸4-上下文: 最近累计 ${ctx} token > ${contextGate}, 不再发'继续'! 建议先瘦身:"
            Log "  .\codex-session-health.ps1 -Command mitigate -Mode fresh (新线程重开) 或 -Mode compact"
            return $false
        }
        return $true
    }

    function Record-Send([string]$promptText) {
        $script:lastSendHash = ($promptText | ConvertTo-Json -Compress) | ForEach-Object { $_.GetHashCode() }
        $script:lastSendTime = [DateTime]::UtcNow
        $script:sendWindow.Enqueue([DateTime]::UtcNow)
    }
    $continuePrompt = '继续: 检查进度; 未完成则继续执行; 全部完成后输出完成协议'
    $deadline = [DateTime]::UtcNow.AddSeconds($WatchSeconds)
    $rounds = 0; $capacitySwitches = 0; $stallInterrupts = 0
    $runSince = $null   # 停止按钮首次出现时间(卡死检测)
    $capBaseline = @(Find-CapacityBanner $win).Count   # 历史容量消息基线, 只对"新增"响应
    Log "容量消息基线: $capBaseline 条(只响应新增)"
    while ([DateTime]::UtcNow -lt $deadline) {
        $rounds++
        # 1) 新增容量错误 -> 只退避 + 目标恢复, 不切模型(锁定 sol)
        $cap = @(Find-CapacityBanner $win)
        if ($cap.Count -gt $capBaseline) {
            $capacitySwitches++
            Log "E3 新增容量错误 #$capacitySwitches (基线 $capBaseline -> 现在 $($cap.Count)) -> 不切模型(锁定 sol), 退避后恢复目标"
            $capBaseline = @(Find-CapacityBanner $win).Count
            Log "E3 退避 ${capacityBackoff}s(指数, 上限300) 后点'恢复目标'"
            Start-Sleep -Seconds $capacityBackoff
            if ($capacityBackoff -lt 300) { $capacityBackoff = $capacityBackoff * 2 }
            & $PSCommandPath -Command goal | Out-Null
            Start-Sleep -Seconds 8
            continue
        }
        # 2) 完成检测: 扫描聊天区文本
        $texts = @(Get-All $win | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $_.Current.Name -match [regex]::Escape($ConfirmText) })
        if ($texts.Count -gt 0) { Log "完成协议命中 (round=$rounds) -> completed"; exit 0 }
        # 3) 运行中
        $stop = Get-StopButton $win
        if ($stop) {
            if (-not $runSince) { $runSince = [DateTime]::UtcNow; Log "回合开始运行 @ $($runSince.ToString('HH:mm:ss'))" }
            # 卡死检测: 运行超过 150s 且无完成 -> 停止 + 点"恢复目标"(零输入恢复)
            elseif (([DateTime]::UtcNow - $runSince).TotalSeconds -gt 150) {
                $stallInterrupts++
                Log "E5 回合卡死 #$stallInterrupts ($([int]([DateTime]::UtcNow - $runSince).TotalSeconds)s 无进展) -> 点停止"
                Click-Element $stop
                Start-Sleep -Seconds 3
                Log "E5 -> 点'恢复目标'恢复(零输入, 不投喂文本)"
                & $PSCommandPath -Command goal | Out-Null
                $runSince = $null
                Start-Sleep -Seconds 10
                continue
            }
            Start-Sleep -Seconds 5; continue
        }
        $runSince = $null
        $capacityBackoff = 30   # 回合正常结束 -> 容量退避复位
        # 3.5) 目标暂停 -> 零输入恢复(省钱: 不产生新用户消息)
        $goalStatus = @(Find-Elements $win '目标|Goal') | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name -match '停滞|暂停|stall|paus' } | Select-Object -First 1
        if ($goalStatus) {
            Log "round#$rounds 目标暂停/停滞 -> goal 零输入恢复"
            & $PSCommandPath -Command goal | Out-Null
            Start-Sleep -Seconds 8
            continue
        }
        # 4) idle 且存在"继续" -> 点继续(喂下一轮)
        $cont = Get-ContinueButtons $win
        if ($cont.Count -gt 0) {
            Log "round#$rounds 检测到'继续'按钮 -> 点击喂下一轮"
            Click-Element $cont[0]; Start-Sleep -Seconds 3
            Keep-Minimized
            continue
        }
        # 5) idle: 有目标 -> 点"恢复目标"(零输入); 完全没目标才轮到文本(最后手段)
        $anyGoal = @(Find-Elements $win '恢复目标|目标已|目标暂停|目标停滞|Goal') | Where-Object { -not $_.Current.IsOffscreen } | Select-Object -First 1
        $composer = Get-Composer $win
        if ($anyGoal -and $composer) {
            Log "round#$rounds idle 有目标 -> 点'恢复目标'(零输入)"
            & $PSCommandPath -Command goal | Out-Null
            Start-Sleep -Seconds 8; continue
        }
        if ($composer) {
            if (Test-SendGate $continuePrompt) {
                $ctx = Get-LatestContextTokens
                Log "round#$rounds idle 且无目标 -> 发'继续'(预计输入 token ~$ctx, 绝对最后手段)"
                Send-ToComposer $win $continuePrompt
                Record-Send $continuePrompt
            }
            Start-Sleep -Seconds 5; continue
        }
        Start-Sleep -Seconds 5
    }
    Log "watch 超时(${WatchSeconds}s) 未完成"
    exit 2
}
