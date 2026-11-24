import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The orb, the pins of the screen in view, and the open comment bubble,
/// drawn over the app's window while the orb is out.
///
/// They are never in a screenshot. On iOS they are in a window of their
/// own, above the app's, which lets every touch away from them through to
/// the app. On macOS they are a view over the window's content, hidden
/// while a screenshot is drawn.
@MainActor
final class Overlay: NSObject {
    let review: Review
    /// The app's window the orb is over.
    private(set) weak var window: PlatformWindow?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    #if canImport(UIKit)
        private var host: OverlayWindow?
        private var pinTap: UITapGestureRecognizer?
    #else
        private var host: OverlayHostingView?
        private var monitor: Any?
    #endif

    init(review: Review, window: PlatformWindow, openReview: @escaping () -> Void) {
        self.review = review
        self.window = window
        super.init()
        let view = OverlayView(review: review, openReview: openReview)
        #if canImport(UIKit)
            guard let scene = window.windowScene else { return }
            let host = OverlayWindow(windowScene: scene)
            host.review = review
            host.windowLevel = window.windowLevel + 1
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .clear
            host.rootViewController = controller
            host.isHidden = false
            self.host = host
            // A double tap drops a pin. The app's touches and taps wait to see
            // whether a second tap follows, and are cancelled when one does,
            // so the first tap of a pin does not also press what is under it.
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            tap.numberOfTapsRequired = 2
            tap.numberOfTouchesRequired = 1
            tap.delaysTouchesBegan = true
            tap.cancelsTouchesInView = true
            tap.delegate = self
            window.addGestureRecognizer(tap)
            pinTap = tap
            // The bubble's text field needs the keyboard, which goes to the
            // key window. Back to the app's window once it closes.
            review.bubbleChanged = { [weak host, weak window] open in
                if open { host?.makeKey() } else { window?.makeKey() }
            }
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                    queue: .main
                ) { [weak review, weak host] note in
                    let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                        .cgRectValue
                    MainActor.assumeIsolated {
                        guard let review, let host, let frame else { return }
                        let top = host.convert(frame, from: nil).minY
                        review.keyboardTop = top < host.bounds.height ? top : nil
                    }
                })
        #else
            guard let content = window.contentView else { return }
            let host = OverlayHostingView(rootView: view)
            host.review = review
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            self.host = host
            // Option-click drops a pin, as a double click is the app's own.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard Gesture.isPinClick(event) else { return event }
                let number = event.windowNumber
                let location = event.locationInWindow
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, number == window.windowNumber,
                        let content = window.contentView, !self.review.reviewing,
                        self.review.open == nil
                    else { return false }
                    let local = content.convert(location, from: nil)
                    guard content.bounds.contains(local) else { return false }
                    self.pin(
                        at: CGPoint(
                            x: local.x,
                            y: content.isFlipped ? local.y : content.bounds.height - local.y))
                    return true
                }
                return handled ? nil : event
            }
        #endif
        refresh()
        // Which screen is in view, so that only its pins are shown.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let window else { return }
        let key = Self.screenKey(of: window)
        if !key.isSame(as: review.current) { review.current = key }
        host?.measure()
    }

    /// Drops a pin at `point` on the screen in view, and takes its screenshot.
    func pin(at point: CGPoint) {
        guard let window else { return }
        #if canImport(UIKit)
            let screenshot = Capture.screenshot(of: window)
        #else
            // The overlay is in the window's content: out of the picture.
            host?.isHidden = true
            let screenshot = Capture.screenshot(of: window)
            host?.isHidden = false
        #endif
        guard let screenshot else { return }
        let key = Self.screenKey(of: window)
        let entry = Screens.shown(in: window).last
        review.pin(
            at: point, on: screenshot, key: key, screen: entry?.name,
            source: entry.map { "\($0.file):\($0.line)" })
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        review.bubbleChanged = nil
        #if canImport(UIKit)
            if let pinTap { pinTap.view?.removeGestureRecognizer(pinTap) }
            pinTap = nil
            host?.isHidden = true
            window?.makeKey()
        #else
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            host?.removeFromSuperview()
        #endif
        host = nil
    }

    #if canImport(UIKit)
        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let window, !review.reviewing, review.open == nil
            else { return }
            pin(at: recognizer.location(in: window))
        }
    #endif

    /// The screen in view in `window` now.
    static func screenKey(of window: PlatformWindow) -> ScreenKey {
        let name = Screens.shown(in: window).last?.name
        #if canImport(UIKit)
            return ScreenKey(owner: topController(window.rootViewController), name: name)
        #else
            return ScreenKey(owner: window, name: name)
        #endif
    }

    #if canImport(UIKit)
        /// The view controller on top: what is presented, the top of a
        /// navigation stack, the selected tab.
        static func topController(_ root: UIViewController?) -> UIViewController? {
            var current = root
            var steps = 0
            while let controller = current, steps < 30 {
                steps += 1
                if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                    current = presented
                } else if let navigation = controller as? UINavigationController,
                    let top = navigation.topViewController
                {
                    current = top
                } else if let tabs = controller as? UITabBarController,
                    let selected = tabs.selectedViewController
                {
                    current = selected
                } else if let container = container(in: controller, depth: 0) {
                    current = container
                } else {
                    return controller
                }
            }
            return current
        }

        /// A navigation or tab controller among `controller`'s children, as
        /// SwiftUI's NavigationStack and TabView have.
        private static func container(in controller: UIViewController, depth: Int)
            -> UIViewController?
        {
            guard depth < 4 else { return nil }
            for child in controller.children {
                if child is UINavigationController || child is UITabBarController { return child }
                if let found = container(in: child, depth: depth + 1) { return found }
            }
            return nil
        }
    #endif
}

