# Per-agent OTel setup reference

`ENDPOINT` = the gateway base URL (default `http://localhost:4318`). `USER` = the name the user gave.
Always back up a config file before editing it (`<file>.bak-YYYYmmddHHMM`) and merge into it — never replace it.
All agents: the config is read at process start; the user must restart running sessions afterwards.

## Claude Code (`claude`)

File: `~/.claude/settings.json`, key `env` (create the key if absent, keep other keys):

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "ENDPOINT",
  "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",
  "OTEL_EXPORTER_OTLP_HEADERS": "x-user=USER"
}
```

- `cumulative` is mandatory: Claude Code defaults to delta, and a delta exporter sends nothing while idle, so Prometheus gets one sample and every `rate`/`increase` panel stays empty.
- `OTEL_EXPORTER_OTLP_HEADERS` is `k=v,k2=v2`; if the user already has a value (e.g. an Authorization header) append `,x-user=USER`.
- Leave `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_ASSISTANT_RESPONSES` unset (prompt content stays local).
- Nothing to install.

## Claude Code Router (`ccr`)

Proxy only — it emits no telemetry; Claude Code through it keeps exporting. Optional marker so routed sessions are distinguishable: add `"OTEL_RESOURCE_ATTRIBUTES": "router=ccr"` to the same `env` block. Nothing to install.

## Gemini CLI (`gemini`)

File: `~/.gemini/settings.json`, key `telemetry`:

```json
"telemetry": {
  "enabled": true,
  "target": "local",
  "otlpEndpoint": "ENDPOINT",
  "otlpProtocol": "http",
  "logPrompts": false
}
```

- `logPrompts` defaults to **true** (ships prompt text) — always set false.
- No `headers` key exists; the bundled OTel JS exporters read the standard env var. Set it persistently for the user (Windows: `setx OTEL_EXPORTER_OTLP_HEADERS "x-user=USER"`; macOS/Linux: `export OTEL_EXPORTER_OTLP_HEADERS=x-user=USER` in the shell profile). Verified: the header arrives as `user=USER`.
- Nothing to install. Note: Gemini CLI for individual Google accounts has been retired in favour of Antigravity (`IneligibleTierError`); configure it anyway if present, it is harmless.

## Codex CLI (`codex`)

File: `~/.codex/config.toml`. `analytics_enabled` must be **top-level** — insert it at the very top of the file, above any `[table]`, otherwise it lands inside the last table and metrics stay silently disabled. Append the tables at the end:

```toml
analytics_enabled = true

[otel]
environment = "dev"

[otel.metrics_exporter.otlp-http]
endpoint = "ENDPOINT/v1/metrics"
protocol = "binary"
headers = { "x-user" = "USER" }

[otel.exporter.otlp-http]
endpoint = "ENDPOINT/v1/logs"
protocol = "binary"
headers = { "x-user" = "USER" }

[otel.trace_exporter.otlp-http]
endpoint = "ENDPOINT/v1/traces"
protocol = "binary"
headers = { "x-user" = "USER" }
```

- Endpoints need the full `/v1/<signal>` path. Validate the result parses (`python -c "import tomllib;tomllib.load(open(p,'rb'))"`).
- Codex does **not** tag users itself; without the header its metrics are `user="unknown"`.
- Nothing to install. `codex exec` exports once at exit; the gateway/dashboard handle one-shot runs.

## OpenCode (`opencode`)

File: `~/.config/opencode/opencode.json` (create if absent):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    ["@devtheops/opencode-plugin-otel", {
      "enabled": true,
      "endpoint": "ENDPOINT",
      "protocol": "http/protobuf"
    }]
  ]
}
```

