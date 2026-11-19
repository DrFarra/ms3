import Foundation
import CoreLocation

// Shapes follow the WooCommerce Store API (/wp-json/wc/store/v1), decoded with convertFromSnakeCase.

struct WCImage: Codable, Hashable {
    let src: String
    let thumbnail: String?
}

struct Term: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    var title: String { name.htmlPlain }
}

struct Prices: Codable, Hashable {
    let price: String
    let regularPrice: String?
    let currencyMinorUnit: Int?

    var current: String { Gs.format(price, minor: currencyMinorUnit ?? 0) }
    var regular: String { Gs.format(regularPrice, minor: currencyMinorUnit ?? 0) }
    var discountPercent: Int? {
        guard let r = Double(regularPrice ?? ""), let p = Double(price), r > 0, r > p else { return nil }
        return Int(((r - p) / r * 100).rounded())
    }
}

struct Product: Codable, Hashable, Identifiable {
    struct AddToCart: Codable, Hashable { let maximum: Int? }

    let id: Int
    let name: String
    let permalink: String?
    let sku: String?
    let shortDescription: String?
    let description: String?
    let prices: Prices
    let images: [WCImage]
    let categories: [Term]?
    let tags: [Term]?
    let isInStock: Bool?
    let lowStockRemaining: Int?
    let addToCart: AddToCart?

    var title: String { name.htmlPlain }
    var thumb: String? { images.first?.thumbnail ?? images.first?.src }
    var inStock: Bool { isInStock ?? true }
    var maxQuantity: Int { max(1, min(addToCart?.maximum ?? 99, 99)) }
}

struct Category: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let parent: Int
    let count: Int

    var title: String { name.htmlPlain }

    /// The site's own category menu; other top-level categories are active ingredients created by mistake.
    static let mainMenu = ["medicamentos", "belleza", "higiene-personal", "mamas-y-bebes", "nutricion-y-deporte",
                           "fragancias", "infantiles", "bazar-y-hogar", "ofertas"]

    var symbol: String {
        switch slug {
        case "bazar-y-hogar": "house"
        case "belleza": "sparkles"
        case "fragancias": "drop"
        case "higiene-personal": "hands.sparkles"
        case "infantiles": "teddybear"
        case "mamas-y-bebes": "stroller"
        case "medicamentos": "pills"
        case "nutricion-y-deporte": "figure.run"
        case "ofertas": "tag"
        default: "square.grid.2x2"
        }
    }
}

struct Cart: Codable {
    struct Item: Codable, Hashable {
        let key: String
        let id: Int
        let quantity: Int
        let name: String
        let images: [WCImage]
        let prices: Prices
        let totals: LineTotals
        let quantityLimits: Limits?
        var title: String { name.htmlPlain }
        var maxQuantity: Int { max(1, min(quantityLimits?.maximum ?? 99, 99)) }
    }
    struct LineTotals: Codable, Hashable {
        let lineTotal: String?
        let currencyMinorUnit: Int?
    }
    struct Limits: Codable, Hashable { let maximum: Int? }
    struct Totals: Codable {
        let totalItems: String?
        let totalDiscount: String?
        let totalPrice: String?
        let currencyMinorUnit: Int?
    }

    let items: [Item]
    let totals: Totals
    let itemsCount: Int
}

struct Branch: Identifiable, Hashable {
    let id: String
    let title: String
    let address: String
    let phone: String?
    let email: String?
    let hours: String?
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    func distance(from here: CLLocation) -> CLLocationDistance { here.distance(from: CLLocation(latitude: lat, longitude: lng)) }
}

struct ProductQuery: Hashable {
    enum Sort: String, CaseIterable, Hashable {
        case standard = "Predeterminado"
        case popularity = "Más vendidos"
        case latest = "Más nuevos"
        case priceAsc = "Precio: menor a mayor"
        case priceDesc = "Precio: mayor a menor"

        var params: (String, String)? {
            switch self {
            case .standard: nil
            case .popularity: ("popularity", "desc")
            case .latest: ("date", "desc")
            case .priceAsc: ("price", "asc")
            case .priceDesc: ("price", "desc")
            }
        }
    }

