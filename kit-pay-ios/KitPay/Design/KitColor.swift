import SwiftUI
import UIKit

enum KitColor {
    static let navy = Color(red: 18 / 255, green: 45 / 255, blue: 70 / 255)
    static let deepNavy = Color(red: 8 / 255, green: 33 / 255, blue: 52 / 255)
    static let green = Color(red: 52 / 255, green: 185 / 255, blue: 139 / 255)
    /// Pale brand surface behind glyphs and chips, and the default glass tint.
    ///
    /// This used to be a fixed light mint. Every call site pairs it with `primaryText`, which flips
    /// to white in dark mode, so each of those glyphs became white-on-mint and all but vanished.
    /// The dark variant is a deep brand green, so the same glyph stays legible without any call
    /// site having to branch on the colour scheme.
    static let paleGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 22 / 255, green: 74 / 255, blue: 58 / 255, alpha: 1)
            : UIColor(red: 213 / 255, green: 246 / 255, blue: 234 / 255, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)

    /// Public account verification wears blue, deliberately distinct from green KYC status.
    /// The blue seal is driven only by a validated server designation; completing KYC alone must
    /// never manufacture one locally.
    static let verifiedBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 96 / 255, green: 168 / 255, blue: 238 / 255, alpha: 1)
            : UIColor(red: 16 / 255, green: 94 / 255, blue: 176 / 255, alpha: 1)
    })

    /// Surface tint behind verified identity artwork, the blue counterpart of `paleGreen`.
    static let paleBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 20 / 255, green: 50 / 255, blue: 82 / 255, alpha: 1)
            : UIColor(red: 214 / 255, green: 232 / 255, blue: 250 / 255, alpha: 1)
    })

    /// Money shared out in a group wears gold, so it is never mistaken for an ordinary message or
    /// for the green of a one-to-one payment at a glance.
    ///
    /// Both variants are darkened well past decorative "shiny gold": the light one has to carry
    /// `primaryText` on it and the dark one has to sit on a near-black chat wallpaper.
    static let gold = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 224 / 255, green: 176 / 255, blue: 68 / 255, alpha: 1)
            : UIColor(red: 176 / 255, green: 126 / 255, blue: 18 / 255, alpha: 1)
    })

    /// Surface tint behind a group payment card and its glyphs, the gold counterpart of
    /// `paleGreen`.
    static let paleGold = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 74 / 255, green: 57 / 255, blue: 14 / 255, alpha: 1)
            : UIColor(red: 252 / 255, green: 240 / 255, blue: 205 / 255, alpha: 1)
    })

    /// The two ends of the sheen along a group payment card's edge. Kept subtle enough that the
    /// card still reads as a chat bubble rather than an advert.
    static let goldSheen = LinearGradient(
        colors: [
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 246 / 255, green: 206 / 255, blue: 108 / 255, alpha: 1)
                    : UIColor(red: 214 / 255, green: 166 / 255, blue: 54 / 255, alpha: 1)
            }),
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 150 / 255, green: 110 / 255, blue: 30 / 255, alpha: 1)
                    : UIColor(red: 140 / 255, green: 96 / 255, blue: 10 / 255, alpha: 1)
            }),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
