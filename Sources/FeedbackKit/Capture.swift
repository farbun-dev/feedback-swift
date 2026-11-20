import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
    typealias PlatformWindow = UIWindow
#else
    import AppKit
    typealias PlatformWindow = NSWindow
#endif

/// A picture of the app's own window, taken without asking for any
/// permission: the app draws its views into an image.
struct Screenshot: @unchecked Sendable {
    let image: CGImage
    /// The window's size in points. A region is relative to this.
    let pointSize: CGSize

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    func png() -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

@MainActor
enum Capture {
    static func keyWindow() -> PlatformWindow? {
        #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows =
                scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
                + scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first
        #else
            return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
        #endif
    }

    /// The key window as it looks now, with masked views blanked out.
    static func screenshot() -> Screenshot? {
        guard let window = keyWindow() else { return nil }
        #if canImport(UIKit)
            let bounds = window.bounds
            let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
            let picture = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            guard let image = picture.cgImage else { return nil }
            let size = bounds.size
        #else
            guard let view = window.contentView else { return nil }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            view.cacheDisplay(in: bounds, to: rep)
            guard let image = rep.cgImage else { return nil }
            let size = bounds.size
        #endif
        let masked = blank(Masks.frames(in: window), in: image, pointSize: size) ?? image
        return Screenshot(image: masked, pointSize: size)
    }

    /// `image` with each of `rects`, in points from the top left, painted over.
    nonisolated static func blank(_ rects: [CGRect], in image: CGImage, pointSize: CGSize) -> CGImage? {
        guard !rects.isEmpty, pointSize.width > 0 else { return image }
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        // Core Graphics counts from the bottom left; regions from the top left.
        let scale = CGFloat(width) / pointSize.width
        context.setFillColor(gray: 0.5, alpha: 1)
        for rect in rects {
            let r = CGRect(
                x: rect.minX * scale, y: CGFloat(height) - rect.maxY * scale,
                width: rect.width * scale, height: rect.height * scale)
            context.fill(r.intersection(full))
        }
        return context.makeImage()
    }
}

/// Views marked with `.feedbackMasked()`, by their frame in the window.
@MainActor
enum Masks {
    static var registered: [UUID: (window: ObjectIdentifier?, frame: CGRect)] = [:]

    static func frames(in window: PlatformWindow) -> [CGRect] {
        let id = ObjectIdentifier(window)
        return registered.values.filter { $0.window == nil || $0.window == id }.map(\.frame)
    }
}
