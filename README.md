# LocalAI worker – setup on another PC

This repo turns a PC with an NVIDIA GPU into a worker of the LocalAI server.
The server sends it the model and routes part of the requests to it.

## 1. Install prerequisites (once)

**Windows**
1. Up-to-date NVIDIA driver.
2. Docker Desktop with the WSL 2 backend (the default). GPU support works out of the box.
3. Check in PowerShell: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`
4. Allow the server to reach the worker ports (PowerShell as Administrator):
   ```powershell
   New-NetFirewallRule -DisplayName "LocalAI worker" -Direction Inbound -Protocol TCP -LocalPort 50050-50059 -Action Allow -Profile Private,Domain
   ```
   Make sure the Wi-Fi network is set to **Private** in Windows settings.

**Linux**
1. NVIDIA driver, Docker Engine, NVIDIA Container Toolkit
   (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`).
2. Check: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`
3. If ufw is on: `sudo ufw allow from <server-ip> to any port 50050:50059 proto tcp`

## 2. Configure

Get the files onto the PC: copy this folder, or `git clone` it. The `.env` file holds
the server address and join token and is not in git. Get it from the server PC:
running `localai worker-kit` there writes it into this folder, and you copy it along.
Without it, copy `.env.example` to `.env` and fill in the server values.

In `.env`, set `WORKER_IP` to this PC's Wi-Fi IP
(Windows: `ipconfig`, Linux: `hostname -I`). Optionally set `WORKER_NAME`.
Best: give every PC a fixed IP (DHCP reservation in the router).

## 3. Start

In this folder:

```
docker compose up -d --build
docker compose logs -f
```

You should see `Registered with frontend` and `Worker ready`. The worker then shows
up in the server's web UI (Nodes). The first request it serves is slow: it downloads
the CUDA backend (~3 GB) and receives the model from the server (~7 GB over Wi-Fi).
After that, both stay on this PC.

It restarts with Docker automatically. Stop: `docker compose down`.
Update: `docker compose build --pull && docker compose up -d`.
