import SwiftUI

/// The feedback sheet: who is sending, the screenshot to mark up, a comment
/// per mark, and a comment about the whole screen.
struct ComposeView: View {
    let session: Session
    @State var draft: Draft
    let close: () -> Void

    @State private var result: Outbox.Outcome?
    @State private var busy = false
    @State private var signInError: String?
    @FocusState private var focused: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let result, case .sent(let saved) = result {
                    sent(saved)
                } else {
                    form
                }
            }
            .navigationTitle("Feedback")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    // Parts

    private var form: some View {
        ScrollViewReader { proxy in
            Form {
                Section { account } footer: {
                    if let signInError { Text(signInError).foregroundStyle(.red) }
                }
                if let screenshot = draft.screenshot {
                    Section {
                        // The hint shares the row so the screenshot stays its
                        // own accessibility element, framed to the image.
                        VStack(spacing: 10) {
                            MarkupView(screenshot: screenshot, marks: $draft.marks)
                                // Large, but short enough to leave the first comment in view.
                                .frame(maxWidth: .infinity, maxHeight: 460)
                            #if os(macOS)
                                Text("Click a spot or drag over an area to add a mark.")
                            #else
                                Text("Tap a spot or drag over an area to add a mark.")
                            #endif
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    }
                }
                if !draft.marks.isEmpty {
                    Section("Marks") {
                        ForEach(Array($draft.marks.enumerated()), id: \.element.id) {
                            index, $mark in
                            markRow(index: index, mark: $mark)
                        }
                    }
                }
                Section(draft.marks.isEmpty ? "What's wrong, or what could be better?" : "Anything else") {
                    TextField(
                        draft.marks.isEmpty ? "Describe it" : "About the whole screen",
                        text: $draft.overall, axis: .vertical
                    )
                    .lineLimit(3...10)
                    .labelsHidden()
                }
                if let result {
                    Section { outcome(result) }
                }
                Section {} footer: { details }
            }
            .formStyle(.grouped)
            // A new mark's comment field may be under the keyboard:
            // bring it into view, ready to type in.
            .onChange(of: draft.marks.count) { old, new in
                guard new > old, let id = draft.marks.last?.id else { return }
                // After the new row is laid out, or there is nothing to focus
                // or scroll to.
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    focused = id
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private var account: some View {
        switch session.account {
        case .unknown:
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
                screenPill
            }
        case .signedIn(let person):
            HStack(spacing: 10) {
                Avatar(person: person)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name.isEmpty ? person.githubLogin : person.name)
                    Text(person.githubLogin).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed in as \(person.githubLogin)")
                Spacer()
                screenPill
            }
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to send").font(.headline)
                Text(
                    "Only people with access to \(session.appName ?? "this app") can send feedback. Your marks are kept."
                )
                .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await signIn() }
                } label: {
                    Text("Continue with GitHub").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.vertical, 4)
        case .noAccess(let login):
            Label(
                "\(login ?? "This account") may not send feedback here",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var screenPill: some View {
        if let screen = draft.screen {
            Text(screen)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
                .accessibilityLabel("Screen: \(screen)")
        }
    }

    private func markRow(index: Int, mark: Binding<Draft.Mark>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MarkBadge(number: index + 1).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            TextField("What about this mark?", text: mark.comment, axis: .vertical)
                .focused($focused, equals: mark.wrappedValue.id)
                .lineLimit(1...6)
                // On macOS a form shows the title as a label; keep it a placeholder.
                .labelsHidden()
            Button {
                let id = mark.wrappedValue.id
                withAnimation { draft.marks.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove mark \(index + 1)")
        }
        .id(mark.wrappedValue.id)
    }

    private var details: some View {
        let version = [session.build.appVersion, session.build.buildNumber.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let app = [session.appName, version.isEmpty ? nil : version].compactMap { $0 }
            .joined(separator: " ")
        return Text(
            (app.isEmpty ? "" : "\(app) · ")
                + "Sent with the screenshot, the screen's name and device details.")
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
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.white, .green)
            Text("Sent").font(.title2.bold())
            Text("Thanks for the feedback.").foregroundStyle(.secondary)
            if let url = saved.url {
                Link(destination: url) { Text("Open in the inbox").padding(.horizontal, 8) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if finished {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
            }
            if session.waiting > 0 {
                ToolbarItem(placement: .status) {
                    Text("\(session.waiting) waiting to send").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Send") { Task { await send() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.canSend || isNoAccess)
                }
            }
        }
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
    /// Drawn over the screenshot, where it needs a ring to stand out.
    var ringed = false

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor))
            .overlay { if ringed { Circle().stroke(.white, lineWidth: 2) } }
            .shadow(color: .black.opacity(ringed ? 0.3 : 0), radius: 3, y: 1)
    }
}

/// The signed-in person's GitHub picture, or their initial until it loads.
struct Avatar: View {
    let person: API.Person

    var body: some View {
        AsyncImage(url: URL(string: person.avatarURL)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String((person.name.isEmpty ? person.githubLogin : person.name).prefix(1)))
                .font(.subheadline.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.indigo)
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .accessibilityHidden(true)
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            // The marks are drawn unclipped, so badges at the edge stay whole.
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
            .accessibilityElement()
            .accessibilityLabel("Screenshot of the screen")
            .accessibilityIdentifier("feedback-screenshot")
    }

    @ViewBuilder private func markView(_ rect: CGRect, number: Int) -> some View {
        if rect.width == 0 && rect.height == 0 {
            MarkBadge(number: number, ringed: true).offset(x: rect.minX - 11, y: rect.minY - 11)
        } else {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
                MarkBadge(number: number, ringed: true).offset(x: -11, y: -11)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }
}
