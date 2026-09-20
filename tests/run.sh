#!/usr/bin/env bash
# End-to-end test for the agent OTel gateway.
# Usage: tests/run.sh          (boots the stack, runs assertions, tears down)
#        KEEP=1 tests/run.sh   (leaves the stack running afterwards)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: stop mangling container paths in docker args
# Isolates the test stack from a user's real `docker compose up` (which would otherwise be
# reused and then wiped by `down -v`).
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-agent-otel-gateway-test}"
cd "$(dirname "$0")/.."

GATEWAY=http://localhost:4318
HEALTH=http://localhost:13133
PROM=http://localhost:8889/metrics
GRAFANA=http://localhost:3000

FAILED=0
ABORTED=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*" >&2; FAILED=1; }
die()  { echo "ABORT - $*" >&2; ABORTED=1; exit 1; }

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    if [ "$FAILED" = "1" ] || [ "$ABORTED" = "1" ]; then
      echo "# collector logs (last 50 lines) for post-mortem" >&2
      docker compose logs --no-color --tail=50 otel-collector >&2 || true
    fi
    docker compose down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "# 1. config validation"
docker compose config -q || die "docker compose config failed"
docker compose run --rm --no-deps otel-collector validate --config=/etc/otelcol-contrib/config.yaml || die "collector config invalid"
ok "configs valid"

echo "# 2. boot stack"
docker compose up -d || die "compose up failed"
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
# wait until the last-posted agent (pi) is visible on the scrape endpoint
for _ in $(seq 1 30); do
  P="$(curl -fsS "$PROM" 2>/dev/null || true)"
  if grep -qE 'ai_agent_token_usage_total\{[^}]*agent="pi"' <<<"$P"; then break; fi
  sleep 1
done

echo "# 4. assertions on :8889/metrics"
OUT="$(curl -fsS "$PROM")" || die "cannot scrape :8889"
expect() { if grep -qE "$1" <<<"$OUT"; then ok "$2"; else fail "$2  (pattern: $1)"; fi; }
reject() { if grep -qE "$1" <<<"$OUT"; then fail "$2  (pattern: $1)"; else ok "$2"; fi; }
L='[^}]*'   # any run of labels before the one we care about (stays inside one {...} block); labels are emitted in alphabetical order, so chains must follow that order

# unified token counter per agent, with normalised type values
for a in claude_code gemini_cli codex opencode pi; do
  expect "^ai_agent_token_usage_total${L}agent=\"$a\"${L}type=\"input\"" "$a: ai_agent_token_usage_total type=input"
done
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}type=\"cache_read\"[^}]*\} 5000$" "claude_code: cacheRead -> cache_read (5000)"
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}type=\"cache_write\"[^}]*\} 800$" "claude_code: cacheCreation -> cache_write (800)"
expect "^ai_agent_token_usage_total${L}agent=\"gemini_cli\"${L}type=\"reasoning\"[^}]*\} 120$" "gemini_cli: thought -> reasoning (120)"
expect "^ai_agent_token_usage_total${L}agent=\"gemini_cli\"${L}type=\"cache_read\"[^}]*\} 3000$" "gemini_cli: cache -> cache_read (3000)"
expect "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"cache_read\"[^}]*\} 2000$" "codex: histogram sum -> counter, cached_input -> cache_read (2000)"
expect "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"reasoning\"[^}]*\} 350$" "codex: reasoning_output -> reasoning (350)"
reject "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"total\"" "codex: token_type=total dropped (would double count)"
reject "token_type=" "codex: token_type key renamed away"
expect "^ai_agent_token_usage_total${L}agent=\"codex\"${L}type=\"input\"[^}]*\} 1500$" "codex: histogram sum -> counter (1500)"
expect "^ai_agent_token_usage_total${L}agent=\"opencode\"${L}type=\"cache_write\"[^}]*\} 400$" "opencode: cacheCreation -> cache_write (400)"
expect "^ai_agent_token_usage_total${L}agent=\"pi\"${L}model=\"claude-sonnet-5\"${L}type=\"cache_write\"[^}]*\} 600$" "pi: gen_ai histogram -> counter, keys renamed (600)"

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
expect "^ai_agent_tool_call_count_total${L}agent=\"codex\"${L}tool_name=\"shell_command\"" "codex: tool -> tool_name"
expect "^ai_agent_tool_call_count_total${L}agent=\"pi\"${L}tool_name=\"bash\"" "pi: gen_ai.tool.name -> tool_name"

