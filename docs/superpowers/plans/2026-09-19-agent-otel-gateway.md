# AI Agent OTel Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `otel/opentelemetry-collector-contrib` gateway on :4318/:4317 that normalises metrics from Claude Code (incl. via CCR), Gemini CLI, Codex, OpenCode, Pi (`@damngamerz/pi-otel`) and Antigravity into an `ai_agent.*` schema, forwards them to `grafana/otel-lgtm`, and ships a provisioned Grafana dashboard "AI Agents".

**Architecture:** The gateway collector runs `otlp → memory_limiter → filter → transform (OTTL) → attributes → deltatocumulative → batch → {otlphttp→otel-lgtm, prometheus:8889, debug}`. Agent identity is derived from the metric-name prefix and written as datapoint attribute `agent`; histogram token metrics (Codex, Pi) become sums via `extract_sum_metric`. otel-lgtm's Prometheus receives OTLP and Grafana loads the dashboard from a mounted provisioning file. Tests are a bash script that boots the stack, POSTs hand-written OTLP JSON fixtures, and asserts on `:8889/metrics` and on Grafana's API.

**Tech Stack:** Docker Compose, otel-collector-contrib (OTTL), grafana/otel-lgtm, bash + curl for tests. No application code.

**Spec:** `docs/superpowers/specs/2026-09-19-agent-otel-gateway-design.md`

---

## File structure

| Path | Responsibility |
|---|---|
| `docker-compose.yml` | Runs `otel-collector` (gateway) and `otel-lgtm`; wires mounts and ports |
| `otel-collector-config.yaml` | The whole gateway: receivers, unify transform, cardinality stripping, exporters |
| `grafana/provisioning/dashboards.yaml` | Tells Grafana to load dashboards from the `custom` dir |
| `grafana/dashboards/ai-agents.json` | The "AI Agents" dashboard |
| `tests/fixtures/<agent>.json` | One OTLP/HTTP JSON metrics payload per agent, with `__NOW__`/`__START__` timestamp placeholders |
| `tests/run.sh` | End-to-end test: validate config, boot stack, POST fixtures, assert |
| `README.md` | How to run, how to point each agent at the gateway |
| `.gitattributes` | Force LF for `*.sh`/`*.yaml`/`*.json` so scripts run on Windows checkouts |

Prerequisites on the machine running the tests: Docker Desktop with Compose v2, bash (Git Bash on Windows), curl, sed, `date`.

---

### Task 1: Compose skeleton + pass-through collector config

**Files:**
- Create: `.gitattributes`
- Create: `docker-compose.yml`
- Create: `otel-collector-config.yaml` (pass-through version; Task 3 replaces the processors)
- Create: `grafana/provisioning/dashboards.yaml`

- [ ] **Step 1: Create `.gitattributes`**

```
* text=auto
*.sh text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
*.json text eol=lf
*.md text eol=lf
```

- [ ] **Step 2: Create `docker-compose.yml`**

```yaml
services:
  otel-lgtm:
    image: grafana/otel-lgtm:latest
    ports:
      - "3000:3000"   # Grafana (anonymous admin enabled by the image)
    volumes:
      - ./grafana/provisioning/dashboards.yaml:/otel-lgtm/grafana/conf/provisioning/dashboards/ai-agents.yaml:ro
      - lgtm-data:/data
    # The image declares its own HEALTHCHECK (Grafana, Loki, Tempo, Prometheus, internal collector).

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    command: ["--config=/etc/otelcol-contrib/config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro
    ports:
      - "4317:4317"    # OTLP gRPC
      - "4318:4318"    # OTLP HTTP (default for the agents)
      - "8889:8889"    # Prometheus scrape endpoint
      - "13133:13133"  # health_check extension
    depends_on:
      otel-lgtm:
        condition: service_healthy

volumes:
  lgtm-data:
```

- [ ] **Step 3: Create `grafana/provisioning/dashboards.yaml`**

```yaml
apiVersion: 1

providers:
  - name: "AI Agents"
    type: file
    options:
      path: /otel-lgtm/grafana/conf/provisioning/dashboards/custom
      foldersFromFilesStructure: false
```

- [ ] **Step 4: Create the pass-through `otel-collector-config.yaml`**

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch: {}

exporters:
  otlphttp/lgtm:
    endpoint: http://otel-lgtm:4318
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:8889
    metric_expiration: 10m
    resource_to_telemetry_conversion:
      enabled: false
  debug:
    verbosity: basic