#if canImport(UIKit)
    extension Overlay: UIGestureRecognizerDelegate {
        /// The app's own taps under the pin tap, such as a SwiftUI button's,
        /// wait for it to fail. Scrolling, dragging and long presses do not,
        /// so they start as soon as the finger moves or holds, and neither do
        /// the window's own, such as the system's edge gestures.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            !(other.view is UIWindow || other is UIPanGestureRecognizer
                || other is UIPinchGestureRecognizer || other is UIRotationGestureRecognizer
                || other is UILongPressGestureRecognizer)
        }
    }

    /// The orb's window. Touches go to the app under it, except on the orb,
    /// a pin, or anywhere while a bubble is open.
    final class OverlayWindow: UIWindow {
        weak var review: Review?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let review, review.isInteractive(at: point) else { return nil }
            return super.hitTest(point, with: event)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        func measure() {
            guard let review else { return }
            if review.size != bounds.size { review.size = bounds.size }
            let insets = EdgeInsets(
                top: safeAreaInsets.top, leading: safeAreaInsets.left,
                bottom: safeAreaInsets.bottom, trailing: safeAreaInsets.right)
            if review.insets != insets { review.insets = insets }
        }
    }
#else
    /// The orb's view, over the window's content. Clicks go to the app
    /// under it, except on the orb, a pin, or anywhere while a bubble is open.
    final class OverlayHostingView: NSHostingView<OverlayView> {
        weak var review: Review?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let review else { return nil }
            let local = convert(point, from: superview)
            let top = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
            guard bounds.contains(local), review.isInteractive(at: top) else { return nil }
            return super.hitTest(point)
        }

        override func layout() {
            super.layout()
            measure()
        }

        func measure() {
            guard let review else { return }
            if review.size != bounds.size { review.size = bounds.size }
            let insets = EdgeInsets(
                top: safeAreaInsets.top, leading: safeAreaInsets.left,
                bottom: safeAreaInsets.bottom, trailing: safeAreaInsets.right)
            if review.insets != insets { review.insets = insets }
        }
    }
#endif

struct OverlayView: View {
    let review: Review
    let openReview: () -> Void

