import SwiftUI

/// Browse-grid poster tile: a photo from the album (via
/// AlbumLoader.tileThumbnail(for:) -- a properly downsampled, correctly
/// oriented ImageIO thumbnail, not a naive full-res decode) with the
/// title overlaid on a bottom-up gradient for legibility, falling back to
/// a plain gradient + title if the album has no usable media at all.
/// Which exact photo gets used is AlbumLoader's call: an explicit
/// `<title>.cover.<ext>` if one exists, otherwise a random photo from the
/// album chosen once per app launch (stays fixed all session, reshuffles
/// next launch) -- see AlbumLoader.pickPosterSource(for:).
///
/// A Coming Soon album (Album.isComingSoon -- a folder that exists but
/// doesn't have enough content to actually watch yet, see
/// MediaScanner.swift's header) still renders here like any other tile,
/// just dimmed with a small red "COMING SOON" pill near the bottom. The
/// tile stays tappable (no `.disabled`, so hover/click still feel alive),
/// but the actual tap is a no-op -- see RootView's onSelect closure,
/// which checks `isComingSoon` before ever opening the player.
struct AlbumTile: View {
    let album: Album
    /// Landscape (16/9) for standalone titles, portrait (2/3) for
    /// multi-season shows -- set per-row by BrowseView. Defaults to the
    /// original landscape ratio so any other call site keeps working
    /// unchanged.
    var aspectRatio: CGFloat = 16 / 9
    let onTap: () -> Void

    @State private var hovering = false
    // Bumped by the refresh button below to force this view's body (and
    // so `thumbnail`, which isn't itself @State-backed) to re-evaluate --
    // AlbumLoader.refreshPoster(for:) does the actual re-pick/cache-clear,
    // this just tells SwiftUI something changed and it's time to re-read.
    @State private var refreshTick = 0

    private var thumbnail: NSImage? {
        AlbumLoader.tileThumbnail(for: album)
    }

    var body: some View {
        Button(action: onTap) {
            // GeometryReader has no content-size opinion of its own, so
            // it's purely at the mercy of the `.aspectRatio` modifier
            // below: given the fixed width the grid column proposes, it
            // always resolves to EXACTLY width/aspectRatio for height --
            // no more, no less. Every child is then force-sized to that
            // exact `geo.size` box. Without this, a plain
            // `Image(...).aspectRatio(contentMode: .fill)` with no frame
            // has its OWN intrinsic size leak into the ZStack's layout,
            // so each tile ended up sized after that particular photo's
            // own proportions (short for a landscape shot, tall for a
            // portrait one) instead of a uniform box -- which is exactly
            // why tiles in the same row were coming out different sizes.
            GeometryReader { geo in
                // alignment: .top so the Text below (the only child here
                // without its own explicit frame) sits at the top of the
                // card instead of the ZStack's default center.
                ZStack(alignment: .top) {
                    Theme.posterGradient

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            // Reading refreshTick here is what makes this
                            // view re-render (and so re-read `thumbnail`)
                            // when the refresh button below bumps it.
                            .id(refreshTick)
                    }

                    // Scrim now shines down from the TOP (was bottom-up)
                    // to back the title now that it lives up there.
                    LinearGradient(
                        colors: [Color.black.opacity(0.85), Color.black.opacity(0.25), Color.clear],
                        startPoint: .top, endPoint: .center
                    )

                    Text(album.title)
                        .font(.system(size: 20, weight: .bold))
                        // Explicitly no case transform: titles.json already
                        // authors every title in proper Title Case ("NYC",
                        // "Valentine's Day", "Atlantic City"), so this
                        // displays as-is rather than forcing .uppercase or
                        // .capitalized -- the latter would actually mangle
                        // "NYC" into "Nyc" and "Valentine's Day" into
                        // "Valentine'S Day" (Swift's .capitalized treats
                        // the apostrophe as a word break).
                        .textCase(nil)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(12)
                        .shadow(color: .black.opacity(0.7), radius: 4)

                    if album.isComingSoon {
                        // A uniform dim, not just the title-legibility
                        // scrim already above -- reads at a glance as
                        // "not ready yet" even before spotting the pill.
                        Color.black.opacity(0.4)

                        Text("COMING SOON")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.4)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.red)
                            .clipShape(Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 16)
                    }

                    // Hover-only refresh button, corner-pinned regardless
                    // of the ZStack's own .top alignment (the explicit
                    // .frame + alignment: .topTrailing below overrides
                    // that for just this one child). A second, separate
                    // Button nested inside the card's outer Button works
                    // fine on macOS -- each intercepts its own click
                    // region -- as long as it keeps .buttonStyle(.plain)
                    // so it doesn't inherit the outer button's styling.
                    if hovering && !album.isComingSoon {
                        Button {
                            AlbumLoader.refreshPoster(for: album)
                            refreshTick += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(hovering ? 1.08 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.6 : 0), radius: 16)
            .animation(.easeOut(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