service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/lgtm, prometheus, debug]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/lgtm]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/lgtm]
```

- [ ] **Step 5: Validate compose and collector config**

Run (from repo root, bash):
```bash
docker compose config -q && echo COMPOSE_OK
docker run --rm -v "$PWD/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro" otel/opentelemetry-collector-contrib:latest validate --config=/etc/otelcol-contrib/config.yaml && echo CONFIG_OK
```
Expected: `COMPOSE_OK` then `CONFIG_OK` (the validate command prints nothing on success).

- [ ] **Step 6: Commit**

```bash
git add .gitattributes docker-compose.yml otel-collector-config.yaml grafana/provisioning/dashboards.yaml
git commit -m "feat: compose skeleton with pass-through collector and otel-lgtm"
```

---

### Task 2: Fixtures and the end-to-end test script (red)

**Files:**
- Create: `tests/fixtures/claude_code.json`
- Create: `tests/fixtures/gemini_cli.json`
- Create: `tests/fixtures/codex.json`
- Create: `tests/fixtures/opencode.json`
- Create: `tests/fixtures/pi.json`
- Create: `tests/fixtures/antigravity.json`
- Create: `tests/run.sh`

All fixtures are OTLP/HTTP JSON (`ExportMetricsServiceRequest`). `aggregationTemporality: 2` = cumulative. `__START__`/`__NOW__` are replaced by `run.sh` with real nanosecond timestamps so otel-lgtm's Prometheus accepts the samples. Claude Code's fixture deliberately carries the high-cardinality attributes it really sends so the test can prove they are stripped, plus `router=ccr` (what `OTEL_RESOURCE_ATTRIBUTES=router=ccr` produces).

- [ ] **Step 1: Create `tests/fixtures/claude_code.json`**

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "claude-code"}},
      {"key": "service.version", "value": {"stringValue": "2.1.0"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "com.anthropic.claude_code"},
      "metrics": [
        {"name": "claude_code.token.usage", "unit": "tokens", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "input"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}, {"key": "user.email", "value": {"stringValue": "dev@example.com"}}, {"key": "user.account_uuid", "value": {"stringValue": "acc-1"}}, {"key": "organization.id", "value": {"stringValue": "org-1"}}, {"key": "terminal.type", "value": {"stringValue": "vscode"}}, {"key": "router", "value": {"stringValue": "ccr"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "1200"},
          {"attributes": [{"key": "type", "value": {"stringValue": "output"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}, {"key": "router", "value": {"stringValue": "ccr"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "300"},
          {"attributes": [{"key": "type", "value": {"stringValue": "cacheRead"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}, {"key": "router", "value": {"stringValue": "ccr"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "5000"},
          {"attributes": [{"key": "type", "value": {"stringValue": "cacheCreation"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}, {"key": "router", "value": {"stringValue": "ccr"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "800"}
        ]}},
        {"name": "claude_code.cost.usage", "unit": "USD", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asDouble": 0.42}
        ]}},
        {"name": "claude_code.session.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "start_type", "value": {"stringValue": "fresh"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "1"}
        ]}},
        {"name": "claude_code.lines_of_code.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "added"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "40"},
          {"attributes": [{"key": "type", "value": {"stringValue": "removed"}}, {"key": "model", "value": {"stringValue": "claude-opus-5"}}, {"key": "session.id", "value": {"stringValue": "sess-cc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "5"}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 2: Create `tests/fixtures/gemini_cli.json`**

Includes the duplicate `gen_ai.client.token.usage` histogram that the gateway must drop.

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "gemini-cli"}},
      {"key": "session.id", "value": {"stringValue": "sess-gem-1"}},
      {"key": "installation.id", "value": {"stringValue": "inst-1"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "gemini-cli"},
      "metrics": [
        {"name": "gemini_cli.token.usage", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "input"}}, {"key": "model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "900"},
          {"attributes": [{"key": "type", "value": {"stringValue": "output"}}, {"key": "model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "250"},
          {"attributes": [{"key": "type", "value": {"stringValue": "thought"}}, {"key": "model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "120"},
          {"attributes": [{"key": "type", "value": {"stringValue": "cache"}}, {"key": "model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "3000"},
          {"attributes": [{"key": "type", "value": {"stringValue": "tool"}}, {"key": "model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "60"}
        ]}},
        {"name": "gemini_cli.session.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "1"}
        ]}},
        {"name": "gemini_cli.lines.changed", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "added"}}, {"key": "function_name", "value": {"stringValue": "write_file"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "22"},
          {"attributes": [{"key": "type", "value": {"stringValue": "removed"}}, {"key": "function_name", "value": {"stringValue": "write_file"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "3"}
        ]}},
        {"name": "gemini_cli.tool.call.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "function_name", "value": {"stringValue": "read_file"}}, {"key": "success", "value": {"boolValue": true}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "7"}
        ]}},
        {"name": "gen_ai.client.token.usage", "unit": "{token}", "histogram": {"aggregationTemporality": 2, "dataPoints": [
          {"attributes": [{"key": "gen_ai.token.type", "value": {"stringValue": "input"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "gemini-2.5-pro"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "1", "sum": 900, "bucketCounts": ["0", "1"], "explicitBounds": [100]}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 3: Create `tests/fixtures/codex.json`**

Token usage is a histogram; the gateway must produce a counter from it.

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "codex_tui"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "codex"},
      "metrics": [
        {"name": "codex.turn.token_usage", "histogram": {"aggregationTemporality": 2, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "input"}}, {"key": "model", "value": {"stringValue": "gpt-5-codex"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "2", "sum": 1500, "bucketCounts": ["0", "0", "2"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "type", "value": {"stringValue": "output"}}, {"key": "model", "value": {"stringValue": "gpt-5-codex"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "2", "sum": 400, "bucketCounts": ["0", "1", "1"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "type", "value": {"stringValue": "cached"}}, {"key": "model", "value": {"stringValue": "gpt-5-codex"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "2", "sum": 2000, "bucketCounts": ["0", "0", "2"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "type", "value": {"stringValue": "reasoning"}}, {"key": "model", "value": {"stringValue": "gpt-5-codex"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "2", "sum": 350, "bucketCounts": ["0", "1", "1"], "explicitBounds": [100, 500]}
        ]}},
        {"name": "codex.thread.started", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "originator", "value": {"stringValue": "codex_cli_rs"}}, {"key": "model", "value": {"stringValue": "gpt-5-codex"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "1"}
        ]}},
        {"name": "codex.tool.call", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "tool.name", "value": {"stringValue": "shell"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "4"}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 4: Create `tests/fixtures/opencode.json`**

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "opencode"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "opencode-plugin-otel"},
      "metrics": [
        {"name": "opencode.token.usage", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "input"}}, {"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "700"},
          {"attributes": [{"key": "type", "value": {"stringValue": "output"}}, {"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "200"},
          {"attributes": [{"key": "type", "value": {"stringValue": "reasoning"}}, {"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "90"},
          {"attributes": [{"key": "type", "value": {"stringValue": "cacheRead"}}, {"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "2500"},
          {"attributes": [{"key": "type", "value": {"stringValue": "cacheCreation"}}, {"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "400"}
        ]}},
        {"name": "opencode.cost.usage", "unit": "USD", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asDouble": 0.11}
        ]}},
        {"name": "opencode.session.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "1"}
        ]}},
        {"name": "opencode.lines_of_code.count", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "type", "value": {"stringValue": "added"}}, {"key": "session.id", "value": {"stringValue": "sess-oc-1"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "15"}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 5: Create `tests/fixtures/pi.json`**

Matches `@damngamerz/pi-otel`: `service.name=pi`, semconv histogram with `gen_ai.token.type`, `gen_ai.system=pi`.

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "pi"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "@damngamerz/pi-otel"},
      "metrics": [
        {"name": "gen_ai.client.token.usage", "unit": "{token}", "histogram": {"aggregationTemporality": 2, "dataPoints": [
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}}, {"key": "gen_ai.provider.name", "value": {"stringValue": "anthropic"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "gen_ai.token.type", "value": {"stringValue": "input"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "3", "sum": 1100, "bucketCounts": ["0", "1", "2"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}}, {"key": "gen_ai.provider.name", "value": {"stringValue": "anthropic"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "gen_ai.token.type", "value": {"stringValue": "output"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "3", "sum": 330, "bucketCounts": ["0", "3", "0"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}}, {"key": "gen_ai.provider.name", "value": {"stringValue": "anthropic"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "gen_ai.token.type", "value": {"stringValue": "cache_read"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "3", "sum": 4000, "bucketCounts": ["0", "0", "3"], "explicitBounds": [100, 500]},
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}}, {"key": "gen_ai.provider.name", "value": {"stringValue": "anthropic"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "claude-sonnet-5"}}, {"key": "gen_ai.token.type", "value": {"stringValue": "cache_write"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "count": "3", "sum": 600, "bucketCounts": ["0", "1", "2"], "explicitBounds": [100, 500]}
        ]}},
        {"name": "pi.agent.cost", "unit": "USD", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.provider.name", "value": {"stringValue": "anthropic"}}, {"key": "gen_ai.request.model", "value": {"stringValue": "claude-sonnet-5"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asDouble": 0.09}
        ]}},
        {"name": "pi.agent.prompts", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "3"}
        ]}},
        {"name": "gen_ai.client.tool.calls", "sum": {"aggregationTemporality": 2, "isMonotonic": true, "dataPoints": [
          {"attributes": [{"key": "gen_ai.system", "value": {"stringValue": "pi"}}, {"key": "gen_ai.tool.name", "value": {"stringValue": "bash"}}], "startTimeUnixNano": "__START__", "timeUnixNano": "__NOW__", "asInt": "5"}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 6: Create `tests/fixtures/antigravity.json`**

```json
{
  "resourceMetrics": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "antigravity-cli"}}
    ]},
    "scopeMetrics": [{
      "scope": {"name": "agy-otel"},
      "metrics": [
        {"name": "agy.quota.remaining_fraction", "gauge": {"dataPoints": [
          {"attributes": [{"key": "model", "value": {"stringValue": "gemini-3-pro"}}], "timeUnixNano": "__NOW__", "asDouble": 0.8}
        ]}},
        {"name": "agy.quota.seconds_to_reset", "gauge": {"dataPoints": [
          {"attributes": [{"key": "model", "value": {"stringValue": "gemini-3-pro"}}], "timeUnixNano": "__NOW__", "asInt": "3600"}
        ]}}
      ]
    }]
  }]
}
```

- [ ] **Step 7: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
# End-to-end test for the agent OTel gateway.
# Usage: tests/run.sh          (boots the stack, runs assertions, tears down)
#        KEEP=1 tests/run.sh   (leaves the stack running afterwards)
set -euo pipefail
cd "$(dirname "$0")/.."

GATEWAY=http://localhost:4318
HEALTH=http://localhost:13133
PROM=http://localhost:8889/metrics
GRAFANA=http://localhost:3000
IMAGE=otel/opentelemetry-collector-contrib:latest

FAILED=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*" >&2; FAILED=1; }
die()  { echo "ABORT - $*" >&2; exit 1; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "# 1. config validation"
docker compose config -q || die "docker compose config failed"
docker run --rm -v "$PWD/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  "$IMAGE" validate --config=/etc/otelcol-contrib/config.yaml || die "collector config invalid"
ok "configs valid"

echo "# 2. boot stack"
docker compose up -d
for _ in $(seq 1 90); do
  if curl -fsS "$HEALTH" >/dev/null 2>&1 && curl -fsS "$GRAFANA/api/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS "$HEALTH" >/dev/null || die "collector never became healthy"
curl -fsS "$GRAFANA/api/health" >/dev/null || die "grafana never became healthy"
ok "stack healthy"

echo "# 3. post fixtures"
NOW="$(date +%s)000000000"
START=$((NOW - 60000000000))
for f in tests/fixtures/*.json; do
  sed -e "s/__NOW__/$NOW/g" -e "s/__START__/$START/g" "$f" \
    | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- "$GATEWAY/v1/metrics" >/dev/null \
    || die "POST $f rejected"
  ok "posted $(basename "$f")"
done
sleep 5

echo "# 4. assertions on :8889/metrics"
OUT="$(curl -fsS "$PROM")"
expect() { if echo "$OUT" | grep -qE "$1"; then ok "$2"; else fail "$2  (pattern: $1)"; fi; }
reject() { if echo "$OUT" | grep -qE "$1"; then fail "$2  (pattern: $1)"; else ok "$2"; fi; }
L='\{[^}]*'   # label-block prefix, any labels before

# unified token counter per agent, with normalised type values
for a in claude_code gemini_cli codex opencode pi; do
  expect "^ai_agent_token_usage_total${L}agent=\"$a\"${L}type=\"input\"" "$a: ai_agent_token_usage_total type=input"
done
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}type=\"cache_read\"[^}]*\} 5000" "claude_code: cacheRead -> cache_read (5000)"
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}type=\"cache_write\"[^}]*\} 800" "claude_code: cacheCreation -> cache_write (800)"
expect "^ai_agent_token_usage_total${L}agent=\"gemini_cli\"${L}type=\"reasoning\"[^}]*\} 120" "gemini_cli: thought -> reasoning (120)"
expect "^ai_agent_token_usage_total${L}agent=\"gemini_cli\"${L}type=\"cache_read\"[^}]*\} 3000" "gemini_cli: cache -> cache_read (3000)"
expect "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"cache_read\"[^}]*\} 2000" "codex: histogram sum -> counter, cached -> cache_read (2000)"
expect "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"input\"[^}]*\} 1500" "codex: histogram sum -> counter (1500)"
expect "^ai_agent_token_usage_total${L}agent=\"opencode\"${L}type=\"cache_write\"[^}]*\} 400" "opencode: cacheCreation -> cache_write (400)"
expect "^ai_agent_token_usage_total${L}agent=\"pi\"${L}model=\"claude-sonnet-5\"${L}type=\"cache_write\"[^}]*\} 600" "pi: gen_ai histogram -> counter, keys renamed (600)"

# cost
for a in claude_code opencode pi; do
  expect "^ai_agent_cost_usage_total${L}agent=\"$a\"" "$a: ai_agent_cost_usage_total"
done
expect "^ai_agent_cost_usage_total${L}agent=\"pi\"${L}model=\"claude-sonnet-5\"" "pi: cost model renamed from gen_ai.request.model"

# sessions
for a in claude_code gemini_cli codex opencode; do
  expect "^ai_agent_session_count_total${L}agent=\"$a\"" "$a: ai_agent_session_count_total"
done

# lines of code
for a in claude_code gemini_cli opencode; do
  expect "^ai_agent_lines_of_code_count_total${L}agent=\"$a\"${L}type=\"added\"" "$a: ai_agent_lines_of_code_count_total type=added"
done

# tool calls with normalised tool_name
expect "^ai_agent_tool_call_count_total${L}agent=\"gemini_cli\"${L}tool_name=\"read_file\"" "gemini_cli: function_name -> tool_name"
expect "^ai_agent_tool_call_count_total${L}agent=\"codex\"${L}tool_name=\"shell\"" "codex: tool.name -> tool_name"
expect "^ai_agent_tool_call_count_total${L}agent=\"pi\"${L}tool_name=\"bash\"" "pi: gen_ai.tool.name -> tool_name"

# pass-through metrics keep their name and gain agent
expect "^agy_quota_remaining_fraction${L}agent=\"antigravity\"" "antigravity: pass-through gauge tagged"
expect "^pi_agent_prompts_total${L}agent=\"pi\"" "pi: pass-through counter tagged"

# CCR marker survives
expect "^ai_agent_token_usage_total${L}router=\"ccr\"" "claude_code via CCR: router label kept"

# unit suffixes must not leak into names
reject "^ai_agent_cost_usage_USD" "no _USD unit suffix on cost"
reject "^ai_agent_token_usage_tokens" "no _tokens unit suffix on tokens"

# cardinality stripping
reject "session_id=" "session.id stripped"
reject "user_email=" "user.email stripped"
reject "user_account_uuid=" "user.account_uuid stripped"
reject "organization_id=" "organization.id stripped"
reject "terminal_type=" "terminal.type stripped"

# gemini's duplicate semconv histogram dropped, pi's kept
reject "^gen_ai_client_token_usage[a-z_]*${L}agent=\"gemini_cli\"" "gemini_cli: gen_ai.client.token.usage dropped"
reject "^ai_agent_token_usage_total${L}agent=\"unknown\"" "no unknown-agent token series"
reject "^gen_ai_token_type|gen_ai_token_type=" "gen_ai.token.type key renamed away"

echo "# 5. assertions via otel-lgtm (Grafana -> Prometheus proxy)"
Q="$GRAFANA/api/datasources/proxy/uid/prometheus/api/v1/query"
RES=""
for _ in $(seq 1 15); do
  RES="$(curl -fsS -G "$Q" --data-urlencode 'query=count by (agent) (ai_agent_token_usage_total)' || true)"
  echo "$RES" | grep -q '"agent":"pi"' && break
  sleep 2
done
for a in claude_code gemini_cli codex opencode pi; do
  if echo "$RES" | grep -q "\"agent\":\"$a\""; then ok "lgtm prometheus has agent=$a"; else fail "lgtm prometheus missing agent=$a"; fi
done
if echo "$RES" | grep -q '_USD'; then fail "lgtm: unit suffix leaked"; else ok "lgtm: no unit suffix"; fi

echo "# 6. dashboard provisioned"
if curl -fsS "$GRAFANA/api/search?query=AI%20Agents" | grep -q '"uid":"ai-agents"'; then
  ok "dashboard 'AI Agents' provisioned"
else
  fail "dashboard 'AI Agents' not found"
fi
if curl -fsS "$GRAFANA/api/dashboards/uid/ai-agents" | grep -q '"title":"AI Agents"'; then
  ok "dashboard loads by uid"
else
  fail "dashboard uid ai-agents not loadable"
fi

echo
if [ "$FAILED" = "0" ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
```

