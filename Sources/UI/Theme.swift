import SwiftUI

/// Colour themes. Each theme is a three-stop gradient used for accents,
/// selection, the unread marker, primary buttons and the welcome screen.
enum AppTheme: String, CaseIterable, Identifiable {
    case aurora, sunset, ocean, forest, berry, graphite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .berry: return "Berry"
        case .graphite: return "Graphite"
        }
    }

    var colors: [Color] {
        switch self {
        case .aurora:   return [Color(hex: 0x6D5DFC), Color(hex: 0x3B82F6), Color(hex: 0x14C8D8)]
        case .sunset:   return [Color(hex: 0xF43F5E), Color(hex: 0xF97316), Color(hex: 0xFBBF24)]
        case .ocean:    return [Color(hex: 0x1D4ED8), Color(hex: 0x0EA5E9), Color(hex: 0x2DD4BF)]
        case .forest:   return [Color(hex: 0x059669), Color(hex: 0x10B981), Color(hex: 0x84CC16)]
        case .berry:    return [Color(hex: 0x9333EA), Color(hex: 0xDB2777), Color(hex: 0xF472B6)]
        case .graphite: return [Color(hex: 0x475569), Color(hex: 0x64748B), Color(hex: 0x94A3B8)]
        }
    }

    /// The single colour used where a gradient doesn't fit (text, icons).
    var accent: Color { colors[1] }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var softGradient: LinearGradient {
        LinearGradient(colors: colors.map { $0.opacity(0.16) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .aurora
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Tinted rounded-square icon used in the sidebar and settings (iOS-Settings style).
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: colors.last?.opacity(0.35) ?? .clear, radius: 2, y: 1)
    }
}

/// Primary pill button filled with the theme gradient.
struct GradientButtonStyle: ButtonStyle {
    var theme: AppTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.gradient))
            .shadow(color: theme.colors[0].opacity(0.35), radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary pill button: soft tinted background.
struct PillButtonStyle: ButtonStyle {
    var theme: AppTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.accent.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}

/// Palette for sender avatars — harmonious, saturated, readable with white initials.
enum AvatarPalette {
    static let pairs: [(Color, Color)] = [
        (Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)),
        (Color(hex: 0xEC4899), Color(hex: 0xF43F5E)),
        (Color(hex: 0xF97316), Color(hex: 0xF59E0B)),
        (Color(hex: 0x10B981), Color(hex: 0x14B8A6)),
        (Color(hex: 0x0EA5E9), Color(hex: 0x3B82F6)),
        (Color(hex: 0x8B5CF6), Color(hex: 0xD946EF)),
        (Color(hex: 0x06B6D4), Color(hex: 0x22C55E)),
        (Color(hex: 0xEF4444), Color(hex: 0xF97316)),
        (Color(hex: 0x64748B), Color(hex: 0x475569)),
    ]

    static func pair(for key: String) -> (Color, Color) {
        var h: UInt64 = 5381
        for b in key.lowercased().utf8 { h = (h &* 33) &+ UInt64(b) }
        return pairs[Int(h % UInt64(pairs.count))]
    }
}
