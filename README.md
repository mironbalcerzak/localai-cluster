# LocalAI worker

Turns a PC with an NVIDIA GPU into a worker of the LocalAI server. The server
sends it the model (gemma-4-12b by default) and routes part of the requests to it,
so every PC added raises the number of requests served in parallel.

```
localai-worker.bat / .sh   start, stop, logs, status, update
localai-worker.ps1         the Windows logic behind the .bat
.env.example               template of the settings
docker/                    Dockerfile, compose file, entrypoint; docker/.env goes here
```

## 1. Prerequisites (once per PC)

**Windows**
1. Up-to-date NVIDIA driver.
2. [Docker Desktop](https://www.docker.com/products/docker-desktop/) with the WSL 2 backend (the default).
3. Let the server reach the worker ports. In PowerShell as Administrator:
   ```powershell
   New-NetFirewallRule -DisplayName "LocalAI worker" -Direction Inbound -Protocol TCP -LocalPort 50050-50059 -Action Allow -Profile Private,Domain
   ```
   The Wi-Fi network must be set to **Private** in Windows settings.

**Linux**
1. NVIDIA driver, Docker Engine with the compose plugin, NVIDIA Container Toolkit
   (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`).
2. If ufw is on: `sudo ufw allow from <server-ip> to any port 50050:50059 proto tcp`

Check GPU access in Docker on either system:
`docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

## 2. Settings

Put the configured `.env` you received into the `docker/` directory (`docker/.env`).
It holds the server address and join token, so it is not in git.
(On the server, `localai worker-kit` creates it. By hand: copy `.env.example`.)

This PC's IP and name are detected automatically. Set `WORKER_IP` / `WORKER_NAME`
in `docker/.env` only to override them. Best: give every PC a fixed IP (DHCP
reservation in the router).

## 3. Run

- **Windows:** double-click `localai-worker.bat`
- **Linux:** `./localai-worker.sh`

The script builds the image, starts the worker, waits until it is registered with
the server and sends one test request for the model. The first start downloads the
LocalAI image (~10 GB), then the CUDA backend (~3 GB) and the model from the server
(~7 GB over Wi-Fi). These stay on the PC, so later starts are quick.

The worker restarts with Docker automatically. Other commands:
`stop`, `logs`, `status`, `update` (e.g. `localai-worker.bat logs`).
