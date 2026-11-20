# Feedback for iOS and macOS

The Swift SDK for [Feedback](https://feedback.farbun.dev): people on your team
mark up a screenshot of your app, write a comment on each mark, and the item
lands in the Feedback inbox, and from there in your GitHub issues.

It does nothing for ordinary users of your app. It shows itself only when the
app asks, such as from a debug menu or a `yourapp://feedback` link, and only
people signed in with GitHub, on the service's allow list, can send.

Requires iOS 17 or macOS 14. No dependencies.

## Adding it to an app

1. Add the package: `https://github.com/farbun-dev/feedback-swift`, product
   `FeedbackKit`.
2. In the Feedback dashboard, open the app and add a native return address for
   each platform: `<your bundle identifier>:/feedback`, such as
   `com.example.shop:/feedback`. Nothing needs to be added to the app's
   Info.plist; the system sign-in sheet catches that address itself.
3. Configure it early, with the app's public key from the dashboard:

   ```swift
   import FeedbackKit

   @main
   struct ShopApp: App {
       init() {
           Feedback.configure(appKey: "pk_…")
       }

       var body: some Scene {
           WindowGroup {
               ContentView()
                   .onOpenURL { url in
                       // Before the app's own handling: it answers false for
                       // any link that is not yourapp://feedback.
                       if Feedback.handle(url) { return }
                       handleLink(url)
                   }
           }
       }
   }
   ```

4. Open it from somewhere only your team will find:

   ```swift
   Button("Send feedback") { Feedback.show() }
   ```

   Or pass `showOnGesture: true` to `configure`, and no button is needed: a
   two-finger triple tap anywhere opens the sheet on iOS, and
   Control-Option-Command-F on macOS. It works alongside the app's own
   gestures and cancels none of its touches.

   `Feedback.isAvailable` is true once someone has signed in on the device, if
   you want to show a button only then. `Feedback.handle(_:)` opens the sheet
   for the app's own `yourapp://feedback` link only; http and https links and
   other paths are left to the app.

   `baseURL` defaults to the hosted service, `https://feedback.farbun.dev`.

   **The commit.** Set it once and every item says which code it is about: add
   a `FeedbackCommit` key to the app's Info.plist with the value
   `$(CI_COMMIT)`, which Xcode Cloud defines (unverified: that the variable is
   expanded in Info.plist; a value still reading `$(…)` is ignored). Or pass
   `commit:` to `configure`.

## Naming screens and hiding private views

```swift
CheckoutView().feedbackScreen("Checkout")   // sent as the screen, with file and line
TextField("Card", text: $card).feedbackMasked()   // blanked out of screenshots
```

Screens and masks belong to the window they are in. When several named screens
are visible in the window at once, such as a split view, the last one to appear
is sent as the screen and all of them are listed in the environment.

UIKit and AppKit apps get their chain of view controllers sent automatically.

## What is sent

One upload to `POST /sdk/v1/apps/<key>/feedback` (version 1 of the request,
described in the service's `web/README.md`):

- the key window's screenshot, drawn by the app itself, so no screen-recording
  permission is asked for;
- each mark's comment and region, as fractions of the screenshot, and the
  comment about the whole screen;
- the screen's name and source location, app version, build number, bundle
  identifier, and the commit when you pass one;
- system version, device model, window size and scale, locale, light or dark
  appearance, and text size.

The server decides the platform from the sign-in.

## Sign-in and sending

- Sign-in is GitHub through the system sheet (`ASWebAuthenticationSession`),
  OAuth with PKCE. The token lasts 30 days and is kept in the Keychain on this
  device only.
- Signing out ends this device's sign-in only. The SDK never asks the server
  to end every session, which would also sign the person out of the dashboard.
- Each item is saved on the device before it is sent, with an idempotency key.
  One that cannot be sent (offline, server error, rate limit) is sent again
  later — after 30 seconds, 2 minutes, 10 minutes, then hourly, for up to a
  week — and the server never saves it twice. Items are retried when the app
  becomes active.

## Developing

```sh
swift test                              # unit tests, on macOS
xcodebuild test -scheme Feedback -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`Examples/Sample` is a small app for both platforms, with a UI test that marks
up a screenshot. Generate its project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd Examples/Sample && xcodegen && open Sample.xcodeproj
```

`EndToEndTests` sends one item to a running server when `FEEDBACK_E2E_URL`,
`FEEDBACK_E2E_KEY` and `FEEDBACK_E2E_TOKEN` are set, and is skipped otherwise.
