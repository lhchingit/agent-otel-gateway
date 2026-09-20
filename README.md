# agent-otel-gateway

One OpenTelemetry Collector gateway that receives metrics from AI coding agents, normalises them into a common `ai_agent.*` schema, and shows them on a single Grafana dashboard.

```
agents --OTLP :4318 (http) / :4317 (grpc)--> otel-collector-contrib --> otel-lgtm (Prometheus + Grafana :3000)
                                                    '--> :8889/metrics (Prometheus scrape endpoint)
```

Supported: Claude Code (directly or through Claude Code Router), Gemini CLI, Codex CLI, OpenCode (`opencode-plugin-otel`), Pi (`@damngamerz/pi-otel`), Antigravity CLI (via the hook in `hooks/antigravity/`, activity only).

## Run

```bash
docker compose up -d
# Grafana: http://localhost:3000  (dashboard "AI Agents" is the home dashboard)
# Raw Prometheus endpoint: http://localhost:8889/metrics
```

Images: `otel/opentelemetry-collector-contrib:latest` (gateway) and `grafana/otel-lgtm:0.33.0` (pinned, because the compose file mounts into image-internal paths).

## Unified metrics

| Metric (Prometheus name) | Labels | Meaning |
|---|---|---|
| `ai_agent_token_usage_total` | `agent`, `model`, `type` = input / output / cache_read / cache_write / reasoning / tool | tokens |
| `ai_agent_cost_usage_total` | `agent`, `model` | USD (Claude Code, OpenCode, Pi only) |
| `ai_agent_session_count_total` | `agent` | sessions started |
| `ai_agent_lines_of_code_count_total` | `agent`, `type` = added / removed | lines changed |
| `ai_agent_tool_call_count_total` | `agent`, `tool_name` | tool invocations |

`agent` is one of `claude_code`, `gemini_cli`, `codex`, `opencode`, `pi`, `antigravity`, `unknown`. Every other metric an agent sends is passed through under its original name with the `agent` label added.

All series also carry `session_id`. It is kept on purpose: the agents export cumulative per-session counters, and without it two concurrent sessions of the same agent would collide on one series and corrupt `rate()`/`increase()`. Always aggregate with `sum by (agent, ...)`. Agents that send no session identifier (Codex, Pi) get one synthesised from the datapoint start time, which is unique per process.

Removed from every metric: `user.id`, `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`, `terminal.type`, `prompt.id`, `installation.id`, `app.entrypoint`.

## Multiple users, one dashboard

Run the stack on a host everyone can reach and point every agent at `http://<host>:4318` instead of `localhost`. Each person identifies themselves with an OTLP request header:

```
OTEL_EXPORTER_OTLP_HEADERS=x-user=alice
```

The gateway copies `x-user` onto every metric, log and span as the `user` label (`attributes/user` in the collector config; requests without the header get `user="unknown"`). The dashboard has a `User` variable, a "Users" row (per-user table, tokens by user and agent, cost by user), and every panel filters on the selected users. This is **not authentication** — a client can claim any name — so keep the gateway inside your network (VPN/Tailscale) or put TLS + auth in front of it; the collector's `basicauth` extension plus `from_context: auth.username` is the drop-in upgrade when you need verified identities.

Per agent, the same header is set as:

| Agent | Where |
|---|---|
| Claude Code | `OTEL_EXPORTER_OTLP_HEADERS=x-user=alice` (env or `settings.json` `env`) |
| Gemini CLI | `OTEL_EXPORTER_OTLP_HEADERS=x-user=alice` (standard OTel SDK env var) |
| Codex CLI | `headers = { "x-user" = "alice" }` inside each `[otel.*_exporter.otlp-http]` table |
| OpenCode | `OPENCODE_OTLP_HEADERS=x-user=alice` |
| Pi | `OTEL_EXPORTER_OTLP_HEADERS=x-user=alice` |
| Antigravity | `OTEL_EXPORTER_OTLP_HEADERS=x-user=alice` in `~/.config/agy-otel/env` |

Sessions that were already running when the label was introduced continue under their old label set until they end; totals may briefly count both.

`grafana/otel-lgtm` is a single-node development stack. For a team, keep the gateway and swap the backend: point `otlp_http/lgtm` at Grafana Cloud's OTLP endpoint, or at a self-hosted Prometheus/Mimir + Loki + Tempo, and import `grafana/dashboards/ai-agents.json`.

