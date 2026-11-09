// Renders docs/screenshot.png with fixed sample data (ImageRenderer cannot capture the live blur).
// Run from the repo root:
//   swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
//     Sources/Usage.swift Sources/Views.swift scripts/screenshot.swift -o build/screenshot
//   cp -R Resources/*.lproj build/ && build/screenshot docs en -AppleLanguages '(en)' -AppleLocale en_US
//   mv docs/screenshot-en.png docs/screenshot.png
import AppKit
import SwiftUI

@MainActor
func write<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = scale
    guard let cgImage = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    else { print("render failed: \(path)"); return }
    try! png.write(to: URL(fileURLWithPath: path))
}

/// Stand-in for the behind-window blur, which ImageRenderer cannot capture.
struct Glass<Content: View>: View {
    let radius: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.11).opacity(0.86)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

struct Hero: View {
    let store: UsageStore
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Glass(radius: 14) {
                UsageCard(store: store, now: now).padding(14).frame(width: 250)
            }
            VStack(alignment: .leading, spacing: 22) {
                Glass(radius: 15) {
                    CompactPill(store: store, now: now).padding(.horizontal, 12).padding(.vertical, 8)
                }
                Glass(radius: 8) {
                    MenuBarLabel(store: store)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .padding(.top, 6)
        }
        .padding(44)
        .background(
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.22, blue: 0.30), Color(red: 0.15, green: 0.16, blue: 0.30),
                         Color(red: 0.08, green: 0.12, blue: 0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

@main
struct Harness {
    @MainActor static func main() {
        let out = CommandLine.arguments[1]
        let suffix = CommandLine.arguments[2]
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 20))!
        let store = UsageStore.sample(
            session: UsageWindow(percent: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60), length: 5 * 3600),
            weekly: UsageWindow(percent: 25, resetsAt: now.addingTimeInterval(4 * 86400 + 3600), length: 7 * 86400),
            updated: now.addingTimeInterval(-60)
        )
        write(Hero(store: store, now: now), to: "\(out)/screenshot-\(suffix).png")
    }
}
