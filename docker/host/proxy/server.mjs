// LocalAI cluster proxy: the host's port on the network, in front of the LocalAI frontend.
//
// Auth     LocalAI's distributed mode needs authentication. A client's own key is checked
//          once (cached) and passed on when LocalAI accepts it; no key, or a key LocalAI
//          rejects with 401, is replaced by LOCALAI_API_KEY. Workers' /api/node/* calls
//          pass through untouched (they carry their join token).
// Eviction Inference requests name their model. At most LOCALAI_MAX_LOADED_MODELS different
//          models are loaded in the cluster: before a request needs another model, the least
//          recently used idle one is unloaded. If all loaded models are busy, the request
//          waits (up to LOCALAI_EVICT_WAIT) instead of failing out of memory.
// Idle     A model with no running requests and no use for LOCALAI_IDLE_UNLOAD is unloaded.
// Mirror   Every 5 s: a model loaded on any PC is switched to "a copy on every PC" (LocalAI
//          scheduling spread_all), so all PCs load it together; when this proxy unloads it,
//          it goes back to "load on demand" first, so it leaves every PC together.
// Files    Workers' sync service (docker/worker/sync) downloads the host's model files from
//          /_cluster/files (needs the join token), so a load on a worker finds them in place.
// Install  At start, LOCALAI_MODEL and LOCALAI_EMBEDDING_MODEL are installed on the host when
//          missing (from LOCALAI_MODEL_URI / LOCALAI_EMBEDDING_MODEL_URI). Workers get the
//          files from the host the first time they load a model.
//
// Plain Node (no packages). Settings come from the environment (see docker-compose.yml).
import http from "node:http";
import { EventEmitter } from "node:events";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { join, normalize } from "node:path";

const UPSTREAM_HOST = process.env.UPSTREAM_HOST || "frontend";
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT || 8080);
const LISTEN_PORT = Number(process.env.LISTEN_PORT || 8080);
const DEFAULT_KEY = process.env.LOCALAI_API_KEY || "";
const MAX_LOADED = Math.max(1, parseInt(process.env.LOCALAI_MAX_LOADED_MODELS || "1", 10) || 1);
const IDLE_MS = parseDuration(process.env.LOCALAI_IDLE_UNLOAD || "2m");
const EVICT_WAIT_MS = parseDuration(process.env.LOCALAI_EVICT_WAIT || "10m");
const KEY_CACHE_MS = 5 * 60_000;
const MAX_JSON_BODY = 32 * 1024 * 1024;
const MIRROR_MS = 5000;
const MODELS_DIR = process.env.MODELS_DIR || "/models"; // the host's models, read-only
const REGISTRATION_TOKEN = process.env.LOCALAI_REGISTRATION_TOKEN || "";
const IDLE_CHECK_MS = 15_000;
const INSTALL_RETRY_MS = 10 * 60_000;

// Models the cluster needs, installed at start when missing.
const REQUIRED_MODELS = [
  {
    name: process.env.LOCALAI_MODEL,
    uri: process.env.LOCALAI_MODEL_URI,
    quant: process.env.LOCALAI_MODEL_QUANT,
  },
  {
    name: process.env.LOCALAI_EMBEDDING_MODEL,
    uri: process.env.LOCALAI_EMBEDDING_MODEL_URI,
    embeddings: true,
  },
].filter((m) => m.name);

// POST endpoints whose JSON body names the model they run on.
const INFERENCE_PATHS = new Set([
  "/v1/chat/completions", "/chat/completions",
  "/v1/completions", "/completions",
  "/v1/embeddings", "/embeddings",
  "/v1/responses", "/v1/rerank", "/v1/messages",
  "/v1/audio/speech", "/tts",
  "/api/chat", "/api/generate", "/api/embed", "/api/embeddings",
]);
const isInference = (method, path) =>
  method === "POST" && (INFERENCE_PATHS.has(path) || path.startsWith("/v1/images/"));

