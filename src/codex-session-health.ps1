# codex-session-health.ps1 — 长会话降智检测与缓解
# 降智机制(实测依据): 会话 JSONL 最大 101MB, 活跃会话累计 2061 万 token,
#   上下文窗口 ~258K, 超限后 app 自动 compaction/截断 -> 早期目标/约束丢失 -> 模型降智。
# 命令:
#   scan                 全量扫描: 大小/token/活跃度, 标记膨胀会话
#   signals -ThreadId    单会话降智信号: token 趋势 / 压缩事件 / 复读 / 停滞 -> 健康判定
#   mitigate -ThreadId -Mode compact|fresh [-Goal 文本]
#       compact: 通过 app-server thread/compact/start 压缩上下文(保留线程)
#       fresh :  新线程 + 冻结目标重开(上下文归零, 推荐 token 超阈值时)
<#
.SYNOPSIS
  检测 Codex 会话降智并缓解。
.PARAMETER Command
  scan | signals | mitigate
.PARAMETER ThreadId
  会话 id(rollout 文件名中的 01a0xxxx-... 段)
.PARAMETER Mode
  mitigate 模式: compact(压缩) | fresh(新线程重开)
.PARAMETER Goal
  fresh 模式的冻结目标文本(缺省从会话最后消息提取)
.PARAMETER SizeMB / Tokens
  膨胀阈值(默认 80MB / 100万 token)
#>
[CmdletBinding()]
param(
    [ValidateSet('scan','signals','mitigate')]
    [string]$Command = 'scan',
    [string]$ThreadId,
    [ValidateSet('compact','fresh')]
    [string]$Mode = 'compact',
    [string]$Goal,
    [int]$SizeMB = 80,
    [long]$Tokens = 1000000
)
$ErrorActionPreference = 'Stop'
$sessDir = "$env:USERPROFILE\.codex\sessions"
$codexBin = (Get-Command codex -ErrorAction Stop).Source

function Log([string]$m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

function Get-Rollout([string]$threadId) {
    return (Get-ChildItem $sessDir -Recurse -Filter "*$threadId*.jsonl" -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1)
}

# .NET 流式读尾部 N 行(FileShare.ReadWrite, 绕开 Get-Content 在活文件上的锁)
function Read-TailLines([string]$file, [int]$n) {
    $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        $ring = New-Object System.Collections.Generic.Queue[string]
        while (($line = $sr.ReadLine()) -ne $null) {
            $ring.Enqueue($line)
            if ($ring.Count -gt $n) { [void]$ring.Dequeue() }
        }
        return @($ring)
    } finally { $fs.Close() }
}

function Get-TokenStats([string]$file, [int]$tailN = 3000) {
    $tokens = @(); $compacts = 0; $agentMsgs = @(); $stalls = 0
    # 正则流式扫描(避免逐行 ConvertFrom-Json 的巨慢开销)
    $totalRe = '"total_tokens"\s*:\s*(\d+)'
    $msgRe = '"type"\s*:\s*"agent_message"\s*,\s*"message"\s*:\s*"((?:[^"\\]|\\.)*)"'
    foreach ($line in (Read-TailLines $file $tailN)) {
        if ($line -match 'compact') { $compacts++ }
        elseif ($line -match 'task_complete') { $stalls++ }
        $m = [regex]::Match($line, $totalRe)
        if ($m.Success -and $line -match 'token_count') { $tokens += [long]$m.Groups[1].Value }
        $m2 = [regex]::Match($line, $msgRe)
        if ($m2.Success) { $agentMsgs += $m2.Groups[1].Value }
    }
    return @{ tokens=$tokens; compacts=$compacts; agentMsgs=$agentMsgs; stalls=$stalls }
}

# ================= scan =================
if ($Command -eq 'scan') {
    Log "== 会话全量扫描(阈值: ${SizeMB}MB / ${Tokens} token) =="
    $sessions = Get-ChildItem $sessDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Length -Descending
    Log "会话总数: $($sessions.Count)"
    $i = 0
    foreach ($s in $sessions | Select-Object -First 12) {
        $i++
        $tid = if ($s.Name -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } else { '?' }
        $flag = ''
        if ($s.Length -gt ($SizeMB * 1MB)) { $flag += ' [膨胀]' }
        if ($s.LastWriteTime -gt (Get-Date).AddHours(-2)) { $flag += ' [活跃]' }
        "{0,2}. {1,9:N0}B  {2}  {3}{4}" -f $i, $s.Length, $s.LastWriteTime.ToString('MM-dd HH:mm'), $tid.Substring(0,8), $flag
    }
    exit 0
}

