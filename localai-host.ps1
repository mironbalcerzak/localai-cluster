# LocalAI host (Windows, Docker Desktop): the server of the cluster. Run via localai-host.bat.
#
#   localai-host.bat [start]     start (default); creates docker\host\.env on first run
#   localai-host.bat stop | update | status | logs [service]
#   localai-host.bat worker-env  write docker\worker\.env to hand out to worker PCs
#   localai-host.bat nodes       list the workers
#   localai-host.bat api-key     print the API key for clients
param([string]$Command = "start", [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ComposeFile = Join-Path $Root "docker\host\docker-compose.yml"
$EnvFile = Join-Path $Root "docker\host\.env"
$WorkerEnv = Join-Path $Root "docker\worker\.env"
$Scheduling = Join-Path $Root "docker\host\scheduling.yaml"
$DefaultPort = "23422"

function Fail($msg) { Write-Host "Error: $msg" -ForegroundColor Red; exit 1 }

function Read-EnvFile {
    $values = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $values[$Matches[1]] = ($Matches[2] -replace '\s+#.*$', '').Trim().Trim('"')
        }
    }
    return $values
}

# Text file with LF line endings and no BOM (what docker compose expects).
function Write-PlainFile($path, [string[]]$lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

function New-Secret([int]$bytes = 24) {
    $b = New-Object byte[] $bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return -join ($b | ForEach-Object { $_.ToString("x2") })
}

function Get-LanIp {
    try {
        return (Find-NetRoute -RemoteIPAddress 1.1.1.1 | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
    } catch { return $null }
}

function Get-Port { $p = (Read-EnvFile)["LOCALAI_PORT"]; if ($p) { $p } else { $DefaultPort } }
function Get-Url { "http://127.0.0.1:$(Get-Port)" }

function Invoke-Compose { & docker compose -f $ComposeFile @args; if ($LASTEXITCODE -ne 0) { Fail "docker compose $args failed" } }

function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker Desktop is not installed (see README.md)" }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop is not running: start it and try again" }
}

# Settings and secrets, created once.
function Initialize-Env {
    if (Test-Path $EnvFile) { return }
    Write-PlainFile $EnvFile @(
        "COMPOSE_PROJECT_NAME=localai",
        "LOCALAI_PORT=$DefaultPort",
        "# 0.0.0.0 = reachable from the LAN (workers register here). The web UI needs a login.",
        "LOCALAI_BIND=0.0.0.0",
        "LOCALAI_REGISTRATION_TOKEN=$(New-Secret)",
        "POSTGRES_PASSWORD=$(New-Secret)",
        "# Static key for API clients: Authorization: Bearer <key>",
        "LOCALAI_API_KEY=sk-$(New-Secret)",
        "# Parallel requests the GPU of this PC serves at once.",
        "LLAMACPP_PARALLEL=5",
        "LOCALAI_LOCAL_NODE_NAME=$env:COMPUTERNAME"
    )
    Write-Host "Created $EnvFile"
}

function Wait-Ready {
    Write-Host -NoNewline "Waiting for LocalAI"
    for ($i = 0; $i -lt 90; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$(Get-Url)/readyz" -TimeoutSec 5 | Out-Null
            Write-Host " OK"; return
        } catch { Write-Host -NoNewline "."; Start-Sleep -Seconds 2 }
    }
    Write-Host ""
    Fail "LocalAI did not get ready. See: localai-host.bat logs frontend"
}

function Write-WorkerEnv {
    $cfg = Read-EnvFile
    $ip = Get-LanIp
    if (-not $ip) { Fail "cannot detect this PC's LAN IP" }
    $model = (Select-String -Path $Scheduling -Pattern '^- model_name:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
    if (-not $model) { $model = "gemma-4-12b-it-Q4_K_M" }
    Write-PlainFile $WorkerEnv @(
        "# Created by 'localai-host.bat worker-env'. Same file for every worker PC.",
        "",
        "# --- LocalAI server ---",
        "LOCALAI_SERVER=$ip",
        "LOCALAI_SERVER_PORT=$(Get-Port)",
        "LOCALAI_REGISTRATION_TOKEN=$($cfg["LOCALAI_REGISTRATION_TOKEN"])",
        "# Lets the start scripts send a test request after starting.",
        "LOCALAI_API_KEY=$($cfg["LOCALAI_API_KEY"])",
        "",
        "# Model the start scripts test with (workers load what docker/host/scheduling.yaml says).",
        "LOCALAI_MODEL=$model",
        "",
        "# Parallel requests this GPU serves at once",
        "LLAMACPP_PARALLEL=$($cfg["LLAMACPP_PARALLEL"])",
        "",
        "# --- this PC: leave empty for auto-detection ---",
        "WORKER_IP=",
        "WORKER_NAME="
    )
    Write-Host "Written: $WorkerEnv  (holds the join token and API key)"
    Write-Host "Server address in it: $ip. Give this PC a fixed IP in the router, or rerun this when it changes."
    Write-Host "On each worker PC: check out this repo, put the file at docker\worker\.env, run localai-worker.bat / .sh"
}

function Assert-Env { if (-not (Test-Path $EnvFile)) { Fail "start the host once first" } }

switch ($Command) {
    "start" {
        Test-Docker; Initialize-Env
        Invoke-Compose up -d
        Wait-Ready
        Write-Host "LocalAI host running: $(Get-Url)   LAN: http://$(Get-LanIp):$(Get-Port)" -ForegroundColor Green
        Write-Host "First visit: sign up; the first account becomes admin."
        Write-Host "API key: localai-host.bat api-key   Workers: localai-host.bat nodes   Worker settings: localai-host.bat worker-env"
    }
    "update" { Test-Docker; Initialize-Env; Invoke-Compose pull; Invoke-Compose up -d; Wait-Ready }
    "stop" { Test-Docker; Invoke-Compose down }
    "status" { Test-Docker; Invoke-Compose ps }
    "logs" { Test-Docker; & docker compose -f $ComposeFile logs -f --tail 100 @Rest }
    "worker-env" { Assert-Env; Write-WorkerEnv }
    "api-key" { Assert-Env; (Read-EnvFile)["LOCALAI_API_KEY"] }
    "nodes" {
        Assert-Env
        try {
            $r = Invoke-RestMethod -Uri "$(Get-Url)/api/nodes" -Headers @{ Authorization = "Bearer $((Read-EnvFile)["LOCALAI_API_KEY"])" }
        } catch { Fail "host not reachable at $(Get-Url)" }
        $list = if ($r.nodes) { $r.nodes } else { $r }
        $list | Select-Object name, address, status | Format-Table -AutoSize
    }
    default { Write-Host "Usage: localai-host.bat [start|stop|update|status|logs|worker-env|nodes|api-key]"; exit 1 }
}
