import SwiftUI
import MapKit
import WebKit
import CoreLocation

/// A site page running hidden in the app. It lets the site's own scripts do their work: the branch popup
/// (read its list, click an entry so the site stores the branch) and the store locator (its branch list).
@MainActor @Observable
final class HiddenSite: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    private var pageLoaded = false

    /// Keeps every JSON response the page's scripts receive that contains a list of places (objects with "lat…"),
    /// so we get the branch data exactly as the site loads it, without knowing each plugin's request format.
    private static let captureScript = """
    (() => {
      window.__geo = [];
      const hasLat = o => o && typeof o === 'object' && Object.keys(o).some(k => /^lat/i.test(k));
      const walk = v => {
        if (Array.isArray(v)) { if (v.some(hasLat)) window.__geo.push(v.filter(hasLat)); else v.forEach(walk); }
        else if (v && typeof v === 'object') {
          const vals = Object.values(v);
          if (vals.length && vals.every(hasLat)) window.__geo.push(vals); else vals.forEach(walk);
        }
      };
      // Branch-popup responses carry HTML (<a data-id data-lat …>) rather than JSON: keep those raw, with the request.
      window.__raw = [];
      const keep = (t, req) => {
        try { walk(JSON.parse(t)); } catch (e) {}
        if (typeof t === 'string' && /data-lat|inventor/i.test(t)) window.__raw.push({ req, body: t.slice(0, 300000) });
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u, ...rest) { this.__req = m + ' ' + u; return open.call(this, m, u, ...rest); };
      XMLHttpRequest.prototype.send = function (...a) {
        const req = (this.__req || '') + (typeof a[0] === 'string' ? ' body=' + a[0].slice(0, 300) : '');
        this.addEventListener('load', () => { try { keep(this.responseText, req); } catch (e) {} });
        return send.apply(this, a);
      };
      const f = window.fetch;
      window.fetch = async (...a) => {
        const r = await f(...a);
        r.clone().text().then(t => keep(t, 'fetch ' + String(a[0]))).catch(() => {});
        return r;
      };
    })();
    """

    init(path: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: path, relativeTo: WebBridge.site)!))
    }

    /// Branches with coordinates that the page's scripts loaded (polls every 250 ms, `attempts` times).
    func places(attempts: Int = 60) async -> [Branch] {
        guard await waitForPage() else { return [] }
        for _ in 0..<attempts {
            let raw = await WebBridge.run("return window.__geo ?? []", in: webView) as? [[[String: Any]]] ?? []
            let found = Branch.parse(raw.flatMap { $0 })
            if !found.isEmpty { return found }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return []
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageLoaded = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }

    private func waitForPage() async -> Bool {
        for _ in 0..<150 where !pageLoaded { try? await Task.sleep(for: .milliseconds(200)) }   // ~30 s on slow networks
        return pageLoaded
    }

    /// Every branch the site's selector knows: entries in the page plus any HTML the popup's requests returned.
    func inventoryOptions() async -> [InventoryOption] {
        guard await waitForPage() else { return [] }
        let js = """
        document.querySelector('.woocommerce-multi-inventory-open-poup')?.click();
        const strings = v => typeof v === 'string' ? [v] : Array.isArray(v) ? v.flatMap(strings)
          : (v && typeof v === 'object') ? Object.values(v).flatMap(strings) : [];
        const collect = () => {
          const found = new Map();
          const take = root => root.querySelectorAll('[data-id][data-lat]').forEach(a => {
            if (found.has(a.dataset.id)) return;
            const text = c => a.querySelector('[class*="' + c + '"]')?.textContent ?? '';
            found.set(a.dataset.id, { id: a.dataset.id, name: a.dataset.name || text('location-name'),
              lat: a.dataset.lat, lng: a.dataset.lng, address: text('location-address'), distance: text('location-distance') });
          });
          take(document);
          for (const r of window.__raw ?? []) {
            let parts; try { parts = strings(JSON.parse(r.body)); } catch (e) { parts = [r.body]; }
            parts.filter(p => p.includes('data-lat')).forEach(p => take(new DOMParser().parseFromString(p, 'text/html')));
          }
          return [...found.values()];
        };
        // Entries arrive in steps (nearest first, the rest later): wait until the count holds for ~3 s (max ~30 s).
        let last = -1, stable = 0, rows = [];
        for (let i = 0; i < 100 && stable < 10; i++) {
          rows = collect();
          stable = (rows.length > 0 && rows.length === last) ? stable + 1 : 0;
          last = rows.length;
          await new Promise(r => setTimeout(r, 300));
        }
        return rows;
        """
        return InventoryOption.parse(await WebBridge.run(js, in: webView) as? [[String: Any]] ?? [])
    }

    /// Selects the branch the way the site's own links do ("/?inventory=<id>"); if the site doesn't confirm it,
    /// clicks the entry in its popup. Returns the branch name the site then shows, or nil if it didn't change.
    func select(_ option: InventoryOption) async -> String? {
        func confirmed(_ name: String?) -> Bool {
            guard let name else { return false }
            return name == option.name || AddressMatch.best(name, in: [option.name]) != nil
        }
        pageLoaded = false
        webView.load(URLRequest(url: URL(string: "/?inventory=\(option.id)", relativeTo: WebBridge.site)!))
        guard await waitForPage() else { return nil }
        if let name = await WebBridge.selectedBranch(in: webView), confirmed(name) { return name }

        let click = """
        document.querySelector('.woocommerce-multi-inventory-open-poup')?.click();
        for (let i = 0; i < 40; i++) {
          const el = document.querySelector('[data-id="' + id + '"][data-lat]');
          if (el) { el.click(); return true; }
          await new Promise(r => setTimeout(r, 300));
        }
        return false;
        """
        guard await WebBridge.run(click, in: webView, args: ["id": option.id]) as? Bool == true else { return nil }
        for _ in 0..<60 {   // ~15 s for the site to save it (it usually reloads the page)
            try? await Task.sleep(for: .milliseconds(250))
            if pageLoaded, let name = await WebBridge.selectedBranch(in: webView), confirmed(name) { return name }
        }
        return nil
    }

    /// Requests the page's scripts made that returned branch data (for the diagnostics report).
    func capturedRequests() async -> String {
        await WebBridge.run("return (window.__raw ?? []).map(r => r.req + '\\n' + r.body.slice(0, 600)).join('\\n---\\n')",
                            in: webView) as? String ?? ""
    }
}

