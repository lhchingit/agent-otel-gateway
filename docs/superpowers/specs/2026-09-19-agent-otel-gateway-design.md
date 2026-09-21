# AI Agent OTel Gateway — Design

Date: 2026-09-19

## Goal

A single `otel/opentelemetry-collector-contrib:latest` gateway on port 4318 (OTLP/HTTP) and 4317 (OTLP/gRPC) that receives metrics from common AI coding agents, normalises them into one `ai_agent.*` schema, strips high-cardinality attributes, and forwards them to `grafana/otel-lgtm`, where a provisioned Grafana dashboard ("AI Agents") shows all agents in one view. A Prometheus scrape endpoint on `:8889` is also exposed.

Supported sources: Claude Code (directly or via Claude Code Router), Gemini CLI, Antigravity CLI, Pi (`@damngamerz/pi-otel`), Codex CLI, OpenCode (`opencode-plugin-otel`).

## Architecture

```
agents --OTLP :4318/:4317--> otel-collector-contrib (gateway)
                              memory_limiter -> attributes/user -> filter -> transform -> attributes -> delta_to_cumulative -> batch
                              |-> otlp_http -> otel-lgtm:4318 (internal) -> Prometheus -> Grafana :3000
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
hooks/antigravity/hook.py                Antigravity CLI hook (spans + counters over OTLP/HTTP)
hooks/antigravity/hooks.json             snippet for ~/.gemini/config/hooks.json
```

## Source inventory (what each agent emits)

| Agent | service.name | Prefix | Token metric | Cost metric | Notes |
|---|---|---|---|---|---|
| Claude Code | `claude-code` | `claude_code.` | `claude_code.token.usage` counter, `type`=input/output/cacheRead/cacheCreation, `model` | `claude_code.cost.usage` counter, `model` | Default gRPC 4317; `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` for 4318. Puts `session.id`, `user.*`, `organization.id`, `terminal.type` on every datapoint. |
| CCR | — | — | — | — | Proxy only; Claude Code still emits `claude_code.*`. Users set `OTEL_RESOURCE_ATTRIBUTES=router=ccr`, which Claude Code copies onto datapoints as `router`. |
| Gemini CLI | `gemini-cli` | `gemini_cli.` | `gemini_cli.token.usage` counter, `type`=input/output/thought/cache/tool, `model` | none | Also emits `gen_ai.client.token.usage` (dropped: duplicate). `GEMINI_TELEMETRY_OTLP_PROTOCOL=http`. |
| Antigravity | `antigravity-cli` | `agy.` | none | none | No native export. Repo ships `hooks/antigravity/hook.py` (Windows-compatible port of the SigNoz hook, no `os.fork`, no `agy -p /usage` quota sampling which on agy 1.2.7 runs a real agent turn). Emits spans plus delta counters `agy.tool.call.count{tool_name,model,session.id}`, `agy.invocation.count{model,session.id}`, `agy.turn.count{model,session.id}`; `service.instance.id` pinned to hostname so hook processes share one stream. |
| Pi (`npm:pi-otel` by nikiforovall, or `@damngamerz/pi-otel`) | `pi` | `pi.` / `gen_ai.` | `gen_ai.client.token.usage` **histogram**, `gen_ai.token.type`=input/output/cache_read/cache_write, `gen_ai.request.model`, `gen_ai.system=pi` | `pi.agent.cost` counter (damngamerz only; nikiforovall reports none) | Both default to `http://localhost:4318`. Tools: `gen_ai.client.tool.calls` (`gen_ai.tool.name`). nikiforovall config lives in `~/.pi/agent/settings.json` under `otel` (incl. `headers`). Verified with pi-otel 0.3.0 on 2026-09-21. |
| Codex | `codex_tui` / `codex_exec` | `codex.` | `codex.turn.token_usage` **histogram**, `token_type`=input/output/cached_input/reasoning_output/total, `model` | none | `analytics_enabled=true` + `[otel.metrics_exporter.otlp-http] endpoint="http://localhost:4318/v1/metrics"`, `protocol="binary"`. Sessions: `codex.thread.started`. Tools: `codex.tool.call` (`tool`, `success`). No session identifier (concurrent sessions collide). Verified against codex-cli 0.142.0 on 2026-09-20. |
| OpenCode | `opencode` | `opencode.` | `opencode.token.usage` counter, `type`=input/output/reasoning/cacheRead/cacheCreation, `model` | `opencode.cost.usage` | `OPENCODE_OTLP_PROTOCOL=http/protobuf`, `OPENCODE_OTLP_ENDPOINT=http://localhost:4318`. |

