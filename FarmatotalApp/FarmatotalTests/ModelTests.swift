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

    func testStockReply() throws {
        // Replies captured from api.farmatotal.com.py.
        let ok = #"{"success":true,"value":[{"stk_articulo":"7840653003828","stk_descripcion":"ALERGINA JARABE FCO. X 100 ML.","stk_cant_act":21,"stk_cant_sol":1,"stk_sucursal":99,"has_stock":"true"}]}"#
        XCTAssertEqual(try StockAPI.units(from: Data(ok.utf8)), 21)
        let missing = #"{"success":false,"message":"STK_DETALLE vac¿o"}"#
        XCTAssertThrowsError(try StockAPI.units(from: Data(missing.utf8)))
    }

    func testBranchNameMatching() {
        let names = ["Terminal - Avda. Dr. Fernando De La Mora 2416 Esq. Cedro", "Rio Apa - Avda. Cacique Lambare Nº 2654",
                     "Medicos Del Chaco - Avda. Médicos Del Chaco 433"]
        XCTAssertEqual(AddressMatch.bestName("TERMINAL", in: names), 0)                 // checkout often uses short names
        XCTAssertEqual(AddressMatch.bestName("Farmatotal Río Apa", in: names), 1)
        XCTAssertEqual(AddressMatch.bestName("Médicos del Chaco", in: names), 2)
        XCTAssertNil(AddressMatch.bestName("Encarnación", in: names))
    }

    func testSiteFormPayload() {
        // Shaped like the site's billing-address form (fields from the user's screenshot).
        let rows: [[String: Any]] = [
            ["name": "billing_first_name", "type": "text", "label": "Nombres y Apellidos / Razón Social", "required": true, "value": ""],
            ["name": "billing_tipo_doc", "type": "radio", "label": "Tipo de Documento", "required": NSNumber(value: true),
             "options": [["1", "Cédula"], ["2", "RUC"]], "value": "1"],
            ["name": "billing_country", "type": "select", "label": "País / Región", "options": [["PY", "Paraguay"]], "value": "PY"],
            ["name": "newsletter", "type": "checkbox", "label": "Recibir ofertas", "options": [["1", ""]], "value": ""],
            ["name": "woocommerce-edit-address-nonce", "type": "hidden", "value": "abc123"],
            ["name": "save_address", "type": "hidden", "value": "Guardar dirección"],
            ["name": "", "type": "text"],
            ["name": "weird", "type": "date", "value": "x"],
        ]
        var spec = SiteFormSpec(action: "https://www.farmatotal.com.py/mi-cuenta/edit-address/facturacion/", submitLabel: "Guardar", fields: FormField.parse(rows))
        XCTAssertEqual(spec.fields.count, 7)
        XCTAssertEqual(spec.fields[1].kind, .radio)
        XCTAssertTrue(spec.fields[1].required)
        XCTAssertEqual(spec.fields[1].options.map(\.label), ["Cédula", "RUC"])
        XCTAssertEqual(spec.fields[6].kind, .text)                         // unknown types become text
        XCTAssertEqual(spec.missing, ["Nombres y Apellidos / Razón Social"])
        XCTAssertNil(spec.payload["newsletter"])                           // unchecked checkbox not sent
        XCTAssertEqual(spec.payload["woocommerce-edit-address-nonce"], "abc123")
        XCTAssertEqual(spec.payload["save_address"], "Guardar dirección")
        spec.fields[0].value = "Silva Emilio"
        spec.fields[3].value = "1"
        XCTAssertTrue(spec.missing.isEmpty)
        XCTAssertEqual(spec.payload["newsletter"], "1")

        // Checkout: shipping fields only count when "ship to a different address" is checked.
        var checkout = SiteFormSpec(action: "", submitLabel: "Realizar pedido", fields: FormField.parse([
            ["name": "billing_first_name", "type": "text", "label": "Nombre", "required": true, "value": "Ana"],
            ["name": "ship_to_different_address", "type": "checkbox", "label": "¿Enviar a otra dirección?", "options": [["1", ""]], "value": ""],
            ["name": "shipping_address_1", "type": "text", "label": "Dirección de envío", "required": true, "value": ""],
        ]))
        XCTAssertEqual(checkout.visibleFields.map(\.name), ["billing_first_name", "ship_to_different_address"])
        XCTAssertTrue(checkout.missing.isEmpty)
        checkout.fields[1].value = "1"
        XCTAssertEqual(checkout.missing, ["Dirección de envío"])
    }

    func testQueryPath() {
        var q = ProductQuery(search: "ibuprofeno 400", category: 12, onSale: true, sort: .priceAsc, minPrice: 1000)
        XCTAssertEqual(q.path(page: 2),
                       "/wp-json/wc/store/v1/products?page=2&per_page=20&search=ibuprofeno%20400&category=12&on_sale=true&orderby=price&order=asc&min_price=1000")
        q = ProductQuery(sku: "7840653003828")
        XCTAssertEqual(q.path(page: 1), "/wp-json/wc/store/v1/products?page=1&per_page=20&sku=7840653003828")
    }
}
