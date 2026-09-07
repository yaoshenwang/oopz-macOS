import Foundation

/// Compile-time literal boundaries keep arbitrary names, tokens, URLs and bodies out of logs.
/// Every interpolation is redacted, including values whose shape is not recognized as a secret.
struct DiagnosticMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let text: String
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(_ privateValue: T) { text += "[private]" }
    }
}