function parseDuration(text) {
  const m = String(text).trim().match(/^(\d+(?:\.\d+)?)(ms|s|m|h)?$/);
  if (!m) throw new Error(`bad duration: ${text}`);
  return Number(m[1]) * { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[m[2] || "s"];
}

const log = (...args) => console.log(new Date().toISOString(), ...args);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const agent = new http.Agent({ keepAlive: true, maxSockets: 512 });

// ---------------------------------------------------------------- LocalAI API (default key)

function api(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request(
      {
        agent, host: UPSTREAM_HOST, port: UPSTREAM_PORT, method, path, timeout: 60_000,
        headers: {
          Authorization: `Bearer ${DEFAULT_KEY}`,
          ...(data && { "Content-Type": "application/json", "Content-Length": data.length }),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try { json = text ? JSON.parse(text) : null; } catch {}
          resolve({ status: res.statusCode, json, text });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error(`${method} ${path}: timeout`)));
    req.on("error", reject);
    req.end(data);
  });
}

// ---------------------------------------------------------------- auth

const keyCache = new Map(); // credential -> { ok, until }

async function credentialAccepted(headers) {
  const id = `${headers.authorization || ""}|${headers["x-api-key"] || ""}`;
  const hit = keyCache.get(id);
  if (hit && hit.until > Date.now()) return hit.ok;
  const status = await new Promise((resolve) => {
    const req = http.request(
      {
        agent, host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: "GET", path: "/v1/models", timeout: 15_000,
        headers: {
          ...(headers.authorization && { authorization: headers.authorization }),
          ...(headers["x-api-key"] && { "x-api-key": headers["x-api-key"] }),
        },
      },
      (res) => { res.resume(); resolve(res.statusCode); },
    );
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve(0));
    req.end();
  });
  if (status === 0) return true; // LocalAI unreachable: pass the key on, the request will fail anyway
  const ok = status !== 401;
  keyCache.set(id, { ok, until: Date.now() + KEY_CACHE_MS });
  if (keyCache.size > 1000) keyCache.delete(keyCache.keys().next().value);
  return ok;
}

// Headers for the frontend: the client's own key when LocalAI accepts it, else the default key.
async function upstreamHeaders(req, path) {
  const headers = { ...req.headers };
  headers["x-forwarded-for"] = [headers["x-forwarded-for"], req.socket.remoteAddress].filter(Boolean).join(", ");
  headers["x-forwarded-host"] ??= req.headers.host;
  headers["x-forwarded-proto"] ??= "http";
  if (path.startsWith("/api/node/")) return headers;
  const own = headers.authorization || headers["x-api-key"];
  if (own && (await credentialAccepted(headers))) return headers;
  if (own) log(`auth: key rejected by LocalAI, using the default key (${req.method} ${path})`);
  delete headers["x-api-key"];
  headers.authorization = `Bearer ${DEFAULT_KEY}`;
  return headers;
}

// ---------------------------------------------------------------- models

const usage = new Map(); // model -> { active, lastUsed } for requests that went through this proxy
const released = new EventEmitter();
released.setMaxListeners(0);

function use(model) {
  let u = usage.get(model);
  if (!u) usage.set(model, (u = { active: 0, lastUsed: 0 }));
  return u;
}

// Models LocalAI has on any PC: name -> { states, inFlight, lastUsed (ms) }.
async function loadedModels() {
  const r = await api("GET", "/api/nodes/models");
  if (r.status !== 200 || !Array.isArray(r.json)) throw new Error(`GET /api/nodes/models: HTTP ${r.status}`);
  const out = new Map();
  for (const rep of r.json) {
    const m = out.get(rep.model_name) || { states: [], inFlight: 0, lastUsed: 0 };
    m.states.push(rep.state);
    m.inFlight += rep.in_flight || 0;
    m.lastUsed = Math.max(m.lastUsed, Date.parse(rep.last_used || rep.updated_at || 0) || 0);
    out.set(rep.model_name, m);
  }
  return out;
}

