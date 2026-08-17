import SwiftUI

/// All-black background with the classic Netflix red for titles/accents.
enum Theme {
    static let background = Color.black
    static let elevated = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let red = Color(red: 229 / 255, green: 9 / 255, blue: 20 / 255)
    static let redDark = Color(red: 176 / 255, green: 6 / 255, blue: 15 / 255)
    static let textDim = Color(red: 179 / 255, green: 179 / 255, blue: 179 / 255)
    static let textFaint = Color(red: 115 / 255, green: 115 / 255, blue: 115 / 255)

    static let posterGradient = LinearGradient(
        colors: [Color(red: 0.22, green: 0.11, blue: 0.11), Color(red: 0.10, green: 0.10, blue: 0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
