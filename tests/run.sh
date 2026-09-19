#!/usr/bin/env bash
# End-to-end test for the agent OTel gateway.
# Usage: tests/run.sh          (boots the stack, runs assertions, tears down)
#        KEEP=1 tests/run.sh   (leaves the stack running afterwards)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: stop mangling container paths in docker args
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
