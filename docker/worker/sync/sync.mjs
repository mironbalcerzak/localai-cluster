// LocalAI cluster worker sync: keeps this worker's models the same as the host's.
//
// Every SYNC_INTERVAL (5 s) it reads the host's model files from the host proxy
// (/_cluster/files, with the join token) and downloads whatever is missing or has another
// size into /models/<model>/<path>: where LocalAI's own upload would put it, so a model
// load on this worker finds the files in place ("Upload skipped") and starts at once.
// Loading and unloading together with the host is the host proxy's job.
//
// Plain Node (no packages). Settings come from the environment (see docker-compose.yml).
import { createWriteStream } from "node:fs";
import { chown, mkdir, rename, stat, unlink } from "node:fs/promises";
import { dirname, join, normalize, relative, sep } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const HOST_URL = (process.env.HOST_URL || "").replace(/\/+$/, "");
const TOKEN = process.env.LOCALAI_REGISTRATION_TOKEN || "";
const MODELS_DIR = process.env.MODELS_DIR || "/models";
const INTERVAL_MS = Number(process.env.SYNC_INTERVAL_MS || 5000);
const OWNER = { uid: 10001, gid: 10001 }; // the localai user of the LocalAI image

const log = (...args) => console.log(new Date().toISOString(), ...args);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const gb = (n) => `${(n / 1024 ** 3).toFixed(1)} GB`;

// Inside MODELS_DIR, or null for a path that would leave it.
function target(model, path) {
  const p = join(MODELS_DIR, normalize(model), normalize(path));
  const rel = relative(MODELS_DIR, p);
  return rel && !rel.startsWith("..") && !rel.startsWith(sep) ? p : null;
}

// mkdir -p, handing every folder it creates below MODELS_DIR to the localai user.
async function makeDirs(dir) {
  const missing = [];
  for (let d = dir; d !== MODELS_DIR && d.startsWith(MODELS_DIR); d = dirname(d)) {
    if (await stat(d).catch(() => null)) break;
    missing.unshift(d);
  }
  for (const d of missing) {
    await mkdir(d).catch((e) => { if (e.code !== "EEXIST") throw e; });
    await chown(d, OWNER.uid, OWNER.gid).catch(() => {});
  }
}

async function download(model, file, dest) {
  const part = `${dest}.part`;
  await makeDirs(dirname(dest));
  let have = (await stat(part).catch(() => null))?.size || 0;
  if (have > file.size) { await unlink(part); have = 0; }
  log(`${model}: downloading ${file.path} (${gb(file.size)}${have ? `, resuming at ${gb(have)}` : ""})`);
  const res = await fetch(`${HOST_URL}/_cluster/files?path=${encodeURIComponent(file.path)}`, {
    headers: { "X-Registration-Token": TOKEN, ...(have && { Range: `bytes=${have}-` }) },
  });
  if (res.status !== 200 && res.status !== 206) throw new Error(`HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  if (res.status === 200) have = 0; // the host sent the whole file
  let done = have;
  let nextLog = Date.now() + 30_000;
  const body = Readable.fromWeb(res.body);
  body.on("data", (chunk) => {
    done += chunk.length;
    if (Date.now() > nextLog) {
      log(`${model}: ${file.path} ${Math.floor((done / file.size) * 100)}% (${gb(done)} of ${gb(file.size)})`);
      nextLog = Date.now() + 30_000;
    }
  });
  await pipeline(body, createWriteStream(part, { flags: have ? "a" : "w" }));
  const size = (await stat(part)).size;
  if (size !== file.size) throw new Error(`${file.path}: got ${size} of ${file.size} bytes, will resume`);
  await chown(part, OWNER.uid, OWNER.gid).catch(() => {});
  await rename(part, dest);
  log(`${model}: ${file.path} done`);
}

async function syncOnce() {
  const res = await fetch(`${HOST_URL}/_cluster/files`, {
    headers: { "X-Registration-Token": TOKEN },
    signal: AbortSignal.timeout(30_000),
  });
  if (res.status !== 200) throw new Error(`host ${HOST_URL}: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  const { models } = await res.json();
  let fetched = 0;
  for (const model of models) {
    for (const file of model.files) {
      const dest = target(model.name, file.path);
      if (!dest) continue;
      if ((await stat(dest).catch(() => null))?.size === file.size) continue;
      await download(model.name, file, dest);
      fetched++;
    }
  }
  return { models: models.length, fetched };
}

if (!HOST_URL || !TOKEN) {
  console.error("sync: HOST_URL and LOCALAI_REGISTRATION_TOKEN must be set");
  process.exit(1);
}
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => process.exit(0));
log(`sync: keeping ${MODELS_DIR} in step with the models of ${HOST_URL}, every ${INTERVAL_MS / 1000}s`);
let state = "";
for (;;) {
  try {
    const r = await syncOnce();
    const now = `in sync: ${r.models} model(s)`;
    if (r.fetched || now !== state) log(now);
    state = now;
  } catch (e) {
    const now = `waiting: ${e.cause?.code || e.message}`;
    if (now !== state) log(now);
    state = now;
  }
  await sleep(INTERVAL_MS);
}
