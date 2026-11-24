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
    /// A point on the content of the scroll view a pin was dropped on, so
    /// that the pin moves with what it was dropped on as that scrolls.
    struct Anchor {
        /// The scroll view on iOS, its document view on macOS: a view whose
        /// own coordinates move with the content.
        weak var view: PlatformView?
        /// In the view's own coordinates.
        let point: CGPoint
    }

    let review: Review
    /// The app's window the orb is over.
    private(set) weak var window: PlatformWindow?
    private var anchors: [Draft.Pin.ID: Anchor] = [:]
    private var link: CADisplayLink?
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
            review.bubbleChanged = { [weak self, weak host, weak window] open in
                if open {
                    host?.makeKey()
                    self?.reveal()
                } else {
                    window?.makeKey()
                }
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
            // The app's content may have moved for the keyboard, taking the
            // open pin out of sight.
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIResponder.keyboardDidChangeFrameNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reveal() }
                })
        #else
            guard let content = window.contentView else { return }
            let host = OverlayHostingView(rootView: view)
            host.review = review
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            self.host = host
            review.bubbleChanged = { [weak self] open in if open { self?.reveal() } }
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
        // Every frame, in every run loop mode, so that pins keep up with the
        // content while it is dragged and while it glides to a stop.
        #if canImport(UIKit)
            let link = CADisplayLink(target: self, selector: #selector(refresh))
        #else
            let link = window.displayLink(target: self, selector: #selector(refresh))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Which screen is in view, so that only its pins are shown, and where
    /// those dropped on scrolling content are now.
    @objc func refresh() {
        guard let window else { return }
        let key = Self.screenKey(of: window)
        if !key.isSame(as: review.current) { review.current = key }
        host?.measure()
        var positions: [Draft.Pin.ID: CGPoint] = [:]
        var outOfSight: Set<Draft.Pin.ID> = []
        for pin in review.draft.pins where review.isShown(pin) {
            // Once its scroll view is gone, such as when the screen was
            // closed and opened again, the pin stays where it was dropped.
            guard let anchor = anchors[pin.id], let view = anchor.view, view.window === window
            else { continue }
            positions[pin.id] = location(of: anchor.point, in: view)
            if !Self.isInSight(anchor.point, in: view) { outOfSight.insert(pin.id) }
        }
        if review.positions != positions { review.positions = positions }
        if review.outOfSight != outOfSight { review.outOfSight = outOfSight }
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
        let anchor = anchor(at: point)
        let id = review.pin(
            at: point, on: screenshot, key: key, screen: entry?.name,
            source: entry.map { "\($0.file):\($0.line)" })
        if let id, let anchor { anchors[id] = anchor }
    }

    func remove() {
        link?.invalidate()
        link = nil
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

        /// The innermost scroll view under `point`, and the point on its
        /// content, when it is in sight there. A text view scrolls only its
        /// own text, so the pin goes with what the text view is in.
        private func anchor(at point: CGPoint) -> Anchor? {
            guard let window else { return nil }
            var view = window.hitTest(point, with: nil)
            while let current = view, !(current is UIScrollView) || current is UITextView {
                view = current.superview
            }
            guard let view else { return nil }
            let local = view.convert(point, from: window)
            return Self.isInSight(local, in: view) ? Anchor(view: view, point: local) : nil
        }

        /// Where `point`, in `view`, is in the window now.
        private func location(of point: CGPoint, in view: UIView) -> CGPoint {
            view.convert(point, to: nil)
        }

        /// Whether `point`, in `view`, is inside every scroll view from `view`
        /// out, and clear of what covers their edges, such as bars.
        private static func isInSight(_ point: CGPoint, in view: UIView) -> Bool {
            var current: UIView? = view
            while let ancestor = current {
                if let scroll = ancestor as? UIScrollView,
                    !scroll.bounds.inset(by: scroll.adjustedContentInset)
                        .contains(view.convert(point, to: scroll))
                {
                    return false
                }
                current = ancestor.superview
            }
            return true
        }
    #else
        /// The innermost scroll view under `point`, and the point on its
        /// content, when it is in sight there.
        private func anchor(at point: CGPoint) -> Anchor? {
            guard let content = window?.contentView else { return nil }
            let local = CGPoint(
                x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
            let hit = content.hitTest(content.convert(local, to: content.superview))
            guard let scroll = hit as? NSScrollView ?? hit?.enclosingScrollView,
                let document = scroll.documentView
            else { return nil }
            let onDocument = document.convert(local, from: content)
            return Self.isInSight(onDocument, in: document)
                ? Anchor(view: document, point: onDocument) : nil
        }

        /// Where `point`, in `view`, is over the window's content now, from
        /// its top left.
        private func location(of point: CGPoint, in view: NSView) -> CGPoint {
            guard let content = window?.contentView else { return point }
            let local = content.convert(point, from: view)
            return CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
        }

        /// Whether `point`, in `view`, is inside every scroll view from `view`
        /// out, and clear of what covers their edges, such as the toolbar.
        private static func isInSight(_ point: CGPoint, in view: NSView) -> Bool {
            var scroll = view.enclosingScrollView
            while let current = scroll {
                guard let document = current.documentView,
                    current.documentVisibleRect.contains(view.convert(point, to: document))
                else { return false }
                scroll = current.enclosingScrollView
            }
            return true
        }
    #endif

    /// Scrolls the open pin back into sight, such as when its comment is
    /// opened again from the review sheet.
    private func reveal() {
        refresh()
        guard let id = review.open, review.outOfSight.contains(id), let anchor = anchors[id],
            let view = anchor.view
        else { return }
        let point = anchor.point
        #if canImport(UIKit)
            // Each scroll view from the pin's out, as they may be nested.
            var current: UIView? = view
            while let ancestor = current {
                if let scroll = ancestor as? UIScrollView {
                    Self.scroll(scroll, toShow: view.convert(point, to: scroll))
                }
                current = ancestor.superview
            }
        #else
            view.scrollToVisible(CGRect(x: point.x - 60, y: point.y - 60, width: 120, height: 120))
        #endif
    }

    #if canImport(UIKit)
        /// Scrolls `scroll` so that `point`, in its own coordinates, is in the
        /// middle of what is in sight, or as near as the content allows.
        private static func scroll(_ scroll: UIScrollView, toShow point: CGPoint) {
            let inset = scroll.adjustedContentInset
            let visible = scroll.bounds.inset(by: inset)
            guard !visible.contains(point) else { return }
            let size = scroll.contentSize
            var offset = scroll.contentOffset
            if point.y < visible.minY || point.y > visible.maxY {
                let highest = max(-inset.top, size.height + inset.bottom - scroll.bounds.height)
                offset.y = min(max(offset.y + point.y - visible.midY, -inset.top), highest)
            }
            if point.x < visible.minX || point.x > visible.maxX {
                let highest = max(-inset.left, size.width + inset.right - scroll.bounds.width)
                offset.x = min(max(offset.x + point.x - visible.midX, -inset.left), highest)
            }
            scroll.setContentOffset(offset, animated: true)
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

/// The comment of one pin, pointing at it.
private struct Bubble: View {
    let review: Review
    let id: Draft.Pin.ID
    @FocusState private var focused: Bool
    /// Its height once laid out, which grows with the comment.
    @State private var height: CGFloat?

    static let width: CGFloat = 264

    var body: some View {
        let width = min(Self.width, review.size.width - 16)
        let place = placement(width: width)
        let shape = BubbleShape(tip: place.tip, below: place.below)
        VStack(alignment: .leading, spacing: 10) {
            TextField("What's wrong here?", text: text, axis: .vertical)
                .font(.subheadline)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityIdentifier("feedback-pin-comment")
            HStack {
                Button(role: .destructive) {
                    review.deleteOpen()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.red)
                Spacer()
                Button("Done") { review.closeBubble() }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 10)
        .padding(place.below ? .top : .bottom, BubbleShape.point.height)
        .frame(width: width)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .background {
            shape.fill(.thickMaterial)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .offset(x: place.origin.x, y: place.origin.y)
        // Shown once its height is known, so it does not jump into place.
        .opacity(height == nil ? 0 : 1)
        .task(id: id) {
            // Once the overlay has become the key window.
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    /// Below the pin, or above it near the bottom or the keyboard, with
    /// where along its edge it points at the pin. It has no point when it
    /// had to be moved away from the pin to fit.
    private func placement(width: CGFloat) -> (origin: CGPoint, below: Bool, tip: CGFloat?) {
        let size = review.size
        let pin = review.draft.pins.first { $0.id == id }.map(review.centre(of:)) ?? .zero
        let height = height ?? 120
        let x = min(max(pin.x - width / 2, 8), max(8, size.width - width - 8))
        let top = review.insets.top + 4
        let bottom = min(size.height - review.insets.bottom, review.keyboardTop ?? .infinity) - 8
        // The tip of the point, just clear of the pin.
        let gap = Review.pinSize / 2 + 3
        let below = pin.y + gap + height <= bottom
        let ideal = below ? pin.y + gap : pin.y - gap - height
        let y = max(top, min(ideal, bottom - height))
        return (CGPoint(x: x, y: y), below, abs(y - ideal) < 1 ? pin.x - x : nil)
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

/// A bubble's outline: a rounded rectangle with a point on its top edge, or
/// its bottom edge, `tip` from its left. The point's room is kept free either
/// way, along that edge.
private struct BubbleShape: Shape {
    /// The point on the edge that faces the pin.
    static let point = CGSize(width: 18, height: 8)

    let tip: CGFloat?
    let below: Bool

    func path(in rect: CGRect) -> Path {
        let point = Self.point
        let radius: CGFloat = 16
        var body = rect
        body.size.height -= point.height
        if below { body.origin.y += point.height }
        let path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        guard let tip else { return path }
        let half = point.width / 2
        let x = min(max(rect.minX + tip, body.minX + radius + half), body.maxX - radius - half)
        let base = below ? body.minY : body.maxY
        let peak = below ? rect.minY : rect.maxY
        // Overlaps the body a little, so the two join without a seam.
        let inside: CGFloat = below ? 1 : -1
        var pointer = Path()
        pointer.move(to: CGPoint(x: x - half, y: base + inside))
        pointer.addLine(to: CGPoint(x: x - half, y: base))
        pointer.addCurve(
            to: CGPoint(x: x, y: peak), control1: CGPoint(x: x - half / 2, y: base),
            control2: CGPoint(x: x - 2.5, y: peak))
        pointer.addCurve(
            to: CGPoint(x: x + half, y: base), control1: CGPoint(x: x + 2.5, y: peak),
            control2: CGPoint(x: x + half / 2, y: base))
        pointer.addLine(to: CGPoint(x: x + half, y: base + inside))
        pointer.closeSubpath()
        return path.union(pointer)
    }
}
