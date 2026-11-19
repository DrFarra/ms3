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

    func testRestRouteFallbackPath() {
        XCTAssertEqual(API.restRoute("/wp-json/wc/store/v1/products?page=1&per_page=20"),
                       "/?rest_route=/wc/store/v1/products&page=1&per_page=20")
        XCTAssertEqual(API.restRoute("/wp-json/wc/store/v1/cart"), "/?rest_route=/wc/store/v1/cart")
        XCTAssertNil(API.restRoute("/sucursales/"))
        let failed = WebBridge.Response(status: 404, body: Data(), headers: [:],
                                        url: "https://www.farmatotal.com.py/wp-json/wc/store/v1/products?page=1")
        XCTAssertEqual(API.diagnosis(failed), "\n(/wp-json/wc/store/v1/products)")
    }

    func testAddressMatchPairsBranches() {
        // Popup entry (from the user's screenshot) vs. store-locator entries.
        let candidates = ["Rio Apa Avda. Cacique Lambare Nº 2654 Esq. Rio Apa, Asunción",
                          "Terminal Avda. Fernando de la Mora 2416 c/ Cedro, Asunción",
                          "Casa Central Avda. Defensores del Chaco c/ Cerro Cora"]
        XCTAssertEqual(AddressMatch.best("Terminal - Avda. Dr. Fernando De La Mora 2416 Esq. Cedro", in: candidates), 1)
        XCTAssertEqual(AddressMatch.best("Rio Apa - Avda. Cacique Lambare Nº 2654", in: candidates), 0)
        XCTAssertNil(AddressMatch.best("Encarnación Centro", in: candidates))
        XCTAssertEqual(AddressMatch.streetPart("Avda. Dr. Fernando De La Mora 2416 Esq. Cedro"), "Avda. Dr. Fernando De La Mora 2416")
        XCTAssertEqual(AddressMatch.streetPart("Avda. República Argentina Nº 2670 c/ Concepción"), "Avda. República Argentina Nº 2670")
        XCTAssertEqual(AddressMatch.streetPart("Mcal. López 1234"), "Mcal. López 1234")
        XCTAssertEqual("<p>Agregar a favoritos</p>Texto".withoutWishlistNoise, "<p></p>Texto")
    }

    func testParsesCapturedBranches() throws {
        // Shapes like Agile Store Locator's (strings) and a taxonomy-style popup (numbers, other key names).
        let json = """
        [{"id":"7","title":"Terminal","street":"Avda. Fernando de la Mora 2416","city":"Asunción","lat":"-25.3001","lng":"-57.6102",
          "phone":"021 555","open_hours":"{\\"mon\\":[\\"7:00 AM - 10:00 PM\\"],\\"sun\\":\\"0\\"}"},
         {"term_id":12,"name":"Rio Apa","address":"Avda. Cacique Lambaré 2654","latitude":-25.31,"longitude":-57.63},
         {"title":"Sin coordenadas","lat":"","lng":""},
         {"title":"Terminal","lat":"-25.3","lng":"-57.6"}]
        """
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let b = Branch.parse(rows)
        XCTAssertEqual(b.map(\.title), ["Rio Apa", "Terminal"])          // invalid + duplicate dropped, sorted
        XCTAssertEqual(b[0].id, "12")
        XCTAssertEqual(b[0].lat, -25.31)
        XCTAssertEqual(b[1].address, "Avda. Fernando de la Mora 2416, Asunción")
        XCTAssertEqual(b[1].hours, "Lun: 7:00 AM - 10:00 PM\nDom: cerrado")
    }

    func testParsesBranchPopupEntries() {
        // Values as the live popup has them (from the on-device diagnostics report), whitespace included.
        let rows: [[String: Any]] = [
            ["id": "1697", "name": "Terminal - Avda. Dr. Fernando De La Mora 2416 Esq. Cedro",
             "lat": "-25.32742987804708", "lng": "-57.59585357056962",
             "address": "\n\t\t\t\t\tAvda. Dr. Fernando De La Mora 2416 Esq. Cedro\t\t\t\t", "distance": "1 km"],
            ["id": "1697", "name": "Terminal - duplicate"],                     // same inventory twice → once
            ["id": "1729", "name": "Rio Apa - Avda. Cacique Lambare Nº 2654", "lat": "", "lng": ""],
            ["id": "", "name": "sin id"],
        ]
        let o = InventoryOption.parse(rows)
        XCTAssertEqual(o.map(\.id), ["1697", "1729"])
        XCTAssertEqual(o[0].shortName, "Terminal")
        XCTAssertEqual(o[0].address, "Avda. Dr. Fernando De La Mora 2416 Esq. Cedro")
        XCTAssertEqual(o[0].lat, -25.32742987804708)
        XCTAssertEqual(o[0].siteDistance, "1 km")
        XCTAssertNil(o[1].coordinate)
        XCTAssertEqual(o[1].address, "Avda. Cacique Lambare Nº 2654")   // falls back to the part after " - "
    }

    func testQueryPath() {
        var q = ProductQuery(search: "ibuprofeno 400", category: 12, onSale: true, sort: .priceAsc, minPrice: 1000)
        XCTAssertEqual(q.path(page: 2),
                       "/wp-json/wc/store/v1/products?page=2&per_page=20&search=ibuprofeno%20400&category=12&on_sale=true&orderby=price&order=asc&min_price=1000")
        q = ProductQuery(sku: "7840653003828")
        XCTAssertEqual(q.path(page: 1), "/wp-json/wc/store/v1/products?page=1&per_page=20&sku=7840653003828")
    }
}
