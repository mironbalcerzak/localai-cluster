#!/bin/bash
# LocalAI cluster. Runs in the foreground; Ctrl+C stops it.
#
#   ./localai.sh host     run the server (API + web UI) and use this PC's GPU.
#                         The first run creates .env next to this script.
#   ./localai.sh worker   lend this PC's GPU to the host. Needs the host's .env
#                         copied next to this script.
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
# Copy this file next to localai.sh / localai.bat on every worker PC.

# Address of the host. Update it here and on the workers if the host's IP changes.
LOCALAI_SERVER=${ip}
LOCALAI_PORT=23422
LOCALAI_REGISTRATION_TOKEN=$(openssl rand -hex 24)
# Key for API clients: Authorization: Bearer <key>
LOCALAI_API_KEY=sk-$(openssl rand -hex 24)

# Model loaded on every PC, and parallel requests per PC.
LOCALAI_MODEL=gemma-4-12b-it-Q4_K_M
LLAMACPP_PARALLEL=5

# Used by the host only.
LOCALAI_BIND=0.0.0.0
POSTGRES_PASSWORD=$(openssl rand -hex 24)

# Worker only, normally detected: IP and name of the worker PC.
WORKER_IP=
WORKER_NAME=
EOF
    )
    echo "Created ${ENV_FILE}: copy it next to localai.sh / localai.bat on every worker PC."
}

case "${1:-}" in
    host)
        check_docker
        [[ -f "$ENV_FILE" ]] || create_env
        export LOCALAI_LOCAL_NODE_NAME="$(hostname)"
        echo "LocalAI host: http://127.0.0.1:$(env_get LOCALAI_PORT)  (LAN: http://$(env_get LOCALAI_SERVER):$(env_get LOCALAI_PORT))"
        echo "API key: $(env_get LOCALAI_API_KEY)   Ctrl+C stops it."
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
    *)
        echo "Usage: $0 host|worker" >&2
        exit 2
        ;;
esac
