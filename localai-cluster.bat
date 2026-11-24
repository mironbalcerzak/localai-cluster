@echo off
rem LocalAI cluster. Runs in the foreground; Ctrl+C stops it.
rem
rem   localai-cluster.bat host     run the server (API + web UI) and use this PC's GPU.
rem                        The first run creates .env next to this script.
rem   localai-cluster.bat worker   lend this PC's GPU to the host. Needs the host's .env
rem                        copied next to this script.
rem   localai-cluster.bat diagnose
rem                        check the connections this PC needs: as host (LocalAI, NATS, every
rem                        registered worker reachable from here) or as worker (host, token,
rem                        registration, containers, model sync), and whether this PC's
rem                        models run on its GPU. Read-only.
rem   localai-cluster.bat model-capacity [model]
rem                        print how many requests the cluster serves at once for a model
rem                        (slots per PC x PCs with it loaded; LOCALAI_MODEL by default).
rem                        Only the number goes to stdout; details go to stderr.
rem   localai-cluster.bat model-list-all
rem                        list every model of the host as "<model><TAB><capacity>".
rem   localai-cluster.bat useChatCompletions [prompt] [model] [worker]
rem                        send a prompt to the cluster (/v1/chat/completions) and print the
rem                        reply. Without a prompt (or with "-") it is read from stdin. The
rem                        model is LOCALAI_MODEL by default ("" for the default too). With a
rem                        worker name, the request runs on that PC (for diagnosing). The PC
rem                        that served it goes to stderr.
setlocal EnableExtensions
set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%.env"

if /i "%~1"=="host" goto :host
if /i "%~1"=="worker" goto :worker
if /i "%~1"=="diagnose" goto :diagnose
if /i "%~1"=="model-capacity" goto :model_capacity
if /i "%~1"=="model-list-all" goto :model_list_all
if /i "%~1"=="useChatCompletions" goto :use_chat_completions
echo Usage: %~nx0 host^|worker^|diagnose^|model-capacity [model]^|model-list-all^|useChatCompletions [prompt] [model] [worker]
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b 2

rem ---------------------------------------------------------------- host
:host
call :check_docker || exit /b 1
if exist "%ENV_FILE%" goto :host_run
call :create_env || exit /b 1
:host_run
call :load_env
set "LOCALAI_LOCAL_NODE_NAME=%COMPUTERNAME%"
echo LocalAI host: http://127.0.0.1:%LOCALAI_PORT%  - LAN: http://%LOCALAI_SERVER%:%LOCALAI_PORT%
echo No login or API key needed. Missing models are installed on start. Ctrl+C stops it.
docker compose -p localai --env-file "%ENV_FILE%" -f "%ROOT%docker\host\docker-compose.yml" up
exit /b %ERRORLEVEL%

rem ---------------------------------------------------------------- worker
:worker
call :check_docker || exit /b 1
if exist "%ENV_FILE%" goto :worker_env_ok
echo Error: missing "%ENV_FILE%": copy the .env from the host next to this script
exit /b 1
:worker_env_ok
call :load_env
if defined LOCALAI_SERVER goto :worker_server_ok
echo Error: LOCALAI_SERVER is empty in "%ENV_FILE%"
exit /b 1
:worker_server_ok
if not defined WORKER_IP call :ip_towards %LOCALAI_SERVER% WORKER_IP
if defined WORKER_IP goto :worker_ip_ok
echo Error: cannot detect this PC's IP towards %LOCALAI_SERVER%; set WORKER_IP in "%ENV_FILE%"
exit /b 1
:worker_ip_ok
if not defined WORKER_NAME set "WORKER_NAME=%COMPUTERNAME%"
echo LocalAI worker '%WORKER_NAME%' (%WORKER_IP%) -^> host %LOCALAI_SERVER%. Ctrl+C stops it.
docker compose -p localai-worker --env-file "%ENV_FILE%" -f "%ROOT%docker\worker\docker-compose.yml" up --build
exit /b %ERRORLEVEL%

rem ---------------------------------------------------------------- diagnose
rem The checks are PowerShell, kept at the end of this file after the DIAGNOSE marker line:
rem cmd never runs past the last "exit /b", and this reads that part and runs it.
:diagnose
set "DIAG_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = [IO.File]::ReadAllText($env:DIAG_SELF); $i = $t.IndexOf('rem DIAGNOSE' + '-POWERSHELL'); $i = $t.IndexOf([char]10, $i) + 1; & ([scriptblock]::Create($t.Substring($i)))"
exit /b %ERRORLEVEL%

