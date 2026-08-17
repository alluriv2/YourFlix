import Foundation

/// TEMPORARY stand-in for AlbumLoader, used only to preview the
/// browse -> season list -> "coming soon" navigation flow before the real
/// season-aware content pipeline (flatten-media.sh + AlbumLoader parsing)
/// is built. Mirrors source_media/titles.json exactly. No real photos are
/// referenced, so AlbumTile/HeroView fall back to their built-in
/// gradient+title look automatically.
///
/// Swap RootView back to AlbumLoader.loadAlbums() once the real pipeline
/// ships real season-tagged media -- see RootView.swift's onAppear.
enum MockData {
    static func albums() -> [Album] {
        func flat(_ title: String) -> Album {
            Album(id: title, title: title, subtitle: nil, year: nil, tags: [], blurb: nil, coverURL: nil, songURL: nil, media: [])
        }
        func seasoned(_ title: String, _ seasonLabels: [String]) -> Album {
            let seasons = seasonLabels.map { Season(id: "\(title)-\($0)", label: $0) }
            return Album(id: title, title: title, subtitle: nil, year: nil, tags: [], blurb: nil, coverURL: nil, songURL: nil, media: [], seasons: seasons)
        }

        return [
            flat("Albany"),
            flat("Atlantic City"),
            flat("Letchworth"),
            flat("Niagara"),
            flat("Philly"),
            seasoned("Valentine's Day", ["Season 1"]),
            seasoned("NYC", ["Season 1", "Season 2", "Season 3"]),
            seasoned("Birthdays", ["Season 1", "Season 2", "Season 3"]),
            seasoned("Grad", ["Season 1", "Season 2"]),
            seasoned("Breaks", ["Season 1", "Season 2", "Season 3", "Season 4"]),
        ]
    }
}
