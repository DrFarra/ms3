import SwiftUI
import WebKit

/// Checks every part of the app against the live site from this phone (the only place Cloudflare lets through)
/// and builds a report with the real data shapes, so fixes don't depend on guesses. Read-only: changes nothing.
struct DiagnosticsView: View {
    struct Check: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    @State private var checks: [Check] = []
    @State private var samples: [String] = []
    @State private var running = false
    @State private var sites: [HiddenSite] = []   // hidden pages must be in the window for their scripts to run

    private var report: String {
        let header = "Farmatotal app – diagnóstico \(Date().formatted())\n"
        let lines = checks.map { "\($0.ok ? "OK" : "FALLA") · \($0.name): \($0.detail)" }
        return header + lines.joined(separator: "\n") + "\n\n--- Muestras ---\n" + samples.joined(separator: "\n\n")
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Label(running ? "Revisando…" : "Revisar todo", systemImage: "stethoscope")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running)
            } footer: {
                Text("Prueba cada parte de la app contra el sitio real. No cambia nada (no agrega al carrito ni cambia la sucursal). Tarda hasta un minuto.")
            }
            if !checks.isEmpty {
                Section("Resultado") {
                    ForEach(checks) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(c.name, systemImage: c.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(c.ok ? .green : .red)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if !running {
                    Section {
                        ShareLink(item: report) { Label("Compartir informe", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = report } label: { Label("Copiar informe", systemImage: "doc.on.doc") }
                    }
                }
            }
        }
        .navigationTitle("Diagnóstico")
        .background {
            ForEach(sites, id: \.self) { HiddenWebView(webView: $0.webView).frame(width: 1, height: 1).opacity(0.01) }
        }
    }

    private func add(_ name: String, _ ok: Bool, _ detail: String) { checks.append(Check(name: name, ok: ok, detail: detail)) }

    private func sample(_ title: String, _ text: String?) { samples.append("[\(title)]\n" + String((text ?? "(vacío)").prefix(1500))) }

    private func run() async {
        running = true
        checks = []
        samples = []

        // Catalog (Store API through the in-app session)
        var first: Product?
        do {
            let r = try await API.products(ProductQuery(), page: 1)
            first = r.items.first
            add("Productos", !r.items.isEmpty, "\(r.items.count) en la página 1 de \(r.totalPages)")
        } catch { add("Productos", false, error.localizedDescription) }
        do {
            let r = try await API.products(ProductQuery(onSale: true, minDiscount: 50), page: 1)
            add("Ofertas 50%+", true, "\(r.items.count) en la primera página (filtro en el teléfono)")
        } catch { add("Ofertas 50%+", false, error.localizedDescription) }
        do {
            let r = try await API.products(ProductQuery(search: "ibuprofeno"), page: 1)
            add("Búsqueda", !r.items.isEmpty, "“ibuprofeno”: \(r.items.count) resultados")
        } catch { add("Búsqueda", false, error.localizedDescription) }
        if let sku = first?.sku, !sku.isEmpty {
            do {
                let r = try await API.products(ProductQuery(sku: sku), page: 1)
                add("Código de barras", r.items.contains { $0.id == first?.id }, "SKU \(sku): \(r.items.count) resultado(s)")
            } catch { add("Código de barras", false, error.localizedDescription) }
        }
        if let id = first?.id {
            do {
                let p = try await API.product(id: id)
                add("Ficha de producto", true, "\(p.title) · \(p.prices.current) · \(p.images.count) foto(s)")
                if let img = p.images.first.flatMap({ URL(string: $0.thumbnail ?? $0.src) }) {
                    let loaded = await ImageLoader.load(img)
                    add("Imágenes", loaded != nil, loaded == nil ? "no cargó \(img.lastPathComponent)" : "OK")
                }
            } catch { add("Ficha de producto", false, error.localizedDescription) }
        }
        do {
            let all = try await API.categories()
            let main = topLevel(all)
            add("Categorías", main.count >= 5, "\(main.count) principales de \(all.count): " + main.map(\.title).joined(separator: ", "))
        } catch { add("Categorías", false, error.localizedDescription) }
        do {
            let (c, r): (Cart, WebBridge.Response) = try await API.send(WebBridge.storeAPI + "/cart")
            add("Carrito", r.headers["nonce"] != nil, "\(c.itemsCount) artículo(s); permiso para modificar: \(r.headers["nonce"] != nil ? "sí" : "NO")")
        } catch { add("Carrito", false, error.localizedDescription) }

        // Branches: store-locator page and the branch popup, run hidden like the real screens do
        let locator = HiddenSite(path: "/sucursales/")
        let popup = HiddenSite(path: "/rastrear-pedido/")
        sites = [locator, popup]
        async let located = locator.places()
        let options = await popup.inventoryOptions()
        add("Selector de sucursal", options.count > 1, "\(options.count) sucursales: " + options.prefix(5).map(\.shortName).joined(separator: ", "))
        let withCoords = options.filter { $0.coordinate != nil }.count
        let popupPlaces = await popup.places(attempts: 8)
        add("Ubicación desde el selector", withCoords > 0 || !popupPlaces.isEmpty,
            "con coordenadas en la lista: \(withCoords); datos capturados: \(popupPlaces.count)")
        let stores = await located
        add("Página Sucursales", !stores.isEmpty, "\(stores.count) sucursales con ubicación" +
            (stores.first.map { " (ej.: \($0.title), \($0.address))" } ?? ""))
        add("Sucursal elegida", true, await WebBridge.selectedBranch(in: popup.webView) ?? "ninguna")

        // Raw shapes, so any mismatch can be fixed exactly
        sample("Producto (claves)", first.map { _ in "id, name, prices, images, categories… (decodificó bien)" })
        sample("Popup: primer elemento", await WebBridge.run(
            "return document.querySelector('.woocommerce-multi-inventory-popup-locations-location')?.outerHTML ?? ''",
            in: popup.webView) as? String)
        sample("Popup: datos capturados", await WebBridge.run("return JSON.stringify(window.__geo ?? []).slice(0, 1500)", in: popup.webView) as? String)
        sample("Sucursales: datos capturados", await WebBridge.run("return JSON.stringify(window.__geo ?? []).slice(0, 1500)", in: locator.webView) as? String)
        sample("Sucursales: scripts de la página", await WebBridge.run(
            "return [...document.scripts].map(s => s.src).filter(Boolean).filter(s => /store|locator|asl|inventory/i.test(s)).join('\\n')",
            in: locator.webView) as? String)

        sites = []
        running = false
    }
}
