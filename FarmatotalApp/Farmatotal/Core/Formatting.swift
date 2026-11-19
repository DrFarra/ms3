import Foundation

enum Gs {
    private static let locale = Locale(identifier: "es_PY")

    /// Store API prices come as strings in the currency's minor unit (guaraní has 0 decimals).
    static func format(_ minorUnits: String?, minor: Int = 0) -> String {
        guard let s = minorUnits, let v = Double(s) else { return "" }
        let value = v / pow(10, Double(minor))
        return "₲ " + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
}

extension String {
    /// Strips tags and decodes HTML entities (WooCommerce sends names like "8&#215;4 Deo").
    var htmlPlain: String {
        var s = replacingOccurrences(of: "<br ?/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
        for (k, v) in ["&quot;": "\"", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        while let r = s.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let code = s[r].dropFirst(2).dropLast()
            let n = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            var replacement = ""
            if let n, let u = UnicodeScalar(n) { replacement = String(Character(u)) }
            s.replaceSubrange(r, with: replacement)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
