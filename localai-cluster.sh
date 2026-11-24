#!/bin/bash
# LocalAI cluster. Runs in the foreground; Ctrl+C stops it.
#
#   ./localai-cluster.sh host     run the server (API + web UI) and use this PC's GPU.
#                         The first run creates .env next to this script.
#   ./localai-cluster.sh worker   lend this PC's GPU to the host. Needs the host's .env
#                         copied next to this script.
#   ./localai-cluster.sh diagnose
#                         check the connections this PC needs: as host (LocalAI, NATS, every
#                         registered worker reachable from here) or as worker (host, token,
#                         registration, containers, model sync), and whether this PC's
#                         models run on its GPU. Read-only.
#   ./localai-cluster.sh model-capacity [model]
#                         print how many requests the cluster serves at once for a model
#                         (slots per PC x PCs with it loaded; LOCALAI_MODEL by default).
#                         Only the number goes to stdout; details go to stderr.
#   ./localai-cluster.sh model-list-all
#                         list every model of the host as "<model><TAB><capacity>".
#   ./localai-cluster.sh useChatCompletions [prompt] [model] [worker]
#                         send a prompt to the cluster (/v1/chat/completions) and print the
#                         reply. Without a prompt (or with "-") it is read from stdin. The
#                         model is LOCALAI_MODEL by default ("" for the default too). With a
#                         worker name, the request runs on that PC (for diagnosing). The PC
#                         that served it goes to stderr. Needs jq or python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="${ROOT}/.env"

die() { echo "Error: $*" >&2; exit 1; }

env_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1 | tr -d '\r'
}

# Source IP of this PC on the route towards $1.
ip_towards() { ip -4 route get "$1" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }

check_docker() {
    command -v docker >/dev/null || die "Docker is not installed"
    docker info >/dev/null 2>&1 || die "Docker is not running, or this user may not use it (add yourself to the docker group)"
}

create_env() {
    local ip
    ip="$(ip_towards 1.1.1.1)"
    [[ -n "$ip" ]] || die "cannot detect this PC's LAN IP"
    command -v openssl >/dev/null || die "openssl is needed to create the secrets"
    (
        umask 077
        cat > "$ENV_FILE" <<EOF
# LocalAI cluster settings, created by the host on its first run.
# Copy this file next to localai-cluster.sh / localai-cluster.bat on every worker PC.

# Address of the host. Update it here and on the workers if the host's IP changes.
LOCALAI_SERVER=${ip}
LOCALAI_PORT=23422
LOCALAI_REGISTRATION_TOKEN=$(openssl rand -hex 24)
# Key the host's proxy adds to requests: clients and the web UI need none.
LOCALAI_API_KEY=sk-$(openssl rand -hex 24)

# Chat and embedding model. Parallel requests per PC are picked by LocalAI from the GPU's VRAM.
LOCALAI_MODEL=gemma-4-12B-it-qat-UD-Q4_K_XL
LOCALAI_EMBEDDING_MODEL=Qwen3-Embedding-8B-Q4_K_M.gguf
# Where the host's proxy installs the models from when they are missing.
LOCALAI_MODEL_URI=huggingface://unsloth/gemma-4-12B-it-qat-GGUF
LOCALAI_MODEL_QUANT=UD-Q4_K_XL
LOCALAI_EMBEDDING_MODEL_URI=huggingface://Qwen/Qwen3-Embedding-8B-GGUF/Qwen3-Embedding-8B-Q4_K_M.gguf
# Models load on the first request and unload after this long without one.
LOCALAI_IDLE_UNLOAD=2m
# How many different models may be loaded at once in the cluster. Loading another
# one first unloads the least recently used idle model.
LOCALAI_MAX_LOADED_MODELS=1

# Used by the host only.
LOCALAI_BIND=0.0.0.0
POSTGRES_PASSWORD=$(openssl rand -hex 24)

# Worker only, normally detected: IP and name of the worker PC.
WORKER_IP=
WORKER_NAME=
EOF
    )
    echo "Created ${ENV_FILE}: copy it next to localai-cluster.sh / localai-cluster.bat on every worker PC."
}

# --- host API, for the commands below (works from any PC with the .env). The host's
# proxy adds the API key, so requests need none.
api_init() {
    [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}"
    command -v curl >/dev/null || die "curl is needed"
    API_URL="http://$(env_get LOCALAI_SERVER):$(env_get LOCALAI_PORT)"
}
api_get() { curl -sf -m 10 "${API_URL}$1"; }

