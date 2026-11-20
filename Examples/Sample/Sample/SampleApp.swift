import FeedbackKit
import SwiftUI

@main
struct SampleApp: App {
    init() {
        // Replace with your app's key. Its sign-in returns to
        // dev.farbun.feedback.sample:/feedback, which must be registered
        // for the app in the Feedback dashboard.
        Feedback.configure(
            appKey: ProcessInfo.processInfo.environment["FEEDBACK_APP_KEY"] ?? "pk_sample",
            baseURL: URL(string: "https://feedback.farbun.dev")!)
    }

    var body: some Scene {
        WindowGroup {
            CartView()
                .onOpenURL { Feedback.handle($0) }
        }
    }
}

struct CartView: View {
    @State private var card = "4242 4242 4242 4242"

    var body: some View {
        NavigationStack {
            List {
                Section("Your cart") {
                    LabeledContent("Rubber duck", value: "€4.00")
                    LabeledContent("Duck pond", value: "€12.50")
                    LabeledContent("Total", value: "€0.00").bold()
                }
                Section("Payment") {
                    TextField("Card number", text: $card)
                        .feedbackMasked()
                }
                Section {
                    Button("Send feedback") { Feedback.show() }
                }
            }
            .navigationTitle("Checkout")
            .feedbackScreen("Checkout")
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-showFeedback") {
                try? await Task.sleep(for: .seconds(1))
                Feedback.show()
            }
        }
    }
}
