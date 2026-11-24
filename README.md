# LocalAI cluster

Several PCs with NVIDIA GPUs on one network serve LocalAI together. One PC is
the **host**: it runs the API and web UI and uses its own GPU. The other PCs are
**workers**: they join the host, get the model from it and take part of the
requests. Each PC serves several requests at once (LocalAI picks how many from
the GPU's VRAM; see Capacity), so every PC added raises the total.

```
localai-cluster.sh / .bat   host | worker
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
   The Wi-Fi network must be set to **Private** in Windows settings (Settings, Network &
   internet, Wi-Fi, the network's properties): the rules above do not apply on a Public one.

   If Windows once asked whether Docker may use the network and the answer was no (or the
   dialog was closed), it added **block** rules for Docker, and a block rule wins over the
   allow rule above. List them, and remove the ones whose Action is Block:
   ```powershell
   Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*docker*" -and $_.Action -eq "Block" } | Format-Table DisplayName, Profile, Enabled
   Get-NetFirewallRule | Where-Object { $_.DisplayName -like "*docker*" -and $_.Action -eq "Block" } | Remove-NetFirewallRule
   ```

**Linux**
1. NVIDIA driver, Docker Engine with the compose plugin, NVIDIA Container Toolkit
   (`sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`).
2. If ufw is on, a worker needs: `sudo ufw allow from <host-ip> to any port 50050:50059 proto tcp`

**Check that the host reaches each worker.** A worker connects out to the host, so it
shows as healthy in the web UI even when the host cannot connect back to it, yet every
model load and request the host sends to it then hangs. From the host, with the worker
running (any HTTP answer means the port is open; a timeout means it is blocked):
```
curl -m 5 http://<worker-ip>:50050/
curl -m 5 http://<worker-ip>:50051/
```

Check GPU access in Docker on either system:
`docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

Give every PC a fixed IP (DHCP reservation in the router).

## Host

```
./localai-cluster.sh host        (Windows: localai-cluster.bat host)
```

The first run creates `.env` next to the script: the host's IP, a join token,
the API key, the model (`LOCALAI_MODEL`, gemma-4-12b by default) and the
database password.

**No login and no API key.** LocalAI's distributed mode needs authentication, so
it stays on inside. A small Node proxy on the host's port (`docker/host/proxy/server.mjs`)
handles keys: a client's own key is checked once and passed on when LocalAI accepts
it; no key, or a key LocalAI rejects (401), is replaced by `LOCALAI_API_KEY`. So tools
that insist on sending a key work, and so do clients and the web UI without one (the
UI opens as the admin "API Key User"; the add-on pages do not work under that user).
The workers' own calls (`/api/node/*`) pass through unchanged, with their join token.

**Models load on demand, on every PC together, and only `LOCALAI_MAX_LOADED_MODELS`
at a time.** No model is loaded while the cluster is idle. The first request for a
model loads it, and within 5 seconds the proxy has every PC load it too (LocalAI
scheduling `spread_all`), so all PCs serve it; when the proxy unloads it, it leaves
every PC together. The proxy reads the model of every
inference request and keeps at most `LOCALAI_MAX_LOADED_MODELS` different models (1 by
default) loaded in the cluster: a request for another model first unloads the least
recently used idle one. If all loaded models are busy, the request waits until one is
idle (up to `LOCALAI_EVICT_WAIT`, 10 minutes, then HTTP 503), so with the default of 1
chat and embedding requests take turns, and each switch reloads a model. A model with
no requests for `LOCALAI_IDLE_UNLOAD` (2 minutes) is unloaded. The proxy logs every
unload: `docker logs localai-proxy-1`.

**Models install themselves.** When the host starts, its proxy checks that the chat
model `LOCALAI_MODEL` and the embedding model `LOCALAI_EMBEDDING_MODEL` are installed and
installs the missing ones from `LOCALAI_MODEL_URI` (with the variant `LOCALAI_MODEL_QUANT`)
and `LOCALAI_EMBEDDING_MODEL_URI`. The defaults are the UD-Q4_K_XL variant of
`unsloth/gemma-4-12B-it-qat-GGUF` and `Qwen3-Embedding-8B-Q4_K_M.gguf` from
`Qwen/Qwen3-Embedding-8B-GGUF`, about 12 GB of downloads on a fresh host. Follow it
with `docker logs -f localai-proxy-1`; a failed install is tried again after 10
minutes. Workers install nothing: they get the files from the host the first time
they load a model and keep them. For another model, set its name (as LocalAI names it
after the install) and its source in `.env`, and restart the host.

## Worker

1. Check out this repo and copy the host's `.env` next to the scripts.
2. Run:
   ```
   ./localai-cluster.sh worker      (Windows: localai-cluster.bat worker)
   ```

This PC's IP and name are detected (override with `WORKER_IP` / `WORKER_NAME` in
`.env`). The first run downloads the LocalAI image (~10 GB) and the CUDA backend
(~3 GB). They stay on the PC, so later runs are quick.

Next to the worker runs a `sync` service: every 5 seconds it compares this PC's models
with the host's and downloads what is missing from the host (about 12 GB the first
time, over the network, resumed after an interruption). So a model is already on the
PC when the host loads it here. Follow it with `docker logs -f localai-worker-sync`.
The host's own GPU worker has the same service (`worker-sync`).

## Capacity

```
./localai-cluster.sh model-capacity [model]   (Windows: localai-cluster.bat model-capacity [model])
./localai-cluster.sh model-list-all           (Windows: localai-cluster.bat model-list-all)
```

`model-capacity` prints how many requests the cluster serves at once for a model
(`LOCALAI_MODEL` by default): the request slots per PC (LocalAI picks them from the
GPU's VRAM) times the PCs that have the model loaded. Only the number goes to stdout,
so scripts can cap their concurrency with it, e.g. `N=$(./localai-cluster.sh model-capacity)`.
A summary line with the requests running right now goes to stderr.

`model-list-all` lists every model on the host, one `<model><TAB><capacity>` per line.
A model that is installed but not loaded on any PC shows 0.

Both work on any PC that has the `.env`. The numbers change when PCs join or leave,
so check them again from time to time.

## Chat from the command line

```
./localai-cluster.sh useChatCompletions "prompt" [model]
echo "prompt" | ./localai-cluster.sh useChatCompletions - [model]
(Windows: localai-cluster.bat useChatCompletions "prompt" [model])
```

Sends the prompt to the cluster (`/v1/chat/completions`, `LOCALAI_MODEL` by default)
and prints only the reply, so scripts can use it. Without a prompt, or with `-`, the
prompt is read from stdin. The first request after a start loads the model and can
take a minute. Exit codes: 1 on an error, 3 when the reply was cut off by the token
limit. The Linux script needs `jq` or `python3`.

## Security notes

- Anyone who can reach the host's port is admin of LocalAI: they can use the API,
  install and delete models and change settings. Keep it on a home network.
- `.env` holds the join token, API key and database password: share it only with your own PCs.
- The message bus (NATS, port 4222) has no password: anyone on the network could
  send it commands. Fine on a home network, not on a shared one.
