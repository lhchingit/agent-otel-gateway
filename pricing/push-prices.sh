#!/bin/sh
# Push pricing/prices.csv to the gateway as the gauge llm_price_per_mtok{model,type}.
# Runs forever (every INTERVAL seconds) so the series never goes stale in Prometheus;
# ONCE=1 pushes a single time and exits. Needs only sh + curl (curlimages/curl works).
#
#   PRICES_FILE  path to the CSV                     (default /pricing/prices.csv)
#   PRICES_URL   HTTP(S) URL of the CSV; when set it is fetched before every push and
#                wins over PRICES_FILE (e.g. a raw GitHub URL). If the fetch fails the
#                last successfully fetched copy is reused, then PRICES_FILE.
#   PRICES_URL_HEADERS  optional extra curl header for the fetch, e.g. "Authorization: token ..."
#   ENDPOINT     OTLP/HTTP base URL of the gateway   (default http://otel-collector:4318)
#   INTERVAL     seconds between pushes              (default 60)
#   ONCE         set to 1 to push once and exit
set -u
PRICES_FILE="${PRICES_FILE:-/pricing/prices.csv}"
PRICES_URL="${PRICES_URL:-}"
PRICES_URL_HEADERS="${PRICES_URL_HEADERS:-}"
ENDPOINT="${ENDPOINT:-http://otel-collector:4318}"
INTERVAL="${INTERVAL:-60}"
FETCHED=/tmp/prices.fetched.csv

# Decide which CSV to use for this push; prints the path.
resolve_source() {
  if [ -n "$PRICES_URL" ]; then
    if [ -n "$PRICES_URL_HEADERS" ]; then
      fetch_ok=$(curl -fsS -H "$PRICES_URL_HEADERS" -o "$FETCHED.tmp" "$PRICES_URL" && echo 1 || echo 0)
    else
      fetch_ok=$(curl -fsS -o "$FETCHED.tmp" "$PRICES_URL" && echo 1 || echo 0)
    fi
    if [ "$fetch_ok" = 1 ] && [ -s "$FETCHED.tmp" ]; then
      mv "$FETCHED.tmp" "$FETCHED"; echo "$FETCHED"; return
    fi
    echo "$(date '+%H:%M:%S') fetch of $PRICES_URL failed" >&2
    [ -s "$FETCHED" ] && { echo "$FETCHED"; return; }
  fi
  echo "$PRICES_FILE"
}

build_payload() {
  now="$(date +%s)000000000"
  points=""
  n=0
  # CSV: model,type,usd_per_mtok ; skip comments / blanks ; tolerate CRLF
  while IFS=, read -r model type price _; do
    model="$(printf '%s' "$model" | tr -d '\r ')"
    type="$(printf '%s' "$type" | tr -d '\r ')"
    price="$(printf '%s' "$price" | tr -d '\r ')"
    case "$model" in ''|'#'*) continue;; esac
    [ -n "$type" ] && [ -n "$price" ] || continue
    [ -n "$points" ] && points="$points,"
    points="$points{\"attributes\":[{\"key\":\"model\",\"value\":{\"stringValue\":\"$model\"}},{\"key\":\"type\",\"value\":{\"stringValue\":\"$type\"}}],\"timeUnixNano\":\"$now\",\"asDouble\":$price}"
    n=$((n+1))
  done < "$SRC"
  printf '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"llm-pricing"}}]},"scopeMetrics":[{"scope":{"name":"llm-pricing"},"metrics":[{"name":"llm_price_per_mtok","description":"List price in USD per million tokens, by model and token type","unit":"","gauge":{"dataPoints":[%s]}}]}]}]}' "$points"
  echo "$n" >&2
}

push() {
  SRC="$(resolve_source)"
  [ -r "$SRC" ] || { echo "$(date '+%H:%M:%S') no readable price source ($SRC)" >&2; return 1; }
  payload="$(build_payload 2>/tmp/n)"
  n="$(cat /tmp/n)"
  code="$(printf '%s' "$payload" | curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @- "$ENDPOINT/v1/metrics")"
  echo "$(date '+%H:%M:%S') pushed $n price rows from $SRC to $ENDPOINT -> HTTP $code"
}

if [ "${ONCE:-0}" = "1" ]; then push; exit 0; fi
while :; do push; sleep "$INTERVAL"; done
