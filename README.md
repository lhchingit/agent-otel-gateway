# agent-otel-gateway

One OpenTelemetry Collector gateway that receives metrics from AI coding agents, normalises them into a common `ai_agent.*` schema, and shows them on a single Grafana dashboard.

```
agents --OTLP :4318 (http) / :4317 (grpc)--> otel-collector-contrib --> otel-lgtm (Prometheus + Grafana :3000)
                                                    '--> :8889/metrics (Prometheus scrape endpoint)
```

Supported: Claude Code (directly or through Claude Code Router), Gemini CLI, Codex CLI, OpenCode (`opencode-plugin-otel`), Pi (`@damngamerz/pi-otel`), Antigravity CLI (hook-based, quota gauges only).

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

All series also carry `session_id`. It is kept on purpose: the agents export cumulative per-session counters, and without it two concurrent sessions of the same agent would collide on one series and corrupt `rate()`/`increase()`. Always aggregate with `sum by (agent, ...)`. Agents that send no session identifier at all (Pi) will still overlap when run concurrently.

Removed from every metric: `user.id`, `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`, `terminal.type`, `prompt.id`, `installation.id`, `app.entrypoint`.

## Point each agent at the gateway

Replace `localhost` with the gateway host if the agent runs on another machine.

### Claude Code

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

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

`~/.codex/config.toml`:

```toml
analytics_enabled = true

[otel]
metrics_exporter = "otlp-http"

[otel.metrics_exporter.otlp-http]
endpoint = "http://localhost:4318/v1/metrics"
protocol = "binary"
```

Codex needs the full `/v1/metrics` path. Its `service.name` is `codex_tui` (interactive) or `codex_exec`.

### OpenCode

Install `opencode-plugin-otel`, then:

```bash
export OPENCODE_ENABLE_TELEMETRY=1
export OPENCODE_OTLP_PROTOCOL=http/protobuf
export OPENCODE_OTLP_ENDPOINT=http://localhost:4318
```

### Pi

```bash
pi install npm:@damngamerz/pi-otel
```

The plugin defaults to `http://127.0.0.1:4318`; override with `PI_OTEL_ENDPOINT` if the gateway runs elsewhere. Keep its default `service.name` (`pi`) or the `gen_ai.system=pi` attribute — the gateway uses them to attribute the semconv `gen_ai.*` metrics to Pi.

### Antigravity CLI

Antigravity has no native OTel export. Use the community hook script (see the SigNoz "Antigravity CLI monitoring" guide) with, in `~/.config/agy-otel/env`:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Only `agy.quota.*` gauges arrive as metrics; token/cost data is not available from Antigravity.

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
| `tests/fixtures/*.json` | sample OTLP payloads, one per agent |
| `docs/superpowers/specs/` | design spec |