## Point each agent at the gateway

Replace `localhost` with the gateway host if the agent runs on another machine.

### Claude Code

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative
```

Or the same keys under `"env"` in `~/.claude/settings.json`. Either way, **restart every running Claude Code session** — the environment is read at launch.

`OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` matters: Claude Code defaults to `delta`, and with delta an idle session sends nothing after its last change. A session that ran one prompt then sat idle leaves a single sample in Prometheus, and every `rate()`/`increase()` panel shows "No data" until a second sample arrives. With `cumulative` the SDK re-sends every 60 s (`OTEL_METRIC_EXPORT_INTERVAL`) regardless of activity, so the dashboard fills within about two minutes and stays current.

**Through Claude Code Router (CCR):** CCR itself sends no telemetry; Claude Code keeps sending its own. Add a marker so routed sessions are distinguishable in Grafana (it becomes a `router="ccr"` label):

```bash
export OTEL_RESOURCE_ATTRIBUTES=router=ccr
```

### Gemini CLI

```bash
export GEMINI_TELEMETRY_ENABLED=true
export GEMINI_TELEMETRY_TARGET=local
export GEMINI_TELEMETRY_OTLP_ENDPOINT=http://localhost:4318
export GEMINI_TELEMETRY_OTLP_PROTOCOL=http
```

(or the equivalent `telemetry.*` keys in `~/.gemini/settings.json`).

### Codex CLI

Add to `~/.codex/config.toml` (keep `analytics_enabled` at the top level, above any `[table]`; metrics are silently disabled without it):

```toml
analytics_enabled = true

[otel]
environment = "dev"

[otel.metrics_exporter.otlp-http]
endpoint = "http://localhost:4318/v1/metrics"
protocol = "binary"

[otel.exporter.otlp-http]          # log events (optional)
endpoint = "http://localhost:4318/v1/logs"
protocol = "binary"

[otel.trace_exporter.otlp-http]    # traces (optional)
endpoint = "http://localhost:4318/v1/traces"
protocol = "binary"
```

Codex needs the full signal path in each endpoint. Its `service.name` is `codex_tui` (interactive) or `codex_exec` (`codex exec`). Verify with `codex exec "reply with ok"`; `agent="codex"` appears within a minute. Codex sends no session identifier; the gateway synthesises one per process from the datapoint start time, so runs never collide. One-shot `codex exec` runs export once at exit and still show up in the totals (they use `last_over_time`), but not in the rate graphs, which need two samples.

What Codex 0.142 actually emits (differs from older docs): tokens as histogram `codex.turn.token_usage{token_type=input|output|cached_input|reasoning_output|total}`, tool calls as `codex.tool.call{tool,success,sandbox,...}`. The gateway renames `token_type`->`type`, `tool`->`tool_name`, maps `cached_input`->`cache_read`, `reasoning_output`->`reasoning`, and drops the `total` bucket (it is the sum of the others).

### OpenCode

Telemetry comes from the community plugin `@devtheops/opencode-plugin-otel`. Configure it in `~/.config/opencode/opencode.json`; OpenCode installs the npm package itself on first start:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    ["@devtheops/opencode-plugin-otel", {
      "enabled": true,
      "endpoint": "http://localhost:4318",
      "protocol": "http/protobuf"
    }]
  ]
}
```

Equivalent environment variables: `OPENCODE_ENABLE_TELEMETRY=1`, `OPENCODE_OTLP_ENDPOINT=http://localhost:4318`, `OPENCODE_OTLP_PROTOCOL=http/protobuf` (optional `OPENCODE_OTLP_METRICS_INTERVAL=5000` for quicker feedback while testing). Metrics are cumulative by default, so idle sessions keep reporting. Verify with `opencode run "reply with ok"`; the log at `~/.local/share/opencode/log/` shows `OTel SDK initialized` and `otel: session.created`, and `agent="opencode"` appears on the dashboard within a minute.

**Version caveat (as of 2026-09-20):** the plugin targets OpenCode 1.x (`opencode-ai`, peer `@opencode-ai/plugin ^1.14`). OpenCode 2.0 (`@opencode/cli`, released 2026-09-20) changed the plugin module format and rejects it with `Plugin must export a default definition with an id and an effect or setup function` — the plugin loads but emits nothing. Until the plugin is updated, run 1.x. To keep a 2.0 install untouched, run 1.x from an isolated folder with its own data directories (2.0 migrates the shared SQLite database, which 1.x then cannot open):

