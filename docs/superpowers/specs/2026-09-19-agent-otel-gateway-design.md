# AI Agent OTel Gateway — Design

Date: 2026-09-19

## Goal

A single `otel/opentelemetry-collector-contrib:latest` gateway on port 4318 (OTLP/HTTP) and 4317 (OTLP/gRPC) that receives metrics from common AI coding agents, normalises them into one `ai_agent.*` schema, strips high-cardinality attributes, and forwards them to `grafana/otel-lgtm`, where a provisioned Grafana dashboard ("AI Agents") shows all agents in one view. A Prometheus scrape endpoint on `:8889` is also exposed.

Supported sources: Claude Code (directly or via Claude Code Router), Gemini CLI, Antigravity CLI, Pi (`@damngamerz/pi-otel`), Codex CLI, OpenCode (`opencode-plugin-otel`).

## Architecture

```
agents --OTLP :4318/:4317--> otel-collector-contrib (gateway)
                              memory_limiter -> transform -> attributes -> deltatocumulative -> batch
                              |-> otlphttp  -> otel-lgtm:4318 (internal) -> Prometheus -> Grafana :3000
                              |-> prometheus exporter :8889/metrics
                              '-> debug (verbosity: basic)
                              logs / traces: pass-through -> otel-lgtm
```

Host ports: 4317, 4318, 8889 (gateway); 3000 (Grafana). otel-lgtm's own 4317/4318 are not published.

## Files

```
docker-compose.yml                       otel-collector + otel-lgtm
otel-collector-config.yaml               gateway config
grafana/provisioning/dashboards.yaml     mounted to /otel-lgtm/grafana/conf/provisioning/dashboards/ai-agents.yaml
grafana/dashboards/ai-agents.json        mounted to /otel-lgtm/grafana/conf/provisioning/dashboards/custom/ai-agents.json
README.md                                per-agent connection settings
tests/fixtures/<agent>.json              OTLP/HTTP JSON metrics payload per agent
tests/run.sh                             end-to-end check (bash + curl + docker compose)
```

## Source inventory (what each agent emits)

| Agent | service.name | Prefix | Token metric | Cost metric | Notes |
|---|---|---|---|---|---|
| Claude Code | `claude-code` | `claude_code.` | `claude_code.token.usage` counter, `type`=input/output/cacheRead/cacheCreation, `model` | `claude_code.cost.usage` counter, `model` | Default gRPC 4317; `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` for 4318. Puts `session.id`, `user.*`, `organization.id`, `terminal.type` on every datapoint. |
| CCR | — | — | — | — | Proxy only; Claude Code still emits `claude_code.*`. Users set `OTEL_RESOURCE_ATTRIBUTES=router=ccr`, which Claude Code copies onto datapoints as `router`. |
| Gemini CLI | `gemini-cli` | `gemini_cli.` | `gemini_cli.token.usage` counter, `type`=input/output/thought/cache/tool, `model` | none | Also emits `gen_ai.client.token.usage` (dropped: duplicate). `GEMINI_TELEMETRY_OTLP_PROTOCOL=http`. |
| Antigravity | `antigravity-cli` | `agy.` | none | none | Community hook script; only `agy.quota.*` gauges. Pass-through with `agent` label. |
| Pi (`@damngamerz/pi-otel`) | `pi` | `pi.` / `gen_ai.` | `gen_ai.client.token.usage` **histogram**, `gen_ai.token.type`=input/output/cache_read/cache_write, `gen_ai.request.model`, `gen_ai.system=pi` | `pi.agent.cost` counter | Default `http://127.0.0.1:4318`. Also `pi.agent.prompts`, `pi.agent.turns`, `gen_ai.client.tool.calls` (`gen_ai.tool.name`). |
| Codex | `codex_tui` / `codex_exec` | `codex.` | `codex.turn.token_usage` **histogram**, `type`=input/output/cached/reasoning/tool, `model` | none | `[otel.metrics_exporter.otlp-http] endpoint="http://localhost:4318/v1/metrics"`, `protocol="binary"`, requires `analytics_enabled=true`. Sessions: `codex.thread.started`. Tools: `codex.tool.call` (`tool.name`). |
| OpenCode | `opencode` | `opencode.` | `opencode.token.usage` counter, `type`=input/output/reasoning/cacheRead/cacheCreation, `model` | `opencode.cost.usage` | `OPENCODE_OTLP_PROTOCOL=http/protobuf`, `OPENCODE_OTLP_ENDPOINT=http://localhost:4318`. |

## Unified schema

