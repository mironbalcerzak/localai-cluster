# localai-mcp

MCP server (stdio) for the LocalAI cluster. It gives an MCP client, such as Claude
Code, three tools:

| Tool | What it does |
|------|--------------|
| `available-models` | Models on the host, each with its parallel capacity and the requests running now. A model loaded on no PC has capacity 0. |
| `parallel-capacity` | For one model (default `LOCALAI_MODEL`): slots per PC x PCs with it loaded = `capacity`, plus `in_flight` and `free`. Send at most `free` requests at once so they do not queue. |
| `chat-completions` | A chat completion through the cluster (`/v1/chat/completions`, not streamed): `messages`, optional `model`, `max_tokens`, `temperature`, `top_p`, `stop`, `json`. Returns the reply, the model's reasoning, the finish reason and token usage. |

Gemma 4 reasons before it answers, and the reasoning counts against `max_tokens`.
Give it room (1000+ tokens), or the reply can be cut off before it starts; the tool
says so when that happens. Leave `temperature` unset (the model's default, 1.0) or
near it: at 0, Gemma 4 can repeat one line in its reasoning until it runs out of tokens.

## Setup

Needs Node.js 20+.

```
cd localai-mcp
npm install
```

The server reads the host address, API key and default model from the cluster's
`.env` one folder up (`LOCALAI_SERVER`, `LOCALAI_PORT`, `LOCALAI_API_KEY`,
`LOCALAI_MODEL`), so it works on any PC that has the `.env`. Environment variables
override it:

| Variable | Default |
|----------|---------|
| `LOCALAI_URL` | `http://<LOCALAI_SERVER>:<LOCALAI_PORT>` |
| `LOCALAI_API_KEY` | from `.env` |
| `LOCALAI_MODEL` | from `.env` |
| `LOCALAI_ENV_FILE` | `../.env` |
| `LOCALAI_TIMEOUT_MS` | `600000` (10 min, queue wait and model load included) |

## Add to Claude Code

```
claude mcp add localai -- node /path/to/localai-cluster/localai-mcp/server.js
```

Or in an `.mcp.json`:

```json
{
  "mcpServers": {
    "localai": { "command": "node", "args": ["/path/to/localai-cluster/localai-mcp/server.js"] }
  }
}
```