## Unified schema

All unified metrics have `unit` set to `""` so Prometheus (both the exporter and otel-lgtm's OTLP receiver) produces the same name, e.g. `ai_agent_token_usage_total`.

| Unified name | Type | Labels | Sources |
|---|---|---|---|
| `ai_agent.token.usage` | monotonic sum | `agent`, `model`, `type` in input/output/cache_read/cache_write/reasoning/tool | `claude_code.token.usage`, `gemini_cli.token.usage`, `opencode.token.usage`, `codex.turn.token_usage` (histogram -> `extract_sum_metric(true)`), `gen_ai.client.token.usage` when `gen_ai.system=="pi"` (histogram -> `extract_sum_metric(true)`) |
| `ai_agent.cost.usage` | monotonic sum | `agent`, `model` | `claude_code.cost.usage`, `opencode.cost.usage`, `pi.agent.cost` |
| `ai_agent.session.count` | monotonic sum | `agent` | `claude_code.session.count`, `gemini_cli.session.count`, `opencode.session.count`, `codex.thread.started` |
| `ai_agent.lines_of_code.count` | monotonic sum | `agent`, `type` in added/removed | `claude_code.lines_of_code.count`, `gemini_cli.lines.changed`, `opencode.lines_of_code.count` |
| `ai_agent.tool.call.count` | monotonic sum | `agent`, `tool_name` | `gemini_cli.tool.call.count` (`function_name`), `codex.tool.call` (`tool`), `gen_ai.client.tool.calls` when pi (`gen_ai.tool.name`), `agy.tool.call.count` |

Value normalisation for `type`: `cacheRead`->`cache_read`, `cached`->`cache_read`, `cache`->`cache_read`, `cached_input`->`cache_read`, `cacheCreation`->`cache_write`, `thought`->`reasoning`, `reasoning_output`->`reasoning`. Codex datapoints with `token_type="total"` are dropped (sum of the others).
Key normalisation: `gen_ai.token.type`->`type`, `token_type`->`type`, `gen_ai.request.model`->`model`, `function_name`->`tool_name`, `tool.name`->`tool_name`, `gen_ai.tool.name`->`tool_name`, `tool`->`tool_name`.

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

## User identity (multi-user deployments)

Clients send `OTEL_EXPORTER_OTLP_HEADERS=x-user=<name>`. The OTLP receiver runs with `include_metadata: true`; an `attributes/user` processor (`insert`, `from_context: metadata.x-user`) copies the header onto every datapoint/log/span as `user`; `transform/unify` sets `user="unknown"` when absent. Unauthenticated by design (deployed inside a trusted network); the upgrade path is the `basicauth` extension with `from_context: auth.username`. The dashboard gets a `user` variable that every query filters on, plus a "Users" row (per-user table with tokens/cost/sessions/agents/last seen, tokens by user x agent, cost by user).

## Cardinality control

Datapoint attributes deleted: `user.id`, `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`, `terminal.type`, `prompt.id`, `installation.id`, `app.entrypoint`. The same per-user keys are also deleted from the resource so they cannot surface via `target_info`.

`session.id` is deliberately **kept** as a label. The agents export cumulative per-session counters; without `session.id` two concurrent sessions of one agent share a label set, their samples interleave, and Prometheus reads each drop as a counter reset (over-counting `rate()`/`increase()`). Cardinality is bounded by sessions per day and aged out by `metric_expiration` / staleness. Gemini CLI puts `session.id` on the resource; the transform copies it to each datapoint so every agent carries it uniformly. Dashboard queries always aggregate with `sum by (agent, ...)`. Agents that send no session id (Codex, Pi) get one synthesised from the datapoint `start_time_unix_nano`, which is constant per process: every run owns its own series that starts at 0 and never resets. Only sources that neither send a session id nor keep a stable start time would fragment; none of the supported ones do.

Prometheus exporter: `add_metric_suffixes: true` (default), `metric_expiration: 10m`, `resource_to_telemetry_conversion: false`. `delta_to_cumulative` (`max_stale: 24h` so idle sessions do not reset, `max_streams: 10000`) sits before the exporters so delta-temporality sources still produce Prometheus counters. Component names use the current (non-alias) forms `otlp_http` and `delta_to_cumulative` because the collector image tag floats.

## Estimated cost (price table)

`pricing/prices.csv` (`model,type,usd_per_mtok`) is published as the gauge `llm_price_per_mtok{model,type}` by `pricing/push-prices.sh` (sh + curl, runs in the `llm-pricing` compose service every 60 s; on Kubernetes the same script as a sidecar with the CSV from a ConfigMap). Cost is computed in PromQL at query time — `tokens * on (model, type) group_left () last_over_time(llm_price_per_mtok[1d]) / 1e6` — so price edits apply retroactively and need no restart. Chosen over converting at ingest (OTTL rules generated from the CSV) because that would require a collector rollout per price change and would not re-price history. Gateway-side the gauge passes through untouched (it gets `agent="unknown"`, `user="unknown"`, which the join ignores).

## Grafana dashboard "AI Agents"

Datasource `uid: prometheus` (provisioned by otel-lgtm). Variables: `user`, `agent` (both multi, All, from `label_values({__name__=~"ai_agent_.*"}, ...)`), `model` (multi, All).

| Row | Panels |
|---|---|
| Overview (stat) | tokens 24h, cost USD 24h, sessions 24h, agents reporting now. Totals use `sum(last_over_time(x[24h]))`: with per-session counters that start at 0 this is the exact session total and works from the first sample (one-shot runs like `codex exec` export exactly once). `increase()` would need two samples and under-counts the first chunk. Graphs keep `rate`/`increase`. |
| Tokens | tokens per 5-min bucket by agent (stacked bars); by type (stacked bars); tokens by model (pie). Bucket delta is `x - ((x offset $__interval) or (x * 0))`: a series that just appeared counts from 0, so a one-shot run draws a bar; `rate()` would need two samples. |
| Cost | cost per 5-min bucket by agent (stacked bars, same delta formula); cost by model (bar); text note: Gemini/Codex/Antigravity report no cost |
| Estimated cost | estimated USD 24h (stat); per 5-min by agent (bars); top 10 users by estimated cost; by model; "Unpriced models" table (tokens seen, no CSV row) |
| Activity | sessions by agent; lines added/removed by agent; tool calls top 10 (table, agent x tool_name) |
| Antigravity | turns 24h, tool calls 24h (stat); turns and invocations over time (bars) — Antigravity's only signals |
| Detail | table: one row per agent — tokens, cost, sessions, last seen |

Provisioning: `dashboards.yaml` provider of type `file` pointing to `/otel-lgtm/grafana/conf/provisioning/dashboards/custom`.

## Docker Compose

- `otel-collector`: `otel/opentelemetry-collector-contrib:latest`, mounts config, ports 4317/4318/8889, `depends_on: otel-lgtm (service_healthy)`.
- `otel-lgtm`: `grafana/otel-lgtm` pinned to the version validated at build time (we mount into image-internal paths and rely on its HEALTHCHECK), port 3000, mounts the two grafana files, healthcheck on Grafana `/api/health`.

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
7. `docker compose down -v` unless `KEEP=1`. The test uses its own `COMPOSE_PROJECT_NAME` so it never reuses or wipes a user's running stack.

Fixtures are hand-written OTLP JSON reflecting the source inventory above, with one histogram fixture each for Codex and Pi.

## Out of scope

Transforming logs/traces; per-user reporting; auth on the gateway; long-term Prometheus retention.
