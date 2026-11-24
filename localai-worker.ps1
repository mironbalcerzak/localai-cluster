# LocalAI cluster worker for Windows (Docker Desktop). Run via localai-worker.bat.
#
#   localai-worker.bat [start]   build, start and test (default)
#   localai-worker.bat stop | logs | status | update
#
# Needs docker\worker\.env (copy of .env.example with the server values filled in).
param([string]$Command = "start")

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ComposeFile = Join-Path $Root "docker\worker\docker-compose.yml"
$EnvFile = Join-Path $Root "docker\worker\.env"
$Container = "localai-worker"

function Fail($msg) { Write-Host "Error: $msg" -ForegroundColor Red; exit 1 }

# KEY=value pairs from docker\worker\.env (comments, quotes and spaces stripped).
function Read-EnvFile {
    $values = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $v = ($Matches[2] -replace '\s+#.*$', '').Trim().Trim('"')
            $values[$Matches[1]] = $v
        }
    }
    return $values
}

function Invoke-Compose { & docker compose -f $ComposeFile @args; if ($LASTEXITCODE -ne 0) { Fail "docker compose $args failed" } }

function Test-Prereqs {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker Desktop is not installed (see README.md)" }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { Fail "Docker Desktop is not running: start it and try again" }
    if (-not (Test-Path $EnvFile)) { Fail "missing $EnvFile : put the configured .env there (template: .env.example)" }
    $cfg = Read-EnvFile
    if (-not $cfg["LOCALAI_SERVER"]) { Fail "LOCALAI_SERVER is empty in docker\worker\.env" }
    if (-not $cfg["LOCALAI_REGISTRATION_TOKEN"]) { Fail "LOCALAI_REGISTRATION_TOKEN is empty in docker\worker\.env" }
    return $cfg
}

# WORKER_IP / WORKER_NAME: from .env, else detected. Set in the environment for compose.
function Set-Identity($cfg) {
    $ip = $cfg["WORKER_IP"]
    if (-not $ip) {
        try {
            $ip = (Find-NetRoute -RemoteIPAddress $cfg["LOCALAI_SERVER"] |
                Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
        } catch { $ip = $null }
        if (-not $ip) { Fail "cannot detect this PC's IP towards $($cfg["LOCALAI_SERVER"]); set WORKER_IP in docker\worker\.env" }
    }
    $name = $cfg["WORKER_NAME"]
    if (-not $name) { $name = $env:COMPUTERNAME }
    $env:WORKER_IP = $ip
    $env:WORKER_NAME = $name
}

function Get-ServerUrl($cfg) {
    $port = $cfg["LOCALAI_SERVER_PORT"]; if (-not $port) { $port = "23422" }
    return "http://$($cfg["LOCALAI_SERVER"]):$port"
}

function Wait-Registered($cfg) {
    Write-Host -NoNewline "Waiting for the worker to register with $($cfg["LOCALAI_SERVER"])"
    for ($i = 0; $i -lt 90; $i++) {
        $logs = (& docker logs $Container 2>&1 | Out-String)
        if ($logs -match "Worker ready") { Write-Host " OK"; return }
        Write-Host -NoNewline "."; Start-Sleep -Seconds 2
    }
    Write-Host ""
    Write-Host "The worker did not register. Last log lines:" -ForegroundColor Red
    & docker logs --tail 15 $Container
    Fail "check that the server is running and $(Get-ServerUrl $cfg) opens from this PC"
}

# End-to-end check: one chat request for LOCALAI_MODEL through the server.
function Test-Request($cfg) {
    $key = $cfg["LOCALAI_API_KEY"]; $model = $cfg["LOCALAI_MODEL"]
    if (-not $key -or -not $model) {
        Write-Host "Skipping the test request (LOCALAI_API_KEY or LOCALAI_MODEL empty in docker\worker\.env)."
        return
    }
    $url = "$(Get-ServerUrl $cfg)/v1/chat/completions"
    $body = @{ model = $model; max_tokens = 8; messages = @(@{ role = "user"; content = "Say hi" }) } | ConvertTo-Json -Depth 4
    Write-Host "Test request for '$model' (the first one can take minutes while the model is copied)..."
    for ($i = 0; $i -lt 10; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -Method Post -TimeoutSec 900 `
                -Headers @{ Authorization = "Bearer $key" } -ContentType "application/json" -Body $body | Out-Null
            Write-Host "Cluster answered with ${model}: OK" -ForegroundColor Green
            return
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            switch ($code) {
                503 { Write-Host "  model still loading, retrying in 30s..."; Start-Sleep -Seconds 30 }
                401 { Fail "test request rejected: LOCALAI_API_KEY is wrong" }
                404 { Fail "test request: model '$model' is not known to the server" }
                default { Fail "test request failed: $($_.Exception.Message)" }
            }
        }
    }
    Write-Host "Model still loading after several minutes; check later with: localai-worker.bat logs"
}

switch ($Command) {
    "start" {
        $cfg = Test-Prereqs; Set-Identity $cfg
        Write-Host "Starting worker '$env:WORKER_NAME' ($env:WORKER_IP). The first start downloads ~10 GB."
        Invoke-Compose up -d --build
        Wait-Registered $cfg
        Test-Request $cfg
        Write-Host "Done. The worker restarts with Docker Desktop automatically. Logs: localai-worker.bat logs"
    }
    "update" {
        $cfg = Test-Prereqs; Set-Identity $cfg
        Invoke-Compose build --pull
        Invoke-Compose up -d
        Wait-Registered $cfg
    }
    "stop" { Invoke-Compose down }
    "logs" { & docker logs -f --tail 100 $Container }
    "status" { & docker ps -a --filter "name=^/$Container$" --format "{{.Names}}: {{.Status}}" }
    default { Write-Host "Usage: localai-worker.bat [start|stop|logs|status|update]"; exit 1 }
}
