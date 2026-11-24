#!/usr/bin/env node
// MCP server (stdio) for the LocalAI cluster. Tools:
//   available-models    models on the host, each with its parallel capacity
//   parallel-capacity   requests one model can serve at once, and how many run now
//   chat-completions    an OpenAI-style chat completion through the cluster
//
// Settings, from the environment or else from the cluster's .env (../.env, or LOCALAI_ENV_FILE):
//   LOCALAI_URL         http://host:port of the host (else LOCALAI_SERVER + LOCALAI_PORT from .env)
//   LOCALAI_API_KEY     Bearer key for the API
//   LOCALAI_MODEL       default model for parallel-capacity and chat-completions
//   LOCALAI_TIMEOUT_MS  how long a chat completion may take, queue wait included (default 10 min)
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Agent, fetch } from "undici";
import { z } from "zod";

const HERE = dirname(fileURLToPath(import.meta.url));

function readEnvFile(path) {
  const values = {};
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return values;
  }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m) values[m[1]] = m[2];
  }
  return values;
}

const envFile = readEnvFile(process.env.LOCALAI_ENV_FILE || join(HERE, "..", ".env"));
const setting = (name) => process.env[name] || envFile[name] || "";

const BASE_URL = (
  setting("LOCALAI_URL") ||
  (setting("LOCALAI_SERVER") ? `http://${setting("LOCALAI_SERVER")}:${setting("LOCALAI_PORT") || "23422"}` : "")
).replace(/\/+$/, "");
const API_KEY = setting("LOCALAI_API_KEY");
const DEFAULT_MODEL = setting("LOCALAI_MODEL");
const TIMEOUT_MS = Number(setting("LOCALAI_TIMEOUT_MS")) || 600_000;

// Node's fetch gives up on response headers after 5 minutes; a queued completion may take longer.
const dispatcher = new Agent({ headersTimeout: TIMEOUT_MS, bodyTimeout: TIMEOUT_MS });