rem ---------------------------------------------------------------- model-capacity / model-list-all
rem Both ask the host's API, so they work on any PC with the .env (the host's proxy adds the
rem API key, so requests need none). CAP_PS holds the shared
rem PowerShell: Cap $model -> slots per PC ("parallel:N" in the effective config, else 1),
rem PCs with the model loaded, and requests running on them now.
:model_capacity
call :cap_init || exit /b 1
set "CAP_MODEL=%~2"
if not defined CAP_MODEL set "CAP_MODEL=%LOCALAI_MODEL%"
powershell -NoProfile -Command "%CAP_PS% $m=$env:CAP_MODEL; $r = Cap $m; [Console]::Error.WriteLine(\"model ${m}: $($r.Slots) slots/PC x $($r.Replicas) PCs loaded, $($r.InFlight) requests running\"); Write-Output ($r.Slots * $r.Replicas)"
exit /b %ERRORLEVEL%

:model_list_all
call :cap_init || exit /b 1
powershell -NoProfile -Command "%CAP_PS% try { $ms = (Invoke-RestMethod -TimeoutSec 10 ($u+'/v1/models')).data } catch { Fail \"cannot read the models from $u\" }; foreach ($x in $ms) { $r = Cap $x.id; Write-Output ($x.id + \"`t\" + ($r.Slots * $r.Replicas)) }"
exit /b %ERRORLEVEL%

:cap_init
if exist "%ENV_FILE%" goto :cap_env_ok
echo Error: missing "%ENV_FILE%" 1>&2
exit /b 1
:cap_env_ok
call :load_env
set "CAP_PS=$u='http://%LOCALAI_SERVER%:%LOCALAI_PORT%'; function Fail($t) { [Console]::Error.WriteLine('Error: ' + $t); exit 1 }; function Cap($m) { try { $c = Invoke-RestMethod -TimeoutSec 10 ($u+'/api/models/config-json/'+[uri]::EscapeDataString($m)) } catch { Fail ('cannot read the config of ' + $m + ' from ' + $u) }; try { $n = Invoke-RestMethod -TimeoutSec 10 ($u+'/api/nodes/models') } catch { Fail ('cannot read the loaded models from ' + $u) }; $s = 1; foreach ($o in @($c.options)) { if ($o -match '^(n_)?parallel:(\d+)$') { $s = [int]$Matches[2]; break } }; $l = @($n | Where-Object { $_.model_name -eq $m -and $_.state -eq 'loaded' }); $f = ($l | Measure-Object -Property in_flight -Sum).Sum; if (-not $f) { $f = 0 }; [pscustomobject]@{ Slots = $s; Replicas = $l.Count; InFlight = $f } };"
exit /b 0

rem ---------------------------------------------------------------- useChatCompletions
rem The prompt and model reach PowerShell as environment variables, so their quotes and
rem special characters need no escaping. Exit codes: 1 error, 3 reply cut off by the token limit.
:use_chat_completions
call :cap_init || exit /b 1
set "CHAT_PROMPT=%~2"
set "CHAT_MODEL=%~3"
set "CHAT_WORKER=%~4"
if not defined CHAT_MODEL set "CHAT_MODEL=%LOCALAI_MODEL%"
powershell -NoProfile -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false; $p = $env:CHAT_PROMPT; if (-not $p -or $p -eq '-') { $p = [Console]::In.ReadToEnd() }; if (-not $p.Trim()) { [Console]::Error.WriteLine('Error: empty prompt'); exit 1 }; $body = @{ model = $env:CHAT_MODEL; stream = $false; messages = @(@{ role = 'user'; content = $p }) } | ConvertTo-Json -Depth 5; $h = @{}; if ($env:CHAT_WORKER) { $h['X-Cluster-Worker'] = $env:CHAT_WORKER }; $u = 'http://' + $env:LOCALAI_SERVER + ':' + $env:LOCALAI_PORT + '/v1/chat/completions'; try { $w = Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 600 -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) $u } catch { $m = $_.ErrorDetails.Message; if (-not $m) { $m = $_.Exception.Message }; [Console]::Error.WriteLine('Error: ' + $m); exit 1 }; $r = [Text.Encoding]::UTF8.GetString($w.RawContentStream.ToArray()) | ConvertFrom-Json; $served = $w.Headers['X-Cluster-Worker-Served']; if ($served) { [Console]::Error.WriteLine('served by: ' + $served) }; $c = $r.choices[0]; if ($c.message.content) { Write-Output $c.message.content }; if ($c.finish_reason -eq 'length') { [Console]::Error.WriteLine('Warning: the reply was cut off (token limit reached)'); exit 3 }; if (-not $c.message.content) { [Console]::Error.WriteLine('Error: the model returned an empty reply'); exit 1 }"
exit /b %ERRORLEVEL%

