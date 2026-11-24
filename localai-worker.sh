#!/bin/bash
# LocalAI cluster worker for Linux.
#
#   ./localai-worker.sh [start]   build, start and test (default)
#   ./localai-worker.sh stop | logs | status | update
#
# Needs docker/.env (copy of .env.example with the server values filled in).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yml"
ENV_FILE="${ROOT}/docker/.env"
CONTAINER="localai-worker"

die() { echo "Error: $*" >&2; exit 1; }

# Value of KEY from docker/.env (without surrounding quotes, CR or inline comment).
env_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1 \
        | sed 's/[[:space:]]*#.*$//; s/\r$//; s/^"\(.*\)"$/\1/; s/[[:space:]]*$//'
}

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

check_prereqs() {
    command -v docker >/dev/null || die "Docker is not installed (see README.md)"
    docker info >/dev/null 2>&1 || die "Docker is not running, or this user may not use it (add yourself to the docker group)"
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is missing (package docker-compose-plugin)"
    [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}: put the configured .env there (template: .env.example)"
    [[ -n "$(env_get LOCALAI_SERVER)" ]] || die "LOCALAI_SERVER is empty in docker/.env"
    [[ -n "$(env_get LOCALAI_REGISTRATION_TOKEN)" ]] || die "LOCALAI_REGISTRATION_TOKEN is empty in docker/.env"
}

# WORKER_IP / WORKER_NAME: from .env, else detected. Exported for compose.
resolve_identity() {
    local server ip name
    server="$(env_get LOCALAI_SERVER)"
    ip="$(env_get WORKER_IP)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 route get "$server" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
        [[ -n "$ip" ]] || die "cannot detect this PC's IP towards ${server}; set WORKER_IP in docker/.env"
    fi
    name="$(env_get WORKER_NAME)"
    export WORKER_IP="$ip" WORKER_NAME="${name:-$(hostname)}"
}

wait_registered() {
    local server port
    server="$(env_get LOCALAI_SERVER)"; port="$(env_get LOCALAI_SERVER_PORT)"; port="${port:-23422}"
    echo -n "Waiting for the worker to register with ${server}"
    for _ in $(seq 1 90); do
        if docker logs "$CONTAINER" 2>&1 | grep -q "Worker ready"; then
            echo " OK"; return 0
        fi
        echo -n "."; sleep 2
    done
    echo
    echo "The worker did not register. Last log lines:" >&2
    docker logs --tail 15 "$CONTAINER" >&2 || true
    echo "Check: is the server running and is http://${server}:${port} reachable from this PC?" >&2
    return 1
}

# End-to-end check: one chat request for LOCALAI_MODEL through the server.
test_request() {
    local server port key model url code
    server="$(env_get LOCALAI_SERVER)"; port="$(env_get LOCALAI_SERVER_PORT)"; port="${port:-23422}"
    key="$(env_get LOCALAI_API_KEY)"; model="$(env_get LOCALAI_MODEL)"
    if [[ -z "$key" || -z "$model" ]]; then
        echo "Skipping the test request (LOCALAI_API_KEY or LOCALAI_MODEL empty in docker/.env)."
        return 0
    fi
    url="http://${server}:${port}/v1/chat/completions"
    echo "Test request for '${model}' (the first one can take minutes while the model is copied)..."
    for _ in $(seq 1 10); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 900 \
            -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
            -d "{\"model\":\"${model}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}" \
            "$url" || true)"
        case "$code" in
            200) echo "Cluster answered with ${model}: OK"; return 0 ;;
            503) echo "  model still loading, retrying in 30s..."; sleep 30 ;;
            401) echo "Test request rejected: LOCALAI_API_KEY is wrong." >&2; return 1 ;;
            404) echo "Test request: model '${model}' is not known to the server." >&2; return 1 ;;
            *) echo "Test request failed (HTTP ${code:-no answer})." >&2; return 1 ;;
        esac
    done
    echo "Model still loading after several minutes; check later with: $0 logs" >&2
}

case "${1:-start}" in
    start)
        check_prereqs; resolve_identity
        echo "Starting worker '${WORKER_NAME}' (${WORKER_IP}). The first start downloads ~10 GB."
        compose up -d --build
        wait_registered
        test_request
        echo "Done. The worker restarts with Docker automatically. Logs: $0 logs"
        ;;
    update)
        check_prereqs; resolve_identity
        compose build --pull
        compose up -d
        wait_registered
        ;;
    stop) compose down ;;
    logs) docker logs -f --tail 100 "$CONTAINER" ;;
    status) docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}}: {{.Status}}' ;;
    help|-h|--help) sed -n '2,8p' "$0" ;;
    *) die "unknown command: $1 (try: $0 help)" ;;
esac
