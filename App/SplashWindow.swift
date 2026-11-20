import AppKit
import SwiftUI

/// Whether the launch splash is still on screen; the app window stays invisible until it is gone.
@MainActor
enum Splash {
    static var isShowing = true
    private static var waiting: [@MainActor () -> Void] = []

    /// Runs `action` once the splash has gone.
    static func whenFinished(_ action: @escaping @MainActor () -> Void) { waiting.append(action) }

    static func finish() {
        isShowing = false
        let actions = waiting
        waiting = []
        actions.forEach { $0() }
    }
}

/// A borderless window of fixed size, centered on the screen, shown for a moment at launch and separate from the app's own window.
@MainActor
final class SplashWindowController {
    private static let size = NSSize(width: 800, height: 450)
    private var window: NSWindow?

    func show(for seconds: TimeInterval = 2) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSHostingView(rootView: SplashView().frame(width: Self.size.width, height: Self.size.height))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        window.contentView = content
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.midY - Self.size.height / 2))
        }
        window.orderFrontRegardless()
        self.window = window

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.dismiss() }
    }

    private func dismiss() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            window.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.window?.close()
            self?.window = nil
            Splash.finish()
        }
    }
}

/// Keeps the window this view lives in invisible until the splash has gone, then fades it in.
struct WindowReveal: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard Splash.isShowing, let window = view.window else { return }
            window.alphaValue = 0
            Splash.whenFinished {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    window.animator().alphaValue = 1
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Resizes the window and centres it on screen when `size` changes, overriding the frame macOS restored from the previous run.
struct WindowSize: NSViewRepresentable {
    let size: CGSize

    final class Coordinator { var applied: CGSize? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.applied != size else { return }
        context.coordinator.applied = size
        DispatchQueue.main.async { [size] in
            nsView.window?.setContentSize(size)
            nsView.window?.center()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let splash = SplashWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        splash.show()
    }
}
