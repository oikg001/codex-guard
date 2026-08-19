# codex-relay-switch.ps1 — 容量根治: 切换上游 relay + 重启 super-instruct bridge
# 原理: "Selected model is at capacity" 来自上游 relay(tonikcapi.xyz 等)模型池饱和。
#       bridge(super-instruct.exe)启动时读取 ~/.codex/relay_url.txt 作为上游, 换 relay = 换容量池。
# 命令:
#   status            现状: relay_url.txt / bridge 进程 / 8080 / config 指向 / 探针结果
#   set -Url <relay>  换 relay: 备份 -> 写 relay_url.txt -> 重启 bridge -> 探针验证(失败自动回滚)
#   probe             通过 8080 发最小请求, 分类上游回复(overloaded/capacity/正常/错误)
<#
.SYNOPSIS
  切换 codex bridge 的上游 relay 以绕开容量饱和。
.PARAMETER Command
  status | set | probe
.PARAMETER Url — set 的目标 relay(如 https://ai.zfb.la/v1)
.PARAMETER Model — 探针用模型名
#>
[CmdletBinding()]
param(
    [ValidateSet('status','set','probe')]
    [string]$Command = 'status',
    [string]$Url,
    [string]$Model = 'gpt-5.6-sol'
)
$ErrorActionPreference = 'Stop'
$codexHome = "$env:USERPROFILE\.codex"
$relayFile = Join-Path $codexHome 'relay_url.txt'
$configFile = Join-Path $codexHome 'config.toml'
$bridgeExe = 'C:\Users\oikg0\AppData\Local\Super-Instruct\super-instruct.exe'
$bridgeSrc = 'C:\Users\oikg0\AppData\Local\Super-Instruct\bridge.md'

function Log([string]$m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

function Get-BridgeProcess { return (Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'super-instruct' } | Select-Object -First 1) }

function Test-Port([int]$port, [int]$ms = 3000) {
    try { $c = [System.Net.Sockets.TcpClient]::new(); $t = $c.ConnectAsync('127.0.0.1', $port); if ($t.Wait($ms) -and $c.Connected) { $c.Close(); return $true } else { $c.Close(); return $false } } catch { return $false }
}

# 探针: 走 8080 发最小请求(带 auth.json 认证), 返回分类: ok | overloaded | capacity | error
function Invoke-Probe {
    try {
        $authKey = $null
        try { $authKey = (Get-Content (Join-Path $codexHome 'auth.json') -Raw | ConvertFrom-Json).OPENAI_API_KEY } catch {}
        $headers = @{}
        if ($authKey) { $headers.Authorization = "Bearer $authKey" }
        $body = @{ model=$Model; input='ping' } | ConvertTo-Json -Compress
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/responses' -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 60 -UseBasicParsing
        $txt = $r.Content
        if ($txt -match '"error"\s*:\s*null') { $txt = $txt -replace '"error"\s*:\s*null', '' }   # 去掉空的 error 字段
        if ($txt -match 'overloaded|at capacity|capacity|繁忙|过载') { return 'overloaded' }
        if ($txt -match '"error"\s*:\s*\{|"type"\s*:\s*"error"|failed|unauthorized|invalid_api_key') { return 'error' }
        return 'ok'
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { return "http-$([int]$resp.StatusCode)" } else { return "conn-fail" }
    }
}

# 部署自修复: 确保 bridge.md 与 config 指向 8080(幂等)
function Repair-Deployment {
    $changed = $false
    if (-not (Test-Path (Join-Path $codexHome 'bridge.md')) -and (Test-Path $bridgeSrc)) {
        Copy-Item $bridgeSrc (Join-Path $codexHome 'bridge.md') -Force; $changed = $true; Log "修复: bridge.md 已还原"
    }
    $c = Get-Content $configFile -Raw
    if ($c -notmatch 'model_instructions_file\s*=\s*"\./bridge\.md"') {
        $c = $c -replace '(?m)^(model\s*=)', "model_instructions_file = `"./bridge.md`"`n`$1"; $changed = $true
    }
    if ($c -match 'base_url\s*=\s*"(?!http://127\.0\.0\.1:8080")[^"]*"') {
        $c = $c -replace '(?m)(base_url\s*=\s*")[^"]*(")', '$1http://127.0.0.1:8080$2'; $changed = $true
    }
    if ($changed) { Set-Content $configFile -Value $c -Encoding UTF8; Log "修复: config.toml 已指向 8080 + bridge.md" }
}

function Restart-Bridge {
    $proc = Get-BridgeProcess
    if ($proc) {
        Log "停止旧 bridge pid=$($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 20; $i++) { if (-not (Test-Port 8080 500)) { break }; Start-Sleep -Milliseconds 500 }
    }
    Start-Sleep -Seconds 2
    Log "启动新 bridge(relay=$((Get-Content $relayFile)))"
    $p = Start-Process -FilePath $bridgeExe -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (Test-Port 8080 500) { break } }
    if (-not (Test-Port 8080 1000)) { Log "!! 8080 未起来, 执行部署自修复"; Repair-Deployment; Start-Sleep -Seconds 3 }
    Start-Sleep -Seconds 3
    Repair-Deployment   # 幂等兜底
    Log "bridge pid=$($p.Id) 8080=$(Test-Port 8080 1000)"
}

# ================= status =================
if ($Command -eq 'status') {
    Log "relay_url.txt  : $((Get-Content $relayFile -ErrorAction SilentlyContinue))"
    $proc = Get-BridgeProcess
    Log "bridge 进程    : $(if($proc){"pid=$($proc.ProcessId)"}else{'未运行'})"
    Log "8080           : $(Test-Port 8080)"
    $cfg = Select-String -Path $configFile -Pattern '^\s*base_url\s*=' | Select-Object -Last 1
    Log "config base_url: $(if($cfg){$cfg.Line.Trim()}else{'?'})"
    Log "bridge.md      : $(Test-Path (Join-Path $codexHome 'bridge.md'))"
    Log "--- 探针 ---"
    Log "上游回复分类   : $(Invoke-Probe)"
    exit 0
}

# ================= probe =================
if ($Command -eq 'probe') {
    Log "探针模型=$Model -> $(Invoke-Probe)"
    exit 0
}

# ================= set =================
if ($Command -eq 'set') {
    if (-not $Url) { throw 'set 需要 -Url' }
    if ($Url -notmatch '^https?://') { throw "Url 需以 http(s):// 开头: $Url" }
    $oldRelay = Get-Content $relayFile -ErrorAction SilentlyContinue
    $bakRelay = "$relayFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $relayFile $bakRelay -ErrorAction SilentlyContinue
    Log "备份 relay: $bakRelay ($oldRelay)"
    Set-Content $relayFile -Value $Url -Encoding ASCII
    Log "relay_url.txt -> $Url"
    Restart-Bridge
    Start-Sleep -Seconds 2
    $probe = Invoke-Probe
    Log "新 relay 探针: $probe"
    if ($probe -eq 'ok') { Log "切换成功: 上游 $Url 正常响应"; exit 0 }
    if ($probe -eq 'overloaded') { Log "新 relay 也 overloaded(上游整体饱和); 保留切换, 建议稍后重试或换更多 relay"; exit 3 }
    # 失败回滚
    Log "切换后异常($probe), 回滚到旧 relay: $oldRelay"
    Set-Content $relayFile -Value $oldRelay -Encoding ASCII
    Restart-Bridge
    Log "回滚完成, 探针: $(Invoke-Probe)"
    exit 4
}