# pass-through metrics keep their name and gain agent
expect "^ai_agent_tool_call_count_total${L}agent=\"antigravity\"${L}tool_name=\"read_file\"" "antigravity: hook tool counter mapped (delta -> cumulative)"
expect "^agy_turn_count_total${L}agent=\"antigravity\"${L}session_id=\"conv-agy-1\"" "antigravity: pass-through turn counter tagged"
reject "^agy_tool_call_count_total" "antigravity: source tool counter renamed away"
expect "^pi_agent_prompts_total${L}agent=\"pi\"" "pi: pass-through counter tagged"

# CCR marker survives
expect "^ai_agent_token_usage_total${L}router=\"ccr\"" "claude_code via CCR: router label kept"

# unit suffixes must not leak into names
reject "^ai_agent_cost_usage_USD" "no _USD unit suffix on cost"
reject "^ai_agent_token_usage_tokens" "no _tokens unit suffix on tokens"

# session.id is kept (cumulative per-session counters must not collide); per-user keys are stripped
expect "^ai_agent_token_usage_total${L}session_id=\"sess-cc-1\"" "claude_code: session.id kept (sess-cc-1)"
expect "^ai_agent_token_usage_total${L}session_id=\"sess-cc-2\"" "claude_code: second concurrent session is a separate series"
expect "^ai_agent_token_usage_total${L}agent=\"gemini_cli\"${L}session_id=\"sess-gem-1\"" "gemini_cli: resource-level session.id promoted to label"
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}session_id=\"sess-cc-1\"${L}type=\"input\"[^}]*\} 1200$" "claude_code sess-cc-1 input = 1200 (not overwritten by sess-cc-2)"
expect "^ai_agent_token_usage_total${L}agent=\"claude_code\"${L}session_id=\"sess-cc-2\"${L}type=\"input\"[^}]*\} 100$" "claude_code sess-cc-2 input = 100"
reject "user_email=" "user.email stripped"
reject "user_account_uuid=" "user.account_uuid stripped"
reject "organization_id=" "organization.id stripped"
reject "terminal_type=" "terminal.type stripped"
reject "installation_id=" "installation.id stripped"

# gemini's duplicate semconv histogram dropped, pi's kept
reject "^gen_ai_client_token_usage[a-z_]*${L}agent=\"gemini_cli\"" "gemini_cli: gen_ai.client.token.usage dropped"
reject "^ai_agent_token_usage_total${L}agent=\"unknown\"" "no unknown-agent token series"
reject "gen_ai_token_type=" "gen_ai.token.type key renamed away"

echo "# 5. assertions via otel-lgtm (Grafana -> Prometheus proxy)"
Q="$GRAFANA/api/datasources/proxy/uid/prometheus/api/v1/query"
RES=""
for _ in $(seq 1 15); do
  RES="$(curl -fsS -G "$Q" --data-urlencode 'query=count by (agent) (ai_agent_token_usage_total)' || true)"
  grep -q '"agent":"pi"' <<<"$RES" && break
  sleep 2
done
for a in claude_code gemini_cli codex opencode pi; do
  if grep -q "\"agent\":\"$a\"" <<<"$RES"; then ok "lgtm prometheus has agent=$a"; else fail "lgtm prometheus missing agent=$a"; fi
done
NAMES="$(curl -fsS -G "$Q" --data-urlencode 'query=count by (__name__) ({__name__=~"ai_agent_.*"})' || true)"
if grep -q '"__name__":"ai_agent_cost_usage_total"' <<<"$NAMES"; then ok "lgtm: ai_agent_cost_usage_total present"; else fail "lgtm: ai_agent_cost_usage_total missing"; fi
if grep -q '"__name__":"ai_agent_token_usage_total"' <<<"$NAMES"; then ok "lgtm: ai_agent_token_usage_total present"; else fail "lgtm: ai_agent_token_usage_total missing"; fi
if grep -q '_USD' <<<"$NAMES"; then fail "lgtm: _USD unit suffix leaked"; else ok "lgtm: no _USD unit suffix"; fi
if grep -q '_tokens_' <<<"$NAMES"; then fail "lgtm: _tokens_ unit suffix leaked"; else ok "lgtm: no _tokens_ unit suffix"; fi

echo "# 6. dashboard provisioned"
SEARCH="$(curl -fsS "$GRAFANA/api/search?query=AI%20Agents" || true)"
if grep -q '"uid":"ai-agents"' <<<"$SEARCH"; then
  ok "dashboard 'AI Agents' provisioned"
else
  fail "dashboard 'AI Agents' not found"
fi
DASH="$(curl -fsS "$GRAFANA/api/dashboards/uid/ai-agents" || true)"
if grep -q '"title":"AI Agents"' <<<"$DASH"; then
  ok "dashboard loads by uid"
else
  fail "dashboard uid ai-agents not loadable"
fi

echo
if [ "$FAILED" = "0" ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