- [ ] **Step 8: Make it executable and run it — expect failures**

Run: `chmod +x tests/run.sh && tests/run.sh`
Expected: config valid, stack boots, fixtures post, then many `FAIL -` lines (no `ai_agent_*` metrics yet, `session_id=` present, dashboard missing), ending with `SOME CHECKS FAILED` and exit 1. If the run aborts before assertions (e.g. `collector never became healthy`), fix the compose/config from Task 1 before continuing.

- [ ] **Step 9: Commit**

```bash
git add tests/
git commit -m "test: add OTLP fixtures per agent and end-to-end gateway test (red)"
```

---

### Task 3: The unify transform (green for metrics assertions)

**Files:**
- Modify: `otel-collector-config.yaml` (replace the `processors:` block and the metrics pipeline's `processors:` list)

- [ ] **Step 1: Replace the `processors:` block**

Replace everything from `processors:` up to (not including) `exporters:` with:

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128

  # Gemini CLI emits both gemini_cli.token.usage and the semconv gen_ai.client.token.usage
  # for the same tokens; keep the former, drop the latter so nothing is counted twice.
  filter/dedupe:
    error_mode: ignore
    metrics:
      metric:
        - 'name == "gen_ai.client.token.usage" and resource.attributes["service.name"] == "gemini-cli"'

  # Normalise every agent into the ai_agent.* schema.
  # Block order matters: (1) derive sums from histograms, (2) tag agent + normalise
  # attributes while original names are still visible, (3) rename metrics.
  transform/unify:
    error_mode: ignore
    metric_statements:
      - context: metric
        statements:
          # Codex and pi-otel report tokens as histograms; extract_sum_metric(true)
          # appends a monotonic Sum named "<name>_sum" (originals are kept).
          - extract_sum_metric(true) where name == "codex.turn.token_usage"
          - extract_sum_metric(true) where name == "gen_ai.client.token.usage"

      - context: datapoint
        statements:
          # --- agent detection: metric-name prefix first, gen_ai.* by system/service ---
          - set(attributes["agent"], "claude_code") where IsMatch(metric.name, "^claude_code\\.")
          - set(attributes["agent"], "gemini_cli") where IsMatch(metric.name, "^gemini_cli\\.")
          - set(attributes["agent"], "codex") where IsMatch(metric.name, "^codex\\.")
          - set(attributes["agent"], "opencode") where IsMatch(metric.name, "^opencode\\.")
          - set(attributes["agent"], "pi") where IsMatch(metric.name, "^pi\\.")
          - set(attributes["agent"], "antigravity") where IsMatch(metric.name, "^agy\\.")
          - set(attributes["agent"], "pi") where IsMatch(metric.name, "^gen_ai\\.") and (attributes["gen_ai.system"] == "pi" or resource.attributes["service.name"] == "pi")
          - set(attributes["agent"], "unknown") where attributes["agent"] == nil
          # --- attribute key normalisation ---
          - set(attributes["type"], attributes["gen_ai.token.type"]) where attributes["gen_ai.token.type"] != nil
          - delete_key(attributes, "gen_ai.token.type")
          - set(attributes["model"], attributes["gen_ai.request.model"]) where attributes["gen_ai.request.model"] != nil and attributes["model"] == nil
          - delete_key(attributes, "gen_ai.request.model")
          - set(attributes["tool_name"], attributes["function_name"]) where attributes["function_name"] != nil
          - delete_key(attributes, "function_name")
          - set(attributes["tool_name"], attributes["tool.name"]) where attributes["tool.name"] != nil
          - delete_key(attributes, "tool.name")
          - set(attributes["tool_name"], attributes["gen_ai.tool.name"]) where attributes["gen_ai.tool.name"] != nil
          - delete_key(attributes, "gen_ai.tool.name")
          # --- token type value normalisation ---
          - set(attributes["type"], "cache_read") where attributes["type"] == "cacheRead" or attributes["type"] == "cached" or attributes["type"] == "cache"
          - set(attributes["type"], "cache_write") where attributes["type"] == "cacheCreation"
          - set(attributes["type"], "reasoning") where attributes["type"] == "thought"

      - context: metric
        statements:
          - set(name, "ai_agent.token.usage") where name == "claude_code.token.usage" or name == "gemini_cli.token.usage" or name == "opencode.token.usage" or name == "codex.turn.token_usage_sum" or name == "gen_ai.client.token.usage_sum"
          - set(name, "ai_agent.cost.usage") where name == "claude_code.cost.usage" or name == "opencode.cost.usage" or name == "pi.agent.cost"
          - set(name, "ai_agent.session.count") where name == "claude_code.session.count" or name == "gemini_cli.session.count" or name == "opencode.session.count" or name == "codex.thread.started"
          - set(name, "ai_agent.lines_of_code.count") where name == "claude_code.lines_of_code.count" or name == "gemini_cli.lines.changed" or name == "opencode.lines_of_code.count"
          - set(name, "ai_agent.tool.call.count") where name == "gemini_cli.tool.call.count" or name == "codex.tool.call" or name == "gen_ai.client.tool.calls"
          # Units differ per agent ("tokens", "{token}", "USD", ""); Prometheus would turn them
          # into name suffixes. Clear them so every backend yields e.g. ai_agent_token_usage_total.
          - set(unit, "") where IsMatch(name, "^ai_agent\\.")

  # High-cardinality per-session / per-user attributes must not become Prometheus labels.
  attributes/cardinality:
    actions:
      - { key: session.id, action: delete }
      - { key: user.id, action: delete }
      - { key: user.email, action: delete }
      - { key: user.account_uuid, action: delete }
      - { key: user.account_id, action: delete }
      - { key: organization.id, action: delete }
      - { key: terminal.type, action: delete }
      - { key: prompt.id, action: delete }
      - { key: installation.id, action: delete }
      - { key: app.entrypoint, action: delete }

  # Prometheus needs cumulative temporality; some SDKs export delta.
  deltatocumulative:
    max_stale: 10m

  batch: {}
```

- [ ] **Step 2: Update the metrics pipeline**

Change the metrics pipeline's processors line to:

```yaml
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, filter/dedupe, transform/unify, attributes/cardinality, deltatocumulative, batch]
      exporters: [otlphttp/lgtm, prometheus, debug]