All unified metrics have `unit` set to `""` so Prometheus (both the exporter and otel-lgtm's OTLP receiver) produces the same name, e.g. `ai_agent_token_usage_total`.

| Unified name | Type | Labels | Sources |
|---|---|---|---|
| `ai_agent.token.usage` | monotonic sum | `agent`, `model`, `type` in input/output/cache_read/cache_write/reasoning/tool | `claude_code.token.usage`, `gemini_cli.token.usage`, `opencode.token.usage`, `codex.turn.token_usage` (histogram -> `extract_sum_metric(true)`), `gen_ai.client.token.usage` when `gen_ai.system=="pi"` (histogram -> `extract_sum_metric(true)`) |
| `ai_agent.cost.usage` | monotonic sum | `agent`, `model` | `claude_code.cost.usage`, `opencode.cost.usage`, `pi.agent.cost` |
| `ai_agent.session.count` | monotonic sum | `agent` | `claude_code.session.count`, `gemini_cli.session.count`, `opencode.session.count`, `codex.thread.started` |
| `ai_agent.lines_of_code.count` | monotonic sum | `agent`, `type` in added/removed | `claude_code.lines_of_code.count`, `gemini_cli.lines.changed`, `opencode.lines_of_code.count` |
| `ai_agent.tool.call.count` | monotonic sum | `agent`, `tool_name` | `gemini_cli.tool.call.count` (`function_name`), `codex.tool.call` (`tool.name`), `gen_ai.client.tool.calls` when pi (`gen_ai.tool.name`) |

Value normalisation for `type`: `cacheRead`->`cache_read`, `cached`->`cache_read`, `cache`->`cache_read`, `cacheCreation`->`cache_write`, `thought`->`reasoning`.
Key normalisation: `gen_ai.token.type`->`type`, `gen_ai.request.model`->`model`, `function_name`->`tool_name`, `tool.name`->`tool_name`, `gen_ai.tool.name`->`tool_name`.

Metrics not in the table keep their original name and gain the `agent` label. Gemini's `gen_ai.client.token.usage` is dropped. Nothing else is dropped.

## Agent detection (transform processor, datapoint context)

Order of evaluation, first match wins; result stored in datapoint attribute `agent`:

1. metric name matches `^claude_code\.` -> `claude_code`
2. `^gemini_cli\.` -> `gemini_cli`
3. `^codex\.` -> `codex`
4. `^opencode\.` -> `opencode`
5. `^pi\.` -> `pi`
6. `^agy\.` -> `antigravity`
7. `^gen_ai\.` and (`attributes["gen_ai.system"] == "pi"` or `resource.attributes["service.name"] == "pi"`) -> `pi`
8. otherwise -> `unknown`

Detection precedes renaming so the same statement list can key on original names.

## Cardinality control (attributes processor)

Delete datapoint attributes: `session.id`, `user.id`, `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`, `terminal.type`, `prompt.id`, `installation.id`, `app.entrypoint`.

Prometheus exporter: `add_metric_suffixes: true` (default), `metric_expiration: 10m`, `resource_to_telemetry_conversion: false`. `deltatocumulative` sits before the exporters so delta-temporality sources still produce Prometheus counters.

## Grafana dashboard "AI Agents"

Datasource `uid: prometheus` (provisioned by otel-lgtm). Variables: `agent` (multi, All), `model` (multi, All), both from `label_values(ai_agent_token_usage_total, ...)`.

| Row | Panels |
|---|---|
| Overview (stat) | tokens 24h, cost USD 24h, sessions 24h, agents reporting now |
| Tokens | token rate by agent (stacked timeseries); tokens by type (stacked); tokens by model (pie) |
| Cost | cost over time by agent; cost by model (bar); text note: Gemini/Codex/Antigravity report no cost |
| Activity | sessions by agent; lines added/removed by agent; tool calls top 10 (table, agent x tool_name) |
| Detail | table: one row per agent — tokens, cost, sessions, last seen |

Provisioning: `dashboards.yaml` provider of type `file` pointing to `/otel-lgtm/grafana/conf/provisioning/dashboards/custom`.

## Docker Compose

- `otel-collector`: `otel/opentelemetry-collector-contrib:latest`, mounts config, ports 4317/4318/8889, `depends_on: otel-lgtm (service_healthy)`.
- `otel-lgtm`: `grafana/otel-lgtm:latest`, port 3000, mounts the two grafana files, healthcheck on Grafana `/api/health`.

## Per-agent connection (README content)

- Claude Code: `CLAUDE_CODE_ENABLE_TELEMETRY=1 OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`; via CCR add `OTEL_RESOURCE_ATTRIBUTES=router=ccr`.
- Gemini CLI: `GEMINI_TELEMETRY_ENABLED=true GEMINI_TELEMETRY_TARGET=local GEMINI_TELEMETRY_OTLP_ENDPOINT=http://localhost:4318 GEMINI_TELEMETRY_OTLP_PROTOCOL=http`.
- Codex: `config.toml` `[otel] metrics_exporter="otlp-http"` block with `/v1/metrics` endpoint, `protocol="binary"`, `analytics_enabled=true`.
- OpenCode: `OPENCODE_ENABLE_TELEMETRY=1 OPENCODE_OTLP_PROTOCOL=http/protobuf OPENCODE_OTLP_ENDPOINT=http://localhost:4318`.
- Pi: `pi install npm:@damngamerz/pi-otel`; default endpoint already `http://127.0.0.1:4318`.
- Antigravity: hook script env `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`; note that only quota gauges arrive as metrics.

## Testing

`tests/run.sh`:
1. `docker compose config` and collector config validation (`otelcol-contrib validate --config`) via the same image.
2. `docker compose up -d`, wait for Grafana `/api/health` and collector `:13133` health.
3. POST each `tests/fixtures/<agent>.json` to `http://localhost:4318/v1/metrics`.
4. Assert on `http://localhost:8889/metrics`: for each agent, `ai_agent_token_usage_total{agent="<x>",...,type="input"}` exists (Antigravity: `agy_quota_remaining_fraction{agent="antigravity"}`); `session_id` label absent; `gen_ai_client_token_usage` for gemini absent; codex/pi token appear as counters not histograms.
5. Query Grafana proxy `/api/datasources/proxy/uid/prometheus/api/v1/query?query=ai_agent_token_usage_total` and assert every agent label present.
6. `GET /api/search?query=AI%20Agents` returns the dashboard.
7. `docker compose down -v` unless `KEEP=1`.

Fixtures are hand-written OTLP JSON reflecting the source inventory above, with one histogram fixture each for Codex and Pi.

## Out of scope

Transforming logs/traces; per-user reporting; auth on the gateway; long-term Prometheus retention.