# urlenc TEXT: TEXT encoded for a URL path segment. re_esc TEXT: TEXT as a literal in grep -E.
urlenc() {
    if command -v jq >/dev/null; then jq -rn --arg s "$1" '$s | @uri'
    elif command -v python3 >/dev/null; then python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
    else printf '%s' "$1"; fi
}
re_esc() { sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$1"; }

# model_capacity MODEL -> "slots replicas in_flight"
#   slots:     "parallel:N" in the effective config (auto-tuned or set), else 1
#   replicas:  copies of the model in state "loaded" (one per PC)
#   in_flight: requests running on those copies right now
model_capacity() {
    local config nodes loaded slots replicas in_flight
    config="$(api_get "/api/models/config-json/$(urlenc "$1")")" || die "cannot read the config of '$1' from ${API_URL}"
    nodes="$(api_get /api/nodes/models)" || die "cannot read the loaded models from ${API_URL}"
    slots="$(grep -oE '"(n_)?parallel:[0-9]+"' <<<"$config" | head -1 | grep -oE '[0-9]+' || true)"
    # Each entry of /api/nodes/models is a flat JSON object.
    loaded="$(grep -oE "\{[^{}]*\"model_name\":\"$(re_esc "$1")\"[^{}]*\}" <<<"$nodes" | grep '"state":"loaded"' || true)"
    replicas="$(grep -c . <<<"$loaded" || true)"
    in_flight="$(grep -oE '"in_flight":[0-9]+' <<<"$loaded" | awk -F: '{n+=$2} END {print n+0}')"
    echo "${slots:-1} ${replicas:-0} ${in_flight}"
}

# chat_request PROMPT MODEL -> JSON body
# chat_reply < RESPONSE -> "<finish_reason>\n<content>\nEND". The END marker keeps an empty or
# newline-ending reply intact through $(...), which strips trailing newlines.
if command -v jq >/dev/null; then
    chat_request() { jq -n --arg p "$1" --arg m "$2" '{model: $m, stream: false, messages: [{role: "user", content: $p}]}'; }
    chat_reply() { jq -r '(.choices[0].finish_reason // "") + "\n" + (.choices[0].message.content // "") + "\nEND"'; }
elif command -v python3 >/dev/null; then
    chat_request() { python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[2], "stream": False, "messages": [{"role": "user", "content": sys.argv[1]}]}))' "$1" "$2"; }
    chat_reply() { python3 -c 'import json,sys; c=json.load(sys.stdin)["choices"][0]; sys.stdout.write((c.get("finish_reason") or "") + "\n" + (c["message"].get("content") or "") + "\nEND\n")'; }
else
    chat_request() { die "useChatCompletions needs jq or python3"; }
fi

# ---------------------------------------------------------------- diagnose
# Checks the connections this PC needs, as host or as worker. Read-only: it sends no
# inference requests and changes nothing. Returns 1 if a check failed.
#   Host:   LocalAI answering here and on the LAN, NATS open, and every registered worker
#           reachable from here on its file port (50050) and model port (50051).
#   Worker: host reachable (API, NATS), join token accepted, this PC registered and
#           healthy, worker and sync containers running.
FAILED=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
info() { printf '        %s\n' "$*"; }
section() { printf '\n%s\n' "$*"; }

# tcp_open HOST PORT: can a TCP connection be made within 5 seconds?
tcp_open() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# http_any URL: does anything answer HTTP there (any status code)?
http_any() { local c; c="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$1")"; [[ "$c" != 000 ]]; }

# JSON on stdin -> tab-separated lines (jq, else python3).
py_tsv() {
    python3 -c '
import json, sys
mode, d = sys.argv[1], json.load(sys.stdin)
rows = {
    "nodes":  lambda: [[n.get(k) or "-" for k in ("name", "status", "address", "http_address", "last_heartbeat")] for n in d],
    "models": lambda: [[m["id"]] for m in d.get("data", [])],
    "loaded": lambda: [[r["model_name"], r["state"], r.get("node_id") or "-"] for r in d],
    "gpus":   lambda: [[n.get(k) or "-" for k in ("name", "id", "gpu_vendor", "total_vram", "address", "available_vram")] for n in d],
}[mode]()
for r in rows: print("\t".join(str(x) for x in r))
' "$1"
}
# Empty fields come out as "-": read with IFS=$'\t' would collapse an empty field and shift the rest.
JQ_DASH='map(if . == null or . == "" then "-" else tostring end) | @tsv'
nodes_tsv()  { if command -v jq >/dev/null; then jq -r ".[] | [.name, .status, .address, .http_address, .last_heartbeat] | ${JQ_DASH}"; else py_tsv nodes; fi; }
models_tsv() { if command -v jq >/dev/null; then jq -r '.data[].id'; else py_tsv models; fi; }
loaded_tsv() { if command -v jq >/dev/null; then jq -r ".[] | [.model_name, .state, .node_id] | ${JQ_DASH}"; else py_tsv loaded; fi; }
gpus_tsv()   { if command -v jq >/dev/null; then jq -r ".[] | [.name, .id, .gpu_vendor, .total_vram, .address, .available_vram] | ${JQ_DASH}"; else py_tsv gpus; fi; }

