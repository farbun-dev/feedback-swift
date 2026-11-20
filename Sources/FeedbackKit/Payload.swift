import Foundation

/// What `POST /sdk/v1/apps/<key>/feedback` takes as its `payload` part.
///
/// This is version 1 of the request, fixed on 20 November 2026. Fields may
/// be added; none may change meaning. The server ignores fields it does not
/// know and decides the platform itself, from the sign-in.
struct FeedbackPayload: Codable, Equatable, Sendable {
    var screen: String?
    var appVersion: String?
    var buildNumber: String?
    var commit: String?
    var environment: [String: JSONValue]
    var annotations: [AnnotationPayload]

    enum CodingKeys: String, CodingKey {
        case screen
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case commit, environment, annotations
    }
}

struct AnnotationPayload: Codable, Equatable, Sendable {
    var comment: String
    /// The file name of one of the request's `files` parts.
    var screenshot: String?
    var region: Region?
    var target: [String: JSONValue]?
}

/// A part of the screenshot, as fractions of its width and height.
/// A width and height of zero mark a point.
public struct Region: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isPoint: Bool { width == 0 && height == 0 }

    /// The region of `rect` within a picture of `size`, clamped to it.
    init(_ rect: CGRect, in size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.standardized.intersection(bounds)
        let r = clipped.isNull ? CGRect(origin: rect.origin, size: .zero) : clipped
        func fraction(_ value: CGFloat, of whole: CGFloat) -> Double {
            whole > 0 ? min(max(Double(value / whole), 0), 1) : 0
        }
        x = fraction(r.minX, of: size.width)
        y = fraction(r.minY, of: size.height)
        width = fraction(r.width, of: size.width)
        height = fraction(r.height, of: size.height)
    }

    /// The same region in a picture of `size`.
    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width, y: y * size.height,
            width: width * size.width, height: height * size.height)
    }
}

/// Any JSON value, for the free-form `environment` and `target` fields.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