// Unload a model on every PC and wait until LocalAI no longer lists it, so its VRAM is free.
async function unload(model, reason) {
  log(`unload ${model} (${reason})`);
  // Back to "load on demand" first, or LocalAI would load it again on every PC.
  await setScheduling(model, "demand");
  unloadedAt.set(model, Date.now());
  const r = await api("POST", "/backend/shutdown", { model });
  if (r.status !== 200 && r.status !== 404) log(`unload ${model}: HTTP ${r.status} ${r.text.slice(0, 200)}`);
  for (let i = 0; i < 60; i++) {
    if (!(await loadedModels()).has(model)) break;
    await sleep(500);
  }
  await sleep(1000); // the worker's process exits just after LocalAI drops the entry
}

// Model switches and idle unloads run one at a time.
let lock = Promise.resolve();
function exclusive(fn) {
  const run = lock.then(fn, fn);
  lock = run.catch(() => {});
  return run;
}

class Busy extends Error {}

// Reserve a slot for one request on `model`, unloading idle models when the limit needs it.
async function admit(model, isGone) {
  const deadline = Date.now() + EVICT_WAIT_MS;
  let announced = false;
  for (;;) {
    const ok = await exclusive(async () => {
      const loaded = await loadedModels();
      const occupied = new Set(loaded.keys());
      for (const [name, u] of usage) if (u.active > 0) occupied.add(name);
      if (occupied.has(model) || occupied.size < MAX_LOADED) {
        use(model).active++;
        return true;
      }
      const idle = [...occupied]
        .filter((name) => name !== model && !(usage.get(name)?.active > 0) && !(loaded.get(name)?.inFlight > 0))
        .sort((a, b) => lastUsed(a, loaded) - lastUsed(b, loaded));
      const need = occupied.size - MAX_LOADED + 1;
      if (idle.length < need) return false;
      for (const name of idle.slice(0, need)) await unload(name, `${model} needs room, limit ${MAX_LOADED}`);
      use(model).active++;
      return true;
    });
    if (ok) return;
    if (isGone()) throw new Busy("client gone");
    if (Date.now() > deadline) throw new Busy(`all ${MAX_LOADED} loaded model(s) stayed busy for ${EVICT_WAIT_MS / 1000}s`);
    if (!announced) log(`wait: ${model} waits for a loaded model to become idle (limit ${MAX_LOADED})`);
    announced = true;
    await new Promise((r) => {
      const t = setTimeout(r, 5000);
      released.once("release", () => { clearTimeout(t); r(); });
    });
  }
}

function release(model) {
  const u = use(model);
  u.active = Math.max(0, u.active - 1);
  u.lastUsed = Date.now();
  released.emit("release");
}

const lastUsed = (name, loaded) => Math.max(usage.get(name)?.lastUsed || 0, loaded.get(name)?.lastUsed || 0);

async function unloadIdle() {
  await exclusive(async () => {
    const loaded = await loadedModels();
    const now = Date.now();
    for (const [name, m] of loaded) {
      if (usage.get(name)?.active > 0 || m.inFlight > 0) continue;
      if (!m.states.every((s) => s === "loaded")) continue; // still loading somewhere
      if (now - lastUsed(name, loaded) < IDLE_MS) continue;
      await unload(name, `idle for ${Math.round((now - lastUsed(name, loaded)) / 1000)}s`);
    }
  });
}

// ---------------------------------------------------------------- mirror loads to every PC

const scheduling = new Map(); // model -> "all" | "demand", as last set in LocalAI
const unloadedAt = new Map(); // model -> when this proxy unloaded it
let schedulingRead = false;

