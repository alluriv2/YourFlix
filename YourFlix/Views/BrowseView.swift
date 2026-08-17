import SwiftUI

/// The landing screen: one large hero/featured panel up top, then exactly
/// two rows below it, each laid out as a grid that wraps to fit the
/// window width — the page scrolls vertically only, no horizontal
/// scrolling. Rows are split by title TYPE, not by tag: standalone titles
/// (Album.seasons empty -- a single flat folder like Albany or Niagara)
/// get the classic landscape poster in the "Titles" row first, and
/// multi-season shows (Album.seasons non-empty -- e.g. NYC's three
/// seasons) get a taller, more "box set" portrait poster in the "Shows"
/// row below that. (This replaces an earlier tag-driven row scheme --
/// "Destinations"/"Celebrations"/etc via info.json "tags" -- that never
/// actually got used once real content was in place.) Whichever album is
/// chosen as the hero is excluded from both rows below it, so it only
/// ever shows up once per run -- as the hero banner, never a second time
/// as a duplicate tile further down the page.
///
/// The hero itself is picked by RootView (see `heroAlbumID`), not here --
/// a fresh random title, any qualifying (non-Coming-Soon) one, chosen
/// once each time the app launches and held fixed for that whole run.
/// BrowseView's only job is to look that id up in `albums` and, if it's
/// somehow gone missing (e.g. content changed between scans), fall back
/// to showing no hero banner at all rather than guessing a different one
/// -- see RootView.runScan() for where the actual pick happens.
struct BrowseView: View {
    let albums: [Album]
    let heroAlbumID: String?
    let onSelect: (Album) -> Void

    private var heroAlbum: Album? {
        guard let heroAlbumID else { return nil }
        return albums.first(where: { $0.id == heroAlbumID })
    }

    private var titleAlbums: [Album] {
        albums.filter { $0.seasons.isEmpty && $0.id != heroAlbum?.id }
    }

    private var showAlbums: [Album] {
        albums.filter { !$0.seasons.isEmpty && $0.id != heroAlbum?.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            logoHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = heroAlbum {
                        HeroView(album: hero) { onSelect(hero) }
                    }

                    if albums.isEmpty {
                        emptyState
                    } else {
                        if !titleAlbums.isEmpty {
                            rowView(
                                rowTitle: "Titles",
                                albums: titleAlbums,
                                posterAspectRatio: 16 / 9,
                                columnMin: 220, columnMax: 300
                            )
                        }
                        if !showAlbums.isEmpty {
                            rowView(
                                rowTitle: "Shows",
                                albums: showAlbums,
                                posterAspectRatio: 2 / 3,
                                columnMin: 160, columnMax: 210
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    /// The "YourFlix" wordmark, top-left, always visible (outside the
    /// ScrollView so it never scrolls away) -- same font/color as the
    /// splash screen's animated logo (see SplashView), just small and
    /// static here, the way Netflix's own logo sits fixed in its browse
    /// screen's top-left corner. The "Y" and "F" print a little larger
    /// than the rest, same small emphasis SplashView's wordmark and the
    /// app icon's "YF" monogram both use, just scaled down to this
    /// header's size (30pt base / 37pt emphasized vs. the hero's 80/100).
    ///
    /// Top padding is deliberately generous (40, not the usual small
    /// header inset): the app's window uses `.windowStyle(.hiddenTitleBar)`
    /// (see YourFlixApp.swift), which leaves the traffic-light window
    /// buttons floating directly over the content's top-left corner with
    /// no titlebar bar pushing them out of the way -- a logo positioned
    /// where a normal top-left header would go sits almost exactly where
    /// those buttons are, and gets covered by them. Clearing that
    /// vertically is enough; once below the buttons' small ~28pt-tall
    /// footprint, horizontal position no longer matters.
    private let logoWord = Array("YourFlix")
    private let logoBaseLetterSize: CGFloat = 30
    private let logoEmphasizedLetterSize: CGFloat = 37
    /// Indices into `logoWord` for "Y" (0) and "F" (4) in "YourFlix" --
    /// mirrors SplashView's `emphasizedLetterIndices`.
    private let logoEmphasizedLetterIndices: Set<Int> = [0, 4]

    private var logoHeader: some View {
        HStack {
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                ForEach(Array(logoWord.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(
                            .custom(
                                "BebasNeueBold",
                                size: logoEmphasizedLetterIndices.contains(index)
                                    ? logoEmphasizedLetterSize : logoBaseLetterSize
                            )
                        )
                        .tracking(1.2)
                        .foregroundColor(Theme.red)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 14)
    }

    private func rowView(
        rowTitle: String,
        albums: [Album],
        posterAspectRatio: CGFloat,
        columnMin: CGFloat,
        columnMax: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rowTitle)
                .font(.largeTitle.bold())
                .foregroundColor(.white)
                .padding(.leading, 40)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: columnMin, maximum: columnMax), spacing: 22)],
                spacing: 22
            ) {
                ForEach(albums) { album in
                    AlbumTile(album: album, aspectRatio: posterAspectRatio) { onSelect(album) }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12) // breathing room so the hover scale-up isn't clipped
        }
        // Symmetric top/bottom (was 28/20) so the gap above a row and the
        // gap below it match -- keeps Hero-to-Titles, Titles-to-Shows, and
        // Shows-to-bottom all the same distance instead of the bottom gap
        // reading tighter than the top one.
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No shows yet")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Make sure the source_media folder is fully\ndownloaded and sitting right next to the app,\nthen quit and reopen the app.")
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}
