@echo off
rem LocalAI cluster. Runs in the foreground; Ctrl+C stops it.
rem
rem   localai-cluster.bat host     run the server (API + web UI) and use this PC's GPU.
rem                        The first run creates .env next to this script.
rem   localai-cluster.bat worker   lend this PC's GPU to the host. Needs the host's .env
rem                        copied next to this script.
rem   localai-cluster.bat model-capacity [model]
rem                        print how many requests the cluster serves at once for a model
rem                        (slots per PC x PCs with it loaded; LOCALAI_MODEL by default).
rem                        Only the number goes to stdout; details go to stderr.
rem   localai-cluster.bat model-list-all
rem                        list every model of the host as "<model><TAB><capacity>".
setlocal EnableExtensions
set "ROOT=%~dp0"
set "ENV_FILE=%ROOT%.env"

if /i "%~1"=="host" goto :host
if /i "%~1"=="worker" goto :worker
if /i "%~1"=="model-capacity" goto :model_capacity
if /i "%~1"=="model-list-all" goto :model_list_all
echo Usage: %~nx0 host^|worker^|model-capacity [model]^|model-list-all
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
echo Login: %LOCALAI_ADMIN_EMAIL% / %LOCALAI_ADMIN_PASSWORD%
echo API key: %LOCALAI_API_KEY%   Ctrl+C stops it.
if defined LOCALAI_ADMIN_PASSWORD call :create_admin
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

rem ---------------------------------------------------------------- model-capacity / model-list-all
rem Both ask the host's API, so they work on any PC with the .env. CAP_PS holds the shared
rem PowerShell: Cap $model -> slots per PC ("parallel:N" in the effective config, else 1),
rem PCs with the model loaded, and requests running on them now.
:model_capacity
call :cap_init || exit /b 1
set "CAP_MODEL=%~2"
if not defined CAP_MODEL set "CAP_MODEL=%LOCALAI_MODEL%"
powershell -NoProfile -Command "%CAP_PS% $m='%CAP_MODEL%'; $r = Cap $m; [Console]::Error.WriteLine(\"model ${m}: $($r.Slots) slots/PC x $($r.Replicas) PCs loaded, $($r.InFlight) requests running\"); Write-Output ($r.Slots * $r.Replicas)"
exit /b %ERRORLEVEL%

:model_list_all
call :cap_init || exit /b 1
powershell -NoProfile -Command "%CAP_PS% try { $ms = (Invoke-RestMethod -TimeoutSec 10 -Headers $h ($u+'/v1/models')).data } catch { Fail \"cannot read the models from $u\" }; foreach ($x in $ms) { $r = Cap $x.id; Write-Output ($x.id + \"`t\" + ($r.Slots * $r.Replicas)) }"
exit /b %ERRORLEVEL%

:cap_init
if exist "%ENV_FILE%" goto :cap_env_ok
echo Error: missing "%ENV_FILE%" 1>&2
exit /b 1
:cap_env_ok
call :load_env
set "CAP_PS=$u='http://%LOCALAI_SERVER%:%LOCALAI_PORT%'; $h=@{Authorization='Bearer %LOCALAI_API_KEY%'}; function Fail($t) { [Console]::Error.WriteLine('Error: ' + $t); exit 1 }; function Cap($m) { try { $c = Invoke-RestMethod -TimeoutSec 10 -Headers $h ($u+'/api/models/config-json/'+$m) } catch { Fail ('cannot read the config of ' + $m + ' from ' + $u) }; try { $n = Invoke-RestMethod -TimeoutSec 10 -Headers $h ($u+'/api/nodes/models') } catch { Fail ('cannot read the loaded models from ' + $u) }; $s = 1; foreach ($o in @($c.options)) { if ($o -match '^(n_)?parallel:(\d+)$') { $s = [int]$Matches[2]; break } }; $l = @($n | Where-Object { $_.model_name -eq $m -and $_.state -eq 'loaded' }); $f = ($l | Measure-Object -Property in_flight -Sum).Sum; if (-not $f) { $f = 0 }; [pscustomobject]@{ Slots = $s; Replicas = $l.Count; InFlight = $f } };"
exit /b 0

rem ---------------------------------------------------------------- helpers
:check_docker
where docker >nul 2>&1 || (echo Error: Docker Desktop is not installed& exit /b 1)
docker info >nul 2>&1 || (echo Error: Docker Desktop is not running: start it and try again& exit /b 1)
exit /b 0

rem Once the web UI answers, create the admin account from .env if nobody signed up yet (in the background).
:create_admin
start "" /b powershell -NoProfile -Command "$u='http://127.0.0.1:%LOCALAI_PORT%'; for ($i=0; $i -lt 300; $i++) { try { Invoke-WebRequest -UseBasicParsing ($u+'/readyz') -TimeoutSec 5 | Out-Null; break } catch { Start-Sleep 2 } }; try { $s = Invoke-RestMethod ($u+'/api/auth/status') } catch { exit }; if (-not $s.hasUsers) { $b = @{ email='%LOCALAI_ADMIN_EMAIL%'; password='%LOCALAI_ADMIN_PASSWORD%'; name='admin'; acknowledge_weak_password=$true } | ConvertTo-Json; try { Invoke-RestMethod -Method Post -ContentType 'application/json' -Body $b ($u+'/api/auth/register') | Out-Null } catch { } }" >nul 2>&1
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
    echo # Key for API clients, sent as a Bearer token.
    echo LOCALAI_API_KEY=sk-%APIKEY%
    echo # Web UI login, created as admin on the host's first start. Must be an email address.
    echo LOCALAI_ADMIN_EMAIL=admin@localai
    echo LOCALAI_ADMIN_PASSWORD=admin123456
    echo.
    echo # Model loaded on every PC. Parallel requests per PC are picked by LocalAI from the
    echo # GPU's VRAM; LLAMACPP_PARALLEL is used only when it picks none.
    echo LOCALAI_MODEL=gemma-4-12B-it-qat-UD-Q4_K_XL
    echo LLAMACPP_PARALLEL=5
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
