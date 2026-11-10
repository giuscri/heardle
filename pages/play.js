import { useState } from "react"
import confetti from "canvas-confetti"
import { findSong, signedUrl } from "../lib/s3"

export default function Play({ title, url, thumbnail }) {
  const MAX_SCORE = 5000
  const STEP = 1500
  const [score, setScore] = useState(MAX_SCORE)
  const [durationMs, setDurationMs] = useState(2000)
  const [playing, setPlaying] = useState(false)
  const [guessed, setGuessed] = useState(false)

  function listenAgainHandler() {
    play(durationMs)
  }

  function nextHintHandler() {
    if (Math.floor(score/10) > 0) {
      setScore(Math.floor(score/10))
      setDurationMs(ms => {
        play(ms + STEP)
        return ms + STEP
      })
    } else {
      setScore(0)
      setGuessed(true)
      play(-1)
    }
  }

  function guessHandler() {
    setGuessed(true)
    if (score === MAX_SCORE) {
      confetti({ particleCount: 500, spread: 360, shapes: ['circle'], colors: ['#ffffff'] })
    }
    play(-1)
  }

  function nextSongHandler() {
    window.location.href = '/'
  }

  async function play(ms) {
    const player = document.querySelector('audio')

    setPlaying(true)
    try {
      await player.play()
    } catch (e) {
      console.error(e)
      setPlaying(false)
      return
    }

    if (ms >= 0) {
      setTimeout(() => {
        player.pause()
        player.currentTime = 0
        setPlaying(false)
      }, ms)
    }
  }

  return (
    <div className="flex flex-col items-center text-center justify-center px-2">
      <h1 className="font-bold text-4xl">Score: {score}</h1>

      <div className={`${!guessed && 'hidden'} flex flex-col items-center`}>
        <p className=''>{title.length > 30 ? title.slice(0,30)+'...' : title}</p>
        <img src={thumbnail} className="h-[70vw] min-h-[70vw] sm:h-[300px] sm:min-h-[300px] max-w-[90vw] object-cover self-center rounded-sm shadow-xl shadow-lime-50"/>
        <button onClick={nextSongHandler} className="mt-2 rounded-full px-2 py-1 border-4 border-lime-50 shadow-white shadow-lg hover:bg-lime-50 hover:text-[#0F0F19] transition duration-500 hover:scale-110">Next song!</button>
      </div>

      <div className={`${guessed && 'hidden'} flex flex-row justify-evenly w-full sm:w-4/5 text-2xl sm:text-3xl whitespace-nowrap`}>
        <button id="next-hint" onClick={nextHintHandler} disabled={playing} className={`rounded text-[0.8rem] sm:text-[1rem] ${ !playing && 'text-red-300 hover:scale-110 focus:scale-110 outline-0' } p-1 transition-all duration-500`}>Help?</button>
        <button id="listen-again" onClick={listenAgainHandler} disabled={playing} className={`rounded text-[0.8rem] sm:text-[1rem] ${ !playing && 'text-yellow-300 hover:scale-110 focus:scale-110 outline-0' } p-1 transition-all duration-500`}>Play</button>
        <button id="guess" onClick={guessHandler} disabled={playing} className={`rounded text-[0.8rem] sm:text-[1rem] ${ !playing && 'text-emerald-400 hover:scale-110 focus:scale-110 outline-0' } p-1 transition-all duration-500`}>Tell me</button>
      </div>

      <audio src={url} preload="auto" playsInline />
    </div>
  )
}

export async function getServerSideProps({ query }) {
  const song = await findSong(String(query.genre || ''), String(query.id || ''))
  if (!song) return { redirect: { destination: '/', permanent: false } }
  const [url, thumbnail] = await Promise.all([
    signedUrl(`songs/${song.id}.mp3`),
    signedUrl(`thumbs/${song.id}.jpg`),
  ])
  return { props: { title: song.title, url, thumbnail } }
}
