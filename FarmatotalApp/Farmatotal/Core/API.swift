import Foundation

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

@MainActor
enum API {
    private static var cachedCategories: [Category]?

    static func send<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                                   headers: [String: String] = [:]) async throws -> (T, WebBridge.Response) {
        let r = try await WebBridge.shared.request(path, method: method, json: json, headers: headers)
        guard (200..<300).contains(r.status) else {
            let message = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["message"] as? String
            throw APIError(message: message?.htmlPlain ?? "Error \(r.status) del servidor" + diagnosis(r), status: r.status)
        }
        return (try JSONDecoder.wc.decode(T.self, from: r.body), r)
    }

    /// Says who blocked a non-JSON error (Cloudflare check, Cloudflare block, web server…) so a screenshot is enough to diagnose it.
    nonisolated static func diagnosis(_ r: WebBridge.Response) -> String {
        let html = String(decoding: r.body.prefix(4000), as: UTF8.self)
        let title = html.range(of: "(?<=<title>)[^<]*", options: [.regularExpression, .caseInsensitive]).map { String(html[$0]).htmlPlain }
        let parts = [r.headers["cf-mitigated"].map { "cf-mitigated: \($0)" },
                     r.headers["server"].map { "server: \($0)" },
                     title.map { "“\($0)”" },
                     r.redirected ? "→ " + (URL(string: r.url).map { $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? r.url) : nil]
            .compactMap { $0 }
        return parts.isEmpty ? "" : "\n(" + parts.joined(separator: " · ") + ")"
    }

    static func products(_ query: ProductQuery, page: Int) async throws -> (items: [Product], totalPages: Int) {
        let (items, r): ([Product], WebBridge.Response) = try await send(query.path(page: page))
        // A scanned barcode is the SKU on this site; if no exact match, fall back to text search.
        if items.isEmpty, page == 1, let sku = query.sku {
            var q = query
            q.sku = nil
            q.search = sku
            return try await products(q, page: 1)
        }
        return (items, Int(r.headers["x-wp-totalpages"] ?? "") ?? 1)
    }

    static func product(id: Int) async throws -> Product {
        try await send(WebBridge.storeAPI + "/products/\(id)").0
    }

    static func categories() async throws -> [Category] {
        if let cachedCategories { return cachedCategories }
        let (all, _): ([Category], WebBridge.Response) = try await send(WebBridge.storeAPI + "/products/categories")
        cachedCategories = all
        return all
    }

    /// Branches come from the site's store-locator plugin (Agile Store Locator), which needs the page's nonce.
    static func branches() async throws -> [Branch] {
        let page = try await WebBridge.shared.request("/sucursales/")
        let html = String(decoding: page.body, as: UTF8.self)
        let rx = try Regex(#"ASL_REMOTE=\{[^}]*?"nonce":"([0-9a-f]+)""#)
        guard let nonce = html.firstMatch(of: rx)?.output[1].substring else {
            throw APIError(message: "No se pudo leer la lista de sucursales", status: 0)
        }
        let r = try await WebBridge.shared.request(
            "/wp-admin/admin-ajax.php?action=asl_load_stores&nonce=\(nonce)&load_all=1&layout=1")
        guard let rows = try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]] else {
            throw APIError(message: "No se pudo leer la lista de sucursales", status: r.status)
        }
        func str(_ d: [String: Any], _ k: String) -> String? {
            if let s = d[k] as? String, !s.isEmpty { return s.htmlPlain }
            if let n = d[k] as? NSNumber { return n.stringValue }
            return nil
        }
        return rows.compactMap { d in
            guard let lat = Double(str(d, "lat") ?? ""), let lng = Double(str(d, "lng") ?? "") else { return nil }
            return Branch(id: str(d, "id") ?? UUID().uuidString,
                          title: str(d, "title") ?? "Sucursal",
                          address: [str(d, "street"), str(d, "city")].compactMap { $0 }.joined(separator: ", "),
                          phone: str(d, "phone"),
                          email: str(d, "email"),
                          hours: hours(d["open_hours"]),
                          lat: lat, lng: lng)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// ASL stores hours as JSON like {"mon":["8:00 AM - 10:00 PM"],"sun":"0"}; "1" = open all day, "0" = closed.
    private static func hours(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            return s.htmlPlain.isEmpty ? nil : s.htmlPlain
        }
        let days = [("mon", "Lun"), ("tue", "Mar"), ("wed", "Mié"), ("thu", "Jue"), ("fri", "Vie"), ("sat", "Sáb"), ("sun", "Dom")]
        let lines = days.compactMap { (key: String, label: String) -> String? in
            switch dict[key] {
            case let list as [String]: return "\(label): \(list.joined(separator: ", "))"
            case let v as String: return v == "1" ? "\(label): abierto" : v == "0" ? "\(label): cerrado" : "\(label): \(v)"
            default: return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
