import SwiftUI

/// The feedback sheet: the screenshot to mark up, a comment per mark, and a
/// comment about the whole screen.
struct ComposeView: View {
    let session: Session
    @State var draft: Draft
    let close: () -> Void

    @State private var result: Outbox.Outcome?
    @State private var busy = false
    @State private var signInError: String?
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let result, case .sent(let saved) = result {
                            sent(saved)
                        } else {
                            content
                        }
                    }
                    .padding()
                }
                // A new mark's comment field may be under the keyboard:
                // bring it into view, ready to type in.
                .onChange(of: draft.marks.count) { old, new in
                    guard new > old, let id = draft.marks.last?.id else { return }
                    focused = id
                    // After the new row is laid out, or there is nothing to scroll to.
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    // Parts

    private var header: some View {
        HStack {
            Text("Send feedback").font(.headline)
            Spacer()
            account
        }
        .padding()
    }

    @ViewBuilder private var account: some View {
        switch session.account {
        case .unknown:
            ProgressView().controlSize(.small)
        case .signedIn(let person):
            Text(person.githubLogin).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityLabel("Signed in as \(person.githubLogin)")
        case .signedOut:
            Button("Sign in with GitHub") { Task { await signIn() } }
        case .noAccess(let login):
            Text("\(login ?? "This account") may not send feedback here")
                .font(.subheadline).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var content: some View {
        if let signInError {
            Text(signInError).foregroundStyle(.red)
        }
        if let screenshot = draft.screenshot {
            #if os(macOS)
                let hint = "Click a spot or drag over an area to comment on it."
            #else
                let hint = "Tap a spot or drag over an area to comment on it."
            #endif
            Text(hint)
                .font(.subheadline).foregroundStyle(.secondary)
            MarkupView(screenshot: screenshot, marks: $draft.marks)
                // Small enough to leave the comments in view below it.
                .frame(maxWidth: .infinity, maxHeight: 380)
        }
        ForEach(Array($draft.marks.enumerated()), id: \.element.id) { index, $mark in
            HStack(alignment: .top) {
                MarkBadge(number: index + 1)
                TextField("What about this?", text: $mark.comment, axis: .vertical)
                    .focused($focused, equals: mark.id)
                    .lineLimit(1...6)
                Button {
                    draft.marks.removeAll { $0.id == mark.id }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove mark \(index + 1)")
            }
            .id(mark.id)
        }
        TextField(
            draft.marks.isEmpty ? "What's wrong, or what could be better?" : "Anything else?",
            text: $draft.overall, axis: .vertical
        )
        .lineLimit(3...10)
        .textFieldStyle(.roundedBorder)
        if let screen = draft.screen {
            Text("Screen: \(screen)").font(.caption).foregroundStyle(.secondary)
        }
        if let result {
            outcome(result)
        }
    }

    @ViewBuilder private func outcome(_ result: Outbox.Outcome) -> some View {
        switch result {
        case .waiting(let reason):
            Label("Saved on this device. It will be sent when it can (\(reason)).",
                  systemImage: "tray.and.arrow.up")
                .foregroundStyle(.orange)
        case .signedOut:
            Label(
                "Saved on this device. It will be sent once you sign in again.",
                systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .refused(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .sent:
            EmptyView()
        }
    }

    private func sent(_ saved: API.Saved) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Thanks, your feedback was sent.").font(.headline)
            if let url = saved.url {
                Link("Open in the inbox", destination: url)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack {
            if session.waiting > 0 {
                Text("\(session.waiting) waiting to send").font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if finished {
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await send() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSend || busy || isNoAccess)
            }
        }
        .padding()
    }

    /// Sent, or kept in the outbox to be sent later: either way this draft
    /// must not be sent again, or it would arrive twice.
    private var finished: Bool {
        switch result {
        case .sent?, .waiting?, .signedOut?: true
        default: false
        }
    }

    private var isNoAccess: Bool {
        if case .noAccess = session.account { return true }
        return false
    }

    // Actions

    private func signIn() async {
        signInError = nil
        do {
            try await session.signIn()
        } catch SignInError.cancelled {
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        if session.token == nil {
            await signIn()
            guard session.token != nil else { return }
        }
        result = await session.send(draft)
    }
}

struct MarkBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor))
    }
}

/// The screenshot, with its marks drawn over it. A tap adds a point, a drag
/// adds a rectangle.
struct MarkupView: View {
    let screenshot: Screenshot
    @Binding var marks: [Draft.Mark]

    @State private var dragging: CGRect?

    var body: some View {
        let size = screenshot.pointSize
        Image(decorative: screenshot.image, scale: screenshot.pixelSize.width / max(size.width, 1))
            .resizable()
            .aspectRatio(size, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let shown = proxy.size
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                            markView(mark.region.rect(in: shown), number: index + 1)
                        }
                        if let dragging {
                            Rectangle().stroke(Color.accentColor, lineWidth: 2)
                                .frame(width: dragging.width, height: dragging.height)
                                .offset(x: dragging.minX, y: dragging.minY)
                        }
                    }
                    .frame(width: shown.width, height: shown.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = CGRect(
                                    origin: value.startLocation, size: .zero
                                ).union(CGRect(origin: value.location, size: .zero))
                            }
                            .onEnded { value in
                                dragging = nil
                                let moved = hypot(value.translation.width, value.translation.height)
                                let rect =
                                    moved < 8
                                    ? CGRect(origin: value.startLocation, size: .zero)
                                    : CGRect(origin: value.startLocation, size: .zero)
                                        .union(CGRect(origin: value.location, size: .zero))
                                marks.append(Draft.Mark(region: Region(rect, in: shown)))
                            }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityElement()
            .accessibilityLabel("Screenshot of the screen")
            .accessibilityIdentifier("feedback-screenshot")
    }

    @ViewBuilder private func markView(_ rect: CGRect, number: Int) -> some View {
        if rect.width == 0 && rect.height == 0 {
            MarkBadge(number: number).offset(x: rect.minX - 11, y: rect.minY - 11)
        } else {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.accentColor.opacity(0.15))
                Rectangle().stroke(Color.accentColor, lineWidth: 2)
                MarkBadge(number: number).offset(x: -11, y: -11)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }
}