# check_gpu URL CONTAINER NODE: does this PC's LocalAI worker run models on the GPU?
# NODE is the worker's name as registered with the host ("worker-local" for the host's own).
check_gpu() {
    local url="$1" c="$2" node="$3" line="" id="" vendor="" vram="" avail="" gpu="" backend="" used="" total="" models=""
    section "GPU (this PC: ${c})"
    if command -v nvidia-smi >/dev/null; then
        gpu="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)"
        if [[ -n "$gpu" ]]; then ok "NVIDIA driver on this PC: ${gpu}"; else fail "nvidia-smi is installed but finds no GPU: check the NVIDIA driver"; fi
    else
        warn "nvidia-smi not found on this PC: is the NVIDIA driver installed?"
    fi
    if [[ -z "$(container_state "$c")" ]]; then fail "container ${c} does not exist: GPU checks skipped"; return; fi
    # On Windows (Docker Desktop, WSL 2) nvidia-smi is mounted at /usr/lib/wsl/lib, often not on PATH.
    gpu="$(docker exec "$c" sh -c 'if command -v nvidia-smi >/dev/null 2>&1; then exec nvidia-smi "$@"; elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then exec /usr/lib/wsl/lib/nvidia-smi "$@"; else exit 127; fi' \
        sh --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
    if [[ -n "$gpu" ]]; then
        IFS=',' read -r _ used total <<<"$gpu"; used="${used// /}"; total="${total// /}"
        ok "container ${c} sees the GPU: ${gpu%%,*} (${used} of ${total} MiB in use)"
    else
        warn "nvidia-smi does not run in container ${c}: LocalAI's own GPU figures below decide"
    fi
    # nvidia-smi alone proves little: llama.cpp needs the driver's CUDA library.
    if docker exec "$c" sh -c 'ldconfig -p 2>/dev/null | grep -q "libcuda\.so\.1 " || [ -e /usr/lib/wsl/lib/libcuda.so.1 ]' 2>/dev/null; then
        ok "container ${c} has the CUDA driver library (libcuda.so.1)"
    else
        fail "container ${c} has no CUDA driver library (libcuda.so.1): models run on the CPU. The GPU request must include \"compute\" (NVIDIA_DRIVER_CAPABILITIES=compute,utility): pull and restart"
    fi
    backend="$(docker exec "$c" cat /backends/llama-cpp/metadata.json 2>/dev/null | sed -n 's/.*"meta_backend_for": *"\([^"]*\)".*/\1/p')"
    case "$backend" in
        "")                    info "llama.cpp backend: not installed yet (the host installs it on the first model load)";;
        *cuda*|*nvidia*)       ok "llama.cpp backend: ${backend} (GPU build)";;
        *)                     fail "llama.cpp backend: ${backend}, not a CUDA build: models run on the CPU. Remove the worker's backends volume and restart it";;
    esac
    line="$(curl -sf -m 10 "${url}/api/nodes" | gpus_tsv | awk -F'\t' -v n="$node" 'tolower($1) == tolower(n) || ($5 ~ "^" n ":")' | head -1)"
    if [[ -z "$line" ]]; then
        warn "LocalAI's view of this PC's GPU: not registered with the host"
    else
        IFS=$'\t' read -r _ id vendor vram _ avail <<<"$line"
        if [[ "$vendor" != "-" && "$vram" =~ ^[0-9]+$ ]] && (( vram > 0 )); then
            ok "LocalAI sees a ${vendor} GPU with $(( vram / 1024 / 1024 / 1024 )) GB VRAM on this PC"
            # Without nvidia-smi in the container, LocalAI's figures tell how much VRAM is in use.
            if [[ -z "$used" && "$avail" =~ ^[0-9]+$ ]]; then used=$(( (vram - avail) / 1024 / 1024 )); fi
        else
            fail "LocalAI sees no GPU on this PC (vendor '${vendor}', VRAM ${vram}): models run on the CPU. Linux: install the NVIDIA Container Toolkit; Windows: Docker Desktop with WSL 2 and an up-to-date NVIDIA driver"
        fi
        models="$(curl -sf -m 10 "${url}/api/nodes/models" | loaded_tsv | awk -F'\t' -v id="$id" '$3 == id && $2 == "loaded" {print $1}' | paste -sd, -)"
        if [[ -z "$models" ]]; then
            info "no model loaded on this PC right now: load one (send a request) and run diagnose again to see it on the GPU"
        elif [[ -n "$used" ]] && (( used > 1024 )); then
            ok "loaded here: ${models}; the GPU holds ${used} MiB, so the model runs on the GPU"
        elif [[ -n "$used" ]]; then
            fail "loaded here: ${models}, but the GPU holds only ${used} MiB: the model runs on the CPU"
        fi
    fi
}

