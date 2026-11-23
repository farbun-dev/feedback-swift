import Foundation

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Shows the orb without a button: a two-finger triple tap anywhere on
/// iOS, Control-Option-Command-F on macOS.
///
/// A one-finger triple tap would clash with the app's own taps and with text
/// selection. Two fingers, three times, is something nobody does by chance;
/// the tap is recognised alongside the app's gestures and cancels none of
/// its touches.
@MainActor
final class Gesture: NSObject {
    static let shared = Gesture()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        #if canImport(UIKit)
            NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { _ in
                // The window that just became key.
                MainActor.assumeIsolated {
                    if let window = Capture.keyWindow() { Gesture.shared.install(on: window) }
                }
            }
            if let window = Capture.keyWindow() { install(on: window) }
        #else
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard Gesture.isShortcut(event) else { return event }
                MainActor.assumeIsolated { Feedback.show() }
                return nil
            }
        #endif
    }

    #if canImport(UIKit)
        private var windows = NSHashTable<UIWindow>.weakObjects()

        func install(on window: UIWindow) {
            guard !windows.contains(window) else { return }
            windows.add(window)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.numberOfTapsRequired = 3
            tap.numberOfTouchesRequired = 2
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { Feedback.show() }
        }
    #else
        nonisolated static func isShortcut(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                == [.control, .option, .command]
                && event.charactersIgnoringModifiers?.lowercased() == "f"
        }

        /// Option-click, which drops a pin while the orb is out.
        nonisolated static func isPinClick(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option]
        }
    #endif
}

#if canImport(UIKit)
    extension Gesture: UIGestureRecognizerDelegate {
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
#endif