```

(logs and traces pipelines stay `[memory_limiter, batch]`.)

- [ ] **Step 3: Validate the config alone**

Run: `docker run --rm -v "$PWD/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro" otel/opentelemetry-collector-contrib:latest validate --config=/etc/otelcol-contrib/config.yaml && echo CONFIG_OK`
Expected: `CONFIG_OK`. If it reports an OTTL parse error, the message names the statement; fix that statement (common causes: a missing `\\` in a regex, `name` vs `metric.name` used in the wrong context).

- [ ] **Step 4: Run the end-to-end test**

Run: `tests/run.sh`
Expected: every check in sections 4 and 5 prints `ok`; section 6 (dashboard) still prints two `FAIL -` lines; final line `SOME CHECKS FAILED`.

If a section-4 check fails, run `KEEP=1 tests/run.sh` and inspect `curl -s localhost:8889/metrics | grep <metric>` and `docker compose logs otel-collector` (the debug exporter prints counts; OTTL runtime errors are logged at warn with the statement text).

- [ ] **Step 5: Commit**

```bash
git add otel-collector-config.yaml
git commit -m "feat: unify agent metrics into ai_agent.* schema and strip cardinality"
```

---

### Task 4: Grafana dashboard "AI Agents" (green for everything)

**Files:**
- Create: `grafana/dashboards/ai-agents.json`
- Modify: `docker-compose.yml` (add the dashboard mount and home-dashboard env)

Colour assignment is fixed per entity (never cycled), from a validated CVD-safe palette for Grafana's default dark theme: claude_code blue `#3987e5`, gemini_cli orange `#d95926`, codex aqua `#199e70`, opencode yellow `#c98500`, pi magenta `#d55181`, antigravity green `#008300`, unknown gray `#8e8e8e`. Token types use the same order: input blue, output orange, cache_read aqua, cache_write yellow, reasoning magenta, tool green.

