import Foundation

/// A field of one of the site's HTML forms (address, account, password, sign-up, order tracking, contact),
/// read from the page so the app can show it natively and post back exactly what the site expects.
struct FormField: Identifiable, Hashable {
    enum Kind: String { case text, email, tel, number, password, select, radio, checkbox, textarea, hidden }
    struct Option: Hashable {
        let value: String
        let label: String
    }

    let name: String
    let kind: Kind
    let label: String
    let placeholder: String
    let required: Bool
    let options: [Option]
    var value: String

    var id: String { name }

    /// Rows produced by the page script: {name, type, label, placeholder, required, options: [[value, label]], value}.
    static func parse(_ rows: [[String: Any]]) -> [FormField] {
        rows.compactMap { r in
            guard let name = r["name"] as? String, !name.isEmpty else { return nil }
            let options = (r["options"] as? [[String]] ?? []).compactMap { $0.count == 2 ? Option(value: $0[0], label: $0[1]) : nil }
            let required = (r["required"] as? Bool) ?? ((r["required"] as? NSNumber)?.boolValue ?? false)
            return FormField(name: name, kind: Kind(rawValue: r["type"] as? String ?? "") ?? .text,
                             label: r["label"] as? String ?? "", placeholder: r["placeholder"] as? String ?? "",
                             required: required, options: options, value: r["value"] as? String ?? "")
        }
    }
}

struct SiteFormSpec {
    let action: String
    let submitLabel: String
    var fields: [FormField]

    /// What the browser would post: every field, but unchecked checkboxes are left out (as in HTML).
    var payload: [String: String] {
        var out: [String: String] = [:]
        for f in fields where !(f.kind == .checkbox && f.value.isEmpty) && out[f.name] == nil { out[f.name] = f.value }
        return out
    }

    /// Fields to show: not hidden ones, and the checkout's shipping fields only when "ship to a different address" is on.
    var visibleFields: [FormField] {
        let shipsElsewhere = fields.first { $0.name == "ship_to_different_address" }.map { !$0.value.isEmpty } ?? true
        return fields.filter { $0.kind != .hidden && (shipsElsewhere || !$0.name.hasPrefix("shipping_")) }
    }

    /// Required visible fields the user left empty (checked before posting, like the browser would).
    var missing: [String] {
        visibleFields.filter { $0.required && $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.label)
    }
}
