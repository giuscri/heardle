#!/usr/bin/env bash
# Download every song of every playlist in playlists.txt as 128kbps MP3 and
# store it in S3, keeping one catalog per genre up to date.
#
# S3 layout:
#   songs/<id>.mp3        audio, 128kbps CBR
#   thumbs/<id>.jpg       cover
#   meta/<id>.json        { id, title, artist }
#   catalog/<genre>.json  [ { id, title, artist }, ... ]  <- read by the webapp
#   failed/<id>           last failure reason; skipped for RETRY_FAILED_DAYS
#
# Idempotent: songs already in S3 are skipped, so re-run it whenever the
# playlists change. Catalogs are rewritten after every song, so the site
# fills up while this runs.
#
# Gentle with YouTube: one song at a time, SLEEP_MIN-SLEEP_MAX seconds apart (default 30-90). It stops and exits 75
# (run-until-done.sh retries later) on a bot check, or after SOFT_FAIL_LIMIT
# consecutive other errors (e.g. age checks), which YouTube also uses when throttling.
# "Video unavailable" is per-video (label/region blocks): skipped, not a throttle signal.
#
# Exits 69 when the proxy (exit node) is unreachable: nothing is wrong with
# YouTube, just wait for it to come back.
#
# Needs deno (JS runtime used by yt-dlp to solve YouTube challenges).
#
# Usage: S3_BUCKET=... [YTDLP_PROXY=socks5://host:port] [YTDLP_COOKIES=cookies.txt] [JOBS=2] ./ingest.sh [genre...]
set -euo pipefail
cd "$(dirname "$0")"

: "${S3_BUCKET:?set S3_BUCKET}"
JOBS="${JOBS:-2}"   # keep it low: YouTube rate-limits aggressively
export SOFT_FAIL_LIMIT="${SOFT_FAIL_LIMIT:-3}"
RETRY_FAILED_DAYS="${RETRY_FAILED_DAYS:-7}"
for cmd in yt-dlp ffmpeg jq aws deno; do
  command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }
done

YTDLP=(yt-dlp --no-warnings --quiet --no-progress
  --sleep-requests "${SLEEP_REQUESTS:-2}" --sleep-interval "${SLEEP_MIN:-30}" --max-sleep-interval "${SLEEP_MAX:-90}")
[[ -n "${YTDLP_COOKIES:-}" ]] && YTDLP+=(--cookies "$YTDLP_COOKIES")
# e.g. socks5://localhost:1055 = Tailscale exit node (residential IP). No fallback:
# if the proxy is down, downloads fail and the run stops.
[[ -n "${YTDLP_PROXY:-}" ]] && YTDLP+=(--proxy "$YTDLP_PROXY")
export S3_BUCKET; export YTDLP_STR="${YTDLP[*]}"

proxy_ok() {
  [[ -z "${YTDLP_PROXY:-}" ]] && return 0
  [[ "$(curl -s --max-time 20 -x "${YTDLP_PROXY/socks5:/socks5h:}" -o /dev/null -w '%{http_code}' https://www.youtube.com/generate_204)" == 204 ]]
}
export -f proxy_ok
if ! proxy_ok; then echo "!!! proxy $YTDLP_PROXY unreachable (exit node offline?)" >&2; exit 69; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/meta" "$work/failed"; echo 0 > "$work/softfails"; : > "$work/streak"

echo "### syncing existing metadata from s3://$S3_BUCKET/meta/"
aws s3 sync --only-show-errors "s3://$S3_BUCKET/meta/" "$work/meta/"
aws s3 sync --only-show-errors "s3://$S3_BUCKET/failed/" "$work/failed/"
# failures older than RETRY_FAILED_DAYS get another chance
find "$work/failed" -type f -mtime +"$RETRY_FAILED_DAYS" -delete
echo "### $(ls "$work/meta" | wc -l) songs done, $(ls "$work/failed" | wc -l) recently failed (skipped)"

write_catalog() {  # $1 = genre; $2 = work dir. Lists only songs fully in S3 (meta present).
  # serialized: with JOBS>1 several downloads finish concurrently
  (
    flock 9
    while read -r id; do
      if [[ -f "$2/meta/$id.json" ]]; then cat "$2/meta/$id.json"; fi
    done < "$2/$1.ids" | jq -s 'unique_by(.id)' > "$2/$1.catalog.json"
    aws s3 cp --only-show-errors --content-type application/json --cache-control no-cache \
      "$2/$1.catalog.json" "s3://$S3_BUCKET/catalog/$1.json"
  ) 9>"$2/catalog.lock"
}
export -f write_catalog

unblame_streak() {  # failures right before a throttling stop were probably throttling too
  while read -r f; do rm -f "$1/failed/$f"; aws s3 rm --only-show-errors "s3://$S3_BUCKET/failed/$f"; done < "$1/streak"
}
export -f unblame_streak