- [ ] **Step 1: Create `grafana/dashboards/ai-agents.json`**

```json
{
  "uid": "ai-agents",
  "title": "AI Agents",
  "tags": ["ai-agents", "otel"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "refresh": "30s",
  "schemaVersion": 39,
  "version": 1,
  "time": {"from": "now-24h", "to": "now"},
  "templating": {
    "list": [
      {
        "name": "agent", "label": "Agent", "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "definition": "label_values(ai_agent_token_usage_total, agent)",
        "query": {"query": "label_values(ai_agent_token_usage_total, agent)", "refId": "agent"},
        "multi": true, "includeAll": true, "allValue": ".*", "refresh": 2, "sort": 1,
        "current": {"selected": true, "text": ["All"], "value": ["$__all"]}
      },
      {
        "name": "model", "label": "Model", "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "definition": "label_values(ai_agent_token_usage_total{agent=~\"$agent\"}, model)",
        "query": {"query": "label_values(ai_agent_token_usage_total{agent=~\"$agent\"}, model)", "refId": "model"},
        "multi": true, "includeAll": true, "allValue": ".*", "refresh": 2, "sort": 1,
        "current": {"selected": true, "text": ["All"], "value": ["$__all"]}
      }
    ]
  },
  "panels": [
    {"type": "row", "id": 100, "title": "Overview", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "panels": []},

    {"type": "stat", "id": 1, "title": "Tokens (24h)", "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum(increase(ai_agent_token_usage_total{agent=~\"$agent\",model=~\"$model\"}[24h]))"}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "color": {"mode": "fixed", "fixedColor": "#3987e5"}}, "overrides": []},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "colorMode": "none", "graphMode": "none", "textMode": "value"}},

    {"type": "stat", "id": 2, "title": "Cost USD (24h)", "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum(increase(ai_agent_cost_usage_total{agent=~\"$agent\",model=~\"$model\"}[24h]))"}],
     "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "color": {"mode": "fixed", "fixedColor": "#3987e5"}}, "overrides": []},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "colorMode": "none", "graphMode": "none", "textMode": "value"}},

    {"type": "stat", "id": 3, "title": "Sessions (24h)", "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum(increase(ai_agent_session_count_total{agent=~\"$agent\"}[24h]))"}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "color": {"mode": "fixed", "fixedColor": "#3987e5"}}, "overrides": []},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "colorMode": "none", "graphMode": "none", "textMode": "value"}},

    {"type": "stat", "id": 4, "title": "Agents with token data", "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "count(count by (agent) (ai_agent_token_usage_total{agent=~\"$agent\"}))"}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "color": {"mode": "fixed", "fixedColor": "#3987e5"}}, "overrides": []},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "colorMode": "none", "graphMode": "none", "textMode": "value"}},

    {"type": "row", "id": 101, "title": "Tokens", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "panels": []},

    {"type": "timeseries", "id": 5, "title": "Token rate by agent", "gridPos": {"h": 8, "w": 10, "x": 0, "y": 6},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (agent) (rate(ai_agent_token_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__rate_interval]))", "legendFormat": "{{agent}}"}],
     "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 25, "stacking": {"mode": "normal", "group": "A"}, "showPoints": "never", "gradientMode": "none"}},
       "overrides": [
         {"matcher": {"id": "byName", "options": "claude_code"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#3987e5"}}]},
         {"matcher": {"id": "byName", "options": "gemini_cli"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}}]},
         {"matcher": {"id": "byName", "options": "codex"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#199e70"}}]},
         {"matcher": {"id": "byName", "options": "opencode"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#c98500"}}]},
         {"matcher": {"id": "byName", "options": "pi"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d55181"}}]},
         {"matcher": {"id": "byName", "options": "antigravity"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#008300"}}]},
         {"matcher": {"id": "byName", "options": "unknown"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#8e8e8e"}}]}
       ]},
     "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}},

    {"type": "timeseries", "id": 6, "title": "Token rate by type", "gridPos": {"h": 8, "w": 8, "x": 10, "y": 6},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (type) (rate(ai_agent_token_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__rate_interval]))", "legendFormat": "{{type}}"}],
     "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 25, "stacking": {"mode": "normal", "group": "A"}, "showPoints": "never", "gradientMode": "none"}},
       "overrides": [
         {"matcher": {"id": "byName", "options": "input"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#3987e5"}}]},
         {"matcher": {"id": "byName", "options": "output"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}}]},
         {"matcher": {"id": "byName", "options": "cache_read"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#199e70"}}]},
         {"matcher": {"id": "byName", "options": "cache_write"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#c98500"}}]},
         {"matcher": {"id": "byName", "options": "reasoning"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d55181"}}]},
         {"matcher": {"id": "byName", "options": "tool"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#008300"}}]}
       ]},
     "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}},

    {"type": "piechart", "id": 7, "title": "Tokens by model (range)", "gridPos": {"h": 8, "w": 6, "x": 18, "y": 6},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (model) (increase(ai_agent_token_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__range]))", "legendFormat": "{{model}}", "instant": true}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0}, "overrides": []},
     "options": {"pieType": "donut", "displayLabels": ["percent"], "legend": {"displayMode": "list", "placement": "right", "showLegend": true, "values": ["value"]}, "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "tooltip": {"mode": "single"}}},

    {"type": "row", "id": 102, "title": "Cost", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14}, "panels": []},

    {"type": "timeseries", "id": 8, "title": "Cost per hour by agent (USD/h)", "gridPos": {"h": 8, "w": 10, "x": 0, "y": 15},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (agent) (rate(ai_agent_cost_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__rate_interval])) * 3600", "legendFormat": "{{agent}}"}],
     "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 25, "stacking": {"mode": "normal", "group": "A"}, "showPoints": "never", "gradientMode": "none"}},
       "overrides": [
         {"matcher": {"id": "byName", "options": "claude_code"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#3987e5"}}]},
         {"matcher": {"id": "byName", "options": "gemini_cli"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}}]},
         {"matcher": {"id": "byName", "options": "codex"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#199e70"}}]},
         {"matcher": {"id": "byName", "options": "opencode"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#c98500"}}]},
         {"matcher": {"id": "byName", "options": "pi"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d55181"}}]},
         {"matcher": {"id": "byName", "options": "antigravity"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#008300"}}]},
         {"matcher": {"id": "byName", "options": "unknown"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#8e8e8e"}}]}
       ]},
     "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}},

    {"type": "barchart", "id": 9, "title": "Cost by model (range)", "gridPos": {"h": 8, "w": 8, "x": 10, "y": 15},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (model) (increase(ai_agent_cost_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__range]))", "legendFormat": "{{model}}", "instant": true, "format": "table"}],
     "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true}, "renameByName": {"Value": "USD"}}}],
     "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "color": {"mode": "fixed", "fixedColor": "#3987e5"}, "custom": {"lineWidth": 1, "fillOpacity": 80}}, "overrides": []},
     "options": {"orientation": "horizontal", "xField": "model", "showValue": "auto", "barWidth": 0.7, "groupWidth": 0.7, "legend": {"showLegend": false, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single"}}},

    {"type": "text", "id": 10, "title": "About cost", "gridPos": {"h": 8, "w": 6, "x": 18, "y": 15},
     "options": {"mode": "markdown", "content": "**Cost is reported only by** Claude Code, OpenCode and Pi (`@damngamerz/pi-otel`).\n\nGemini CLI, Codex and Antigravity do not export a cost metric, so they never appear in the cost panels. Compare them by tokens instead.\n\nSeries colours are fixed per agent: claude_code blue, gemini_cli orange, codex aqua, opencode yellow, pi magenta, antigravity green."}},

    {"type": "row", "id": 103, "title": "Activity", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23}, "panels": []},

    {"type": "timeseries", "id": 11, "title": "Sessions started by agent", "gridPos": {"h": 8, "w": 8, "x": 0, "y": 24},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (agent) (increase(ai_agent_session_count_total{agent=~\"$agent\"}[$__rate_interval]))", "legendFormat": "{{agent}}"}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "custom": {"drawStyle": "bars", "lineWidth": 1, "fillOpacity": 80, "stacking": {"mode": "normal", "group": "A"}, "showPoints": "never", "gradientMode": "none"}},
       "overrides": [
         {"matcher": {"id": "byName", "options": "claude_code"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#3987e5"}}]},
         {"matcher": {"id": "byName", "options": "gemini_cli"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}}]},
         {"matcher": {"id": "byName", "options": "codex"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#199e70"}}]},
         {"matcher": {"id": "byName", "options": "opencode"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#c98500"}}]},
         {"matcher": {"id": "byName", "options": "pi"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d55181"}}]},
         {"matcher": {"id": "byName", "options": "antigravity"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#008300"}}]},
         {"matcher": {"id": "byName", "options": "unknown"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#8e8e8e"}}]}
       ]},
     "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}},

    {"type": "timeseries", "id": 12, "title": "Lines of code by agent", "gridPos": {"h": 8, "w": 8, "x": 8, "y": 24},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum by (agent, type) (increase(ai_agent_lines_of_code_count_total{agent=~\"$agent\"}[$__rate_interval]))", "legendFormat": "{{agent}} {{type}}"}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "custom": {"drawStyle": "bars", "lineWidth": 1, "fillOpacity": 80, "stacking": {"mode": "none", "group": "A"}, "showPoints": "never", "gradientMode": "none"}},
       "overrides": [
         {"matcher": {"id": "byRegexp", "options": "^claude_code .*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#3987e5"}}]},
         {"matcher": {"id": "byRegexp", "options": "^gemini_cli .*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d95926"}}]},
         {"matcher": {"id": "byRegexp", "options": "^codex .*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#199e70"}}]},
         {"matcher": {"id": "byRegexp", "options": "^opencode .*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#c98500"}}]},
         {"matcher": {"id": "byRegexp", "options": "^pi .*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#d55181"}}]},
         {"matcher": {"id": "byRegexp", "options": ".* removed$"}, "properties": [{"id": "custom.fillOpacity", "value": 30}, {"id": "custom.transform", "value": "negative-Y"}]}
       ]},
     "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}},

    {"type": "table", "id": 13, "title": "Tool calls top 10 (range)", "gridPos": {"h": 8, "w": 8, "x": 16, "y": 24},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "topk(10, sum by (agent, tool_name) (increase(ai_agent_tool_call_count_total{agent=~\"$agent\"}[$__range])))", "instant": true, "format": "table"}],
     "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true}, "renameByName": {"Value": "Calls", "agent": "Agent", "tool_name": "Tool"}}}, {"id": "sortBy", "options": {"sort": [{"field": "Calls", "desc": true}]}}],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0}, "overrides": []},
     "options": {"showHeader": true, "cellHeight": "sm"}},

    {"type": "row", "id": 104, "title": "Detail", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 32}, "panels": []},

    {"type": "table", "id": 14, "title": "Per agent (range)", "gridPos": {"h": 8, "w": 24, "x": 0, "y": 33},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [
       {"refId": "A", "expr": "sum by (agent) (increase(ai_agent_token_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__range]))", "instant": true, "format": "table"},
       {"refId": "B", "expr": "sum by (agent) (increase(ai_agent_cost_usage_total{agent=~\"$agent\",model=~\"$model\"}[$__range]))", "instant": true, "format": "table"},
       {"refId": "C", "expr": "sum by (agent) (increase(ai_agent_session_count_total{agent=~\"$agent\"}[$__range]))", "instant": true, "format": "table"},
       {"refId": "D", "expr": "max by (agent) (timestamp(ai_agent_token_usage_total{agent=~\"$agent\"})) * 1000", "instant": true, "format": "table"}
     ],
     "transformations": [
       {"id": "joinByField", "options": {"byField": "agent", "mode": "outer"}},
       {"id": "organize", "options": {
         "excludeByName": {"Time": true, "Time 1": true, "Time 2": true, "Time 3": true, "Time 4": true},
         "renameByName": {"agent": "Agent", "Value #A": "Tokens", "Value #B": "Cost (USD)", "Value #C": "Sessions", "Value #D": "Last seen"},
         "indexByName": {"agent": 0, "Value #A": 1, "Value #B": 2, "Value #C": 3, "Value #D": 4}}}
     ],
     "fieldConfig": {"defaults": {"unit": "short", "decimals": 0}, "overrides": [
       {"matcher": {"id": "byName", "options": "Cost (USD)"}, "properties": [{"id": "unit", "value": "currencyUSD"}, {"id": "decimals", "value": 2}]},
       {"matcher": {"id": "byName", "options": "Last seen"}, "properties": [{"id": "unit", "value": "dateTimeFromNow"}]}
     ]},
     "options": {"showHeader": true, "cellHeight": "sm", "sortBy": [{"displayName": "Tokens", "desc": true}]}}
  ]
}
```

