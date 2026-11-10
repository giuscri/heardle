export default function GenreCard({ i, genreHuman, genreId, artworkSrc, songId }) {
    return (
        <a href={songId ? `/play?genre=${encodeURIComponent(genreId)}&id=${encodeURIComponent(songId)}` : undefined}>
            <div className="text-center text-sm">
                <p className="text-lime-50" style={{textShadow: 'yellow 1px 0 10px'}}>{genreHuman}</p>
                <div className="relative flex justify-center items-center transition-all duration-500 delay-75 hover:shadow-lime-50 hover:scale-110 focus:scale-110">
                    <p className="absolute text-4xl font-bold text-white z-10">{i}</p>
                    <img src={artworkSrc} className="h-[38vw] sm:h-[250px] max-w-[45vw] sm:max-w-none object-cover rounded-sm shadow-xl" />
                </div>
            </div>
        </a>
    )
}
