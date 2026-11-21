import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Screens named with `.feedbackScreen(_:)`, each with the window it is in.
@MainActor
enum Screens {
    struct Entry: Equatable {
        let id: UUID
        let name: String
        let file: String
        let line: Int
        var window: ObjectIdentifier?
    }

    static var shown: [Entry] = []

    /// The named screens in `window`, in the order they appeared. With a
    /// split view or an inspector several are on screen at once; the last is
    /// sent as the screen, and all of them in the environment.
    static func shown(in window: PlatformWindow?) -> [Entry] {
        guard let window else { return shown }
        let id = ObjectIdentifier(window)
        // A screen whose window is not known yet counts, as a mask does.
        return shown.filter { $0.window == nil || $0.window == id }
    }

    static func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        if let index = shown.firstIndex(where: { $0.id == id }) { change(&shown[index]) }
    }
}

extension View {
    /// Names the screen this view is, so feedback sent from it says where it
    /// came from. The file and line are recorded too, as a pointer into the
    /// source for whoever acts on the feedback.
    ///
    /// ```swift
    /// CheckoutView().feedbackScreen("Checkout")
    /// ```
    public func feedbackScreen(
        _ name: String, file: StaticString = #fileID, line: UInt = #line
    ) -> some View {
        modifier(ScreenName(name: name, file: "\(file)", line: Int(line)))
    }

    /// Blanks this view out of feedback screenshots, for anything private.
    public func feedbackMasked() -> some View {
        modifier(Masked())
    }
}

private struct ScreenName: ViewModifier {
    let name: String
    let file: String
    let line: Int
    @State private var id = UUID()
    // Kept here as well as on the entry: on macOS the window can be known
    // before onAppear adds the entry, and the other way round on iOS.
    @State private var window: ObjectIdentifier?

    func body(content: Content) -> some View {
        content
            .background(
                WindowReader { found in
                    window = found.map(ObjectIdentifier.init)
                    Screens.update(id) { $0.window = window }
                }
            )
            .onAppear {
                Screens.shown.removeAll { $0.id == id }
                Screens.shown.append(
                    .init(id: id, name: name, file: file, line: line, window: window))
            }
            .onDisappear { Screens.shown.removeAll { $0.id == id } }
    }
}

private struct Masked: ViewModifier {
    @State private var id = UUID()
    @State private var window: ObjectIdentifier?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    WindowReader { found in
                        window = found.map(ObjectIdentifier.init)
                        register()
                    }
                    GeometryReader { proxy in
                        // In SwiftUI, global coordinates are the window's.
                        Color.clear
                            .onAppear {
                                frame = proxy.frame(in: .global)
                                register()
                            }
                            .onChange(of: proxy.frame(in: .global)) { _, new in
                                frame = new
                                register()
                            }
                    }
                }
            )
            .onDisappear { Masks.registered[id] = nil }
    }

    private func register() {
        Masks.registered[id] = (window, frame)
    }
}

/// Reports the window a view is in, and again whenever it moves to another.
private struct WindowReader {
    let found: @MainActor (PlatformWindow?) -> Void
}

#if canImport(UIKit)
    extension WindowReader: UIViewRepresentable {
        func makeUIView(context: Self.Context) -> Probe {
            let probe = Probe()
            probe.found = found
            probe.isUserInteractionEnabled = false
            return probe
        }

        func updateUIView(_ view: Probe, context: Self.Context) { view.found = found }

        final class Probe: UIView {
            var found: (@MainActor (UIWindow?) -> Void)?
            override func didMoveToWindow() {
                super.didMoveToWindow()
                found?(window)
            }
        }
    }
#else
    extension WindowReader: NSViewRepresentable {
        func makeNSView(context: Self.Context) -> Probe {
            let probe = Probe()
            probe.found = found
            return probe
        }

        func updateNSView(_ view: Probe, context: Self.Context) { view.found = found }

        final class Probe: NSView {
            var found: (@MainActor (NSWindow?) -> Void)?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                found?(window)
            }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
#endif
