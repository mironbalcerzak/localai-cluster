#!/bin/bash
# Turns the settings from .env into LocalAI worker settings, then starts the
# stock LocalAI entrypoint in worker mode.
set -euo pipefail

fail() { echo "localai-worker: $*" >&2; exit 1; }

[[ -n "${LOCALAI_SERVER:-}" ]] || fail "LOCALAI_SERVER is not set in .env (IP of the LocalAI server PC)"
[[ -n "${LOCALAI_REGISTRATION_TOKEN:-}" ]] || fail "LOCALAI_REGISTRATION_TOKEN is not set in .env"
[[ -n "${WORKER_IP:-}" ]] || fail "WORKER_IP is not set in .env: put this PC's Wi-Fi IP there (Windows: ipconfig, Linux: hostname -I)"

export LOCALAI_REGISTER_TO="http://${LOCALAI_SERVER}:${LOCALAI_SERVER_PORT:-23422}"
export LOCALAI_NATS_URL="nats://${LOCALAI_SERVER}:4222"
# The server connects back to this PC on these addresses (ports published by compose).
export LOCALAI_ADVERTISE_ADDR="${WORKER_IP}:50051"
export LOCALAI_ADVERTISE_HTTP_ADDR="${WORKER_IP}:50050"
export LOCALAI_NODE_NAME="${WORKER_NAME:-worker-${WORKER_IP//./-}}"

# Windows (Docker Desktop, WSL 2) puts the NVIDIA driver library libcuda.so.1 in
# /usr/lib/wsl/lib, not in /usr/lib/x86_64-linux-gnu as on Linux. LocalAI's llama.cpp
# backend starts with its own loader (lib/ld.so) and only looks in its own folder plus
# LD_LIBRARY_PATH, so without this it finds no CUDA and silently runs on the CPU.
if [[ -e /usr/lib/wsl/lib/libcuda.so.1 ]]; then
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    echo "localai-worker: Windows GPU driver found in /usr/lib/wsl/lib"
elif [[ -d /usr/lib/wsl ]]; then
    echo "localai-worker: WARNING: WSL 2 but no libcuda.so.1 in /usr/lib/wsl/lib: models will run on the CPU (update the NVIDIA driver and Docker Desktop)" >&2
fi

echo "localai-worker: node ${LOCALAI_NODE_NAME} (${WORKER_IP}) -> server ${LOCALAI_REGISTER_TO}"
exec /entrypoint.sh worker "$@"
