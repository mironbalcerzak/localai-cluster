# LocalAI cluster

Several PCs with NVIDIA GPUs on one network serve LocalAI together. One PC is
the **host**: it runs the API and web UI and uses its own GPU. The other PCs are
**workers**: they join the host, get the model from it and take part of the
requests. Each PC serves `LLAMACPP_PARALLEL` requests at once (5 by default), so
every PC added raises the total.

```
localai.sh / localai.bat   host | worker
.env                       cluster settings, created by the host (gitignored)
.env.example               the format of .env
docker/host/               host compose stack (API, Postgres, NATS, local GPU worker)
docker/worker/             worker image and compose file
```

Both scripts run in the foreground and show the logs; Ctrl+C stops everything.

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

```
./localai.sh host        (Windows: localai.bat host)
```

The first run creates `.env` next to the script: the host's IP, a join token,
the API key, the model (`LOCALAI_MODEL`, gemma-4-12b by default) and the
database password. Then open `http://<host-ip>:23422` and sign up; the first
account becomes admin, later sign-ups wait for approval. API clients send
`Authorization: Bearer <LOCALAI_API_KEY>`.

The model named in `LOCALAI_MODEL` must be installed on the host (web UI, Models);
the host then loads it on every PC.

## Worker

1. Check out this repo and copy the host's `.env` next to the scripts.
2. Run:
   ```
   ./localai.sh worker      (Windows: localai.bat worker)
   ```

This PC's IP and name are detected (override with `WORKER_IP` / `WORKER_NAME` in
`.env`). The first run downloads the LocalAI image (~10 GB), then the CUDA backend
(~3 GB) and the model from the host (~7 GB over Wi-Fi). They stay on the PC, so
later runs are quick.

## Security notes

- `.env` holds the join token, API key and database password: share it only with your own PCs.
- The message bus (NATS, port 4222) has no password: anyone on the network could
  send it commands. Fine on a home network, not on a shared one.
