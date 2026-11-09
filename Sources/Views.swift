import AppKit
import ServiceManagement
import SwiftUI

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let warning = Color(red: 0.98, green: 0.74, blue: 0.24)
    static let critical = Color(red: 0.94, green: 0.33, blue: 0.31)
}

extension UsageWindow {
    func tint(at now: Date) -> Color {
        if percent >= 90 { return .critical }
        if projectedLimitDate(at: now) != nil { return .warning }
        return .claude
    }
}

enum Format {
    static func percent(_ window: UsageWindow?) -> String {
        guard let window else { return "–" }
        return "\(Int(window.percent.rounded()))%"
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return String(localized: "\(days) d \(hours) h") }
        if hours > 0 { return String(localized: "\(hours) h \(minutes) min") }
        return String(localized: "\(minutes) min")
    }

    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInTomorrow(date) { return String(localized: "tomorrow \(time)") }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? String(localized: "just now") : String(localized: "\(minutes) min ago")
    }
}

struct UsageBar: View {
    let window: UsageWindow?
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = min(window?.percent ?? 0, 100) / 100
            let tint = window?.tint(at: now) ?? .claude
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, width * fill))
                    .opacity(fill > 0 ? 1 : 0)
                // Elapsed share of the window: fill right of this tick means burning faster than linear.
                if let pace = window?.elapsedFraction(at: now) {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: geometry.size.height + 6)
                        .offset(x: min(max(width * pace - 1, 0), width - 2))
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: window?.percent)
    }
}

struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(window))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            UsageBar(window: window, now: now)
            VStack(alignment: .leading, spacing: 2) {
                Text(resetText).foregroundStyle(.secondary)
                if let forecast { forecast }
            }
            .font(.system(size: 10))
        }
    }

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else { return String(localized: "Starts with your next request") }
        return String(localized: "Resets \(Format.clock(resetsAt, now: now)) · in \(Format.countdown(to: resetsAt, from: now))")
    }

    private var forecast: Text? {
        guard let window else { return nil }
        if window.percent >= 100 { return Text("Limit reached").foregroundStyle(Color.critical) }
        if let hit = window.projectedLimitDate(at: now) {
            let message = String(localized: "Limit around \(Format.clock(hit, now: now)) at this pace")
            return Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(message)")
                .foregroundStyle(Color.warning)
        }
        if let projected = window.projectedPercentAtReset(at: now) {
            let value = Format.percent(UsageWindow(percent: projected, resetsAt: nil, length: window.length))
            return Text("Forecast at reset: \(value)").foregroundStyle(.tertiary)
        }
        return nil
    }
}

struct UsageCard: View {
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Color.claude)
                Text("Claude Usage").font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let lastUpdate = store.lastUpdate {
                    Text(Format.ago(lastUpdate, now: now)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            UsageRow(title: String(localized: "Session (5 h)"), window: store.session, now: now)
            UsageRow(title: String(localized: "Week (7 d)"), window: store.weekly, now: now)
            if let error = store.error {
                Text(error.localizedDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MiniRing: View {
    let window: UsageWindow?
    let now: Date

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(window?.percent ?? 0, 100) / 100)
                .stroke(window?.tint(at: now) ?? .claude, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

struct CompactPill: View {
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            item(label: String(localized: "5h"), window: store.session)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14)
            item(label: String(localized: "7d"), window: store.weekly)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }

    private func item(label: String, window: UsageWindow?) -> some View {
        HStack(spacing: 5) {
            MiniRing(window: window, now: now)
            Text(Format.percent(window))
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
    }
}

/// Behind-window blur; SwiftUI materials only blur content inside the window.
struct BlurBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = Self.mask(radius: cornerRadius)
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct FloatingView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let radius: CGFloat = store.compact ? 15 : 14
            Group {
                if store.compact {
                    CompactPill(store: store, now: context.date)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    UsageCard(store: store, now: context.date)
                        .padding(14)
                        .frame(width: 250)
                }
            }
            .background(BlurBackground(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { store.compact.toggle() }
            .contextMenu {
                Button("Refresh") { Task { await store.refresh() } }
                Button(store.compact ? LocalizedStringKey("Show details") : "Show compact") { store.compact.toggle() }
                Divider()
                Button("Hide window") { store.showFloating = false }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let icon = Image(systemName: Self.gaugeSymbol(for: store.session?.percent))
        if store.showPercentInMenuBar, store.session != nil || store.weekly != nil {
            Text("\(icon) \(Format.percent(store.session)) · \(Format.percent(store.weekly))")
        } else {
            icon
        }
    }

    private static func gaugeSymbol(for percent: Double?) -> String {
        switch percent ?? 0 {
        case ..<17: "gauge.with.dots.needle.0percent"
        case ..<42: "gauge.with.dots.needle.33percent"
        case ..<59: "gauge.with.dots.needle.50percent"
        case ..<84: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                UsageCard(store: store, now: context.date)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Floating window", isOn: $store.showFloating)
                Toggle("Percentages in the menu bar", isOn: $store.showPercentInMenuBar)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.system(size: 10)).foregroundStyle(Color.critical)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            HStack {
                Button("Refresh") { Task { await store.refresh() } }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .task { await store.refreshIfStale() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
