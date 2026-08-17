import SwiftUI

/// Top-level screen state machine: splash -> browse, with the season list
/// and player presented as overlays on top of whichever screen is behind
/// them.
///
/// Real content: albums come from `AlbumLoader.loadAlbums()`, which scans
/// `source_media/titles.json` directly (see MediaScanner.swift's header)
/// -- no more flatten-media.sh, no more `OurFlix_media` folder. Tapping a
/// flat (no-season) album plays it directly; tapping a multi-season title
/// (NYC, Birthdays, Grad, Breaks, ...) opens the season picker, and
/// tapping a season plays just that season's media.
///
/// Playback itself is curated, not "every photo in the folder": each tap
/// on an album/season calls AlbumLoader.curatedPlaylist(...) right there
/// (not once at app launch), which uses each title/season's pre-computed
/// time-buckets to pick ~100 photos spread evenly across the whole
/// timeline plus a handful of short and long videos, interleaved so no
/// two videos ever land back-to-back. That's why watching the same title
/// twice gives two different cuts, and why the app never just replays the
/// library start-to-finish in filename order.
///
/// Because loadAlbums() can now involve a real (if usually cache-skipped)
/// scan of source_media, it runs off the main thread via
/// Task.detached(...) rather than directly in onAppear, and SplashView is
/// told to wait for it (see runScan() below) instead of just running its
/// own fixed-length animation and moving on regardless.
struct RootView: View {
    enum Screen {
        case splash
        case browse
    }

    @State private var screen: Screen = .splash
    @State private var albums: [Album] = []
    /// Which album is Featured this run -- picked once, right after
    /// `albums` loads (see runScan() below), and held fixed for the rest
    /// of the app's lifetime so it doesn't visibly change mid-browse on
    /// every SwiftUI re-render. Reshuffles on the next launch, same
    /// "random once per run" pattern AlbumLoader already uses for poster
    /// photo picks. Replaces the old "Featured" info.json tag -- any
    /// qualifying (non-Coming-Soon) title can now land here, not just one
    /// specifically marked for it.
    @State private var heroAlbumID: String?
    @State private var selectedShowForSeasons: Album?
    @State private var playingAlbum: Album?
    @State private var scanFinished = false
    @State private var scanIsSlow = false

    var body: some View {
        ZStack {
            switch screen {
            case .splash:
                SplashView(isReady: $scanFinished, showSlowHint: $scanIsSlow) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        screen = .browse
                    }
                }
            case .browse:
                BrowseView(albums: albums, heroAlbumID: heroAlbumID) { album in
                    // Coming Soon tiles (not enough content yet -- see
                    // MediaScanner.swift's header and Album.isComingSoon)
                    // are shown but not playable: tapping one is a
                    // deliberate no-op rather than opening an empty or
                    // broken player.
                    guard !album.isComingSoon else { return }
                    if album.seasons.isEmpty {
                        playingAlbum = Self.curatedForPlay(album)
                    } else {
                        selectedShowForSeasons = album
                    }
                }
                .transition(.opacity)
            }

            if let show = selectedShowForSeasons {
                SeasonListView(
                    album: show,
                    onSelectSeason: { season in
                        // Same treatment as a Coming Soon Album tile on
                        // Browse (see the guard above) -- a season that
                        // doesn't have enough content yet still gets a
                        // tile in the season list, just not a playable
                        // one.
                        guard !season.isComingSoon else { return }
                        playingAlbum = Self.album(forSeason: season, of: show)
                    },
                    onBack: {
                        selectedShowForSeasons = nil
                    }
                )
                .zIndex(5)
                .transition(.opacity)
            }

            if let playingAlbum {
                PlayerView(album: playingAlbum) {
                    self.playingAlbum = nil
                }
                .zIndex(10)
                .transition(.opacity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            runScan()
        }
    }

    /// Kicks off the media scan in the background (Task.detached hops off
    /// the main actor so a slow first-time scan never freezes the splash
    /// animation), and flips `scanIsSlow` on if it's still running a few
    /// seconds later -- see SplashView's header for why. In the normal
    /// (cache-hit, nothing changed) case, the scan finishes in well under
    /// a second and neither the hint nor any noticeable wait ever
    /// happens.
    private func runScan() {
        Task {
            let hintTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    scanIsSlow = true
                }
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                AlbumLoader.loadAlbums()
            }.value
            hintTask.cancel()
            albums = loaded
            // Fresh random Featured pick for this run -- Coming Soon
            // titles (no real content yet) are never eligible. If every
            // title happens to be Coming Soon, this is nil and BrowseView
            // just shows no hero banner at all.
            heroAlbumID = loaded.filter { !$0.isComingSoon }.randomElement()?.id
            scanFinished = true
        }
    }

    /// Wraps one season's media into a lightweight, playable Album so
    /// PlayerView (built to play a whole Album) can play just that season
    /// without needing its own separate playback type. Inherits the
    /// parent show's song/tags/blurb; uses the season's own cover if it
    /// has one, otherwise falls back to the show's. `media` is this
    /// season's freshly-curated selection for THIS watch, not its full
    /// media list -- see AlbumLoader.curatedPlaylist(...).
    private static func album(forSeason season: Season, of show: Album) -> Album {
        // Prefer the season's own custom title-card caption (titles.json's
        // per-season "titleCard") when it has one; otherwise fall back to
        // the default "{Show} — {Season label}" construction. Either way,
        // this is only ever used for playback (in-player header + title
        // card) -- the season-picker thumbnail always shows season.label
        // alone, never this.
        let resolvedTitle = season.titleCardCaption ?? "\(show.title) — \(season.label)"
        return Album(
            id: season.id,
            title: resolvedTitle,
            subtitle: show.subtitle,
            year: show.year,
            tags: show.tags,
            blurb: show.blurb,
            coverURL: season.coverURL ?? show.coverURL,
            songURL: show.songURL,
            media: AlbumLoader.curatedPlaylist(fullMedia: season.media, buckets: season.curationBuckets)
        )
    }

    /// Same idea as album(forSeason:of:), for a flat (no-season) title:
    /// returns a copy of `album` whose `media` is a fresh curated
    /// selection for this one watch, everything else unchanged.
    private static func curatedForPlay(_ album: Album) -> Album {
        Album(
            id: album.id,
            title: album.title,
            subtitle: album.subtitle,
            year: album.year,
            tags: album.tags,
            blurb: album.blurb,
            coverURL: album.coverURL,
            songURL: album.songURL,
            media: AlbumLoader.curatedPlaylist(fullMedia: album.media, buckets: album.curationBuckets),
            seasons: album.seasons,
            isComingSoon: album.isComingSoon
        )
    }
}
