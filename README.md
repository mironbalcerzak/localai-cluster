# LocalAI cluster

Several PCs with NVIDIA GPUs on one network serve LocalAI together. One PC is
the **host**: it runs the API and web UI and uses its own GPU. The other PCs
are **workers**: they join the host, get the model from it (gemma-4-12b by
default) and take part of the requests. Each PC serves `LLAMACPP_PARALLEL`
requests at once (5 by default), so every PC added raises the total.

```
localai-host.sh / .bat     run the host
localai-worker.sh / .bat   run a worker
*.ps1                      the Windows logic behind the .bat files
.env.example               template of the worker settings
docker/host/               host compose file, scheduling.yaml, .env (generated)
docker/worker/             worker Dockerfile, compose file, .env (from the host)
```

The `.bat` files can be double-clicked. Every script takes a command:
`start` (default), `stop`, `update`, `status`, `logs`, plus the extras below.

## Prerequisites (every PC)

**Windows**
1. Up-to-date NVIDIA driver.
2. [Docker Desktop](https://www.docker.com/products/docker-desktop/) with the WSL 2 backend (the default).
3. Inbound firewall rule, in PowerShell as Administrator. On a worker:
   ```powershell
   New-NetFirewallRule -DisplayName "LocalAI worker" -Direction Inbound -Protocol TCP -LocalPort 50050-50059 -Action Allow -Profile Private,Domain
   ```
   On the host:
   ```powershell
   New-NetFirewallRule -DisplayName "LocalAI host" -Direction Inbound -Protocol TCP -LocalPort 23422,4222 -Action Allow -Profile Private,Domain
   ```
   The Wi-Fi network must be set to **Private** in Windows settings.

**Linux**
1. NVIDIA driver, Docker Engine with the compose plugin, NVIDIA Container Toolkit
   (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`).
2. If ufw is on, a worker needs: `sudo ufw allow from <host-ip> to any port 50050:50059 proto tcp`

Check GPU access in Docker on either system:
`docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

Give every PC a fixed IP (DHCP reservation in the router).

## Host

1. Run `localai-host.bat` (Windows) or `./localai-host.sh` (Linux). The first
   start creates `docker/host/.env` with fresh secrets.
2. Open `http://<host-ip>:23422` and sign up. The first account becomes admin;
   later sign-ups wait for approval.
3. The model must exist on the host: on a fresh host, install
   `gemma-4-12b-it-Q4_K_M` in the web UI, or change `docker/host/scheduling.yaml`
   to the model you use. That file decides which models every worker loads.
4. Create the worker settings: `localai-host.bat worker-env` / `./localai-host.sh worker-env`.
   This writes `docker/worker/.env` with the host address, join token and API key.

Extras: `nodes` lists the workers, `api-key` prints the key for API clients
(`Authorization: Bearer <key>`), `logs frontend` shows the logs of one service.

## Worker

1. Check out this repo and put the `docker/worker/.env` created on the host into
   `docker/worker/`. This PC's IP and name are detected automatically; set
   `WORKER_IP` / `WORKER_NAME` there only to override them.
2. Run `localai-worker.bat` (Windows) or `./localai-worker.sh` (Linux).

The script builds the image, starts the worker, waits until it is registered and
sends one test request for the model. The first start downloads the LocalAI
image (~10 GB), then the CUDA backend (~3 GB) and the model from the host (~7 GB
over Wi-Fi). They stay on the PC, so later starts are quick. The worker restarts
with Docker automatically.

## Security notes

- `docker/*/.env` hold the join token, API key and database password; they are gitignored.
- The message bus (NATS, port 4222) has no password: anyone on the network could
  send it commands. Fine on a home network, not on a shared one.