    var search: String?
    var category: Int?
    var tag: Int?
    var sku: String?
    var onSale = false
    var sort: Sort = .standard
    var minPrice: Int?
    var maxPrice: Int?
    /// Not a Store API filter: applied on the device (like the site's /catalogo/?descuento=N, which shows ≥ N%).
    var minDiscount: Int?

    func keeps(_ p: Product) -> Bool { minDiscount.map { (p.prices.discountPercent ?? 0) >= $0 } ?? true }

    func path(page: Int, perPage: Int = 20) -> String {
        var q = [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "per_page", value: "\(perPage)")]
        if let search, !search.isEmpty { q.append(.init(name: "search", value: search)) }
        if let category { q.append(.init(name: "category", value: "\(category)")) }
        if let tag { q.append(.init(name: "tag", value: "\(tag)")) }
        if let sku { q.append(.init(name: "sku", value: sku)) }
        if onSale { q.append(.init(name: "on_sale", value: "true")) }
        if let p = sort.params {
            q.append(.init(name: "orderby", value: p.0))
            q.append(.init(name: "order", value: p.1))
        }
        if let minPrice { q.append(.init(name: "min_price", value: "\(minPrice)")) }
        if let maxPrice { q.append(.init(name: "max_price", value: "\(maxPrice)")) }
        var c = URLComponents()
        c.path = WebBridge.storeAPI + "/products"
        c.queryItems = q
        return c.string!
    }
}

extension JSONDecoder {
    static let wc: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONEncoder {
    static let wc: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

extension Branch {
    /// Builds branches from JSON that the site's own scripts loaded (store locator, branch popup).
    /// Key names differ per plugin, so fields are found by name pattern.
    static func parse(_ rows: [[String: Any]]) -> [Branch] {
        func value(_ d: [String: Any], _ pattern: String) -> String? {
            for (k, v) in d where k.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                if let s = v as? String, !s.isEmpty { return s.htmlPlain }
                if let n = v as? NSNumber { return n.stringValue }
            }
            return nil
        }
        var seen = Set<String>()
        return rows.compactMap { d in
            guard let lat = Double(value(d, "^lat(itude)?$") ?? ""), let lng = Double(value(d, "^(lng|lon|long|longitude)$") ?? ""),
                  lat != 0 || lng != 0,
                  let title = value(d, "^(title|name|term_name|label|store_name)$"), seen.insert(title).inserted
            else { return nil }
            return Branch(id: value(d, "^(id|term_id|store_id)$") ?? title,
                          title: title,
                          address: [value(d, "^(street|address)$"), value(d, "^city$")].compactMap { $0 }.joined(separator: ", "),
                          phone: value(d, "^(phone|tel|telephone)$"),
                          email: value(d, "^email$"),
                          hours: formatHours(d["open_hours"] ?? d["hours"]),
                          lat: lat, lng: lng)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Store-locator hours come as JSON like {"mon":["8:00 AM - 10:00 PM"],"sun":"0"}; "1" = open all day, "0" = closed.
    static func formatHours(_ raw: Any?) -> String? {
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

/// One branch as offered by the site's own selector (multi-inventory plugin). `id` is the site's inventory ID,
/// the same one its "?inventory=<id>" links use.
struct InventoryOption: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let siteDistance: String?
    var lat: Double?
    var lng: Double?

    var shortName: String { name.components(separatedBy: " - ").first ?? name }
    var coordinate: CLLocationCoordinate2D? { lat.flatMap { la in lng.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } } }
    func distance(from here: CLLocation) -> CLLocationDistance? {
        coordinate.map { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
    }

    /// Rows read from the popup's entries: <a data-id data-name data-lat data-lng> plus address and distance text.
    static func parse(_ rows: [[String: Any]]) -> [InventoryOption] {
        func clean(_ v: Any?) -> String { ((v as? String) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var seen = Set<String>()
        return rows.compactMap { r in
            let id = clean(r["id"]), name = clean(r["name"])
            guard !id.isEmpty, !name.isEmpty, seen.insert(id).inserted else { return nil }
            let address = clean(r["address"]), distance = clean(r["distance"])
            return InventoryOption(id: id, name: name,
                                   address: address.isEmpty ? name.components(separatedBy: " - ").dropFirst().joined(separator: " - ") : address,
                                   siteDistance: distance.isEmpty ? nil : distance,
                                   lat: Double(clean(r["lat"])), lng: Double(clean(r["lng"])))
        }
    }
}
