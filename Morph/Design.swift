import SwiftUI

enum MorphStyle {
    static let defaultAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.91, green: 0.69, blue: 0.43, alpha: 1)
            : NSColor(red: 0.60, green: 0.36, blue: 0.16, alpha: 1)
    })
    static let warm = Color(red: 0.91, green: 0.64, blue: 0.33)
    static let cool = Color(red: 0.56, green: 0.71, blue: 0.88)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return AppText.string("System"); case .light: return AppText.string("Hell"); case .dark: return AppText.string("Dunkel") }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum AccentPalette: String, CaseIterable, Identifiable {
    case amber, sage, blue, lavender, rose, graphite, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .amber: return AppText.string("Bernstein")
        case .sage: return AppText.string("Salbei")
        case .blue: return AppText.string("Blau")
        case .lavender: return AppText.string("Lavendel")
        case .rose: return AppText.string("Rosé")
        case .graphite: return AppText.string("Graphit")
        case .custom: return AppText.string("Eigene Farbe")
        }
    }
    func hex(dark: Bool) -> String {
        switch self {
        case .amber: return dark ? "E8B06E" : "995C29"
        case .sage: return dark ? "83C6A5" : "28694F"
        case .blue: return dark ? "8CB8F5" : "275DB0"
        case .lavender: return dark ? "BCA1EC" : "7549AF"
        case .rose: return dark ? "EBA1BD" : "A63F68"
        case .graphite: return dark ? "B5BFCF" : "4D5968"
        case .custom: return "D49559"
        }
    }
}

/// These preferences belong to this app's container, separate from lamp access.
@MainActor
final class ThemeSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { if demoSnapshot == nil { defaults?.set(appearance.rawValue, forKey: "morph.appearance") }; applyAppearance() }
    }
    @Published var accent: AccentPalette {
        didSet { if demoSnapshot == nil { defaults?.set(accent.rawValue, forKey: "morph.accent") } }
    }
    @Published var customHex: String {
        didSet {
            if demoSnapshot == nil, let rgb = ThemeRGB(hex: customHex) { defaults?.set(rgb.hex, forKey: "morph.customAccent") }
        }
    }
    private let defaults: UserDefaults?
    private var demoSnapshot: (AppAppearance, AccentPalette, String)?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults?.string(forKey: "morph.appearance") ?? "") ?? .system
        accent = AccentPalette(rawValue: defaults?.string(forKey: "morph.accent") ?? "") ?? .amber
        let saved = defaults?.string(forKey: "morph.customAccent") ?? "D49559"
        customHex = ThemeRGB(hex: saved)?.hex ?? "D49559"
    }

    var customColor: Color {
        get { (ThemeRGB(hex: customHex) ?? .fallback).color }
        set {
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            customHex = ThemeRGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hex
        }
    }

    func previewColor(for palette: AccentPalette) -> Color {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (ThemeRGB(hex: palette == .custom ? customHex : palette.hex(dark: dark)) ?? .fallback).color
    }

    func color(dark: Bool) -> Color {
        let rgb = ThemeRGB(hex: accent == .custom ? customHex : accent.hex(dark: dark)) ?? .fallback
        return rgb.readable(dark: dark).color
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func reset() {
        appearance = .system
        accent = .amber
        customHex = "D49559"
    }

    func beginDemo() {
        guard demoSnapshot == nil else { return }
        demoSnapshot = (appearance, accent, customHex)
    }

    func endDemo() {
        guard let saved = demoSnapshot else { return }
        appearance = saved.0
        accent = saved.1
        customHex = saved.2
        demoSnapshot = nil
    }
}

private struct ThemeRGB {
    let red: Double
    let green: Double
    let blue: Double
    static let fallback = ThemeRGB(red: 0.6, green: 0.36, blue: 0.16)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 255) / 255,
                  green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }
    var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    private var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// Preserve the chosen hue while keeping accent text and controls legible.
    func readable(dark: Bool) -> ThemeRGB {
        let background = dark ? 0.016 : 0.92
        let target = dark ? 1.0 : 0.0
        for step in 0...40 {
            let mix = Double(step) / 40
            let candidate = ThemeRGB(red: red + (target - red) * mix,
                                     green: green + (target - green) * mix,
                                     blue: blue + (target - blue) * mix)
            let contrast = (max(candidate.luminance, background) + 0.05) / (min(candidate.luminance, background) + 0.05)
            if contrast >= 4.5 { return candidate }
        }
        return ThemeRGB(red: target, green: target, blue: target)
    }
}

private struct MorphAccentKey: EnvironmentKey {
    static let defaultValue = MorphStyle.defaultAccent
}
extension EnvironmentValues {
    var morphAccent: Color {
        get { self[MorphAccentKey.self] }
        set { self[MorphAccentKey.self] = newValue }
    }
}

