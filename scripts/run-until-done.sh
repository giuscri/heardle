#!/usr/bin/env bash
# Run ingest.sh until everything is downloaded:
#  - exit 75 (YouTube throttling): back off 1h, 2h, 4h, ... capped at 8h
#  - exit 69 (proxy/exit node offline): check again every 10 min, no backoff growth
cd "$(dirname "$0")"
attempt=0
while (( attempt < ${MAX_ATTEMPTS:-48} )); do
  echo "=== run (throttle attempt $((attempt + 1))), $(date -u)"
  ./ingest.sh "$@"; rc=$?
  case $rc in
    75) attempt=$((attempt + 1))
        backoff=$(( 3600 * 2 ** (attempt - 1) )); (( backoff > 28800 )) && backoff=28800
        echo "=== rate limited, sleeping ${backoff}s"; sleep "$backoff" ;;
    69) echo "=== proxy offline, retrying in 10 min"; sleep 600 ;;
    *)  echo "=== finished rc=$rc, $(date -u)"; exit $rc ;;
  esac
done
echo "=== giving up after $attempt throttled runs, $(date -u)"; exit 75
