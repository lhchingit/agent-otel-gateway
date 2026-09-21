---
name: setup-agent-otel
description: Use when a developer wants the AI coding agents on their machine (Claude Code, Claude Code Router, Gemini CLI, Codex CLI, OpenCode, Pi, Antigravity CLI) to export OpenTelemetry usage metrics to the agent-otel-gateway or any OTLP collector, asks to "設定 otel", "把 agent 接到 grafana", "enable telemetry for my agents", or wants per-user attribution on the shared dashboard.
---

# Setup agent OTel

## Overview

Every supported agent can send OTLP to one gateway; the gateway normalises the metrics and tags them with a `user` label taken from the `x-user` request header. This skill makes one machine emit correctly: detect agents → install what is missing → write each config idempotently → verify on the gateway. The per-agent facts live in `agents.md` (same directory) — read it, do not work from memory: several agents have non-obvious requirements that silently break export.

## Procedure

1. **Ask exactly one question up front**, with AskUserQuestion: the user name to report as (`x-user`), and — in the same call — whether the gateway is `http://localhost:4318` or another URL, and whether a one-line smoke prompt per agent (a few thousand tokens each) may be run for verification. Do not ask anything else; every other decision has a default in `agents.md`.
2. **Detect**: `bash <skill dir>/detect.sh` (`echo $OTEL_EXPORTER_OTLP_ENDPOINT` first if the gateway is remote). Present the table.
3. **For each installed agent**, follow its section in `agents.md`: back up the config (`.bak-YYYYmmddHHMM`), merge the required keys, install missing pieces (Pi extension, Antigravity hook), keep existing unrelated keys.
4. **Verify** per `agents.md` → Verification: gateway reachable; run the consented smoke prompts (or ask the user to run each agent once); confirm `user="<name>"` on the gateway's `:8889/metrics` for each agent.
5. **Report** a table: agent, what changed, verified yes/no, and remind the user to restart running agent sessions (configs are read at start).

## Quick reference

| Agent | Config | Identity | Install |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` `env` | `OTEL_EXPORTER_OTLP_HEADERS=x-user=…` | none |
| CCR | same as Claude Code | optional `OTEL_RESOURCE_ATTRIBUTES=router=ccr` | none |
| Gemini CLI | `~/.gemini/settings.json` `telemetry` | env `OTEL_EXPORTER_OTLP_HEADERS` (setx / profile) | none |
| Codex | `~/.codex/config.toml` `[otel.*]` + top-level `analytics_enabled` | `headers = { "x-user" = … }` per exporter table | none |
| OpenCode | `~/.config/opencode/opencode.json` `plugin` | env `OPENCODE_OTLP_HEADERS` | plugin auto-installs; **2.0 incompatible** |
| Pi | `~/.pi/agent/settings.json` `otel` | `otel.headers` | `pi install npm:pi-otel` if missing |
| Antigravity | `~/.gemini/config/hooks.json` + `~/.config/agy-otel/env` | env file header | venv + `hooks/antigravity/` from the gateway repo |

## Common mistakes (seen in practice)

| Mistake | Reality |
|---|---|
| "Antigravity has no OTel, skip it" | The repo's hook exports tool calls / invocations / turns. Install it. |
| "Codex tags users from its account" | It does not; without `headers` its metrics are `user="unknown"`. |
| Appending `analytics_enabled = true` to `config.toml` | It lands inside the last `[table]`; Codex metrics stay disabled. Put it at the top. |
| Guessing a `headers` option for OpenCode / Gemini | Neither has one; use the environment variable, set persistently. |
| "Plugin is in the config, so it works" | OpenCode 2.0 rejects the 1.x plugin; check the plugin-load line in the log. |
| Leaving Claude Code on default temporality | Delta + idle session = one sample = empty dashboards. Set `cumulative`. |
| Leaving Gemini `logPrompts` at default | Default is `true` and ships prompt text. Set `false`. |
| Quoting the python path in Antigravity's hook command on Windows | `cmd.exe` mangles it; use the `.cmd` wrapper unquoted. |
| Asking the user many setup questions | Everything except the name / endpoint / smoke consent has a default. |
| Declaring done without a gateway check | Verification is a `curl` on `:8889/metrics` showing the agent **and** the user label. |

## Red flags — stop and re-read `agents.md`

- You are about to write a config key you have not seen in `agents.md`.
- You are about to report success for an agent whose series never appeared on the gateway.
- You are about to run a smoke prompt the user did not consent to.