struct HiddenWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BranchPickerView: View {
    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var picker: HiddenSite?   // created in .task: @State initializers run on every view re-init
    @State private var location = LocationProvider()
    @State private var options: [InventoryOption] = []
    @State private var loading = true
    @State private var selectedID: String?
    @State private var saving = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var selected: InventoryOption? { options.first { $0.id == selectedID } }

    /// Nearest first: by real distance once we know where the user is, else in the site's order (already by distance).
    private var sorted: [InventoryOption] {
        guard let here = location.location else { return options }
        return options.sorted { ($0.distance(from: here) ?? .infinity) < ($1.distance(from: here) ?? .infinity) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map.frame(height: 320)
                list
            }
            .background { if let picker { HiddenWebView(webView: picker.webView).frame(width: 1, height: 1).opacity(0.01) } }
            .navigationTitle("Elegir sucursal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { confirmBar }
        }
        .task {
            location.request()
            await load()
        }
    }

    private var map: some View {
        Map(position: $camera, selection: $selectedID) {
            UserAnnotation()
            ForEach(options.filter { $0.coordinate != nil }) { o in
                Marker(o.shortName, systemImage: "cross.case.fill", coordinate: o.coordinate!)
                    .tint(o.id == selectedID ? Color.red : Color.brand)
                    .tag(o.id)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: selectedID) { _, id in
            if let c = options.first(where: { $0.id == id })?.coordinate {
                withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Cargando sucursales…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if options.isEmpty {
            ContentUnavailableView {
                Label("No se pudo cargar la lista", systemImage: "building.2")
            } description: {
                Text("Podés elegir la sucursal con el selector del sitio.")
            } actions: {
                Button("Abrir selector del sitio") { openSiteSelector() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(sorted) { o in
                        Button { selectedID = o.id } label: { row(o) }
                            .listRowBackground(o.id == selectedID ? Color.brand.opacity(0.15) : nil)
                            .id(o.id)
                    }
                    if options.count <= 1 {
                        Button("¿No ves tu sucursal? Abrir el selector del sitio") { openSiteSelector() }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func row(_ o: InventoryOption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cross.case.fill")
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.brand, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(o.shortName).font(.headline).foregroundStyle(.primary)
                Text(o.address.isEmpty ? o.name : o.address).font(.subheadline).foregroundStyle(.secondary)
                if shop.branchName.map({ AddressMatch.best($0, in: [o.name]) != nil }) == true {
                    Label("Tu sucursal actual", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
            Spacer()
            if let text = distanceText(o) {
                Text(text).font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
            }
        }
        .padding(.vertical, 4)
    }

    private func distanceText(_ o: InventoryOption) -> String? {
        if let here = location.location, let meters = o.distance(from: here) {
            let km = meters / 1000
            return km < 1 ? "\(Int(km * 1000)) m" : km.formatted(.number.precision(.fractionLength(1))) + " km"
        }
        return o.siteDistance
    }

    @ViewBuilder
    private var confirmBar: some View {
        if let o = selected {
            Button {
                Task {
                    saving = true
                    if let name = await picker?.select(o) {
                        shop.branchName = name
                        shop.show("Sucursal: \(o.shortName)")
                        await shop.refreshCart()
                        dismiss()
                    } else {
                        shop.show("No se pudo guardar la sucursal. Probá de nuevo.")
                    }
                    saving = false
                }
            } label: {
                HStack {
                    if saving { ProgressView().tint(.white) }
                    Text(saving ? "Guardando…" : "Elegir \(o.shortName)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LinearGradient.brand, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)
            }
            .disabled(saving)
            .padding()
            .background(.bar)
        }
    }

    private func openSiteSelector() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(600))   // let this sheet close first
            shop.pickBranchOnWeb()
        }
    }

    private func load() async {
        // Light page: the popup is on every page, this one has almost no images.
        let site = picker ?? HiddenSite(path: "/rastrear-pedido/")
        picker = site
        options = await site.inventoryOptions()
        loading = false
        withAnimation { camera = .automatic }   // frame the user and every branch
        await geocodeMissing()
    }

    /// The site gives coordinates for its branches; only if one lacks them, ask Apple's geocoder (one at a time).
    private func geocodeMissing() async {
        let near = location.location.map { CLCircularRegion(center: $0.coordinate, radius: 100_000, identifier: "near") }
        for i in options.indices where options[i].coordinate == nil {
            let street = AddressMatch.streetPart(options[i].address.isEmpty ? options[i].name : options[i].address)
            if let marks = try? await CLGeocoder().geocodeAddressString(street + ", Paraguay", in: near,
                                                                         preferredLocale: Locale(identifier: "es_PY")),
               let c = marks.first?.location?.coordinate {
                options[i].lat = c.latitude
                options[i].lng = c.longitude
            }
        }
    }
}