- [ ] **Step 2: Check the JSON parses**

Run: `docker run --rm -v "$PWD/grafana/dashboards/ai-agents.json:/d.json:ro" otel/opentelemetry-collector-contrib:latest --version >/dev/null; python -c "import json;json.load(open('grafana/dashboards/ai-agents.json'));print('JSON_OK')" 2>/dev/null || node -e "JSON.parse(require('fs').readFileSync('grafana/dashboards/ai-agents.json','utf8'));console.log('JSON_OK')"`
Expected: `JSON_OK` (whichever of python/node is installed).

- [ ] **Step 3: Mount the dashboard in `docker-compose.yml`**

Replace the `otel-lgtm` service with:

```yaml
  otel-lgtm:
    image: grafana/otel-lgtm:latest
    ports:
      - "3000:3000"   # Grafana (anonymous admin enabled by the image)
    environment:
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /otel-lgtm/grafana/conf/provisioning/dashboards/custom/ai-agents.json
    volumes:
      - ./grafana/provisioning/dashboards.yaml:/otel-lgtm/grafana/conf/provisioning/dashboards/ai-agents.yaml:ro
      - ./grafana/dashboards/ai-agents.json:/otel-lgtm/grafana/conf/provisioning/dashboards/custom/ai-agents.json:ro
      - lgtm-data:/data
    # The image declares its own HEALTHCHECK (Grafana, Loki, Tempo, Prometheus, internal collector).
```