- OpenCode installs the npm plugin itself on next start; nothing to `npm install`.
- The plugin has no `headers` option; set `OPENCODE_OTLP_HEADERS=x-user=USER` persistently (`setx` / shell profile) like Gemini.
- **Version check**: the plugin (1.x) targets OpenCode 1.x (`opencode-ai`). OpenCode 2.0 (`@opencode/cli`, Sept 2026) rejects it — the log at `~/.local/share/opencode/log/` shows `failed to load plugin ... Plugin must export a default definition`. Report this to the user instead of pretending it works; the workaround is running `opencode-ai@1.x` from an isolated folder with its own `XDG_*_HOME` (see the repo README).
- If `opencode --version` says its postinstall script was not run: npm 12 blocks install scripts; run `node <global node_modules>/@opencode/cli/postinstall.mjs` once.

## Pi coding agent (`pi`)

File: `~/.pi/agent/settings.json`. Check `packages`:

- Contains `"npm:pi-otel"` → configure key `otel`:
  ```json
  "otel": {
    "enabled": true,
    "endpoint": "ENDPOINT",
    "protocol": "http/protobuf",
    "headers": { "x-user": "USER" },
    "serviceName": "pi",
    "captureContent": "metadata_only",
    "signals": { "traces": true, "metrics": true, "logs": true }
  }
  ```
  (keep any other keys already present in `otel`). No cost metric with this package.
- Contains `"npm:@damngamerz/pi-otel"` → it reads `PI_OTEL_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS=x-user=USER` from the environment (set persistently) and also reports cost.
- Neither → install: `pi install npm:pi-otel`, then configure as above.
- `serviceName` must stay `pi`: the gateway attributes the semconv `gen_ai.*` metrics to Pi by it.

## Antigravity CLI (`agy`)

No native export; the gateway repo ships a hook (`hooks/antigravity/`). Install (Python 3.11+):

1. venv: `python -m venv ~/.local/opt/agy-otel` (`py -3 -m venv` on Windows) and `<venv>/bin/pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-http` (`<venv>\Scripts\pip.exe` on Windows).
2. Copy `hooks/antigravity/hook.py` and, on Windows, `hooks/antigravity/agy-otel-hook.cmd` into `~/.local/opt/agy-otel/`.
3. `~/.config/agy-otel/env`:
   ```
   OTEL_EXPORTER_OTLP_ENDPOINT=ENDPOINT
   OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
   OTEL_EXPORTER_OTLP_HEADERS=x-user=USER
   ```
4. Merge an `agy-otel` block into `~/.gemini/config/hooks.json` (keep existing named blocks). Windows commands must be the **unquoted** `.cmd` wrapper path — `C:\Users\<u>\.local\opt\agy-otel\agy-otel-hook.cmd PostToolUse` — because agy runs hooks through `cmd.exe`, which mangles a command line that starts with a quoted path. macOS/Linux: `~/.local/opt/agy-otel/bin/python ~/.local/opt/agy-otel/hook.py PostToolUse`. Events: `PostToolUse` (with `"matcher": "*"` wrapper), `PostInvocation`, `Stop`; `"timeout": 10`. Template: `hooks/antigravity/hooks.json`.
5. Smoke test without spending tokens: `echo '{"conversationId":"t","toolName":"read_file"}' | <hook command> PostToolUse` must print `{}` and, within ~10 s, `ai_agent_tool_call_count_total{agent="antigravity",...}` appears on the gateway.

Do not use the upstream SigNoz hook as-is: it uses `os.fork()` (absent on Windows → silently emits nothing) and samples quota with `agy -p /usage`, which on agy 1.2.7 starts a real agent turn. Antigravity exposes tool calls, invocations and turns only — no tokens or cost.

## Verification (all agents)

1. Gateway reachable: `curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"resourceMetrics":[]}' ENDPOINT/v1/metrics` → `200`.
2. After the user (or a consented smoke prompt) runs each agent once: `curl -s <gateway host>:8889/metrics | grep 'agent="<name>"' | grep -oE '[{,]user="[^"]*"' | sort -u` → shows `,user="USER"` (anchor on `{` or `,`: Gemini has a `cpu_usage_user` label that a bare `user=` grep matches).
3. Grafana: the agent appears in the Agent dropdown and the user in the User dropdown within a minute.
