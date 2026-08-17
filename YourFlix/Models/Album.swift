import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case photo
        case video
    }

    let id = UUID()
    let kind: Kind
    let url: URL
    let name: String
}

/// Mirrors the optional info.json a user can drop in each album folder.
struct AlbumInfo: Codable, Sendable {
    var title: String?
    var subtitle: String?
    var year: String?
    var tags: [String]?
    var blurb: String?
    var description: String?
}

/// One playable unit's (a flat title, or one season of a multi-season
/// title) pre-computed time-buckets for curated playback, built fresh by
/// MediaScanner.swift every time AlbumLoader.loadAlbums() scans
/// source_media (using cached per-file timestamps whenever a group's
/// folder hasn't changed since last time -- see MediaScanner.swift's
/// header). photoBuckets is true photo files only -- videos never land
/// here regardless of duration. shortVideoBuckets (videos <=5s, e.g. Live
/// Photos) and longVideoBuckets (videos >5s) are kept separate so each
/// can have its own pick count. See AlbumLoader.curatedPlaylist(...) for
/// how these get turned into an actual watch.
struct MediaBucketGroup: Hashable, Sendable {
    var photoBuckets: [[MediaItem]] = []
    var shortVideoBuckets: [[MediaItem]] = []
    var longVideoBuckets: [[MediaItem]] = []
}

/// A season within a multi-season title (e.g. "NYC" -> Season 1/2/3).
/// Titles with no seasons (the common case) just have an empty `seasons`
/// array on their Album and play directly, same as always.
struct Season: Identifiable, Hashable, Sendable {
    let id: String // stable, e.g. "NYC-Season 1"
    let label: String // display label, e.g. "Season 1" -- ALWAYS what season tiles show, never titleCardCaption
    var media: [MediaItem] = []
    var coverURL: URL? = nil
    var curationBuckets: MediaBucketGroup? = nil
    /// Optional custom caption for this season's title card / in-player
    /// header (e.g. "NYC - First Time"), set via titles.json's per-season
    /// "titleCard" key. When nil, playback falls back to the default
    /// "{Show} — {label}" construction -- see RootView.album(forSeason:of:).
    /// Never shown on the season-picker thumbnail; that always shows
    /// `label` alone.
    var titleCardCaption: String? = nil
    /// True when this season's own subfolder exists but doesn't (yet)
    /// have enough content to actually watch -- fewer than
    /// `MediaScanner.minimumItemsToQualify` items, same bar as a flat
    /// title (see Album.isComingSoon). Still gets its own tile in
    /// SeasonListView -- see MediaScanner.swift's header -- just tagged
    /// "Coming Soon" and not tappable into playback (RootView's
    /// onSelectSeason guards on this before ever building a playable
    /// Album out of it). `media`/`curationBuckets` may still hold
    /// whatever few files DO exist, purely so the tile can show a real
    /// photo instead of a blank gradient.
    var isComingSoon: Bool = false

    static func == (lhs: Season, rhs: Season) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Album: Identifiable, Hashable, Sendable {
    let id: String // the folder name / slug
    let title: String
    let subtitle: String?
    let year: String?
    let tags: [String]
    let blurb: String?
    let coverURL: URL?
    let songURL: URL?
    let media: [MediaItem]
    var seasons: [Season] = [] // non-empty means this title is a multi-season show
    var curationBuckets: MediaBucketGroup? = nil // only meaningful when seasons is empty (a flat title)
    /// True when this folder exists under `images/` but doesn't (yet) have
    /// enough content to actually watch -- fewer than
    /// `MediaScanner.minimumItemsToQualify` items for a flat title, or
    /// (for a show) not one season that clears that bar on its own. Still
    /// shows up as a tile -- see MediaScanner.swift's header -- just
    /// tagged "Coming Soon" and not tappable into playback (BrowseView's
    /// caller guards on this before navigating; see RootView). `media`
    /// may still hold whatever few files DO exist (purely so the tile has
    /// a real photo for its poster instead of a blank gradient).
    /// `curationBuckets` is always nil for a Coming-Soon entry, but
    /// `seasons` is NOT necessarily empty -- a show whose folder has
    /// subfolders always gets `seasons` fully populated (each one
    /// possibly Coming Soon itself), even when the show as a whole is
    /// also Coming Soon -- see MediaScanner.swift's header for why.
    var isComingSoon: Bool = false

    static func == (lhs: Album, rhs: Album) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