- [ ] **Step 4: Run the end-to-end test**

Run: `tests/run.sh`
Expected: every line `ok`, final line `ALL PASSED`, exit 0.

- [ ] **Step 5: Look at the dashboard**

Run: `KEEP=1 tests/run.sh` then open `http://localhost:3000/d/ai-agents` in a browser (it is also the home dashboard). Check: all four stat tiles show non-zero values, "Token rate by agent" shows five coloured series with a legend, "Per agent" table has five rows with a "Last seen" like "a few seconds ago", no panel shows "No data" except possibly cost panels for agents without cost. Then `docker compose down -v`.

- [ ] **Step 6: Commit**

```bash
git add grafana/dashboards/ai-agents.json docker-compose.yml
git commit -m "feat: provision AI Agents Grafana dashboard in otel-lgtm"
```

---

### Task 5: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

````markdown
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

## Unified metrics

| Metric (Prometheus name) | Labels | Meaning |
|---|---|---|
| `ai_agent_token_usage_total` | `agent`, `model`, `type` = input / output / cache_read / cache_write / reasoning / tool | tokens |
| `ai_agent_cost_usage_total` | `agent`, `model` | USD (Claude Code, OpenCode, Pi only) |
| `ai_agent_session_count_total` | `agent` | sessions started |
| `ai_agent_lines_of_code_count_total` | `agent`, `type` = added / removed | lines changed |
| `ai_agent_tool_call_count_total` | `agent`, `tool_name` | tool invocations |