rem ---------------------------------------------------------------- helpers
:check_docker
where docker >nul 2>&1 || (echo Error: Docker Desktop is not installed& exit /b 1)
docker info >nul 2>&1 || (echo Error: Docker Desktop is not running: start it and try again& exit /b 1)
exit /b 0

rem Set every KEY=value of .env as a variable (lines starting with # are skipped).
:load_env
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%ENV_FILE%") do set "%%a=%%b"
exit /b 0

rem :ip_towards TARGET VARNAME - source IP of this PC on the route towards TARGET.
:ip_towards
set "%~2="
for /f %%i in ('powershell -NoProfile -Command "(Find-NetRoute -RemoteIPAddress %~1 | Where-Object IPAddress | Select-Object -First 1).IPAddress"') do set "%~2=%%i"
exit /b 0

rem :secret VARNAME - 64 random hex characters.
:secret
for /f %%i in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')"') do set "%~1=%%i"
exit /b 0

:create_env
call :ip_towards 1.1.1.1 HOST_IP
if defined HOST_IP goto :create_env_ip_ok
echo Error: cannot detect this PC's LAN IP
exit /b 1
:create_env_ip_ok
call :secret TOKEN
call :secret APIKEY
call :secret PGPASS
> "%ENV_FILE%" (
    echo # LocalAI cluster settings, created by the host on its first run.
    echo # Copy this file next to localai-cluster.sh / localai-cluster.bat on every worker PC.
    echo.
    echo # Address of the host. Update it here and on the workers if the host's IP changes.
    echo LOCALAI_SERVER=%HOST_IP%
    echo LOCALAI_PORT=23422
    echo LOCALAI_REGISTRATION_TOKEN=%TOKEN%
    echo # Key the host's proxy adds to requests: clients and the web UI need none.
    echo LOCALAI_API_KEY=sk-%APIKEY%
    echo.
    echo # Chat and embedding model. Parallel requests per PC are picked by LocalAI from the GPU's VRAM.
    echo LOCALAI_MODEL=gemma-4-12B-it-qat-UD-Q4_K_XL
    echo LOCALAI_EMBEDDING_MODEL=Qwen3-Embedding-8B-Q4_K_M.gguf
    echo # Where the host's proxy installs the models from when they are missing.
    echo LOCALAI_MODEL_URI=huggingface://unsloth/gemma-4-12B-it-qat-GGUF
    echo LOCALAI_MODEL_QUANT=UD-Q4_K_XL
    echo LOCALAI_EMBEDDING_MODEL_URI=huggingface://Qwen/Qwen3-Embedding-8B-GGUF/Qwen3-Embedding-8B-Q4_K_M.gguf
    echo # Models load on the first request and unload after this long without one.
    echo LOCALAI_IDLE_UNLOAD=2m
    echo # How many different models may be loaded at once in the cluster. Loading another
    echo # one first unloads the least recently used idle model.
    echo LOCALAI_MAX_LOADED_MODELS=1
    echo.
    echo # Used by the host only.
    echo LOCALAI_BIND=0.0.0.0
    echo POSTGRES_PASSWORD=%PGPASS%
    echo.
    echo # Worker only, normally detected: IP and name of the worker PC.
    echo WORKER_IP=
    echo WORKER_NAME=
)
echo Created "%ENV_FILE%": copy it next to localai-cluster.sh / localai-cluster.bat on every worker PC.
exit /b 0

rem DIAGNOSE-POWERSHELL: everything below is PowerShell for "diagnose"; cmd never gets here.
$ErrorActionPreference = 'Continue'
$EnvFile = Join-Path $env:ROOT '.env'
$script:Failed = $false

