#!/bin/bash
# LocalAI host (Linux): the server of the cluster. Runs the API + web UI, Postgres,
# NATS and a worker on this PC's GPU. Other PCs join with localai-worker.sh / .bat.
#
#   ./localai-host.sh [start]     start (default); creates docker/host/.env on first run
#   ./localai-host.sh stop | update | status | logs [service]
#   ./localai-host.sh worker-env  write docker/worker/.env to hand out to worker PCs
#   ./localai-host.sh nodes       list the workers
#   ./localai-host.sh api-key     print the API key for clients
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
COMPOSE_FILE="${ROOT}/docker/host/docker-compose.yml"
ENV_FILE="${ROOT}/docker/host/.env"
WORKER_ENV="${ROOT}/docker/worker/.env"
DEFAULT_PORT=23422

die() { echo "Error: $*" >&2; exit 1; }

env_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1 \
        | sed 's/[[:space:]]*#.*$//; s/\r$//; s/^"\(.*\)"$/\1/; s/[[:space:]]*$//'
}

port() { local p; p="$(env_get LOCALAI_PORT)"; echo "${p:-$DEFAULT_PORT}"; }
url() { echo "http://127.0.0.1:$(port)"; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

check_docker() {
    command -v docker >/dev/null || die "Docker is not installed (see README.md)"
    docker info >/dev/null 2>&1 || die "Docker is not running, or this user may not use it (add yourself to the docker group)"
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is missing (package docker-compose-plugin)"
}

# Settings and secrets, created once.
ensure_env() {
    [[ -f "$ENV_FILE" ]] && return 0
    command -v openssl >/dev/null || die "openssl is needed to create the secrets"
    (
        umask 077
        cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=localai
LOCALAI_PORT=${DEFAULT_PORT}
# 0.0.0.0 = reachable from the LAN (workers register here). The web UI needs a login.
LOCALAI_BIND=0.0.0.0
LOCALAI_REGISTRATION_TOKEN=$(openssl rand -hex 24)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
# Static key for API clients: Authorization: Bearer <key>
LOCALAI_API_KEY=sk-$(openssl rand -hex 24)
# Parallel requests the GPU of this PC serves at once.
LLAMACPP_PARALLEL=5
LOCALAI_LOCAL_NODE_NAME=$(hostname)
EOF
    )
    echo "Created ${ENV_FILE}"
}

wait_ready() {
    echo -n "Waiting for LocalAI"
    for _ in $(seq 1 90); do
        if curl -sf -o /dev/null "$(url)/readyz"; then echo " OK"; return 0; fi
        echo -n "."; sleep 2
    done
    echo; echo "LocalAI did not get ready. See: $0 logs frontend" >&2
    return 1
}

worker_env() {
    local ip model
    ip="$(lan_ip)"
    [[ -n "$ip" ]] || die "cannot detect this PC's LAN IP"
    # First model of the scheduling list: the one every worker loads.
    model="$(sed -n 's/^- model_name:[[:space:]]*//p' "${ROOT}/docker/host/scheduling.yaml" | head -1)"
    (
        umask 077
        cat > "$WORKER_ENV" <<EOF
# Created by 'localai-host.sh worker-env'. Same file for every worker PC.

# --- LocalAI server ---
LOCALAI_SERVER=${ip}
LOCALAI_SERVER_PORT=$(port)
LOCALAI_REGISTRATION_TOKEN=$(env_get LOCALAI_REGISTRATION_TOKEN)
# Lets the start scripts send a test request after starting.
LOCALAI_API_KEY=$(env_get LOCALAI_API_KEY)

# Model the start scripts test with (workers load what docker/host/scheduling.yaml says).
LOCALAI_MODEL=${model:-gemma-4-12b-it-Q4_K_M}

# Parallel requests this GPU serves at once
LLAMACPP_PARALLEL=$(env_get LLAMACPP_PARALLEL)

# --- this PC: leave empty for auto-detection ---
WORKER_IP=
WORKER_NAME=
EOF
    )
    echo "Written: ${WORKER_ENV}  (gitignored: holds the join token and API key)"
    echo "Server address in it: ${ip}. Give this PC a fixed IP in the router, or rerun this when it changes."
    echo "On each worker PC: check out this repo, put the file at docker/worker/.env, run localai-worker.bat / .sh"
}

case "${1:-start}" in
    start)
        check_docker; ensure_env
        compose up -d
        wait_ready
        echo "LocalAI host running: $(url)   LAN: http://$(lan_ip):$(port)"
        echo "First visit: sign up; the first account becomes admin."
        echo "API key: $0 api-key   Workers: $0 nodes   Worker settings: $0 worker-env"
        ;;
    update)
        check_docker; ensure_env
        compose pull
        compose up -d
        wait_ready
        ;;
    stop) check_docker; compose down ;;
    status) check_docker; compose ps ;;
    logs) check_docker; shift; compose logs -f --tail 100 "$@" ;;
    worker-env) [[ -f "$ENV_FILE" ]] || die "start the host once first"; worker_env ;;
    api-key) [[ -f "$ENV_FILE" ]] || die "start the host once first"; env_get LOCALAI_API_KEY ;;
    nodes)
        curl -sf -H "Authorization: Bearer $(env_get LOCALAI_API_KEY)" "$(url)/api/nodes" \
            | python3 -c 'import json,sys
d=json.load(sys.stdin); d=d.get("nodes",d) if isinstance(d,dict) else d
for n in d: print(f"{n.get(\"name\",\"?\"):24} {n.get(\"address\",\"\"):24} {n.get(\"status\",\"\")}")' \
            || die "host not reachable at $(url)"
        ;;
    help|-h|--help) sed -n '2,10p' "$0" ;;
    *) die "unknown command: $1 (try: $0 help)" ;;
esac
