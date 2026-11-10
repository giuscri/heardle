#!/usr/bin/env bash
# Download every song of every playlist in playlists.txt as 128kbps MP3 and
# store it in S3, then (re)write one catalog per genre.
#
# S3 layout:
#   songs/<id>.mp3      audio, 128kbps
#   thumbs/<id>.jpg     cover
#   meta/<id>.json      { id, title, artist }
#   catalog/<genre>.json  [ { id, title, artist }, ... ]  <- read by the webapp
#
# Idempotent: songs already in S3 are skipped, so re-run it whenever the
# playlists change.
#
# Needs deno (JS runtime used by yt-dlp to solve YouTube challenges).
#
# Usage: S3_BUCKET=... [YTDLP_COOKIES=cookies.txt] [JOBS=1] ./ingest.sh [genre...]
set -euo pipefail
cd "$(dirname "$0")"

: "${S3_BUCKET:?set S3_BUCKET}"
JOBS="${JOBS:-1}"   # keep it low: YouTube rate-limits aggressively
for cmd in yt-dlp ffmpeg jq aws deno; do
  command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }
done

YTDLP=(yt-dlp --no-warnings --quiet --no-progress
  --sleep-requests 1 --sleep-interval 5 --max-sleep-interval 15)
[[ -n "${YTDLP_COOKIES:-}" ]] && YTDLP+=(--cookies "$YTDLP_COOKIES")
export S3_BUCKET; export YTDLP_STR="${YTDLP[*]}"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/meta"

echo "### syncing existing metadata from s3://$S3_BUCKET/meta/"
aws s3 sync --only-show-errors "s3://$S3_BUCKET/meta/" "$work/meta/"

fetch_one() {  # $1 = video id; $2 = work dir
  local id=$1 dir=$2/dl/$1
  [[ -f "$2/meta/$id.json" || -f "$2/STOP" ]] && return 0
  mkdir -p "$dir"
  if ! $YTDLP_STR -f bestaudio -x --audio-format mp3 --audio-quality 128K \
      --write-thumbnail --convert-thumbnails jpg --write-info-json \
      -o "$dir/a.%(ext)s" -o "thumbnail:$dir/a.%(ext)s" -o "infojson:$dir/a" \
      "https://www.youtube.com/watch?v=$id" 2>"$dir/err"; then
    cat "$dir/err" >&2
    # bot check = we are being rate limited: stop hammering YouTube
    grep -q "not a bot" "$dir/err" && { echo "!!! rate limited by YouTube, stopping" >&2; touch "$2/STOP"; }
    echo "!!! failed $id" >&2; rm -rf "$dir"; return 0
  fi
  jq -c '{id: .id, title: (.track // .title), artist: (.artist // .creator // .uploader // .channel // "" | sub(" - Topic$"; ""))}' \
    "$dir/a.info.json" > "$dir/meta.json"
  aws s3 cp --only-show-errors --content-type audio/mpeg "$dir/a.mp3" "s3://$S3_BUCKET/songs/$id.mp3"
  aws s3 cp --only-show-errors --content-type image/jpeg "$dir/a.jpg" "s3://$S3_BUCKET/thumbs/$id.jpg"
  # meta last: its presence marks the song as complete
  aws s3 cp --only-show-errors --content-type application/json "$dir/meta.json" "s3://$S3_BUCKET/meta/$id.json"
  mv "$dir/meta.json" "$2/meta/$id.json"; rm -rf "$dir"
  echo "+++ $(jq -r '"\(.artist) - \(.title)"' "$2/meta/$id.json")"
}
export -f fetch_one

grep -Ev '^\s*(#|$)' playlists.txt | while read -r genre url; do
  [[ $# -gt 0 && ! " $* " =~ " $genre " ]] && continue
  echo "### $genre: listing $url"
  $YTDLP_STR --flat-playlist --print id "$url" > "$work/$genre.ids" || true
  if [[ ! -s "$work/$genre.ids" ]]; then echo "!!! $genre: empty/unreachable playlist, catalog untouched" >&2; continue; fi
  echo "### $genre: $(wc -l < "$work/$genre.ids") songs in playlist"
  [[ -f "$work/STOP" ]] && break
  xargs -a "$work/$genre.ids" -P "$JOBS" -I{} bash -c 'fetch_one "$1" "$2"' _ {} "$work"
  ( while read -r id; do [[ -f "$work/meta/$id.json" ]] && cat "$work/meta/$id.json"; done < "$work/$genre.ids" ) \
    | jq -s 'unique_by(.id)' > "$work/$genre.catalog.json"
  aws s3 cp --only-show-errors --content-type application/json --cache-control no-cache \
    "$work/$genre.catalog.json" "s3://$S3_BUCKET/catalog/$genre.json"
  [[ -f "$work/STOP" ]] && { echo "!!! stopped early; re-run later to continue" >&2; break; }
  echo "### $genre: catalog has $(jq length "$work/$genre.catalog.json") songs"
done
