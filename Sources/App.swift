import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var panel: FloatingPanel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--enable-login-item") { Self.enableLoginItemAndExit() }
        let panel = FloatingPanel(rootView: FloatingView(store: store))
        self.panel = panel
        store.$showFloating
            .removeDuplicates()
            .sink { [weak panel] show in
                guard let panel else { return }
                if show {
                    panel.orderFrontRegardless()
                    // Wait one runloop pass so the hosting controller has sized the panel.
                    DispatchQueue.main.async { panel.ensureOnScreen() }
                } else {
                    panel.orderOut(nil)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak panel] _ in panel?.ensureOnScreen() }
            .store(in: &cancellables)
        store.start()
    }

    /// Same as the "Beim Login starten" switch, for scripted setup.
    private static func enableLoginItemAndExit() -> Never {
        do {
            try SMAppService.mainApp.register()
            print("Login item status: \(SMAppService.mainApp.status == .enabled ? "enabled" : "\(SMAppService.mainApp.status.rawValue)")")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Login item registration failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// Borderless, non-activating panel that floats above all apps and follows across Spaces.
/// Its top-left corner is the anchor: content size changes (compact/detail) grow downwards from it.
final class FloatingPanel: NSPanel {
    private static let anchorKey = "panelTopLeft"
    private var anchor: NSPoint?
    private var moveObserver: NSObjectProtocol?

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 170),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        anchor = UserDefaults.standard.string(forKey: Self.anchorKey).map(NSPointFromString)

        // Letting the hosting controller resize the window (sizingOptions) does so from inside the layout
        // pass, and a width change there (compact pill growing) crashes AppKit's constraint engine.
        // So measure the content and resize once that pass is over. fixedSize measures the ideal size;
        // under the window's current size as proposal the content would squeeze and the window never grow.
        let measured = rootView.fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
            DispatchQueue.main.async { self?.fit(size) }
        }
        let host = NSHostingController(rootView: measured)
        host.sizingOptions = []
        contentViewController = host

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberAnchor() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let anchor, rect.size != frame.size, rect.width > 0 {
            rect.origin = NSPoint(x: anchor.x, y: anchor.y - rect.height)
        }
        super.setFrame(rect, display: flag)
        invalidateShadow()
    }

    private func fit(_ size: CGSize) {
        guard size.width > 0, size != frame.size else { return }
        setFrame(NSRect(origin: frame.origin, size: size), display: true)
    }

    /// First launch, a detached display or a stale anchor: move to the top right of the menu-bar screen.
    func ensureOnScreen() {
        let visibleSomewhere = NSScreen.screens.contains { $0.frame.contains(frame) }
        guard anchor == nil || !visibleSomewhere,
              let visible = NSScreen.screens.first?.visibleFrame
        else { return }
        setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - 16))
    }

    private func rememberAnchor() {
        guard frame.width > 0 else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        anchor = topLeft
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.anchorKey)
    }
}