```bash
mkdir oc1 && cd oc1 && npm init -y && npm install-scripts approve opencode-ai && npm i opencode-ai@1.18.31
node node_modules/opencode-ai/postinstall.mjs      # only needed if npm still skipped the script
export XDG_CONFIG_HOME=/path/to/oc1-home/config XDG_DATA_HOME=/path/to/oc1-home/data XDG_CACHE_HOME=/path/to/oc1-home/cache
cp -r ~/.config/opencode "$XDG_CONFIG_HOME/"
./node_modules/.bin/opencode run "reply with ok"
```

**npm 12 caveat:** npm 12 blocks package install scripts by default (`allowScripts`). Both `@opencode/cli` and `opencode-ai` need their `postinstall` to download the platform binary; if `opencode --version` says the postinstall script was not run, execute `node <package dir>/postinstall.mjs` once or approve the package with `npm install-scripts approve <pkg>` before installing.

### Pi

```bash
pi install npm:@damngamerz/pi-otel
```

The plugin defaults to `http://127.0.0.1:4318`; override with `PI_OTEL_ENDPOINT` if the gateway runs elsewhere. Keep its default `service.name` (`pi`) or the `gen_ai.system=pi` attribute — the gateway uses them to attribute the semconv `gen_ai.*` metrics to Pi.

### Antigravity CLI

Antigravity has no native OTel export and exposes no token/cost data to hooks. This repo ships a hook (`hooks/antigravity/hook.py`, a Windows-compatible port of the SigNoz reference hook) that turns Antigravity's `PostToolUse` / `PostInvocation` / `Stop` events into spans (Tempo) and three counters: `agy.tool.call.count{tool_name}` (unified into `ai_agent_tool_call_count_total`), `agy.invocation.count{model}` and `agy.turn.count`. The dashboard shows them in "Tool calls" and in the "Antigravity" row.

Install (Python 3.11+; paths shown for Windows, use `bin/python` on macOS/Linux):

```powershell
py -3 -m venv "$HOME\.local\opt\agy-otel"
& "$HOME\.local\opt\agy-otel\Scripts\python.exe" -m pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-http
Copy-Item hooks\antigravity\hook.py, hooks\antigravity\agy-otel-hook.cmd "$HOME\.local\opt\agy-otel\"
```

`~/.config/agy-otel/env` (hooks inherit an arbitrary shell, so the endpoint lives in a file):

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Register the hook by merging `hooks/antigravity/hooks.json` into `~/.gemini/config/hooks.json` (replace `<you>` with your user name; keep any other named hook blocks you already have). The commands point at the `agy-otel-hook.cmd` wrapper on purpose: agy runs hooks through `cmd.exe`, which mangles a command line that starts with a quoted path and contains further quotes (`"...python.exe" "...hook.py" Stop` fails with "is not recognized as an internal or external command"). On macOS/Linux point the command at `.../bin/python .../hook.py <Event>` directly. Restart `agy`; `~/.gemini/antigravity-cli/cli.log` should log `loaded N named hooks`. Each event returns to the agent in well under 100 ms — the export runs in a detached child process.

Why not the reference hook as-is: it uses `os.fork()`, which does not exist on Windows (the hook silently emits nothing), and it samples quota with `agy -p /usage`, which on agy 1.2.7 starts a real agent turn (tokens and ~30 s) instead of printing quota.

## Test

```bash
tests/run.sh          # boots an isolated test stack, posts one fixture per agent, asserts, tears down
KEEP=1 tests/run.sh   # same, but leaves the stack running so you can look at Grafana
```

The test uses its own compose project (`agent-otel-gateway-test`), so it never touches a stack started with plain `docker compose up`; it fails on port conflicts instead. Requires Docker Desktop with Compose v2, bash (Git Bash on Windows), curl.

## Layout

| Path | Purpose |
|---|---|
| `otel-collector-config.yaml` | gateway pipeline (the OTTL transform lives here) |
| `docker-compose.yml` | gateway + otel-lgtm |
| `grafana/dashboards/ai-agents.json` | the dashboard |
| `grafana/provisioning/dashboards.yaml` | Grafana provisioning entry |
| `hooks/antigravity/` | Antigravity CLI hook (`hook.py`) and `hooks.json` snippet |
| `tests/fixtures/*.json` | sample OTLP payloads, one per agent |
| `docs/superpowers/specs/` | design spec |