async function api(path, { method = "GET", body, timeoutMs = 15_000 } = {}) {
  if (!BASE_URL) throw new Error("LocalAI host unknown: set LOCALAI_URL, or LOCALAI_SERVER in the cluster's .env");
  const res = await fetch(BASE_URL + path, {
    method,
    dispatcher,
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      ...(API_KEY ? { Authorization: `Bearer ${API_KEY}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) {
    let msg = text;
    try {
      msg = JSON.parse(text)?.error?.message || text;
    } catch {}
    const retry = res.headers.get("retry-after");
    throw new Error(`${method} ${path}: HTTP ${res.status}${retry ? ` (retry after ${retry}s)` : ""}: ${msg.slice(0, 500)}`);
  }
  return text ? JSON.parse(text) : null;
}

// Slots per PC: "parallel:N" in the model's effective config (auto-tuned or set), else 1.
function slotsOf(config) {
  for (const o of config?.options ?? []) {
    const m = String(o).match(/^(?:n_)?parallel:(\d+)$/);
    if (m) return Number(m[1]);
  }
  return 1;
}

async function capacityOf(model, replicasCache, nodesCache) {
  const config = await api(`/api/models/config-json/${encodeURIComponent(model)}`);
  const replicas = (replicasCache ?? (await api("/api/nodes/models")) ?? []).filter(
    (r) => r.model_name === model && r.state === "loaded",
  );
  const nodeNames = new Map((nodesCache ?? []).map((n) => [n.id, n.name]));
  const slots = slotsOf(config);
  const capacity = slots * replicas.length;
  const inFlight = replicas.reduce((n, r) => n + (r.in_flight || 0), 0);
  return {
    model,
    slots_per_pc: slots,
    pcs_loaded: replicas.length,
    capacity,
    in_flight: inFlight,
    free: Math.max(0, capacity - inFlight),
    pcs: replicas.map((r) => ({ pc: nodeNames.get(r.node_id) || r.node_id, in_flight: r.in_flight || 0 })),
  };
}

const ok = (data, text) => ({
  content: [{ type: "text", text: text ?? JSON.stringify(data, null, 2) }],
  structuredContent: data,
});
const fail = (err) => ({ isError: true, content: [{ type: "text", text: String(err?.message || err) }] });

const capacityShape = {
  model: z.string(),
  slots_per_pc: z.number().describe("Requests one PC serves at once for this model"),
  pcs_loaded: z.number().describe("PCs that have the model loaded"),
  capacity: z.number().describe("Requests the cluster serves at once: slots_per_pc x pcs_loaded"),
  in_flight: z.number().describe("Requests running right now"),
  free: z.number().describe("capacity - in_flight: requests that start at once if sent now"),
  pcs: z.array(z.object({ pc: z.string(), in_flight: z.number() })),
};

const server = new McpServer({ name: "localai-cluster", version: "0.1.0" });

server.registerTool(
  "available-models",
  {
    title: "Available models",
    description:
      "List the models on the LocalAI cluster, each with its parallel capacity (requests served at once) " +
      "and the requests running now. A model loaded on no PC has capacity 0.",
    inputSchema: {},
    outputSchema: { default_model: z.string(), models: z.array(z.object(capacityShape)) },
  },
  async () => {
    try {
      const [list, replicas, nodes] = await Promise.all([
        api("/v1/models"),
        api("/api/nodes/models"),
        api("/api/nodes"),
      ]);
      const models = await Promise.all((list?.data ?? []).map((m) => capacityOf(m.id, replicas, nodes)));
      return ok({ default_model: DEFAULT_MODEL, models });
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "parallel-capacity",
  {
    title: "Parallel capacity",
    description:
      "How many requests the cluster serves at once for a model (slots per PC x PCs with the model loaded), " +
      "how many run now and how many are free. Send at most `free` new requests at once, so they do not queue. " +
      "The numbers change when PCs join or leave.",
    inputSchema: {
      model: z.string().optional().describe(`Model name; default ${DEFAULT_MODEL || "LOCALAI_MODEL"}`),
    },
    outputSchema: capacityShape,
  },
  async ({ model }) => {
    try {
      const name = model || DEFAULT_MODEL;
      if (!name) throw new Error("no model given and LOCALAI_MODEL is not set");
      const [replicas, nodes] = await Promise.all([api("/api/nodes/models"), api("/api/nodes")]);
      return ok(await capacityOf(name, replicas, nodes));
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "chat-completions",
  {
    title: "Chat completions",
    description:
      "Run a chat completion on the LocalAI cluster (OpenAI /v1/chat/completions, not streamed). " +
      "Returns the assistant's reply, the model's reasoning (if it reasons), the finish reason and token usage. " +
      "Reasoning counts against max_tokens: with a small limit the reply can be cut off before it starts.",
    inputSchema: {
      messages: z
        .array(
          z.object({
            role: z.enum(["system", "user", "assistant"]),
            content: z.string(),
          }),
        )
        .min(1)
        .describe("The conversation, oldest first"),
      model: z.string().optional().describe(`Model name; default ${DEFAULT_MODEL || "LOCALAI_MODEL"}`),
      max_tokens: z.number().int().positive().optional(),
      temperature: z
        .number()
        .min(0)
        .max(2)
        .optional()
        .describe("Leave unset for the model's default. Gemma 4 at 0 can loop in its reasoning until max_tokens"),
      top_p: z.number().min(0).max(1).optional(),
      stop: z.array(z.string()).optional(),
      json: z.boolean().optional().describe("Ask for a JSON object as the reply (response_format json_object)"),
    },
    outputSchema: {
      model: z.string(),
      content: z.string(),
      reasoning: z.string().nullable(),
      finish_reason: z.string().nullable(),
      usage: z.record(z.string(), z.any()).nullable(),
    },
  },
  async ({ messages, model, max_tokens, temperature, top_p, stop, json }) => {
    try {
      const name = model || DEFAULT_MODEL;
      if (!name) throw new Error("no model given and LOCALAI_MODEL is not set");
      const res = await api("/v1/chat/completions", {
        method: "POST",
        timeoutMs: TIMEOUT_MS,
        body: {
          model: name,
          messages,
          stream: false,
          ...(max_tokens !== undefined && { max_tokens }),
          ...(temperature !== undefined && { temperature }),
          ...(top_p !== undefined && { top_p }),
          ...(stop?.length && { stop }),
          ...(json && { response_format: { type: "json_object" } }),
        },
      });
      const choice = res?.choices?.[0];
      const data = {
        model: res?.model || name,
        content: choice?.message?.content ?? "",
        reasoning: choice?.message?.reasoning ?? choice?.message?.reasoning_content ?? null,
        finish_reason: choice?.finish_reason ?? null,
        usage: res?.usage ?? null,
      };
      let text = data.content;
      if (data.finish_reason === "length") {
        text += `${text ? "\n\n" : ""}[cut off: max_tokens reached${data.content ? "" : " before the reply started (reasoning used the tokens)"}]`;
      }
      return ok(data, text);
    } catch (e) {
      return fail(e);
    }
  },
);

await server.connect(new StdioServerTransport());