    @State private var drag: CGSize?
    @State private var flash = 0.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if !review.reviewing {
                if review.open != nil {
                    // A tap anywhere else keeps the comment and closes the bubble.
                    Color.black.opacity(0.001)
                        .onTapGesture { review.closeBubble() }
                        .accessibilityHidden(true)
                }
                ForEach(review.visible) { pin in
                    pinView(pin)
                }
                if let id = review.open {
                    Bubble(review: review, id: id)
                }
                orb
            }
            Color.white.opacity(flash).allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        // The screenshot was taken: a short flash, as the system's does.
        .onChange(of: review.flashes) {
            flash = 0.6
            withAnimation(.easeOut(duration: 0.25)) { flash = 0 }
        }
    }

    private func pinView(_ pin: Draft.Pin) -> some View {
        let number = review.draft.number(of: pin.id)
        return MarkBadge(number: number, ringed: true)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture { tap(pin.id) }
            .accessibilityElement()
            .accessibilityLabel("Pin \(number)")
            .accessibilityValue(pin.comment)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("feedback-pin-\(number)")
            .accessibilityAction { tap(pin.id) }
            .position(review.centre(of: pin))
    }

    private func tap(_ id: Draft.Pin.ID) {
        if review.open == id {
            review.closeBubble()
            return
        }
        review.closeBubble()
        if review.draft.pins.contains(where: { $0.id == id }) { review.open = id }
    }

    private var orb: some View {
        let centre = review.orbCentre
        let count = review.draft.pins.count
        return ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color(white: 0.11).opacity(0.92))
                .overlay {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.3), radius: 7, y: 4)
                .frame(width: Review.orbSize, height: Review.orbSize)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.bold()).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(.red))
                    .overlay(Capsule().stroke(.white, lineWidth: 2))
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: Review.orbSize, height: Review.orbSize)
        .contentShape(Circle())
        .gesture(
            // In the overlay's space: the orb moves with the finger, so its
            // own space would see almost no movement.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if drag != nil || hypot(value.translation.width, value.translation.height) > 6 {
                        drag = value.translation
                    }
                }
                .onEnded { value in
                    if drag != nil {
                        withAnimation(.easeOut(duration: 0.2)) {
                            review.dropOrb(
                                at: CGPoint(
                                    x: centre.x + value.translation.width,
                                    y: centre.y + value.translation.height))
                            drag = nil
                        }
                    } else {
                        openReview()
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Review feedback")
        .accessibilityValue(count == 1 ? "1 pin" : "\(count) pins")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("feedback-orb")
        .accessibilityAction { openReview() }
        .position(x: centre.x + (drag?.width ?? 0), y: centre.y + (drag?.height ?? 0))
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// The comment of one pin, next to it.
private struct Bubble: View {
    let review: Review
    let id: Draft.Pin.ID
    @FocusState private var focused: Bool

    static let width: CGFloat = 240
    static let height: CGFloat = 112

    var body: some View {
        let origin = origin()
        VStack(alignment: .leading, spacing: 6) {
            TextField("What's wrong here?", text: text, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityIdentifier("feedback-pin-comment")
            HStack {
                Button("Delete", role: .destructive) { review.deleteOpen() }
                    .tint(.red)
                Spacer()
                Button("Done") { review.closeBubble() }.bold()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.background)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.1), lineWidth: 0.5))
        .offset(x: origin.x, y: origin.y)
        .task(id: id) {
            // Once the overlay has become the key window.
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    /// Below the pin, or above it near the bottom or the keyboard.
    private func origin() -> CGPoint {
        let size = review.size
        let point = review.draft.pins.first { $0.id == id }.map(review.centre(of:)) ?? .zero
        let x = min(max(point.x - Self.width / 2, 8), max(8, size.width - Self.width - 8))
        let bottom = min(size.height - review.insets.bottom, review.keyboardTop ?? .infinity) - 8
        var y = point.y + 18
        if y + Self.height > bottom { y = point.y - 18 - Self.height }
        y = min(y, bottom - Self.height)
        return CGPoint(x: x, y: max(review.insets.top + 4, y))
    }

    /// The comment. Return keeps it and closes the bubble.
    private var text: Binding<String> {
        let comment = review.comment(of: id)
        return Binding(
            get: { comment.wrappedValue },
            set: { new in
                if new.hasSuffix("\n") {
                    comment.wrappedValue = String(new.dropLast())
                    review.closeBubble()
                } else {
                    comment.wrappedValue = new
                }
            })
    }
}
