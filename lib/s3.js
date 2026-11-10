import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'

const BUCKET = process.env.S3_BUCKET
const REGION = process.env.AWS_REGION || 'eu-west-1'
const CACHE_MS = 5 * 60 * 1000
const URL_TTL_S = 6 * 60 * 60

const s3 = new S3Client({ region: REGION })
const cache = new Map() // genre -> { at, songs }

// catalog/<genre>.json: [{ id, title, artist }], written by scripts/ingest.sh
export async function getCatalog(genre) {
  const hit = cache.get(genre)
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.songs
  let songs = []
  try {
    const res = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `catalog/${genre}.json` }))
    songs = JSON.parse(await res.Body.transformToString())
  } catch (e) {
    if (e.name !== 'NoSuchKey') console.error(`catalog ${genre}:`, e.message)
    if (hit) return hit.songs // keep serving stale data on transient errors
  }
  cache.set(genre, { at: Date.now(), songs })
  return songs
}

export async function randomSong(genre) {
  const songs = await getCatalog(genre)
  return songs.length ? songs[Math.floor(Math.random() * songs.length)] : null
}

export async function findSong(genre, id) {
  return (await getCatalog(genre)).find(s => s.id === id) || null
}

export function signedUrl(key) {
  return getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: URL_TTL_S })
}