async function setScheduling(model, mode) {
  if (scheduling.get(model) === mode) return;
  const body = mode === "all"
    ? { model_name: model, spread_all: true }
    : { model_name: model, min_replicas: 0, max_replicas: 64 };
  const r = await api("POST", "/api/nodes/scheduling", body);
  if (r.status !== 200) return log(`mirror: could not change ${model}: HTTP ${r.status} ${r.text.slice(0, 200)}`);
  scheduling.set(model, mode);
  log(`mirror: ${model} ${mode === "all" ? "loads on every PC" : "loads on demand again"}`);
}

// A model loaded anywhere runs on every PC. Right after this proxy unloaded a model, a copy
// that was still loading somewhere is not spread again (the idle check removes it).
async function mirror() {
  await exclusive(async () => {
    if (!schedulingRead) {
      const r = await api("GET", "/api/nodes/scheduling");
      for (const e of Array.isArray(r.json) ? r.json : []) scheduling.set(e.model_name, e.spread_all ? "all" : "demand");
      schedulingRead = true;
    }
    const loaded = await loadedModels();
    const names = new Set([...loaded.keys(), ...[...scheduling].filter(([, m]) => m === "all").map(([n]) => n)]);
    for (const name of names) {
      const justUnloaded = Date.now() - (unloadedAt.get(name) || 0) < 60_000 && !(usage.get(name)?.active > 0);
      await setScheduling(name, loaded.has(name) && !justUnloaded ? "all" : "demand");
    }
  });
}

// ---------------------------------------------------------------- model files for workers

// Every installed model's files (model file, mmproj), relative to MODELS_DIR. A worker keeps
// them at /models/<model>/<path>, where LocalAI's own upload would put them.
let manifestCache = { at: 0, value: null };
async function manifest() {
  if (manifestCache.value && Date.now() - manifestCache.at < 5000) return manifestCache.value;
  const models = [];
  for (const name of await installedModels()) {
    const cfg = (await api("GET", `/api/models/config-json/${encodeURIComponent(name)}`)).json;
    const files = [];
    for (const p of [cfg?.parameters?.model, cfg?.mmproj]) {
      if (typeof p !== "string" || !p) continue;
      const rel = normalize(p).replace(/^\/+/, "");
      if (rel.startsWith("..")) continue;
      const st = await stat(join(MODELS_DIR, rel)).catch(() => null);
      if (st?.isFile()) files.push({ path: rel, size: st.size });
    }
    if (files.length) models.push({ name, files });
  }
  manifestCache = { at: Date.now(), value: { models } };
  return manifestCache.value;
}

// GET /_cluster/files              -> { models: [{ name, files: [{ path, size }] }] }
// GET /_cluster/files?path=<path>  -> the file (Range supported, for resuming)
async function serveFiles(req, res) {
  if (!REGISTRATION_TOKEN || req.headers["x-registration-token"] !== REGISTRATION_TOKEN) {
    return sendError(res, 401, "join token required (X-Registration-Token)");
  }
  const url = new URL(req.url, "http://proxy");
  const m = await manifest();
  const path = url.searchParams.get("path");
  if (!path) {
    const body = JSON.stringify(m);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    return res.end(body);
  }
  const file = m.models.flatMap((x) => x.files).find((f) => f.path === path);
  if (!file) return sendError(res, 404, "not a model file");
  const range = String(req.headers.range || "").match(/^bytes=(\d+)-$/);
  const start = range ? Number(range[1]) : 0;
  if (start > file.size) return sendError(res, 416, "range past the end");
  res.writeHead(range ? 206 : 200, {
    "Content-Type": "application/octet-stream",
    "Content-Length": file.size - start,
    ...(range && { "Content-Range": `bytes ${start}-${file.size - 1}/${file.size}` }),
  });
  createReadStream(join(MODELS_DIR, file.path), { start }).on("error", () => res.destroy()).pipe(res);
}

// ---------------------------------------------------------------- install missing models

async function installedModels() {
  const r = await api("GET", "/v1/models");
  if (r.status !== 200) throw new Error(`GET /v1/models: HTTP ${r.status}`);
  return new Set((r.json?.data ?? []).map((m) => m.id));
}

