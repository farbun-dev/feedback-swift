import Observation
import SwiftUI

/// While the orb is out: the draft being pinned, which bubble is open, where
/// the orb sits, and the screen in view now.
///
/// Coordinates are points from the top left of the app's window, which the
/// overlay covers exactly.
@MainActor
@Observable
final class Review {
    static let orbSize: CGFloat = 52
    static let pinSize: CGFloat = 22

    var draft: Draft
    /// The pin whose comment bubble is open.
    var open: Draft.Pin.ID? {
        didSet { if (oldValue == nil) != (open == nil) { bubbleChanged?(open != nil) } }
    }
    /// The screen in view now, under the overlay.
    var current = ScreenKey(owner: nil, name: nil)
    /// Whether the review sheet is open, which hides the orb and pins.
    var reviewing = false
    var onRight = true
    /// The orb's centre, as a fraction of the window's height.
    var height: CGFloat = 0.78
    var size: CGSize = .zero
    var insets = EdgeInsets()
    /// Where the keyboard starts, when it is up.
    var keyboardTop: CGFloat?
    /// Counts the pins dropped, for the flash that shows a screenshot was taken.
    var flashes = 0

    @ObservationIgnored var bubbleChanged: ((Bool) -> Void)?

    init(draft: Draft) {
        self.draft = draft
    }

    /// The pins of the screen in view.
    var shown: [Draft.Pin] {
        draft.pins.filter { isShown($0) }
    }

    /// The pins drawn: those of the screen in view, and the open one, which
    /// may have been reopened from the review sheet while another screen is
    /// in view. The SDK cannot take the app back to it.
    var visible: [Draft.Pin] {
        draft.pins.filter { isShown($0) || $0.id == open }
    }

    func isShown(_ pin: Draft.Pin) -> Bool {
        draft.shot(pin.shot)?.key.matches(current) ?? false
    }

    func centre(of pin: Draft.Pin) -> CGPoint {
        CGPoint(x: pin.point.x * size.width, y: pin.point.y * size.height)
    }

    var orbCentre: CGPoint {
        let half = Self.orbSize / 2
        let x = onRight ? size.width - insets.trailing - 10 - half : insets.leading + 10 + half
        let top = insets.top + 8 + half
        let bottom = size.height - insets.bottom - 12 - half
        return CGPoint(x: x, y: min(max(height * size.height, top), max(top, bottom)))
    }

    /// Whether a touch at `point` is for the overlay, and not the app under it.
    func isInteractive(at point: CGPoint) -> Bool {
        if reviewing { return false }
        if open != nil { return true }
        let orb = orbCentre
        if hypot(point.x - orb.x, point.y - orb.y) <= Self.orbSize / 2 + 4 { return true }
        return shown.contains {
            let centre = centre(of: $0)
            return hypot(point.x - centre.x, point.y - centre.y) <= 22
        }
    }

    // Changes

    func pin(
        at point: CGPoint, on screenshot: Screenshot, key: ScreenKey, screen: String?,
        source: String?
    ) {
        guard
            let id = draft.pin(point, on: screenshot, key: key, screen: screen, source: source)
        else { return }
        flashes += 1
        open = id
    }

    /// Closes the open bubble. A pin left without a comment is removed.
    func closeBubble() {
        guard let id = open else { return }
        if let pin = draft.pins.first(where: { $0.id == id }),
            pin.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            draft.remove(id)
        }
        open = nil
    }

    func deleteOpen() {
        if let open { draft.remove(open) }
        open = nil
    }

    /// Snaps the orb to the side nearest to where it was dropped.
    func dropOrb(at point: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        onRight = point.x > size.width / 2
        height = min(max(point.y / size.height, 0), 1)
    }

    func comment(of id: Draft.Pin.ID) -> Binding<String> {
        Binding(
            get: { self.draft.pins.first { $0.id == id }?.comment ?? "" },
            set: { text in
                if let index = self.draft.pins.firstIndex(where: { $0.id == id }) {
                    self.draft.pins[index].comment = text
                }
            })
    }
}
