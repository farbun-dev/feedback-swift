import SwiftUI

/// The review sheet, opened from the orb: who is sending, the pins grouped
/// by screen with each screen's screenshot, a comment about the whole
/// thing, and Send or Discard.
struct ReviewView: View {
    let session: Session
    let review: Review
    /// Closes the sheet and leaves the orb out.
    let close: () -> Void
    /// Closes the sheet and reopens a pin's comment on its screen.
    let goTo: (Draft.Pin.ID) -> Void
    /// Puts the orb away: after sending, or to discard everything.
    let finish: () -> Void

    @State private var result: Outbox.Outcome?
    @State private var busy = false
    @State private var signInError: String?
    @State private var confirmDiscard = false

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

    private var draft: Draft { review.draft }

    private var form: some View {
        Form {
            Section { account } footer: {
                if let signInError { Text(signInError).foregroundStyle(.red) }
            }
            if draft.pins.isEmpty {
                Section {
                    #if os(macOS)
                        Text("No pins yet. Close this and Option-click anything to pin a comment.")
                    #else
                        Text("No pins yet. Close this and double tap anything to pin a comment.")
                    #endif
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(draft.shots.enumerated()), id: \.element.id) { index, shot in
                Section(shot.screen ?? "Screen \(index + 1)") { group(shot) }
            }
            Section("Anything else") {
                TextField(
                    "A comment about the whole thing", text: Bindable(review).draft.overall,
                    axis: .vertical
                )
                .lineLimit(3...10)
                .labelsHidden()
                .accessibilityIdentifier("feedback-overall")
            }
            if let result {
                Section { outcome(result) }
            }
            Section { details }
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            if !finished {
                Section {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                        .frame(maxWidth: .infinity)
                        .confirmationDialog(
                            "Discard all pins and comments?", isPresented: $confirmDiscard
                        ) {
                            Button("Discard", role: .destructive) { finish() }
                        }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One screen: its screenshot with the pins on it, and their comments.
    private func group(_ shot: Draft.Shot) -> some View {
        let pins = draft.pins.filter { $0.shot == shot.id }
        return HStack(alignment: .top, spacing: 12) {
            Thumbnail(shot: shot, pins: pins.map { ($0.point, draft.number(of: $0.id)) })
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pins) { pin in
                    let number = draft.number(of: pin.id)
                    Button { goTo(pin.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MarkBadge(number: number, small: true)
                                .alignmentGuide(.firstTextBaseline) {
                                    $0[VerticalAlignment.center] + 4
                                }
                            if pin.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No comment").foregroundStyle(.secondary)
                            } else {
                                Text(pin.comment).foregroundStyle(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(finished)
                    .accessibilityLabel("Pin \(number): \(pin.comment)")
                    .accessibilityIdentifier("feedback-comment-\(number)")
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var account: some View {
        switch session.account {
        case .unknown:
            ProgressView().controlSize(.small)
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
            }
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to send").font(.headline)
                Text(
                    "Only people with access to \(session.appName ?? "this app") can send feedback. Your pins are kept."
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

    private var details: some View {
        let version = [session.build.appVersion, session.build.buildNumber.map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let app = [session.appName, version.isEmpty ? nil : version].compactMap { $0 }
            .joined(separator: " ")
        return Text(
            (app.isEmpty ? "" : "\(app) · ")
                + "Sent with a screenshot of each screen, its name and device details.")
    }

    @ViewBuilder private func outcome(_ result: Outbox.Outcome) -> some View {
        switch result {
        case .waiting(let reason):
            Label(
                "Saved on this device. It will be sent when it can (\(reason)).",
                systemImage: "tray.and.arrow.up"
            )
            .foregroundStyle(.orange)
        case .signedOut:
            Label(
                "Saved on this device. It will be sent once you sign in again.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
        case .refused(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .sent:
            EmptyView()
        }
    }

    private func sent(_ saved: API.Saved) -> some View {
        let count = draft.files.count
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.white, .green)
            Text("Sent").font(.title2.bold())
            Text(count == 1 ? "One item, 1 screenshot" : "One item, \(count) screenshots")
                .foregroundStyle(.secondary)
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
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
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

/// A small picture of one screen's screenshot, with its pins as dots.
private struct Thumbnail: View {
    let shot: Draft.Shot
    let pins: [(point: Region, number: Int)]

    var body: some View {
        let screenshot = shot.screenshot
        let size = screenshot.pointSize
        let width: CGFloat = size.width > size.height ? 120 : 64
        Image(
            decorative: screenshot.image,
            scale: screenshot.pixelSize.width / max(size.width, 1)
        )
        .resizable()
        .aspectRatio(size, contentMode: .fit)
        .frame(width: width)
        .overlay {
            GeometryReader { proxy in
                ForEach(pins, id: \.number) { pin in
                    Circle().fill(.red)
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                        .frame(width: 9, height: 9)
                        .position(
                            x: pin.point.x * proxy.size.width, y: pin.point.y * proxy.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .accessibilityElement()
        .accessibilityLabel("Screenshot of \(shot.screen ?? "the screen")")
        .accessibilityIdentifier("feedback-screenshot")
    }
}

struct MarkBadge: View {
    let number: Int
    /// Drawn over the app, where it needs a ring to stand out.
    var ringed = false
    var small = false

    var body: some View {
        let side: CGFloat = small ? 18 : 22
        Text("\(number)")
            .font(small ? .caption2.bold() : .caption.bold())
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Circle().fill(.red))
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