let installedCache = { at: 0, value: new Set() };
async function isInstalled(model) {
  if (Date.now() - installedCache.at > 10_000 || !installedCache.value.has(model)) {
    installedCache = { at: Date.now(), value: await installedModels() };
  }
  return installedCache.value.has(model);
}

// The import registers every GGUF as a chat model: switch embedding models over.
async function markEmbeddings(name) {
  const cfg = await api("GET", `/api/models/config-json/${encodeURIComponent(name)}`);
  if (cfg.json?.embeddings === true) return;
  const r = await api("PATCH", `/api/models/config-json/${encodeURIComponent(name)}`, {
    embeddings: true,
    known_usecases: ["embeddings"],
  });
  log(r.status === 200 ? `install: marked ${name} as an embedding model` : `install: could not mark ${name} as an embedding model: HTTP ${r.status}`);
}

// Install one model and wait for the download. Returns true when it is installed under its name.
async function install(model) {
  const body = { uri: model.uri, ...(model.quant && { preferences: { quantizations: model.quant } }) };
  log(`install: ${model.name} is missing, installing it from ${model.uri}${model.quant ? ` (${model.quant})` : ""}`);
  const r = await api("POST", "/models/import-uri", body);
  const uuid = r.json?.uuid;
  if (!uuid) {
    log(`install: could not start the install of ${model.name}: HTTP ${r.status} ${r.text.slice(0, 300)}`);
    return false;
  }
  if (r.json.estimated_size_display) log(`install: downloading about ${r.json.estimated_size_display}`);
  let job = null;
  for (let i = 0; ; i++) {
    await sleep(5000);
    job = (await api("GET", `/models/jobs/${uuid}`)).json;
    if (job?.processed) break;
    if (i % 12 === 11) log(`install: ${model.name} ${Math.floor(job?.progress ?? 0)}%`);
  }
  if (!(await installedModels()).has(model.name)) {
    log(`install: ${model.name} did not install under that name (${job?.message || job?.error || "no message"}); ` +
        `check the web UI, Models, and the model name in .env`);
    return false;
  }
  log(`install: ${model.name} installed`);
  return true;
}

let installing = false;
async function ensureModels() {
  if (installing) return;
  installing = true;
  let failed = false;
  try {
    while ((await api("GET", "/readyz").catch(() => ({ status: 0 }))).status !== 200) await sleep(3000);
    for (const model of REQUIRED_MODELS) {
      let ok = (await installedModels()).has(model.name);
      if (ok) log(`install: ${model.name} is installed`);
      else if (!model.uri) log(`install: ${model.name} is missing and has no source URI in .env`);
      else ok = await install(model);
      if (ok && model.embeddings) await markEmbeddings(model.name);
      failed ||= !ok;
    }
  } catch (e) {
    log(`install: ${e.message}`);
    failed = true;
  } finally {
    installing = false;
  }
  if (failed) {
    log(`install: trying again in ${INSTALL_RETRY_MS / 60_000} minutes`);
    setTimeout(ensureModels, INSTALL_RETRY_MS);
  }
}

// ---------------------------------------------------------------- forwarding

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(new Error("body too large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function sendError(res, status, message, extra = {}) {
  if (res.headersSent) return res.destroy();
  const body = JSON.stringify({ error: { code: status, message, type: "proxy_error" } });
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), ...extra });
  res.end(body);
}

// Send the request to the frontend and stream the answer back. `done` runs once at the end.
function forward(req, res, headers, body, done = () => {}) {
  let finished = false;
  const finish = () => { if (!finished) { finished = true; done(); } };
  if (body) {
    headers["content-length"] = String(body.length);
    delete headers["transfer-encoding"];
  }
  const up = http.request(
    { agent, host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path: req.url, headers },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res);
      upRes.on("end", finish);
      upRes.on("error", finish);
    },
  );
  up.on("error", (e) => { sendError(res, 502, `LocalAI frontend: ${e.message}`); finish(); });
  res.on("close", () => { if (!res.writableFinished) up.destroy(); finish(); });
  if (body) up.end(body);
  else req.pipe(up);
}