fetch_one() {  # $1 = video id; $2 = work dir; $GENRE = genre being processed
  local id=$1 dir=$2/dl/$1
  [[ -f "$2/meta/$id.json" || -f "$2/failed/$id" || -f "$2/STOP" ]] && return 0
  mkdir -p "$dir"
  if ! $YTDLP_STR -f bestaudio -x --audio-format mp3 --audio-quality 128K \
      --write-thumbnail --convert-thumbnails jpg --write-info-json \
      -o "$dir/a.%(ext)s" -o "thumbnail:$dir/a.%(ext)s" -o "infojson:$dir/a" \
      "https://www.youtube.com/watch?v=$id" 2>"$dir/err"; then
    cat "$dir/err" >&2
    echo "!!! failed $id" >&2
    if grep -qE "SOCKS|ProxyError|Unable to download API page|timed out" "$dir/err" && ! proxy_ok; then
      # our network/exit node is down: not the song's fault, not throttling
      echo "!!! proxy unreachable, stopping" >&2; touch "$2/OFFLINE" "$2/STOP"
      unblame_streak "$2"
    elif grep -q "not a bot" "$dir/err"; then
      # bot check = we are being rate limited: stop hammering YouTube (song is retried next run)
      echo "!!! rate limited by YouTube, stopping" >&2; touch "$2/STOP"
      unblame_streak "$2"
    elif grep -q "Video unavailable" "$dir/err"; then
      # blocked/removed for this video only; consistent across IPs, not a throttling signal
      grep -m1 ERROR "$dir/err" | cut -c1-200 > "$2/failed/$id"
      aws s3 cp --only-show-errors "$2/failed/$id" "s3://$S3_BUCKET/failed/$id"
    else
      local n=$(( $(cat "$2/softfails") + 1 )); echo "$n" > "$2/softfails"; touch "$2/streak"
      if (( n >= SOFT_FAIL_LIMIT )); then
        # several failures in a row smells like throttling: stop, don't blame the songs
        echo "!!! $n failures in a row, probably throttled, stopping" >&2; touch "$2/STOP"
        unblame_streak "$2"
      else
        grep -m1 ERROR "$dir/err" | cut -c1-200 > "$2/failed/$id"
        aws s3 cp --only-show-errors "$2/failed/$id" "s3://$S3_BUCKET/failed/$id"
        echo "$id" >> "$2/streak"
      fi
    fi
    rm -rf "$dir"; return 0
  fi
  jq -c '{id: .id, title: (.track // .title), artist: (.artist // .creator // .uploader // .channel // "" | sub(" - Topic$"; ""))}' \
    "$dir/a.info.json" > "$dir/meta.json"
  aws s3 cp --only-show-errors --content-type audio/mpeg "$dir/a.mp3" "s3://$S3_BUCKET/songs/$id.mp3"
  aws s3 cp --only-show-errors --content-type image/jpeg "$dir/a.jpg" "s3://$S3_BUCKET/thumbs/$id.jpg"
  # meta last: its presence marks the song as complete
  aws s3 cp --only-show-errors --content-type application/json "$dir/meta.json" "s3://$S3_BUCKET/meta/$id.json"
  mv "$dir/meta.json" "$2/meta/$id.json"; rm -rf "$dir"; echo 0 > "$2/softfails"; : > "$2/streak"
  echo "+++ $(jq -r '"\(.artist) - \(.title)"' "$2/meta/$id.json")"
  write_catalog "$GENRE" "$2"
}
export -f fetch_one

grep -Ev '^\s*(#|$)' playlists.txt | while read -r genre url; do
  [[ $# -gt 0 && ! " $* " =~ " $genre " ]] && continue
  echo "### $genre: listing $url"
  $YTDLP_STR --flat-playlist --print id "$url" > "$work/$genre.ids" || true
  if [[ ! -s "$work/$genre.ids" ]]; then
    if ! proxy_ok; then echo "!!! proxy unreachable while listing $genre, stopping" >&2; exit 69; fi
    echo "!!! $genre: empty/unreachable playlist, catalog untouched" >&2; touch "$work/INCOMPLETE"; continue
  fi
  echo "### $genre: $(wc -l < "$work/$genre.ids") songs in playlist"
  GENRE=$genre xargs -a "$work/$genre.ids" -P "$JOBS" -I{} bash -c 'fetch_one "$1" "$2"' _ {} "$work"
  write_catalog "$genre" "$work"
  echo "### $genre: catalog has $(jq length "$work/$genre.catalog.json") songs"
  if [[ -f "$work/OFFLINE" ]]; then echo "!!! stopped: proxy offline" >&2; exit 69; fi
  if [[ -f "$work/STOP" ]]; then echo "!!! stopped early; re-run later to continue" >&2; exit 75; fi
done
# a playlist that couldn't be listed (while the network was fine) = not done
if [[ -f "$work/INCOMPLETE" ]]; then exit 75; fi