struct MorphTheme: ViewModifier {
    @ObservedObject var theme: ThemeSettings
    @Environment(\.colorScheme) private var systemScheme
    func body(content: Content) -> some View {
        let dark = (theme.appearance.colorScheme ?? systemScheme) == .dark
        let accent = theme.color(dark: dark)
        content
            .environmentObject(theme)
            .environment(\.morphAccent, accent)
            .environment(\.colorScheme, theme.appearance.colorScheme ?? systemScheme)
            .tint(accent)
    }
}

/// Original vector outline of the lamp's two straight arms, cylindrical head,
/// stem and disc base. No manufacturer artwork or logo is used.
struct LampGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 32
        let offset = CGPoint(x: rect.midX - 16 * scale, y: rect.midY - 16 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        var path = Path()
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: offset.x + x * scale, y: offset.y + y * scale,
                   width: width * scale, height: height * scale)
        }
        path.addRoundedRect(in: box(7.2, 27.0, 12.5, 2.1), cornerSize: CGSize(width: scale, height: scale))
        path.move(to: point(13.4, 27.0))
        path.addLine(to: point(13.4, 14.1))
        path.addLine(to: point(26.9, 11.5))
        path.addLine(to: point(26.9, 9.5))
        path.addLine(to: point(20.4, 5.9))
        path.addRoundedRect(in: box(15.0, 2.7, 5.4, 5.5), cornerSize: CGSize(width: scale, height: scale))
        path.move(to: point(15.8, 7.1))
        path.addLine(to: point(19.6, 7.1))
        path.move(to: point(17.5, 10.0))
        path.addLine(to: point(17.5, 11.9))
        return path
    }
}

struct LampMark: View {
    @Environment(\.morphAccent) private var accent
    var size: CGFloat = 40
    var isOn = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(accent.opacity(isOn ? 0.11 : 0.05))
            LampGlyph()
                .stroke(isOn ? accent : .secondary,
                        style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
                .padding(size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MorphCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MorphStyle.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

struct InlineMessage: View {
    @Environment(\.morphAccent) private var accent
    let text: String
    var symbol = "exclamationmark.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(.secondary)
    }
}

/// A real NSImage template keeps the menu item legible in both menu-bar
/// appearances. The drawing handler is resolution-independent, including on
/// Retina displays; no SwiftUI Shape is hosted inside the status-item label.
@MainActor
enum MenuBarLampIcon {
    enum State: CaseIterable, Hashable { case on, off, disconnected }

    private static let images: [State: NSImage] = Dictionary(uniqueKeysWithValues:
        State.allCases.map { state in
            let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
                draw(state: state, in: rect)
                return true
            }
            image.isTemplate = true
            return (state, image)
        })

    static func image(for state: State) -> NSImage {
        images[state]!
    }

    private static func draw(state: State, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 20, y: rect.height / 20)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(1.35)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Match the original app mark: disc base, stem, two straight arms,
        // far hinge and cylindrical free-end optical head.
        // Keep the outermost strokes at least one point inside the image.
        context.addPath(CGPath(roundedRect: CGRect(x: 4.5, y: 17.0, width: 7.8, height: 1.4),
                               cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
        context.fillPath()
        context.addPath(CGPath(roundedRect: CGRect(x: 7.7, y: 8.4, width: 1.35, height: 8.9),
                               cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
        context.fillPath()
        context.move(to: CGPoint(x: 8.4, y: 8.8))
        context.addLine(to: CGPoint(x: 16.8, y: 7.2))
        context.addLine(to: CGPoint(x: 16.8, y: 5.9))
        context.addLine(to: CGPoint(x: 11.4, y: 3.0))
        context.strokePath()

        context.addPath(CGPath(roundedRect: CGRect(x: 9.4, y: 1.7, width: 3.35, height: 3.5),
                               cornerWidth: 0.65, cornerHeight: 0.65, transform: nil))
        context.fillPath()

        if state == .on {
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: 10.3, y: 6.5))
            context.addLine(to: CGPoint(x: 10.0, y: 7.9))
            context.move(to: CGPoint(x: 12.1, y: 6.5))
            context.addLine(to: CGPoint(x: 12.5, y: 7.8))
            context.strokePath()
        } else if state == .disconnected {
            // A transparent outline separates the slash from the arm/stem.
            // Only alpha is used when macOS tints this template image.
            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineWidth(3.0)
            context.move(to: CGPoint(x: 3.5, y: 15.2))
            context.addLine(to: CGPoint(x: 17.0, y: 5.7))
            context.strokePath()
            context.restoreGState()
            context.setLineWidth(1.15)
            context.move(to: CGPoint(x: 3.5, y: 15.2))
            context.addLine(to: CGPoint(x: 17.0, y: 5.7))
            context.strokePath()
        }
    }
}
