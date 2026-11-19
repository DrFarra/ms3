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
        // The site answers /wp-json/* with its theme's 404 page (confirmed on device); ?rest_route= reaches the same API.
        let r = try await WebBridge.shared.request(restRoute(path) ?? path, method: method, json: json, headers: headers)
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
                     // URLComponents keeps the trailing "/" that URL.path drops.
                     r.redirected ? "→ " + (URLComponents(string: r.url).map { $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? r.url) : nil,
                     // Which address failed (without the query, to keep it short).
                     !r.redirected ? URLComponents(string: r.url).map(\.path).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } : nil]
            .compactMap { $0 }
        return parts.isEmpty ? "" : "\n(" + parts.joined(separator: " · ") + ")"
    }

    /// "/wp-json/wc/store/v1/cart?x=1" → "/?rest_route=/wc/store/v1/cart&x=1" (same API, entry point that skips /wp-json/ rewrites).
    nonisolated static func restRoute(_ path: String) -> String? {
        guard path.hasPrefix("/wp-json/") else { return nil }
        let rest = path.dropFirst("/wp-json".count)
        let parts = rest.split(separator: "?", maxSplits: 1)
        return "/?rest_route=" + parts[0] + (parts.count > 1 ? "&" + parts[1] : "")
    }

    static func products(_ query: ProductQuery, page: Int) async throws -> (items: [Product], totalPages: Int) {
        // Discount filters are applied on the device, so fetch bigger pages to find matches faster.
        let (items, r): ([Product], WebBridge.Response) = try await send(query.path(page: page, perPage: query.minDiscount == nil ? 20 : 60))
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
}