# ================= signals =================
if ($Command -eq 'signals') {
    if (-not $ThreadId) { throw 'signals 需要 -ThreadId' }
    $s = Get-Rollout $ThreadId
    if (-not $s) { Log "找不到会话 $ThreadId"; exit 2 }
    Log "== 降智信号: $($s.Name) ($([math]::Round($s.Length/1MB,1))MB, 更新于 $($s.LastWriteTime.ToString('MM-dd HH:mm'))) =="
    $st = Get-TokenStats $s.FullName
    $verdict = '健康'; $reasons = @()
    # 1) token 趋势
    if ($st.tokens.Count -ge 5) {
        $first = $st.tokens[0]; $last = $st.tokens[-1]
        Log "token 事件: $($st.tokens.Count) 次, 首=$first 末=$last"
        if ($last -gt 500000) { $verdict = '降智'; $reasons += "累计token ${last}(>50万, 上下文严重膨胀)" }
        elseif ($last -gt 100000) { $reasons += "累计token $last(偏高)" }
    } else { Log "token 事件: $($st.tokens.Count) 次(样本不足)" }
    # 2) 压缩事件
    Log "压缩事件: $($st.compacts) 次(compaction=早期上下文被摘要/丢弃)"
    if ($st.compacts -gt 0) { if ($verdict -eq '健康') { $verdict = '注意' }; $reasons += "发生 $($st.compacts) 次上下文压缩" }
    # 3) 复读
    $dupes = @($st.agentMsgs | Group-Object | Where-Object { $_.Count -ge 2 -and $_.Name.Length -gt 30 })
    Log "assistant 消息: $($st.agentMsgs.Count) 条, 复读 $($dupes.Count) 组"
    if ($dupes.Count -gt 0) { if ($verdict -eq '健康') { $verdict = '注意' }; $reasons += "$($dupes.Count) 组重复回复(模型在绕圈)" }
    # 4) 停滞
    Log "回合完成: $($st.stalls) 次"
    Log "---"
    Log "判定: $verdict $(if($reasons.Count){"- " + ($reasons -join '; ')}else{'(无异常)'})"
    if ($verdict -ne '健康') {
        Log "缓解建议: .\codex-session-health.ps1 -Command mitigate -ThreadId $ThreadId -Mode fresh"
        Log "          (或 compact 保留线程仅压缩)"
    }
    exit 0
}

# ================= mitigate =================
if ($Command -eq 'mitigate') {
    if (-not $ThreadId) { throw 'mitigate 需要 -ThreadId' }
    $s = Get-Rollout $ThreadId
    if (-not $s) { Log "找不到会话 $ThreadId"; exit 2 }
    # 提取目标(最后一条用户/assistant 消息前 500 字, 或 -Goal)
    $goal = $Goal
    if (-not $goal) {
        $lines = Read-TailLines $s.FullName 500
        for ($j = $lines.Count - 1; $j -ge 0; $j--) {
            try { $e = $lines[$j] | ConvertFrom-Json } catch { continue }
            if ($e.type -eq 'event_msg' -and $e.payload.type -eq 'user_message' -and $e.payload.message) { $goal = $e.payload.message; break }
        }
        if (-not $goal) { $goal = '继续当前任务, 以最新进展为准, 完成后输出完成协议' }
    }
    Log "目标: $($goal.Substring(0,[Math]::Min(120,$goal.Length)))..."
    # 起 app-server
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $codexBin; $psi.Arguments = 'app-server --stdio'
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::new(); $p.StartInfo = $psi; $p.Start() | Out-Null
    $cts = [System.Threading.CancellationTokenSource]::new()
    function RQ([string]$method, $params, [int]$timeout) {
        $script:reqId++
        $obj = @{ id=$script:reqId; method=$method }; if ($null -ne $params) { $obj.params = $params }
        $p.StandardInput.WriteLine(($obj | ConvertTo-Json -Depth 20 -Compress))
        $dead = [DateTime]::UtcNow.AddSeconds($timeout)
        while ([DateTime]::UtcNow -lt $dead) {
            $vt = $p.StandardOutput.ReadLineAsync($cts.Token); $t = $vt.AsTask()
            $remain = [Math]::Max(1, [int](($dead - [DateTime]::UtcNow).TotalMilliseconds))
            try { $done = $t.WaitAsync([TimeSpan]::FromMilliseconds($remain)); $done.Wait($remain + 300) | Out-Null } catch { return @{ kind='timeout' } }
            $line = $t.Result; if (-not $line -or -not $line.Trim()) { continue }
            try { $m = $line | ConvertFrom-Json } catch { continue }
            if ($m.id -eq $script:reqId) { if ($m.error) { return @{ kind='rpc-error'; code=$m.error.code; err=$m.error.message } }; return @{ kind='ok'; result=$m.result } }
        }
        return @{ kind='timeout' }
    }
    $script:reqId = 0
    $r = RQ 'initialize' @{ clientInfo=@{ name='session-health'; version='1.0' } } 10
    if ($r.kind -ne 'ok') { Log "E2 握手失败"; try{$p.Kill($true)}catch{}; exit 11 }
    $p.StandardInput.WriteLine('{"method":"initialized"}')

    if ($Mode -eq 'compact') {
        Log "== thread/compact/start $ThreadId =="
        $r = RQ 'thread/compact/start' @{ threadId=$ThreadId } 30
        if ($r.kind -eq 'ok') { Log "压缩已触发: $($r.result | ConvertTo-Json -Compress)" } else { Log "压缩失败: $($r.kind) $($r.err)" }
    } else {
        Log "== fresh: 新线程 + 冻结目标重开 =="
        $r = RQ 'thread/start' @{ cwd=(Get-Location).Path; model='gpt-5.6-sol'; approvalPolicy='never'; sandbox='workspace-write'; threadSource='appServer' } 20
        if ($r.kind -ne 'ok') { Log "新线程失败: $($r.kind) $($r.err)"; try{$p.Kill($true)}catch{}; exit 13 }
        $newTid = $r.result.thread.id
        Log "新线程: $newTid"
        $prompt = "$goal`n`n## 背景`n这是在原会话 $ThreadId 基础上新开的干净上下文(原会话已膨胀). 直接继续执行, 完成后输出完成协议."
        $r2 = RQ 'turn/start' @{ threadId=$newTid; input=@(@{ type='text'; text=$prompt }); model='gpt-5.6-sol'; approvalPolicy='never'; sandboxPolicy=@{ type='workspaceWrite' } } 20
        if ($r2.kind -eq 'ok') { Log "新回合已启动 turn=$($r2.result.turn.id)" } else { Log "新回合失败: $($r2.kind) $($r2.err)" }
    }
    try { $cts.Cancel() } catch {}
    try { $p.Kill($true) } catch {}
    exit 0
}
