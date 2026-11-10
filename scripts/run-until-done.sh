#!/usr/bin/env bash
# Run ingest.sh repeatedly: whenever YouTube rate-limits us (exit 75),
# back off (1h, 2h, 4h, ... capped at 8h) and resume where we left off.
cd "$(dirname "$0")"
for attempt in $(seq 1 "${MAX_ATTEMPTS:-48}"); do
  echo "=== attempt $attempt, $(date -u)"
  ./ingest.sh "$@"; rc=$?
  [[ $rc -ne 75 ]] && { echo "=== finished rc=$rc, $(date -u)"; exit $rc; }
  backoff=$(( 3600 * 2 ** (attempt - 1) )); (( backoff > 28800 )) && backoff=28800
  echo "=== rate limited, sleeping ${backoff}s"; sleep "$backoff"
done