function Ok($t)      { Write-Host '  OK    ' -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t)    { Write-Host '  WARN  ' -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Fail($t)    { Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline; Write-Host $t; $script:Failed = $true }
function Info($t)    { Write-Host "        $t" }
function Section($t) { Write-Host ''; Write-Host $t }

# Can a TCP connection be made within 5 seconds?
function Test-Tcp($HostName, $Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync($HostName, [int]$Port).Wait(5000) -and $c.Connected } catch { return $false } finally { $c.Close() }
}

# Does anything answer HTTP at the URL (any status code)?
function Test-HttpAny($Url) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $Url | Out-Null; return $true }
    catch { return $null -ne $_.Exception.Response }
}

function Test-Ready($Url) {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$Url/readyz" | Out-Null; return $true } catch { return $false }
}

function Get-Json($Url, $Headers = @{}) {
    # Assigned first: Windows PowerShell 5.1 writes a JSON array from Invoke-RestMethod as one
    # object, so @(Get-Json ...) would hold the whole list as a single item.
    try { $r = Invoke-RestMethod -TimeoutSec 10 -Headers $Headers $Url } catch { return $null }
    return $r
}

function Get-ContainerState($Name) {
    $s = docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$s".Trim()
}

function Check-Container($Name) {
    $st = Get-ContainerState $Name
    if (-not $st) { Fail "container $Name does not exist" }
    elseif ($st -like 'running*' -and $st -notlike '*unhealthy*') { Ok "container ${Name}: $st" }
    else { Fail "container ${Name}: $st" }
}

# Does this PC's LocalAI worker run models on the GPU? $Node is the worker's name as registered
# with the host ('worker-local' for the host's own).
function Check-Gpu($Url, $Container, $Node) {
    Section "GPU (this PC: $Container)"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $g = nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null | Select-Object -First 1
        if ($g) { Ok "NVIDIA driver on this PC: $g" } else { Fail 'nvidia-smi is installed but finds no GPU: check the NVIDIA driver' }
    } else { Warn 'nvidia-smi not found on this PC: is the NVIDIA driver installed?' }
    if (-not (Get-ContainerState $Container)) { Fail "container $Container does not exist: GPU checks skipped"; return }
    $used = $null
    # Docker Desktop (WSL 2) mounts nvidia-smi at /usr/lib/wsl/lib, often not on the PATH.
    $g = docker exec $Container sh -c 'if command -v nvidia-smi >/dev/null 2>&1; then exec nvidia-smi "$@"; elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then exec /usr/lib/wsl/lib/nvidia-smi "$@"; else exit 127; fi' sh --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $g) {
        $p = "$g".Split(',') | ForEach-Object { $_.Trim() }
        $used = [int]$p[1]
        Ok "container $Container sees the GPU: $($p[0]) ($($p[1]) of $($p[2]) MiB in use)"
    } else { Warn "nvidia-smi does not run in container ${Container}: LocalAI's own GPU figures below decide" }
    # nvidia-smi alone proves little: llama.cpp needs the driver's CUDA library.
    docker exec $Container sh -c 'ldconfig -p 2>/dev/null | grep -q "libcuda\.so\.1 " || [ -e /usr/lib/wsl/lib/libcuda.so.1 ]' 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "container $Container has the CUDA driver library (libcuda.so.1)" }
    else { Fail "container $Container has no CUDA driver library (libcuda.so.1): models run on the CPU. The GPU request must include 'compute' (NVIDIA_DRIVER_CAPABILITIES=compute,utility): pull and restart" }
    $meta = docker exec $Container cat /backends/llama-cpp/metadata.json 2>$null | Out-String
    $backend = if ($meta -match '"meta_backend_for":\s*"([^"]*)"') { $Matches[1] } else { '' }
    if (-not $backend) { Info 'llama.cpp backend: not installed yet (the host installs it on the first model load)' }
    elseif ($backend -match 'cuda|nvidia') { Ok "llama.cpp backend: $backend (GPU build)" }
    else { Fail "llama.cpp backend: $backend, not a CUDA build: models run on the CPU. Remove the worker's backends volume and restart it" }
    $n = @(Get-Json "$Url/api/nodes") | Where-Object { $_ -and ($_.name -eq $Node -or "$($_.address)" -like "${Node}:*") } | Select-Object -First 1
    if (-not $n) { Warn "LocalAI's view of this PC's GPU: not registered with the host"; return }
    if ($n.gpu_vendor -and [double]$n.total_vram -gt 0) {
        Ok "LocalAI sees a $($n.gpu_vendor) GPU with $([math]::Round([double]$n.total_vram / 1GB)) GB VRAM on this PC"
        # Without nvidia-smi in the container, LocalAI's figures tell how much VRAM is in use.
        if ($null -eq $used -and $null -ne $n.available_vram) { $used = [int](([double]$n.total_vram - [double]$n.available_vram) / 1MB) }
    }
    else { Fail "LocalAI sees no GPU on this PC (vendor '$($n.gpu_vendor)', VRAM $($n.total_vram)): models run on the CPU. Use Docker Desktop with WSL 2 and an up-to-date NVIDIA driver" }
    $models = @(Get-Json "$Url/api/nodes/models") | Where-Object { $_ -and $_.node_id -eq $n.id -and $_.state -eq 'loaded' } | ForEach-Object { $_.model_name }
    if (-not $models) { Info 'no model loaded on this PC right now: load one (send a request) and run diagnose again to see it on the GPU' }
    elseif ($null -ne $used -and $used -gt 1024) { Ok "loaded here: $($models -join ', '); the GPU holds $used MiB, so the model runs on the GPU" }
    elseif ($null -ne $used) { Fail "loaded here: $($models -join ', '), but the GPU holds only $used MiB: the model runs on the CPU" }
}

