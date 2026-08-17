import SwiftUI

/// The featured banner atop Browse, styled as a distinct card rather than
/// a full-bleed strip: inset from the screen edges, rounded corners, a
/// soft drop shadow, and a faint hairline border so it visually separates
/// from the page's black background instead of blending into it.
///
/// Carries the same hover-only "change thumbnail" refresh button as a
/// regular AlbumTile (see AlbumTile.swift) -- the hero's poster is picked
/// by the exact same AlbumLoader.pickPosterSource(for:)/refreshPoster(for:)
/// machinery, so it deserves the same re-roll control, just pinned to
/// this card's own top-trailing corner instead of a grid tile's.
struct HeroView: View {
    let album: Album
    let onPlay: () -> Void

    private let heroHeight: CGFloat = 460
    private let cornerRadius: CGFloat = 18

    @State private var hovering = false
    // Bumped by the refresh button below to force `posterBackground` to
    // re-read AlbumLoader.posterImage(for:) after refreshPoster(for:)
    // clears the cache and re-picks -- same trick as AlbumTile's own
    // refreshTick.
    @State private var refreshTick = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            posterBackground
                .frame(height: heroHeight)
                .clipped()
                .id(refreshTick)

            LinearGradient(
                colors: [Theme.background, Theme.background.opacity(0.15), Color.clear],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: heroHeight)

            LinearGradient(
                colors: [Theme.background.opacity(0.9), Color.clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: heroHeight)

            VStack(alignment: .leading, spacing: 14) {
                Text("FEATURED")
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundColor(Theme.red)

                Text(album.title)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)

                if let blurb = album.blurb, !blurb.isEmpty {
                    Text(blurb)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: 480, alignment: .leading)
                }

                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundColor(.black)
                .padding(.top, 4)
            }
            .padding(40)

            // Hover-only "change thumbnail" button, pinned to this card's
            // own top-trailing corner -- a second, separate Button nested
            // alongside the "Play" one above works fine on macOS, each
            // intercepts its own click region, as long as it keeps
            // .buttonStyle(.plain) so it doesn't inherit the outer
            // styling. Icon-only, same as AlbumTile's own refresh button,
            // just sized up a notch to sit comfortably on a banner this
            // size.
            if hovering {
                Button {
                    AlbumLoader.refreshPoster(for: album)
                    refreshTick += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(9)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
            }
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 28, y: 14)
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var posterBackground: some View {
        if let image = AlbumLoader.posterImage(for: album) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Theme.posterGradient
        }
    }
}
