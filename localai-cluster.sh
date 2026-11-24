#!/bin/bash
# LocalAI cluster. Runs in the foreground; Ctrl+C stops it.
#
#   ./localai-cluster.sh host     run the server (API + web UI) and use this PC's GPU.
#                         The first run creates .env next to this script.
#   ./localai-cluster.sh worker   lend this PC's GPU to the host. Needs the host's .env
#                         copied next to this script.
#   ./localai-cluster.sh model-capacity [model]
#                         print how many requests the cluster serves at once for a model
#                         (slots per PC x PCs with it loaded; LOCALAI_MODEL by default).
#                         Only the number goes to stdout; details go to stderr.
#   ./localai-cluster.sh model-list-all
#                         list every model of the host as "<model><TAB><capacity>".
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="${ROOT}/.env"

die() { echo "Error: $*" >&2; exit 1; }

env_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1 | tr -d '\r'
}

# Source IP of this PC on the route towards $1.
ip_towards() { ip -4 route get "$1" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }

# Once the web UI answers: create the admin account from .env if nobody signed up yet.
create_admin() {
    local url email password
    url="http://127.0.0.1:$(env_get LOCALAI_PORT)"
    email="$(env_get LOCALAI_ADMIN_EMAIL)"; password="$(env_get LOCALAI_ADMIN_PASSWORD)"
    [[ -n "$email" && -n "$password" ]] || return 0
    for _ in $(seq 1 300); do
        curl -sf -o /dev/null "${url}/readyz" && break
        sleep 2
    done
    curl -sf "${url}/api/auth/status" | grep -q '"hasUsers":false' || return 0
    curl -s -o /dev/null -H 'Content-Type: application/json' \
        -d "{\"email\":\"${email}\",\"password\":\"${password}\",\"name\":\"admin\",\"acknowledge_weak_password\":true}" \
        "${url}/api/auth/register"
}

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
# Key for API clients: Authorization: Bearer <key>
LOCALAI_API_KEY=sk-$(openssl rand -hex 24)
# Web UI login, created as admin on the host's first start. Must be an email address.
LOCALAI_ADMIN_EMAIL=admin@localai
LOCALAI_ADMIN_PASSWORD=admin123456

# Model loaded on every PC. Parallel requests per PC are picked by LocalAI from the
# GPU's VRAM; LLAMACPP_PARALLEL is used only when it picks none.
LOCALAI_MODEL=gemma-4-12b-it-qat-q4_0
LLAMACPP_PARALLEL=5

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

# --- host API, for model-capacity / model-list-all (works from any PC with the .env)
api_init() {
    [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}"
    command -v curl >/dev/null || die "curl is needed"
    API_URL="http://$(env_get LOCALAI_SERVER):$(env_get LOCALAI_PORT)"
    API_AUTH="Authorization: Bearer $(env_get LOCALAI_API_KEY)"
}
api_get() { curl -sf -m 10 -H "$API_AUTH" "${API_URL}$1"; }

# model_capacity MODEL -> "slots replicas in_flight"
#   slots:     "parallel:N" in the effective config (auto-tuned or set), else 1
#   replicas:  copies of the model in state "loaded" (one per PC)
#   in_flight: requests running on those copies right now
model_capacity() {
    local config nodes loaded slots replicas in_flight
    config="$(api_get "/api/models/config-json/$1")" || die "cannot read the config of '$1' from ${API_URL}"
    nodes="$(api_get /api/nodes/models)" || die "cannot read the loaded models from ${API_URL}"
    slots="$(grep -oE '"(n_)?parallel:[0-9]+"' <<<"$config" | head -1 | grep -oE '[0-9]+' || true)"
    # Each entry of /api/nodes/models is a flat JSON object.
    loaded="$(grep -oE "\{[^{}]*\"model_name\":\"$1\"[^{}]*\}" <<<"$nodes" | grep '"state":"loaded"' || true)"
    replicas="$(grep -c . <<<"$loaded" || true)"
    in_flight="$(grep -oE '"in_flight":[0-9]+' <<<"$loaded" | awk -F: '{n+=$2} END {print n+0}')"
    echo "${slots:-1} ${replicas:-0} ${in_flight}"
}

case "${1:-}" in
    host)
        check_docker
        [[ -f "$ENV_FILE" ]] || create_env
        export LOCALAI_LOCAL_NODE_NAME="$(hostname)"
        echo "LocalAI host: http://127.0.0.1:$(env_get LOCALAI_PORT)  (LAN: http://$(env_get LOCALAI_SERVER):$(env_get LOCALAI_PORT))"
        echo "Login: $(env_get LOCALAI_ADMIN_EMAIL) / $(env_get LOCALAI_ADMIN_PASSWORD)"
        echo "API key: $(env_get LOCALAI_API_KEY)   Ctrl+C stops it."
        create_admin >/dev/null 2>&1 &
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
    *)
        echo "Usage: $0 host|worker|model-capacity [model]|model-list-all" >&2
        exit 2
        ;;
esac
