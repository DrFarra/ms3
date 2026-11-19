import XCTest
@testable import Farmatotal

final class ModelTests: XCTestCase {
    /// Trimmed product as returned by /wp-json/wc/store/v1/products (values from the live site's Alergina page).
    static let productJSON = """
    {"id":27873,"name":"Alergina Jarabe Fco. X 100 Ml.","permalink":"https://www.farmatotal.com.py/producto/alergina-jarabe-fco-x-100-ml/",
     "sku":"7840653003828","short_description":"","description":"<h4>Indicaciones</h4><p>Rinitis al&eacute;rgica.</p>",
     "prices":{"price":"44700","regular_price":"54500","sale_price":"44700","currency_code":"PYG","currency_minor_unit":0},
     "images":[{"id":1,"src":"https://www.farmatotal.com.py/wp-content/uploads/a.jpg","thumbnail":"https://www.farmatotal.com.py/wp-content/uploads/a-300x300.jpg"}],
     "categories":[{"id":10,"name":"Cetirizina","slug":"cetirizina","link":"x"}],"tags":[{"id":5,"name":"General","slug":"general","link":"x"}],
     "is_in_stock":true,"low_stock_remaining":null,"add_to_cart":{"text":"Añadir","minimum":1,"maximum":9999,"multiple_of":1},
     "on_sale":true,"extensions":{}}
    """

    func testDecodesStoreAPIProduct() throws {
        let p = try JSONDecoder.wc.decode(Product.self, from: Data(Self.productJSON.utf8))
        XCTAssertEqual(p.title, "Alergina Jarabe Fco. X 100 Ml.")
        XCTAssertEqual(p.prices.current, "₲ 44.700")
        XCTAssertEqual(p.prices.regular, "₲ 54.500")
        XCTAssertEqual(p.prices.discountPercent, 18)        // the site shows 18%
        XCTAssertEqual(p.maxQuantity, 99)
        XCTAssertTrue(p.inStock)
        XCTAssertEqual(p.thumb, "https://www.farmatotal.com.py/wp-content/uploads/a-300x300.jpg")
        // Favorites/compare are stored with the encoder and must round-trip.
        let again = try JSONDecoder.wc.decode(Product.self, from: JSONEncoder.wc.encode(p))
        XCTAssertEqual(again, p)
    }

    func testHTMLPlain() {
        XCTAssertEqual("8&#215;4 Deo Pure Aqua".htmlPlain, "8×4 Deo Pure Aqua")
        XCTAssertEqual("M&amp;A <b>Mate</b>&nbsp;".htmlPlain, "M&A Mate")
        XCTAssertEqual("&#x41;B".htmlPlain, "AB")
    }

    func testPriceFormatting() {
        XCTAssertEqual(Gs.format("1096500"), "₲ 1.096.500")
        XCTAssertEqual(Gs.format(nil), "")
        XCTAssertNil(Prices(price: "100", regularPrice: "100", currencyMinorUnit: 0).discountPercent)
    }

    func testDiagnosisNamesTheBlocker() {
        let html = "<html><head><title>Attention Required! | Cloudflare</title></head>"
        let r = WebBridge.Response(status: 403, body: Data(html.utf8), headers: ["server": "cloudflare"])
        XCTAssertEqual(API.diagnosis(r), "\n(server: cloudflare · “Attention Required! | Cloudflare”)")
        XCTAssertEqual(API.diagnosis(WebBridge.Response(status: 403, body: Data(), headers: [:])), "")
        let moved = WebBridge.Response(status: 404, body: Data(), headers: [:],
                                       url: "https://www.farmatotal.com.py/inventory/casa-central/?x=1", redirected: true)
        XCTAssertEqual(API.diagnosis(moved), "\n(→ /inventory/casa-central/?x=1)")
    }

    func testQueryPath() {
        var q = ProductQuery(search: "ibuprofeno 400", category: 12, onSale: true, sort: .priceAsc, minPrice: 1000)
        XCTAssertEqual(q.path(page: 2),
                       "/wp-json/wc/store/v1/products?page=2&per_page=20&search=ibuprofeno%20400&category=12&on_sale=true&orderby=price&order=asc&min_price=1000")
        q = ProductQuery(sku: "7840653003828")
        XCTAssertEqual(q.path(page: 1), "/wp-json/wc/store/v1/products?page=1&per_page=20&sku=7840653003828")
    }
}
