#!/usr/bin/env bash
set -euo pipefail

BOOK_ID="${1:-1}"
REQUESTS="${2:-50}"
CONCURRENCY="${3:-20}"

# Allow overriding target ports with LOADTEST_PORTS="8081,8083,8084"
PORTS_CSV="${LOADTEST_PORTS:-8081,8083,8084}"
IFS=',' read -ra PORTS <<< "$PORTS_CSV"
PORT_COUNT=${#PORTS[@]}

if ! [[ "$BOOK_ID" =~ ^[0-9]+$ ]]; then
  echo "Book id must be a positive integer" >&2
  exit 1
fi

if ! [[ "$REQUESTS" =~ ^[0-9]+$ ]] || ((REQUESTS < 1)); then
  echo "Requests must be a positive integer" >&2
  exit 1
fi

if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || ((CONCURRENCY < 1)); then
  echo "Concurrency must be a positive integer" >&2
  exit 1
fi

if ((PORT_COUNT == 0)); then
  echo "Provide at least one port via LOADTEST_PORTS (comma-separated)" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

echo "== Load test =="
echo "BookId=$BOOK_ID Requests=$REQUESTS"
echo "Ports=$(IFS=','; echo \"${PORTS[*]}\")"
echo "Concurrency=$CONCURRENCY"
echo

start_ts=$(date +%s)
tmpdir="$(mktemp -d)"
success_file="$tmpdir/success.txt"
conflict_file="$tmpdir/conflict.txt"
other_file="$tmpdir/other.txt"

touch "$success_file" "$conflict_file" "$other_file"

run_one() {
  local i="$1"
  local port_index=$(((i - 1) % PORT_COUNT))
  local port="${PORTS[$port_index]}"
  local url="http://localhost:${port}/api/books/${BOOK_ID}/borrow"

  # -s: silent, -o: body in file, -w: status code
  local body_file="$tmpdir/body_$i.json"
  local status
  status="$(curl -s -o "$body_file" -w "%{http_code}" -X POST "$url" || true)"

  if [[ "$status" == "200" ]]; then
    echo "$port $status $(cat "$body_file")" >> "$success_file"
  elif [[ "$status" == "409" ]]; then
    echo "$port $status $(cat "$body_file")" >> "$conflict_file"
  else
    echo "$port $status $(cat "$body_file" 2>/dev/null || echo '')" >> "$other_file"
  fi
}

pids=()
for i in $(seq 1 "$REQUESTS"); do
  while ((${#pids[@]} >= CONCURRENCY)); do
    wait "${pids[0]}"
    pids=("${pids[@]:1}")
  done

  run_one "$i" &
  pids+=($!)
done

for p in "${pids[@]}"; do
  wait "$p"
done

end_ts=$(date +%s)
duration=$((end_ts - start_ts))
# Avoid division by zero; if <1s, normalize to 1 for rate computation.
norm_duration=$((duration > 0 ? duration : 1))
rate=$(awk "BEGIN {printf \"%.2f\", $REQUESTS/$norm_duration}")

echo "== Results =="
echo "Success (200):  $(wc -l < "$success_file")"
echo "Conflict (409): $(wc -l < "$conflict_file")"
echo "Other:          $(wc -l < "$other_file")"
echo "Duration:       ${duration}s (approx ${rate} req/s)"
echo
echo "Results by port:"
for port in "${PORTS[@]}"; do
  succ=$(grep -c "^$port " "$success_file")
  conf=$(grep -c "^$port " "$conflict_file")
  othr=$(grep -c "^$port " "$other_file")
  echo " - $port -> 200:$succ 409:$conf other:$othr"
done
echo
echo "Details directory: $tmpdir"
echo " - success.txt  : successful calls"
echo " - conflict.txt : stock exhausted (expected under load)"
echo " - other.txt    : errors to investigate"