# ---------------------------------------------------------------- basics
Section 'Basics'
if (-not (Test-Path $EnvFile)) { Fail "missing $EnvFile"; exit 1 }
Ok ".env found: $EnvFile"
$cfg = @{}
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker Desktop is not installed' }
else {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { Ok 'Docker is running' } else { Fail 'Docker Desktop is not running' }
}

$Server = $cfg['LOCALAI_SERVER']
$Port = if ($cfg['LOCALAI_PORT']) { $cfg['LOCALAI_PORT'] } else { '23422' }
$Token = $cfg['LOCALAI_REGISTRATION_TOKEN']
if (-not $Server) { Fail 'LOCALAI_SERVER is empty in .env'; exit 1 }
$MyIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
Info "host in .env: ${Server}:$Port; this PC: $env:COMPUTERNAME ($($MyIps -join ', '))"

if ($MyIps -contains $Server -or (Get-ContainerState 'localai-proxy-1')) {
    $Role = 'host'; Info 'role: host (LOCALAI_SERVER is this PC, or the host stack runs here)'
} else {
    $Role = 'worker'; Info 'role: worker (LOCALAI_SERVER is another PC)'
}

# ---------------------------------------------------------------- host
if ($Role -eq 'host') {
    Section 'Host containers'
    foreach ($c in 'localai-proxy-1', 'localai-frontend-1', 'localai-worker-local-1', 'localai-worker-sync-1', 'localai-postgres-1', 'localai-nats-1') {
        Check-Container $c
    }

    Section 'Host reachable'
    $local = "http://127.0.0.1:$Port"
    if (Test-Ready $local) { Ok "LocalAI answers on $local" } else { Fail "LocalAI does not answer on $local (is the host started?)" }
    if (Test-Ready "http://${Server}:$Port") { Ok "LocalAI answers on the LAN address http://${Server}:$Port" }
    else { Fail "LocalAI does not answer on http://${Server}:${Port}: wrong LOCALAI_SERVER in .env, or the firewall (TCP $Port)" }
    if (Test-Tcp $Server 4222) { Ok "NATS port ${Server}:4222 is open (workers connect to it)" }
    else { Fail "NATS port ${Server}:4222 is closed: workers cannot connect (firewall, TCP 4222)" }

    Section 'Workers registered with this host'
    $nodes = @(Get-Json "$local/api/nodes")
    if (-not $nodes -or $nodes.Count -eq 0 -or $null -eq $nodes[0]) { Warn 'no workers registered' }
    foreach ($n in $nodes) {
        if ($null -eq $n) { continue }
        $beat = "$($n.last_heartbeat)" -replace '\..*$', ''
        if ($n.status -eq 'healthy') { Ok "$($n.name): $($n.status) (last heartbeat $beat)" } else { Fail "$($n.name): $($n.status) (last heartbeat $beat)" }
        if ("$($n.address)" -like 'worker-local:*') { Info "this PC's own GPU worker, reached inside Docker"; continue }
        # The host connects back to every worker: file uploads and model loads (50050), inference (50051).
        if (Test-HttpAny "http://$($n.http_address)/") { Ok "$($n.name): file port $($n.http_address) reachable from this host" }
        else { Fail "$($n.name): file port $($n.http_address) NOT reachable from this host: open TCP 50050-50059 in that PC's firewall (see README)" }
        $a = "$($n.address)".Split(':')
        if (Test-Tcp $a[0] $a[1]) { Ok "$($n.name): model port $($n.address) reachable from this host" }
        else { Fail "$($n.name): model port $($n.address) NOT reachable from this host: open TCP 50050-50059 in that PC's firewall (see README)" }
    }

    Check-Gpu $local 'localai-worker-local-1' 'worker-local'

    Section 'Models'
    $installed = @((Get-Json "$local/v1/models").data | ForEach-Object { $_.id })
    foreach ($want in $cfg['LOCALAI_MODEL'], $cfg['LOCALAI_EMBEDDING_MODEL']) {
        if (-not $want) { continue }
        if ($installed -contains $want) { Ok "installed: $want" }
        else { Warn "not installed (yet): ${want}: the proxy installs it on start, see docker logs localai-proxy-1" }
    }
    $loaded = @(Get-Json "$local/api/nodes/models")
    if (-not $loaded -or $null -eq $loaded[0]) { Info 'loaded now: none (models load on the first request)' }
    else { Info ('loaded now: ' + (($loaded | Group-Object model_name | ForEach-Object { "$($_.Name) on $($_.Count) PC(s)" }) -join ', ')) }
}

