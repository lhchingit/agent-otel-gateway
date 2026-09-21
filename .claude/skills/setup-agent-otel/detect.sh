#!/usr/bin/env bash
# Detect installed AI coding agents and whether their OTel export is configured.
# Read-only. Works in bash / Git Bash (Windows), macOS and Linux.
# Output: one line per agent: name | status | version | config file | otel | user-header
set -u
have() { command -v "$1" >/dev/null 2>&1; }
ver() { "$@" 2>/dev/null | head -1 | tr -d '\r'; }
row() { printf '%-13s| %-9s| %-12s| %-45s| %-14s| %s\n' "$@"; }
grepq() { [ -f "$2" ] && grep -qE "$1" "$2" 2>/dev/null; }

echo "GATEWAY: ${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}"
echo
row agent status version config otel user-header
row ----- ------ ------- ------ ---- -----------

# Claude Code -----------------------------------------------------------------
f="$HOME/.claude/settings.json"
if have claude; then
  otel=no; usr=no
  grepq '"OTEL_EXPORTER_OTLP_ENDPOINT"' "$f" && otel=yes
  grepq '"OTEL_EXPORTER_OTLP_HEADERS": *"[^"]*x-user=' "$f" && usr=yes
  grepq '"OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": *"cumulative"' "$f" || otel="$otel(no-cumulative)"
  row claude_code installed "$(ver claude --version)" "$f" "$otel" "$usr"
else row claude_code absent - - - -; fi

# Claude Code Router (proxy; Claude Code keeps exporting) -----------------------
if have ccr; then row ccr installed "$(ver ccr -v)" "(uses Claude Code settings)" n/a n/a; else row ccr absent - - - -; fi

# Gemini CLI ------------------------------------------------------------------
f="$HOME/.gemini/settings.json"
if have gemini; then
  otel=no; usr=no
  grepq '"otlpEndpoint"' "$f" && otel=yes
  grepq '"logPrompts": *true' "$f" && otel="$otel(logPrompts=true!)"
  case "${OTEL_EXPORTER_OTLP_HEADERS:-}" in *x-user=*) usr=env;; esac
  row gemini_cli installed "$(ver gemini --version)" "$f" "$otel" "$usr"
else row gemini_cli absent - - - -; fi

# Codex CLI -------------------------------------------------------------------
f="$HOME/.codex/config.toml"
if have codex; then
  otel=no; usr=no
  grepq '^\[otel\.metrics_exporter\.otlp-http\]' "$f" && otel=yes
  grepq '^analytics_enabled *= *true' "$f" || otel="$otel(no-analytics_enabled)"
  grepq '"x-user"' "$f" && usr=yes
  row codex installed "$(ver codex --version)" "$f" "$otel" "$usr"
else row codex absent - - - -; fi

# OpenCode --------------------------------------------------------------------
f="$HOME/.config/opencode/opencode.json"
if have opencode; then
  otel=no; usr=no
  grepq 'opencode-plugin-otel' "$f" && otel=plugin-cfg
  case "${OPENCODE_OTLP_HEADERS:-}" in *x-user=*) usr=env;; esac
  v="$(ver opencode --version)"; case "$v" in *2.*|*postinstall*) v="$v(!)";; esac
  row opencode installed "$v" "$f" "$otel" "$usr"
else row opencode absent - - - -; fi

# Pi coding agent -------------------------------------------------------------
f="$HOME/.pi/agent/settings.json"
if have pi; then
  otel=no; usr=no
  grepq '"npm:pi-otel"' "$f" && otel=pi-otel
  grepq 'damngamerz/pi-otel' "$f" && otel=damngamerz
  grepq '"x-user"' "$f" && usr=yes
  row pi installed "$(ver pi --version)" "$f" "$otel" "$usr"
else row pi absent - - - -; fi

# Antigravity CLI -------------------------------------------------------------
f="$HOME/.gemini/config/hooks.json"
if have agy; then
  otel=no; usr=no
  grepq '"agy-otel"' "$f" && otel=hook
  grepq 'x-user=' "$HOME/.config/agy-otel/env" && usr=yes
  row antigravity installed "$(ver agy --version)" "$f" "$otel" "$usr"
else row antigravity absent - - - -; fi

echo
echo "LEGEND: otel=yes/plugin-cfg/hook means export is configured; parenthesised notes are problems to fix."
echo "        user-header=yes means the x-user header is in the agent's own config; env means only via a shell variable."
