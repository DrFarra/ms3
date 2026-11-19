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
