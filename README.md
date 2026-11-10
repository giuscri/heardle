# MyHeardle

Guess the song from its first seconds. Everything (audio, covers, catalogs) lives in S3;
no Redis, no containers.

## S3 layout

```
songs/<id>.mp3          128kbps audio
thumbs/<id>.jpg         cover
meta/<id>.json          { id, title, artist }
catalog/<genre>.json    [{ id, title, artist }]   <- read by the webapp (cached 5 min)
```

The browser gets short-lived presigned URLs; the bucket stays private.

## Populate / update songs

Needs `yt-dlp`, `deno` (yt-dlp uses it to solve YouTube JS challenges), `ffmpeg`, `jq`, `aws`. Downloads one song at a time with random 5-15s pauses to avoid rate limits. Playlists are in `scripts/playlists.txt`.
Idempotent: re-run whenever playlists change, only new songs are downloaded.

```
S3_BUCKET=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... ./scripts/ingest.sh [genre...]
```

YouTube blocks datacenter IPs: run it from a home connection, or pass
`YTDLP_COOKIES=cookies.txt` (Netscape format).

## Run

```
npm install && npx next build
S3_BUCKET=... AWS_REGION=eu-west-1 npx next start --port 8000   # plus AWS credentials
```

Set `HEARDLE_CHRISTMAS=1` to swap Festivalbar for Christmas.
