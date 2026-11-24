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

# LocalAI's llama.cpp backend starts with its own loader (lib/ld.so), which looks only in
# its own folder, LD_LIBRARY_PATH and the standard folders, not in the system's library
# cache. Windows (Docker Desktop, WSL 2) puts the NVIDIA driver library libcuda.so.1 in
# /usr/lib/wsl/lib, listed only in that cache: the backend then finds no CUDA and silently
# runs on the CPU, while nvidia-smi (mounted at /usr/bin) shows the GPU just fine. So
# put the folder that holds libcuda.so.1 on LD_LIBRARY_PATH, wherever it is.
cuda_dir=""
for d in /usr/lib/wsl/lib $(ldconfig -p 2>/dev/null | awk '$1 == "libcuda.so.1" {print $NF}' | xargs -r -n1 dirname); do
    if [[ -e "$d/libcuda.so.1" ]]; then cuda_dir="$d"; break; fi
done
case "$cuda_dir" in
    "")
        echo "localai-worker: WARNING: no NVIDIA driver library (libcuda.so.1) in this container: models will run on the CPU. Linux: install the NVIDIA Container Toolkit; Windows: update the NVIDIA driver and Docker Desktop" >&2;;
    /usr/lib/x86_64-linux-gnu|/lib/x86_64-linux-gnu)
        echo "localai-worker: NVIDIA driver library: ${cuda_dir}/libcuda.so.1";;
    *)
        export LD_LIBRARY_PATH="${cuda_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        echo "localai-worker: NVIDIA driver library: ${cuda_dir}/libcuda.so.1 (added to LD_LIBRARY_PATH)";;
esac

echo "localai-worker: node ${LOCALAI_NODE_NAME} (${WORKER_IP}) -> server ${LOCALAI_REGISTER_TO}"
exec /entrypoint.sh worker "$@"