async function handle(req, res) {
  const path = (req.url || "/").split("?")[0];
  if (req.method === "GET" && path === "/_cluster/files") return serveFiles(req, res);
  let headers;
  try {
    headers = await upstreamHeaders(req, path);
  } catch (e) {
    return sendError(res, 502, `LocalAI frontend: ${e.message}`);
  }
  if (!isInference(req.method, path) || !String(req.headers["content-type"] || "").includes("json")) {
    return forward(req, res, headers, null);
  }
  let body;
  try {
    body = await readBody(req, MAX_JSON_BODY);
  } catch (e) {
    return sendError(res, 413, e.message);
  }
  let model = null;
  try { model = JSON.parse(body.toString("utf8"))?.model; } catch {}
  if (typeof model !== "string" || !model) return forward(req, res, headers, body);
  // A model that is not installed loads nothing: LocalAI answers it (404) without waiting.
  if (!(await isInstalled(model).catch(() => true))) return forward(req, res, headers, body);

  let gone = false;
  res.on("close", () => { gone = true; });
  try {
    await admit(model, () => gone);
  } catch (e) {
    if (e instanceof Busy) return gone ? undefined : sendError(res, 503, e.message, { "Retry-After": "30" });
    log(`admit ${model}: ${e.message}`);
    return sendError(res, 502, `LocalAI frontend: ${e.message}`);
  }
  if (gone) return release(model);
  forward(req, res, headers, body, () => release(model));
}

// WebSockets (web UI): pass the upgrade through with the same auth handling.
async function handleUpgrade(req, socket, head) {
  const path = (req.url || "/").split("?")[0];
  try {
    const headers = await upstreamHeaders(req, path);
    const up = http.request({ host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path: req.url, headers });
    up.on("upgrade", (upRes, upSocket, upHead) => {
      const lines = [`HTTP/1.1 ${upRes.statusCode} ${upRes.statusMessage}`];
      for (let i = 0; i < upRes.rawHeaders.length; i += 2) lines.push(`${upRes.rawHeaders[i]}: ${upRes.rawHeaders[i + 1]}`);
      socket.write(lines.join("\r\n") + "\r\n\r\n");
      if (upHead?.length) socket.write(upHead);
      if (head?.length) upSocket.write(head);
      upSocket.pipe(socket).pipe(upSocket);
      upSocket.on("error", () => socket.destroy());
      socket.on("error", () => upSocket.destroy());
    });
    up.on("response", (upRes) => {
      socket.write(`HTTP/1.1 ${upRes.statusCode} ${upRes.statusMessage}\r\nConnection: close\r\n\r\n`);
      upRes.pipe(socket);
    });
    up.on("error", () => socket.destroy());
    up.end();
  } catch {
    socket.destroy();
  }
}

// ---------------------------------------------------------------- start

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => { log(`error: ${e.stack || e}`); sendError(res, 500, "proxy error"); });
});
server.on("upgrade", (req, socket, head) => { handleUpgrade(req, socket, head); });
server.requestTimeout = 0; // model loads and long generations take minutes
server.headersTimeout = 60_000;
server.keepAliveTimeout = 65_000;
server.listen(LISTEN_PORT, () => {
  log(`proxy on :${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}; max ${MAX_LOADED} loaded model(s), ` +
      `unload after ${IDLE_MS / 1000}s idle, wait up to ${EVICT_WAIT_MS / 1000}s for room`);
});
setInterval(() => unloadIdle().catch((e) => log(`idle check: ${e.message}`)), IDLE_CHECK_MS);
ensureModels();
setInterval(() => mirror().catch((e) => log(`mirror: ${e.message}`)), MIRROR_MS);
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => process.exit(0));