container_state() { docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$1" 2>/dev/null; }

check_container() {
    local st; st="$(container_state "$1")"
    if [[ -z "$st" ]]; then fail "container $1 does not exist"
    elif [[ "$st" == running* && "$st" != *unhealthy* ]]; then ok "container $1: $st"
    else fail "container $1: $st"; fi
}

diagnose() {
    # ---------------------------------------------------------------- basics
    section "Basics"
    [[ -f "$ENV_FILE" ]] || { fail "missing ${ENV_FILE}"; exit 1; }
    ok ".env found: ${ENV_FILE}"
    command -v curl >/dev/null || { fail "curl is not installed"; exit 1; }
    command -v jq >/dev/null || command -v python3 >/dev/null || { fail "jq or python3 is needed"; exit 1; }
    if ! command -v docker >/dev/null; then fail "Docker is not installed"
    elif ! docker info >/dev/null 2>&1; then fail "Docker is not running, or this user may not use it"
    else ok "Docker is running"; fi

    SERVER="$(env_get LOCALAI_SERVER)"; PORT="$(env_get LOCALAI_PORT)"; PORT="${PORT:-23422}"
    TOKEN="$(env_get LOCALAI_REGISTRATION_TOKEN)"
    [[ -n "$SERVER" ]] || { fail "LOCALAI_SERVER is empty in .env"; exit 1; }
    MY_IPS="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
    info "host in .env: ${SERVER}:${PORT}; this PC: $(hostname) (${MY_IPS% })"

    if [[ " ${MY_IPS} " == *" ${SERVER} "* ]] || [[ -n "$(container_state localai-proxy-1)" ]]; then
        ROLE=host
    else
        ROLE=worker
    fi
    info "role: ${ROLE}$( [[ $ROLE == host ]] && echo " (LOCALAI_SERVER is this PC, or the host stack runs here)" || echo " (LOCALAI_SERVER is another PC)")"

    # ---------------------------------------------------------------- host
    if [[ "$ROLE" == host ]]; then
        section "Host containers"
        for c in localai-proxy-1 localai-frontend-1 localai-worker-local-1 localai-worker-sync-1 localai-postgres-1 localai-nats-1; do
            check_container "$c"
        done

        section "Host reachable"
        if curl -sf -m 5 -o /dev/null "http://127.0.0.1:${PORT}/readyz"; then ok "LocalAI answers on http://127.0.0.1:${PORT}"
        else fail "LocalAI does not answer on http://127.0.0.1:${PORT} (is the host started?)"; fi
        if curl -sf -m 5 -o /dev/null "http://${SERVER}:${PORT}/readyz"; then ok "LocalAI answers on the LAN address http://${SERVER}:${PORT}"
        else fail "LocalAI does not answer on http://${SERVER}:${PORT}: wrong LOCALAI_SERVER in .env, or LOCALAI_BIND"; fi
        if tcp_open "$SERVER" 4222; then ok "NATS port ${SERVER}:4222 is open (workers connect to it)"
        else fail "NATS port ${SERVER}:4222 is closed: workers cannot connect"; fi

        section "Workers registered with this host"
        nodes="$(curl -sf -m 10 "http://127.0.0.1:${PORT}/api/nodes" | nodes_tsv)"
        if [[ -z "$nodes" ]]; then
            warn "no workers registered"
        else
            while IFS=$'\t' read -r name status addr http_addr beat; do
                [[ -n "$name" ]] || continue
                if [[ "$status" == healthy ]]; then ok "${name}: ${status} (last heartbeat ${beat%.*})"
                else fail "${name}: ${status} (last heartbeat ${beat%.*})"; fi
                if [[ "$addr" == worker-local:* ]]; then
                    info "this PC's own GPU worker, reached inside Docker"
                    continue
                fi
                # The host connects back to every worker: file uploads and model loads (50050), inference (50051).
                h="${http_addr%:*}"; hp="${http_addr##*:}"; a="${addr%:*}"; ap="${addr##*:}"
                if http_any "http://${http_addr}/"; then ok "${name}: file port ${http_addr} reachable from this host"
                else fail "${name}: file port ${http_addr} NOT reachable from this host: open TCP 50050-50059 in that PC's firewall (see README)"; fi
                if tcp_open "$a" "$ap"; then ok "${name}: model port ${addr} reachable from this host"
                else fail "${name}: model port ${addr} NOT reachable from this host: open TCP 50050-50059 in that PC's firewall (see README)"; fi
            done <<<"$nodes"
        fi

        check_gpu "http://127.0.0.1:${PORT}" localai-worker-local-1 worker-local

        section "Models"
        installed="$(curl -sf -m 10 "http://127.0.0.1:${PORT}/v1/models" | models_tsv)"
        for want in "$(env_get LOCALAI_MODEL)" "$(env_get LOCALAI_EMBEDDING_MODEL)"; do
            [[ -n "$want" ]] || continue
            if grep -qxF "$want" <<<"$installed"; then ok "installed: ${want}"
            else warn "not installed (yet): ${want}: the proxy installs it on start, see docker logs localai-proxy-1"; fi
        done
        loaded="$(curl -sf -m 10 "http://127.0.0.1:${PORT}/api/nodes/models" | loaded_tsv)"
        if [[ -z "$loaded" ]]; then info "loaded now: none (models load on the first request)"
        else info "loaded now: $(awk -F'\t' '{print $1" ("$2")"}' <<<"$loaded" | sort | uniq -c | awk '{$1=$1" x"; print}' | paste -sd, -)"; fi
    fi

    # ---------------------------------------------------------------- worker
    if [[ "$ROLE" == worker ]]; then
        url="http://${SERVER}:${PORT}"
        section "Host ${SERVER}"
        if curl -sf -m 5 -o /dev/null "${url}/readyz"; then ok "host answers on ${url}"
        else fail "host does not answer on ${url}: is it started, is LOCALAI_SERVER right, is TCP ${PORT} open in the host's firewall?"; fi
        if tcp_open "$SERVER" 4222; then ok "NATS port ${SERVER}:4222 is open"
        else fail "NATS port ${SERVER}:4222 is closed: open TCP 4222 in the host's firewall"; fi
        code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-Registration-Token: ${TOKEN}" "${url}/_cluster/files")"
        case "$code" in
            200) ok "join token accepted (model files can be synced)";;
            401) fail "join token rejected: copy the host's .env to this PC again";;
            *)   fail "model file list: HTTP ${code} (is the host up to date?)";;
        esac

        section "This worker"
        name="$(env_get WORKER_NAME)"; name="${name:-$(hostname)}"
        nodes="$(curl -sf -m 10 "${url}/api/nodes" | nodes_tsv)"
        line="$(awk -F'\t' -v n="$name" 'tolower($1) == tolower(n)' <<<"$nodes" | head -1)"
        if [[ -z "$line" ]]; then
            fail "this PC (${name}) is not registered with the host: is the worker started?"
        else
            IFS=$'\t' read -r _ status addr http_addr beat <<<"$line"
            if [[ "$status" == healthy ]]; then ok "registered as ${name}: ${status} (last heartbeat ${beat%.*})"
            else fail "registered as ${name}: ${status} (last heartbeat ${beat%.*})"; fi
            info "the host connects back to ${http_addr} and ${addr}: run this check on the host to test that"
            if [[ " ${MY_IPS} " != *" ${addr%:*} "* ]]; then
                warn "the host knows this PC as ${addr%:*}, which is not one of its addresses (${MY_IPS% }): set WORKER_IP in .env"
            fi
        fi
        check_container localai-worker
        check_container localai-worker-sync
        last="$(docker logs --tail 50 localai-worker-sync 2>/dev/null | grep -E 'in sync|downloading|waiting|%' | tail -1)"
        case "$last" in
            *"in sync"*) ok "model files: ${last#* }";;
            "")          warn "model files: the sync has not reported yet";;
            *)           warn "model files: ${last#* }";;
        esac
        check_gpu "$url" localai-worker "$name"
    fi

    echo
    if (( FAILED )); then echo "Some checks failed."; exit 1; fi
    echo "All checks passed."
}

