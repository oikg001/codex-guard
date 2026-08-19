# codex-watch-background.ps1 — 把桌面 watch 变成后台常驻任务
# 用法:
#   start   后台启动 watch(隐藏窗口, 日志落盘, PID 记录), 立即返回
#   status  查运行状态 + 最近日志
#   logs    看完整日志尾部
#   stop    停掉后台 watch
<#
.SYNOPSIS
  后台常驻运行 codex-desktop-drive.ps1 watch。
.PARAMETER Command
  start|status|logs|stop
.PARAMETER WatchSeconds
  单次 watch 时长秒(默认 21600=6h; 到点自动重启, 永续)
.PARAMETER RetryModel
  容量错误时切换的模型
.PARAMETER Loop
  start 时循环重启(默认开): watch 超时/退出后自动再拉起
#>
[CmdletBinding()]
param(
    [ValidateSet('start','status','logs','stop')]
    [string]$Command = 'status',
    [int]$WatchSeconds = 21600,
    [string]$RetryModel = 'gpt-5.6-sol',   # 固定 sol
    [switch]$Loop,
    [switch]$AutoMinimize
)
$ErrorActionPreference = 'Stop'
$dir = $env:USERPROFILE
$drive = Join-Path $dir 'codex-desktop-drive.ps1'
$logFile = Join-Path $dir '.codex-watch.log'
$errFile = Join-Path $dir '.codex-watch.err.log'
$pidFile = Join-Path $dir '.codex-watch.pid'

function Get-RunningPid {
    if (-not (Test-Path $pidFile)) { return $null }
    $saved = Get-Content $pidFile -ErrorAction SilentlyContinue
    foreach ($line in $saved) {
        if ($line -match '^\d+') {
            $p = Get-Process -Id ([int]$line) -ErrorAction SilentlyContinue
            if ($p) { return [int]$line }
        }
    }
    return $null
}

function Read-LogTail([string]$file, [int]$n) {
    if (-not (Test-Path $file)) { return }
    Get-Content $file -Tail $n -Encoding UTF8   # 日志现在由 drive 直写 UTF-8, 不再有 GBK 乱码
}

switch ($Command) {
    'start' {
        $existing = Get-RunningPid
        if ($existing) { Write-Host "已在运行 pid=$existing, 无需重复启动(先 stop 再 start)"; exit 0 }
        if (-not (Test-Path $drive)) { Write-Host "找不到 $drive"; exit 1 }
        # 启动参数: 隐藏窗口 + 输出重定向到日志
        $minArg = @()
        if ($AutoMinimize) { $minArg = @('-AutoMinimize') }
        $innerArgs = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $drive, '-Command', 'watch',
            '-WatchSeconds', "$WatchSeconds", '-RetryModel', $RetryModel
        ) + $minArg
        if ($Loop) {
            # 循环模式: 外层再包一层 while, watch 超时后自动重启(日志由 drive 直写 UTF-8, 无需重定向)
            $loopScript = Join-Path $dir '.codex-watch-loop.ps1'
            $minFlag = if ($AutoMinimize) { '-AutoMinimize' } else { '' }
            @"
`$ErrorActionPreference = 'Stop'
while (`$true) {
    `$p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$drive','-Command','watch','-WatchSeconds','$WatchSeconds','-RetryModel','$RetryModel','$minFlag') -WindowStyle Hidden -PassThru
    `$p.WaitForExit()
    Start-Sleep -Seconds 10
}
"@ | Set-Content $loopScript -Encoding UTF8
            $innerArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', $loopScript)
        }
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $innerArgs -WindowStyle Hidden -PassThru
        Set-Content $pidFile -Value $p.Id -Encoding ASCII
        Write-Host "后台 watch 已启动 pid=$($p.Id) (loop=$Loop, watchSeconds=$WatchSeconds, retryModel=$RetryModel, autoMinimize=$AutoMinimize)"
        Write-Host "日志: $logFile"
        Write-Host "状态: .\codex-watch-background.ps1 -Command status"
        exit 0
    }
    'status' {
        $procId = Get-RunningPid
        if ($procId) { Write-Host "后台 watch: RUNNING pid=$procId" } else { Write-Host "后台 watch: 未运行" }
        Write-Host "--- 日志尾部 ---"
        Read-LogTail $logFile 12
        if ((Test-Path $errFile) -and (Get-Item $errFile).Length -gt 0) { Write-Host "--- stderr 尾部 ---"; Read-LogTail $errFile 5 }
        exit 0
    }
    'logs' {
        Read-LogTail $logFile 60
        exit 0
    }
    'stop' {
        $procId = Get-RunningPid
        if ($procId) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue; Write-Host "已停止 pid=$procId" } else { Write-Host "没有在运行的后台 watch" }
        # 顺便杀循环壳与残留 pwsh watch 进程
        Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'codex-desktop-drive\.ps1.*watch' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "清理残留 pid=$($_.ProcessId)" }
        exit 0
    }
}
