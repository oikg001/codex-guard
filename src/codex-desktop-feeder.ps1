# codex-desktop-feeder.ps1 v2 — 桌面端同引擎喂料器
# 通道: 本地 `codex app-server --stdio`(与 Codex 桌面端同一个 app-server 引擎,
#       sessions 落在同一个 ~/.codex/sessions, 桌面端可见/可续)
# 协议: JSON-RPC 2.0 / JSONL, 线上【不带】"jsonrpc":"2.0" 头(官方 app-server README)
# 流程: initialize -> initialized -> thread/start|resume -> turn/start(任务)
#       -> 读通知(item/*, turn/completed) -> 未完成 turn/steer("继续") -> 循环
# 错误检测与应对(每类都有明确处置+退出码):
#   E1 app-server 进程起不来/崩溃        -> 重启(最多3次), 失败退出码 10
#   E2 initialize 握手失败/超时          -> 退出码 11
#   E3 RPC 错误分类:
#        -32001 Server overloaded        -> 指数退避重试(可重试)
#        capacity/429                    -> 退避 + 换模型重新 turn/start
#        -32601 method not found         -> 协议版本不符, 退出码 12
#        thread/turn not found           -> 重建线程
#   E4 停滞(StallSec 无任何通知)          -> turn/steer 喂"继续"; 连续10次 -> interrupt+重建
#   E5 单轮超时(RoundTimeoutSec)          -> interrupt + 换模型重开
#   E6 完成检测: turn/completed + thread/read 末条消息含 ConfirmText -> 退出 0
#   E7 管道断/进程退出                    -> 自动重启 app-server 并 thread/resume 续跑
<#
.SYNOPSIS
  持续给 Codex(桌面端同引擎)喂任务直到完成。
.PARAMETER Command
  diagnose — 健康检查(app-server 启动/握手/thread/list)
  run      — 喂料循环(默认)
.PARAMETER PromptText / PromptFile — 任务文本
.PARAMETER ThreadId — 续跑已有线程(缺省新建)
.PARAMETER Model — 起始模型(默认取 config 或 gpt-5.6-sol)
.PARAMETER Models — 容量错误时轮换的候选模型(逗号分隔)
.PARAMETER MaxRounds — 最大轮数
.PARAMETER StallSec — 停滞阈值秒(默认 120)
.PARAMETER RoundTimeoutSec — 单轮超时秒(默认 900)
.PARAMETER ConfirmText — 完成确认串
.PARAMETER Cwd — 工作目录(默认当前)
.EXAMPLE
  .\codex-desktop-feeder.ps1 -Command diagnose
  .\codex-desktop-feeder.ps1 -PromptText "检查 TODO 补测试" -MaxRounds 50
