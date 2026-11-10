import GenreCard from "../components/GenreCard";
import { randomSong } from '../lib/s3';

export default function Genre({ pop, metal, evergreen, cartoons, christmas, summer, italians, isChristmas }) {
    const genres = [
        {
            genreHuman: "Evergreen",
            genreId: "evergreen",
            artworkSrc: '/nina-simone.gif',
            songId: evergreen.id
        },
        {
            genreHuman: "Pop",
            genreId: "pop",
            artworkSrc: '/anastacia.gif',
            songId: pop.id
        },
        {
            genreHuman: "Metal & Rock",
            genreId: "metal",
            artworkSrc: '/megadeth.gif',
            songId: metal.id
        },
        {
            genreHuman: "Cartoons",
            genreId: "cartoons",
            artworkSrc: '/goku.gif',
            songId: cartoons.id
        },
        {
            genreHuman: "Italians",
            genreId: "italians",
            artworkSrc: '/883.gif',
            songId: italians.id
        },
    ]

    if (isChristmas) {
        genres.push({
            genreHuman: "Christmas",
            genreId: "christmas",
            artworkSrc: '/george-michael.gif',
            songId: christmas.id
        })
    } else {
        genres.push({
            genreHuman: "Festivalbar",
            genreId: "summer",
            artworkSrc: '/festivalbar.jpg',
            songId: summer.id
        })
    }

    return (
        <div className="grid grid-cols-2 sm:grid-cols-3 items-center gap-y-6 sm:gap-y-0 px-2 sm:px-0 py-4 sm:py-0">
            {genres.map((genre, index) =>
                <GenreCard
                    i={index+1}
                    key={genre.genreId}
                    genreHuman={genre.genreHuman}
                    genreId={genre.genreId}
                    artworkSrc={genre.artworkSrc}
                    songId={genre.songId}
                />
            )}
        </div>
    )
}

export async function getServerSideProps() {
    const isChristmas = !!process.env.HEARDLE_CHRISTMAS
    const genres = [ 'pop', 'metal', 'evergreen', 'cartoons', 'italians', isChristmas ? 'christmas' : 'summer' ]

    const props = {}
    await Promise.all(genres.map(async g => {
        props[g] = (await randomSong(g)) || {} // allow a genre to be empty without breaking the app
    }))
    // every genre key must be defined for the destructuring in the component
    for (const g of [ 'pop', 'metal', 'christmas', 'summer', 'cartoons', 'italians', 'evergreen' ]) props[g] ??= {}

    return { props: { ...props, isChristmas } }
}
