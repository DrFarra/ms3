import Foundation

/// Farmatotal's stock service (the one its checkout uses to validate stock per branch). It is not behind
/// Cloudflare, so plain URLSession works. Branches are identified by the store's internal codes
/// (the values of the checkout's "Sucursal" field), not by the website's inventory IDs.
enum StockAPI {
    private static let url = URL(string: "https://api.farmatotal.com.py/farma/next/ecommerce/producto/stock")!

    /// Units of `sku` available at branch `code`.
    static func units(sku: String, branch code: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "STK_SUCURSAL": code,
            "STK_DETALLE": [["STK_ARTICULO": sku, "STK_CANT_SOL": 1]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try units(from: data)
    }

    /// Reply: {"success":true,"value":[{"stk_articulo":"…","stk_cant_act":2,…}]}
    static func units(from data: Data) throws -> Int {
        struct Reply: Decodable {
            struct Row: Decodable { let stk_cant_act: Int }
            let value: [Row]?
            let message: String?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let row = reply.value?.first else {
            throw APIError(message: reply.message ?? "Sin datos de stock", status: 0)
        }
        return max(0, row.stk_cant_act)
    }
}