`agent` is one of `claude_code`, `gemini_cli`, `codex`, `opencode`, `pi`, `antigravity`, `unknown`. Every other metric an agent sends is passed through under its original name with the `agent` label added. `session.id`, `user.*`, `organization.id`, `terminal.type`, `prompt.id`, `installation.id`, `app.entrypoint` are removed from all metrics.

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

**Through Claude Code Router (CCR):** CCR itself sends no telemetry; Claude Code keeps sending its own. Add a marker so you can tell routed sessions apart in Grafana (`router="ccr"` label):

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

The plugin defaults to `http://127.0.0.1:4318`; override with `PI_OTEL_ENDPOINT` if the gateway runs elsewhere. Its `service.name` defaults to `pi`; keep it (or keep `gen_ai.system=pi`), the gateway uses it to attribute `gen_ai.*` metrics.

### Antigravity CLI

Antigravity has no native OTel export. Use the community hook script (see the SigNoz "Antigravity CLI monitoring" guide) with, in `~/.config/agy-otel/env`:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Only `agy.quota.*` gauges arrive as metrics; token/cost data is not available from Antigravity.

## Test

```bash
tests/run.sh          # boots the stack, posts one fixture per agent, asserts, tears down
KEEP=1 tests/run.sh   # same, but leaves the stack running so you can look at Grafana
```

## Layout

| Path | Purpose |
|---|---|
| `otel-collector-config.yaml` | gateway pipeline (OTTL transform lives here) |
| `docker-compose.yml` | gateway + otel-lgtm |
| `grafana/dashboards/ai-agents.json` | the dashboard |
| `grafana/provisioning/dashboards.yaml` | Grafana provisioning entry |
| `tests/fixtures/*.json` | sample OTLP payloads, one per agent |
| `docs/superpowers/specs/` | design spec |
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with per-agent connection settings"
```

---

## Self-review

**Spec coverage:** architecture/ports (Task 1, 4), file layout (all), source inventory encoded in fixtures (Task 2), unified schema + value/key normalisation + unit clearing (Task 3), agent detection order incl. gen_ai/pi rule and `unknown` (Task 3), Gemini duplicate drop (Task 3 filter), cardinality list (Task 3), prometheus exporter settings (Task 1), deltatocumulative (Task 3), logs/traces pass-through (Task 1), dashboard rows/panels/variables (Task 4), provisioning + home dashboard (Task 4), per-agent connection docs (Task 5), tests steps 1–7 (Task 2/4; teardown via trap, `KEEP=1`). No gaps.

**Placeholders:** none; every file is given in full.

**Consistency:** metric names in fixtures ↔ transform `where` clauses ↔ test regexes ↔ dashboard queries all use `ai_agent_token_usage_total`, `ai_agent_cost_usage_total`, `ai_agent_session_count_total`, `ai_agent_lines_of_code_count_total`, `ai_agent_tool_call_count_total`; label keys `agent`, `model`, `type`, `tool_name`, `router`; dashboard uid `ai-agents` matches the test.
