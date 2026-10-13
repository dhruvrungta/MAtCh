import Foundation

/// `application/x-www-form-urlencoded` encoding with the exact rules the portal's
/// other clients use: `A–Z a–z 0–9 . - * _` pass through, a space becomes `+`, and
/// every other byte of the UTF-8 form is percent-encoded with uppercase hex.
enum FormEncoding {
    static func encode(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                output.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                output.append("+")
            default:
                output.append("%")
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return output
    }

    /// Joins already-ordered fields into a request body.
    static func body(_ fields: [(name: String, value: String)]) -> String {
        fields.map { "\($0.name)=\(encode($0.value))" }.joined(separator: "&")
    }

    private static let hexDigits = Array("0123456789ABCDEF")
}