case "${1:-}" in
    host)
        check_docker
        [[ -f "$ENV_FILE" ]] || create_env
        export LOCALAI_LOCAL_NODE_NAME="$(hostname)"
        echo "LocalAI host: http://127.0.0.1:$(env_get LOCALAI_PORT)  (LAN: http://$(env_get LOCALAI_SERVER):$(env_get LOCALAI_PORT))"
        echo "No login or API key needed. Missing models are installed on start. Ctrl+C stops it."
        exec docker compose -p localai --env-file "$ENV_FILE" -f "${ROOT}/docker/host/docker-compose.yml" up
        ;;
    worker)
        check_docker
        [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}: copy the .env from the host next to this script"
        server="$(env_get LOCALAI_SERVER)"
        [[ -n "$server" ]] || die "LOCALAI_SERVER is empty in ${ENV_FILE}"
        ip="$(env_get WORKER_IP)"; ip="${ip:-$(ip_towards "$server")}"
        [[ -n "$ip" ]] || die "cannot detect this PC's IP towards ${server}; set WORKER_IP in ${ENV_FILE}"
        name="$(env_get WORKER_NAME)"
        export WORKER_IP="$ip" WORKER_NAME="${name:-$(hostname)}"
        echo "LocalAI worker '${WORKER_NAME}' (${WORKER_IP}) -> host ${server}. Ctrl+C stops it."
        exec docker compose -p localai-worker --env-file "$ENV_FILE" -f "${ROOT}/docker/worker/docker-compose.yml" up --build
        ;;
    model-capacity)
        api_init
        model="${2:-$(env_get LOCALAI_MODEL)}"
        cap="$(model_capacity "$model")" || exit 1
        read -r slots replicas in_flight <<<"$cap"
        echo "model ${model}: ${slots} slots/PC x ${replicas} PCs loaded, ${in_flight} requests running" >&2
        echo $(( slots * replicas ))
        ;;
    model-list-all)
        api_init
        models="$(api_get /v1/models)" || die "cannot read the models from ${API_URL}"
        for model in $(grep -oE '"id":"[^"]*"' <<<"$models" | cut -d'"' -f4); do
            cap="$(model_capacity "$model")" || exit 1
            read -r slots replicas in_flight <<<"$cap"
            printf '%s\t%s\n' "$model" $(( slots * replicas ))
        done
        ;;
    useChatCompletions)
        api_init
        prompt="${2:--}"
        [[ "$prompt" == "-" ]] && prompt="$(cat)"
        [[ -n "$prompt" ]] || die "empty prompt"
        model="${3:-$(env_get LOCALAI_MODEL)}"
        worker="${4:-}"
        body="$(chat_request "$prompt" "$model")"
        headers="$(mktemp)"; trap 'rm -f "$headers"' EXIT
        # Queue wait and model load (a pinned request reloads the model) included: allow 10 minutes.
        response="$(curl -sS -m 600 -D "$headers" -H 'Content-Type: application/json' \
            ${worker:+-H "X-Cluster-Worker: ${worker}"} \
            -d "$body" -w '\n%{http_code}' "${API_URL}/v1/chat/completions")" \
            || die "cannot reach ${API_URL}"
        code="${response##*$'\n'}"; response="${response%$'\n'*}"
        [[ "$code" == 200 ]] || die "HTTP ${code}: ${response:0:500}"
        served="$(sed -n 's/^[Xx]-[Cc]luster-[Ww]orker-[Ss]erved:[[:space:]]*//p' "$headers" | tr -d '\r' | tail -1)"
        [[ -n "$served" ]] && echo "served by: ${served}" >&2
        reply="$(chat_reply <<<"$response")" || die "unexpected response: ${response:0:500}"
        reply="${reply%$'\n'END}"
        finish="${reply%%$'\n'*}"; content="${reply#*$'\n'}"
        [[ -n "$content" ]] && printf '%s\n' "$content"
        if [[ "$finish" == "length" ]]; then
            echo "Warning: the reply was cut off (token limit reached)" >&2
            exit 3
        fi
        [[ -n "$content" ]] || die "the model returned an empty reply"
        ;;
    diagnose)
        ( set +e; diagnose )
        exit $?
        ;;
    *)
        echo "Usage: $0 host|worker|diagnose|model-capacity [model]|model-list-all|useChatCompletions [prompt] [model] [worker]" >&2
        exit 2
        ;;
esac
