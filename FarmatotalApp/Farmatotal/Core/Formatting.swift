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

extension String {
    /// The site's wishlist plugin injects "Agregar a favoritos" into product descriptions.
    var withoutWishlistNoise: String {
        replacingOccurrences(of: "(?i)agregar a favoritos|add to wishlist", with: "", options: .regularExpression)
    }
}

/// Pairs the site's branch selector entries with store-locator entries (which have coordinates) by shared address words.
enum AddressMatch {
    private static let stopWords: Set<String> = ["avda", "avenida", "esq", "casi", "entre", "nro", "con", "del", "las", "los", "calle", "sucursal", "farmatotal"]

    static func words(_ s: String) -> Set<String> {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    /// "Avda. Dr. Fernando De La Mora 2416 Esq. Cedro" → "Avda. Dr. Fernando De La Mora 2416": geocoders handle the street + number, not the corner.
    static func streetPart(_ address: String) -> String {
        let cut = address.range(of: #"\s+(esq\.?|esquina|c/|casi|entre)\s"#, options: [.regularExpression, .caseInsensitive])
        return String(address[..<(cut?.lowerBound ?? address.endIndex)]).trimmingCharacters(in: .whitespaces)
    }

    /// Index of the candidate sharing the most words with `target`; needs at least 2 in common to avoid false matches.
    static func best(_ target: String, in candidates: [String]) -> Int? {
        let t = words(target)
        let scored = candidates.enumerated().map { ($0.offset, words($0.element).intersection(t).count) }
        guard let top = scored.max(by: { $0.1 < $1.1 }), top.1 >= 2 else { return nil }
        return top.0
    }
}
