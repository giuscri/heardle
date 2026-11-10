#!/usr/bin/env bash
# Run ingest.sh repeatedly: whenever YouTube rate-limits us (exit 75),
# back off for an hour and resume where we left off.
cd "$(dirname "$0")"
for attempt in $(seq 1 "${MAX_ATTEMPTS:-48}"); do
  echo "=== attempt $attempt, $(date -u)"
  ./ingest.sh "$@"; rc=$?
  [[ $rc -ne 75 ]] && { echo "=== finished rc=$rc, $(date -u)"; exit $rc; }
  echo "=== rate limited, sleeping ${BACKOFF:-3600}s"; sleep "${BACKOFF:-3600}"
done
