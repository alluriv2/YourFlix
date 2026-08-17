# source_media

Where your library lives.

```
source_media/
  images/
    NIAGARA_FALLS/            <- flat title
      IMG_0001.jpg
    NEW_YORK_CITY/            <- multi-season show
      NYC_-_FIRST_TIME/
      NYC_-_NEW_YEAR_2025/
  music/
    hero/splash_sound.mp3     <- plays once on the splash screen
    slideshow/*.mp3           <- shared pool, randomly picked per watch
  NIAGARA_FALLS.info.json     <- optional per-title override
  NIAGARA_FALLS.cover.jpg     <- optional fixed poster
```

## Naming

Folder name = display name, underscores -> spaces (`NYC_-_FIRST_TIME` ->
"NYC - FIRST TIME"). A season's folder name becomes its title-card
caption; the season TILE always just says "Season 1", "Season 2", etc.
Seasons are ordered by earliest photo/video timestamp, not
alphabetically -- name them however reads best.

## Minimum content

A flat title or a single season needs ~25 items (photos + short + long
videos) to be watchable. Below that, it still gets a tile -- marked
"Coming Soon" -- rather than vanishing. For a show: every season gets its
own tile regardless, and the show itself only collapses to Coming Soon
if literally none of its seasons qualify.

## Got a flat dump instead of folders?

No manual sorting needed. Any files sitting loose directly at the top
level of `images/` (not yet inside any folder) get automatically moved
into one folder, `Recently_Added` (-> "Recently Added" on screen), the
moment the app scans your library on launch -- everything lands
together in that same folder, not split up by date or anything else.
Want it organized differently (by trip, by person, by month)? Just make
those folders yourself and drop files in directly -- this only ever
handles files that would otherwise be invisible to the app.

This only ever touches files still sitting loose right at `images/`'s
top level -- anything already inside a folder is left alone, so it's
always safe: drop in a fresh unsorted batch any time, relaunch, and
it sorts itself. Renaming `Recently_Added` afterward is safe too.

## Posters

No separate poster folder -- liking a photo during a normal watch is what
curates a title/season's thumbnail pool (see main README). Drop a
`<Folder>.cover.<ext>` file here instead to pin one fixed image, which
always wins over liked photos.

## Music

Already populated -- `music/hero/` and `music/slideshow/` ship with real
tracks, nothing required here. Add, remove, or swap files freely;
slideshow tracks are picked at random per watch.

## That's it

Everything rescans automatically on launch (cached per-folder, so only
what changed gets rescanned). `titles.json` here is an OUTPUT only -- a
human-readable record of the last scan -- never hand-edit it, it's
overwritten every launch.