# ---------------------------------------------------------------- worker
if ($Role -eq 'worker') {
    $url = "http://${Server}:$Port"
    Section "Host $Server"
    if (Test-Ready $url) { Ok "host answers on $url" }
    else { Fail "host does not answer on ${url}: is it started, is LOCALAI_SERVER right, is TCP $Port open in the host's firewall?" }
    if (Test-Tcp $Server 4222) { Ok "NATS port ${Server}:4222 is open" } else { Fail "NATS port ${Server}:4222 is closed: open TCP 4222 in the host's firewall" }
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Headers @{ 'X-Registration-Token' = $Token } "$url/_cluster/files" | Out-Null
        Ok 'join token accepted (model files can be synced)'
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -eq 401) { Fail "join token rejected: copy the host's .env to this PC again" }
        else { Fail "model file list: HTTP $code (is the host up to date?)" }
    }

    Section 'This worker'
    $name = if ($cfg['WORKER_NAME']) { $cfg['WORKER_NAME'] } else { $env:COMPUTERNAME }
    $me = @(Get-Json "$url/api/nodes") | Where-Object { $_ -and $_.name -eq $name } | Select-Object -First 1
    if (-not $me) { Fail "this PC ($name) is not registered with the host: is the worker started?" }
    else {
        $beat = "$($me.last_heartbeat)" -replace '\..*$', ''
        if ($me.status -eq 'healthy') { Ok "registered as ${name}: $($me.status) (last heartbeat $beat)" } else { Fail "registered as ${name}: $($me.status) (last heartbeat $beat)" }
        Info "the host connects back to $($me.http_address) and $($me.address): run this check on the host to test that"
        $ip = "$($me.address)".Split(':')[0]
        if ($MyIps -notcontains $ip) { Warn "the host knows this PC as $ip, which is not one of its addresses ($($MyIps -join ', ')): set WORKER_IP in .env" }
    }
    Check-Container 'localai-worker'
    Check-Container 'localai-worker-sync'
    $last = docker logs --tail 50 localai-worker-sync 2>&1 | Where-Object { "$_" -match 'in sync|downloading|waiting|%' } | Select-Object -Last 1
    $msg = "$last" -replace '^\S+\s+', ''
    if ("$last" -match 'in sync') { Ok "model files: $msg" }
    elseif (-not $last) { Warn 'model files: the sync has not reported yet' }
    else { Warn "model files: $msg" }
    Check-Gpu $url 'localai-worker' $name
}

Write-Host ''
if ($script:Failed) { Write-Host 'Some checks failed.'; exit 1 }
Write-Host 'All checks passed.'
