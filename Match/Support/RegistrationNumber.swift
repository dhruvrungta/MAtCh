import Foundation

/// The shape of a VIT registration number, e.g. `25BIT0088`.
enum RegistrationNumber {
    static let example = "25BIT0088"

    /// Trims and uppercases. Does not strip punctuation.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// `value` must already be normalized.
    static func isValid(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 9 else { return false }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
        func isUpper(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) }
        return scalars[0..<2].allSatisfy(isDigit)
            && scalars[2..<5].allSatisfy(isUpper)
            && scalars[5..<9].allSatisfy(isDigit)
    }
}
