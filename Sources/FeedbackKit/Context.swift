import Foundation

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// What the app's bundle says about the build.
struct BuildInfo: Equatable, Sendable {
    var appVersion: String?
    var buildNumber: String?
    var bundleID: String?

    static func of(_ bundle: Bundle) -> BuildInfo {
        BuildInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleID: bundle.bundleIdentifier)
    }
}

@MainActor
enum Context {
    /// The device, system and display settings, for the `environment` field.
    static func environment(window: PlatformWindow?, bundleID: String?) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "sdk": .string("feedback-swift \(Feedback.sdkVersion)"),
            "locale": .string(Locale.current.identifier),
            "device_model": .string(modelIdentifier()),
        ]
        if let bundleID { values["bundle_id"] = .string(bundleID) }
        #if canImport(UIKit)
            let device = UIDevice.current
            values["os"] = .string("\(device.systemName) \(device.systemVersion)")
            values["device"] = .string(device.model)
            if let window {
                values["window"] = size(window.bounds.size)
                values["scale"] = .number(Double(window.screen.scale))
                let traits = window.traitCollection
                values["appearance"] = traits.userInterfaceStyle == .dark ? "dark" : "light"
                values["text_size"] = .string(traits.preferredContentSizeCategory.rawValue)
                values["view_controllers"] = .array(
                    viewControllers(from: window.rootViewController).map { .string($0) })
            }
        #else
            let version = ProcessInfo.processInfo.operatingSystemVersion
            values["os"] = .string(
                "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
            if let window {
                values["window"] = size(window.contentLayoutRect.size)
                values["scale"] = .number(Double(window.backingScaleFactor))
                let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                values["appearance"] = dark ? "dark" : "light"
                if let root = window.contentViewController {
                    values["view_controllers"] = .array(
                        viewControllers(from: root).map { .string($0) })
                }
            }
        #endif
        let screens = Screens.shown(in: window)
        if let screen = screens.last {
            values["screen_source"] = .string("\(screen.file):\(screen.line)")
        }
        if screens.count > 1 {
            // Several at once, such as a split view: all of them, in order.
            values["screens"] = .array(
                screens.map { .string("\($0.name) (\($0.file):\($0.line))") })
        }
        return values
    }

    private static func size(_ size: CGSize) -> JSONValue {
        .object(["width": .number(Double(size.width)), "height": .number(Double(size.height))])
    }

    /// Such as "iPhone17,1" or "Mac16,10".
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
            if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
                return model + " (Simulator)"
            }
        #endif
        #if os(macOS)
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: &info.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        #endif
    }

    #if canImport(UIKit)
        /// The chain from the root to what is shown on top, by class name.
        static func viewControllers(from root: UIViewController?) -> [String] {
            var names: [String] = []
            var current = root
            while let controller = current, names.count < 20 {
                names.append(String(describing: type(of: controller)))
                if let presented = controller.presentedViewController {
                    current = presented
                } else if let navigation = controller as? UINavigationController {
                    current = navigation.visibleViewController
                } else if let tabs = controller as? UITabBarController {
                    current = tabs.selectedViewController
                } else {
                    current = nil
                }
            }
            return names
        }
    #else
        static func viewControllers(from root: NSViewController) -> [String] {
            var names = [String(describing: type(of: root))]
            var current = root.presentedViewControllers?.last
            while let controller = current, names.count < 20 {
                names.append(String(describing: type(of: controller)))
                current = controller.presentedViewControllers?.last
            }
            return names
        }
    #endif
}
