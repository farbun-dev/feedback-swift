import SwiftUI

/// Screens named with `.feedbackScreen(_:)`, the one shown last on top.
@MainActor
enum Screens {
    struct Entry: Equatable {
        let id: UUID
        let name: String
        let file: String
        let line: Int
    }

    static var shown: [Entry] = []
    static var current: Entry? { shown.last }
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

    func body(content: Content) -> some View {
        content
            .onAppear {
                Screens.shown.removeAll { $0.id == id }
                Screens.shown.append(.init(id: id, name: name, file: file, line: line))
            }
            .onDisappear { Screens.shown.removeAll { $0.id == id } }
    }
}

private struct Masked: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { Masks.registered[id] = (nil, proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            Masks.registered[id] = (nil, frame)
                        }
                }
            )
            .onDisappear { Masks.registered[id] = nil }
    }
}