#>
[CmdletBinding()]
param(
    [ValidateSet('diagnose','run')]
    [string]$Command = 'run',
    [string]$PromptText,
    [string]$PromptFile,
    [string]$ThreadId,
    [string]$Model,
    [string]$Models,
    [int]$MaxRounds = 999999,
    [int]$StallSec = 120,
    [int]$RoundTimeoutSec = 900,
    [string]$ConfirmText = 'CONFIRMED: all tasks completed',
    [string]$Cwd
)
$ErrorActionPreference = 'Stop'
$codexBin = (Get-Command codex -ErrorAction Stop).Source
if (-not $Cwd) { $Cwd = (Get-Location).Path }
if (-not $Model) { $Model = 'gpt-5.6-sol' }
$nonce = -join ((48..57)+(65..90) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
$doneToken = -join $nonce.ToCharArray()[($nonce.Length-1)..0]
$candidates = @('gpt-5.6-sol')   # 固定 sol: 容量只退避重试, 不轮换模型

function Log([string]$m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

class AppServerClient {
    [System.Diagnostics.Process]$Proc
    [System.IO.StreamWriter]$In
    [System.IO.StreamReader]$Out
    [System.Threading.CancellationTokenSource]$Cts
    [int]$Id = 0
    [string]$LastError

    [bool] Start([string]$codexBin) {
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $codexBin
            $psi.Arguments = 'app-server --stdio'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $this.Proc = [System.Diagnostics.Process]::new()
            $this.Proc.StartInfo = $psi
            if (-not $this.Proc.Start()) { $this.LastError = 'start-failed'; return $false }
            $this.In = $this.Proc.StandardInput
            $this.Out = $this.Proc.StandardOutput
            $this.Cts = [System.Threading.CancellationTokenSource]::new()
            return $true
        } catch { $this.LastError = $_.Exception.Message; return $false }
    }

    [hashtable] Request([string]$method, $params, [int]$timeoutSec) {
        $this.Id++
        $obj = @{ id=$this.Id; method=$method }
        if ($null -ne $params) { $obj.params = $params }
        try { $this.In.WriteLine(($obj | ConvertTo-Json -Depth 20 -Compress)) } catch { return @{ kind='io-error'; err=$_.Exception.Message } }
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remain = [Math]::Max(1, [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            try {
                $vt = $this.Out.ReadLineAsync($this.Cts.Token)
                $t = $vt.AsTask()
                $done = $t.WaitAsync([TimeSpan]::FromMilliseconds($remain))
                $done.Wait($remain + 500) | Out-Null
                $line = $t.Result
            } catch { return @{ kind='timeout'; err="no response for $method in ${timeoutSec}s" } }
            if ($null -eq $line) { return @{ kind='eof'; err='app-server closed stdout' } }
            if (-not $line.Trim()) { continue }
            $msg = $null
            try { $msg = $line | ConvertFrom-Json } catch { continue }
            if ($msg.id -eq $this.Id) {
                if ($msg.error) { return @{ kind='rpc-error'; code=$msg.error.code; err=$msg.error.message } }
                return @{ kind='ok'; result=$msg.result }
            }
            # 其他消息(通知)在此请求期间到达 -> 忽略, 继续等本请求响应
        }
        return @{ kind='timeout'; err="no response for $method in ${timeoutSec}s" }
    }

    # 读一条通知/任意行; $null=超时, 'EOF'=进程退出
    [object] ReadLine([int]$timeoutSec) {
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
        $remain = [Math]::Max(1, [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        try {
            $vt = $this.Out.ReadLineAsync($this.Cts.Token)
            $t = $vt.AsTask()
            $done = $t.WaitAsync([TimeSpan]::FromMilliseconds($remain))
            $done.Wait($remain + 500) | Out-Null
            $line = $t.Result
        } catch { return $null }
        if ($null -eq $line) { return 'EOF' }
        if (-not $line.Trim()) { return $null }
        try { return ($line | ConvertFrom-Json) } catch { return $null }
    }

    [void] Close() {
        try { if ($this.Cts) { $this.Cts.Cancel() } } catch {}
        try { if ($this.In) { $this.In.Close() } } catch {}
        try { if (-not $this.Proc.HasExited) { $this.Proc.Kill($true) } } catch {}
        try { $this.Proc.Dispose() } catch {}
    }
}

function Classify-RpcError([hashtable]$r) {
    $txt = "$($r.code) $($r.err)"
    if ($txt -match 'capacity|at capacity|429|overloaded|rate.?limit') { return 'capacity' }
    if ($r.code -eq -32001 -or $txt -match 'Server overloaded') { return 'overloaded' }
    if ($txt -match '-32601|method not found') { return 'method-not-found' }
    if ($txt -match 'not found|no such thread|unknown thread') { return 'thread-missing' }
    return 'unknown'
}

function Exit-With([int]$code, [string]$msg) { Log "$msg  [exit=$code]"; exit $code }

# ================= diagnose =================
if ($Command -eq 'diagnose') {
    Log "== diagnose: app-server stdio 通道 =="
    $c = [AppServerClient]::new()
    if (-not $c.Start($codexBin)) { Exit-With 10 "E1 app-server 启动失败: $($c.LastError)" }
    Log "app-server      : 进程已启动 pid=$($c.Proc.Id)"
    $r = $c.Request('initialize', @{ clientInfo=@{ name='desktop-feeder'; version='2.0' }; capabilities=@{ experimentalApi=$true } }, 10)
    if ($r.kind -eq 'ok') { Log "initialize      : OK userAgent=$($r.result.userAgent)" } else { $c.Close(); Exit-With 11 "E2 initialize 失败: $($r.kind) $($r.err)" }
    $c.Request('initialized', $null, 5) | Out-Null
    $r2 = $c.Request('thread/list', @{ limit=5; sortKey='updated_at'; sortDirection='desc' }, 15)
    if ($r2.kind -eq 'ok') {
        $n = @($r2.result.threads).Count
        Log "thread/list     : OK $n 个线程"
        @($r2.result.threads) | Select-Object -First 3 | ForEach-Object { Log "   - $($_.id)  $($_.title)" }
    } else { Log "thread/list     : $($r2.kind) $(Classify-RpcError $r2) (E3)" }
    $c.Close()
    Log "== diagnose 完成: 通道可用 =="
    exit 0
}

# ================= run =================
$task = if ($PromptFile) { Get-Content $PromptFile -Raw } elseif ($PromptText) { $PromptText } else { Exit-With 2 'run 需要 -PromptText 或 -PromptFile' }
$prompt = @"
$task

## Completion Protocol(严格)
全部目标真正完成后, 最后两行逐字输出:
$doneToken
$ConfirmText
未完成前不要输出上面两行。
"@

$client = [AppServerClient]::new()
$restarts = 0; $rounds = 0; $stalls = 0; $capacityHits = 0; $currentTurnId = $null; $threadId = $ThreadId

function Get-LastAssistantText([string]$threadId) {
    $sess = Get-ChildItem "$env:USERPROFILE\.codex\sessions" -Recurse -Filter "*$threadId*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $sess) { return '' }
    $last = $null
    foreach ($line in (Get-Content $sess.FullName -Tail 200)) {
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ($e.type -eq 'event_msg' -and $e.payload.type -eq 'agent_message' -and $e.payload.message) { $last = $e.payload.message }
        elseif ($e.type -eq 'response_item' -and $e.payload.role -eq 'assistant' -and $e.payload.content) {
            $t = ($e.payload.content | ForEach-Object { $_.text }) -join ''
            if ($t) { $last = $t }
        }
    }
    return $last
}

function Ensure-Server {
    # 服务器在跑且写者可用 -> 直接用
    try {
        if ($script:client.Proc -and -not $script:client.Proc.HasExited -and $script:client.In -and $script:client.In.BaseStream.CanWrite) { return }
    } catch {}
    $script:restarts++
    if ($script:restarts -gt 3) { Exit-With 10 'E1 app-server 重启超过3次' }
    Log "E1 app-server 不在运行, 重启(#$script:restarts)"
    try { $script:client.Close() } catch {}
    Start-Sleep -Seconds 2   # 退避, 防 E7 空转
    $script:client = [AppServerClient]::new()
    if (-not $script:client.Start($codexBin)) { Exit-With 10 "E1 启动失败: $($script:client.LastError)" }
    $r = $script:client.Request('initialize', @{ clientInfo=@{ name='desktop-feeder'; version='2.0' }; capabilities=@{ experimentalApi=$true } }, 10)
    if ($r.kind -ne 'ok') { Exit-With 11 "E2 握手失败: $($r.kind) $($r.err)" }
    $script:client.Request('initialized', $null, 5) | Out-Null
    Log "app-server 就绪 pid=$($script:client.Proc.Id)"
}

function Start-OrResumeThread {
    if ($script:threadId) {
        $r = $script:client.Request('thread/resume', @{ threadId=$script:threadId; cwd=$Cwd; model=$Model; approvalPolicy='never'; sandbox='workspace-write' }, 15)
        if ($r.kind -eq 'ok') { Log "thread/resume    : OK $script:threadId"; return }
        if ((Classify-RpcError $r) -eq 'thread-missing') { Log 'E3 线程不存在, 新建'; $script:threadId = $null }
        else { Log "thread/resume    : $($r.kind) $(Classify-RpcError $r)"; if ($r.kind -eq 'rpc-error') { } }
    }
    $r = $script:client.Request('thread/start', @{ cwd=$Cwd; model=$Model; approvalPolicy='never'; sandbox='workspace-write'; threadSource='appServer' }, 20)
    if ($r.kind -ne 'ok') { Exit-With 13 "线程创建失败: $($r.kind) $($r.err)" }
    $script:threadId = $r.result.thread.id
    Log "thread/start     : OK $script:threadId cwd=$Cwd"
}

function Send-Turn([string]$userText, [string]$steerTurnId) {
    $script:capacityHits = 0
    while ($true) {
        Ensure-Server
        $params = @{ threadId=$script:threadId; input=@(@{ type='text'; text=$userText }); model=$Model; approvalPolicy='never'; sandboxPolicy=@{ type='workspaceWrite' }; clientUserMessageId=('feeder-' + [guid]::NewGuid().ToString('N')) }
        $method = 'turn/start'
        if ($steerTurnId) { $params.expectedTurnId = $steerTurnId; $method = 'turn/steer' }
        $r = $client.Request($method, $params, 30)
        if ($r.kind -eq 'ok') { $script:currentTurnId = $r.result.turn.id; return }
        switch -Regex ($r.kind) {
            '^(timeout|eof|io-error)$' {
                Log "E7 $($r.kind): $($r.err) -> 重启续跑"
                try { $script:client.Close() } catch {}
                Start-Sleep -Seconds 2
                Ensure-Server
                continue
            }
            '^rpc-error$' {
                switch (Classify-RpcError $r) {
                    'capacity' {
                        $script:capacityHits++
                        $bo = [Math]::Min(120, 10 * [Math]::Pow(2, $script:capacityHits))
                        Log "E3 capacity #$($script:capacityHits): $($r.err) -> ${bo}s 退避(锁定 sol, 不换模型)"
                        Start-Sleep -Seconds $bo
                        continue
                    }
                    'overloaded' { Log 'E3 overloaded(-32001) -> 10s 退避重试'; Start-Sleep -Seconds 10; continue }
                    'thread-missing' { Log 'E3 线程丢失 -> 重建'; Start-OrResumeThread; continue }
                    'method-not-found' { Exit-With 12 "E3 协议版本不符: $($r.err)" }
                    default { Exit-With 13 "E3 RPC 错误: code=$($r.code) $($r.err)" }
                }
            }
            default { Exit-With 13 "E3 请求失败: $($r.kind) $($r.err)" }
        }
    }
}

Log "== 桌面端喂料 v2 启动 model=$Model cwd=$Cwd confirm=$ConfirmText =="
Log "doneToken=$doneToken"
Ensure-Server
Start-OrResumeThread
Send-Turn $prompt $null
Log "turn/start OK: $currentTurnId, 监控中(stall=${StallSec}s timeout=${RoundTimeoutSec}s)"

while ($script:rounds -lt $MaxRounds) {
    $script:rounds++
    $turnDone = $false; $lastProgress = [DateTime]::UtcNow
    $watchUntil = [DateTime]::UtcNow.AddSeconds($RoundTimeoutSec)
    while (-not $turnDone -and [DateTime]::UtcNow -lt $watchUntil) {
        $n = $client.ReadLine(3)
        if ($null -eq $n) {
            if (([DateTime]::UtcNow - $lastProgress).TotalSeconds -gt $StallSec) {
                $script:stalls++
                if ($script:stalls -ge 10) {
                    Log "E4 连续停滞10次 -> interrupt + 重建线程"
                    $client.Request('turn/interrupt', @{ threadId=$script:threadId; turnId=$script:currentTurnId }, 5) | Out-Null
                    $script:stalls = 0; $script:threadId = $null; Start-OrResumeThread
                } else {
                    Log "E4 停滞#$script:stalls(${StallSec}s 无通知) -> turn/steer 喂继续"
                    Send-Turn '继续: 检查进度; 未完成则继续执行; 全部完成则输出完成协议' $script:currentTurnId
                    $lastProgress = [DateTime]::UtcNow
                }
                break
            }
            continue
        }
        if ($n -eq 'EOF') { Log "E7 app-server 退出 -> 重启续跑"; $client.Close(); Ensure-Server; break }
        if ($n.method -eq 'turn/completed') { Log "turn/completed   : turn=$($n.params.turnId)"; $turnDone = $true }
        elseif ($n.method -eq 'turn/started' -and $n.params.turnId) { $script:currentTurnId = $n.params.turnId; $lastProgress = [DateTime]::UtcNow }
        elseif ($n.method -match 'item/|delta|thread/statusChanged|reasoning') { $lastProgress = [DateTime]::UtcNow }
        elseif ($n.method -match 'error|Error|failed') { Log "E3 服务端通知: $($n.method) $($n | ConvertTo-Json -Compress -Depth 4)" }
    }
    if (-not $turnDone) {
        Log "E5 单轮超时 ${RoundTimeoutSec}s -> interrupt + 重开(锁定 sol)"
        $client.Request('turn/interrupt', @{ threadId=$script:threadId; turnId=$script:currentTurnId }, 5) | Out-Null
        Send-Turn $prompt $null
        continue
    }
    # 完成检测: 直接读会话 JSONL 的最后一条 agent_message(跨进程可靠)
    $finalText = Get-LastAssistantText $script:threadId
    Log "最后消息: $(if($finalText){$finalText.Substring(0,[Math]::Min(90,$finalText.Length))}else{'(空)'})"
    if ($finalText -match [regex]::Escape($ConfirmText)) {
        Log "完成协议命中 (round=$script:rounds) -> completed"
        $client.Close()
        Log "== 完成 rounds=$script:rounds stalls=$script:stalls restarts=$script:restarts thread=$script:threadId =="
        exit 0
    }
    Log "round#$script:rounds 未完成 -> 新开 turn 继续"
    Send-Turn '继续: 检查进度; 未完成则继续执行; 全部完成则输出完成协议' $null
}
$client.Close()
Exit-With 2 "未确认完成 rounds=$script:rounds"
