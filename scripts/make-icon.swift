// Renders Resources/AppIcon.icns. Run from the repo root: swift scripts/make-icon.swift
import AppKit
import SwiftUI

struct Icon: View {
    private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.20, green: 0.18, blue: 0.17), Color(red: 0.08, green: 0.07, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
            gauge
            Image(systemName: "sparkle")
                .font(.system(size: 230, weight: .medium))
                .foregroundStyle(accent)
                .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    /// 270° gauge opening at the bottom, filled to about two thirds.
    private var gauge: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 56, lineCap: .round))
            Circle()
                .trim(from: 0, to: 0.75 * 0.66)
                .stroke(
                    AngularGradient(colors: [accent.opacity(0.55), accent], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(270 * 0.66)),
                    style: StrokeStyle(lineWidth: 56, lineCap: .round))
        }
        .rotationEffect(.degrees(135))
        .frame(width: 560, height: 560)
        .offset(y: 10)
    }
}

@MainActor
func png(size: Int) -> Data {
    let renderer = ImageRenderer(content: Icon().frame(width: 1024, height: 1024))
    renderer.scale = CGFloat(size) / 1024
    guard let cgImage = renderer.cgImage else { fatalError("render failed") }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try MainActor.assumeIsolated { png(size: base * scale) }.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
