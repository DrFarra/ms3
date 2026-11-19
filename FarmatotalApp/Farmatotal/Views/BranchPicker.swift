import SwiftUI
import MapKit
import WebKit
import CoreLocation

/// One branch as offered by the site's own selector (multi-inventory plugin popup).
struct InventoryOption: Identifiable, Hashable {
    let id: Int              // position in the popup's list; used to click it
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
}

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
      const keep = t => { try { walk(JSON.parse(t)); } catch (e) {} };
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function (...a) {
        this.addEventListener('load', () => { try { keep(this.responseText); } catch (e) {} });
        return send.apply(this, a);
      };
      const f = window.fetch;
      window.fetch = async (...a) => { const r = await f(...a); r.clone().text().then(keep).catch(() => {}); return r; };
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

    func inventoryOptions() async -> [InventoryOption] {
        guard await waitForPage() else { return [] }
        // The nearest branch is drawn first and the rest a moment later: wait until the count stops changing.
        let js = """
        document.querySelector('.woocommerce-multi-inventory-open-poup')?.click();
        const sel = '.woocommerce-multi-inventory-popup-locations-location';
        let last = -1, stable = 0;
        for (let i = 0; i < 80 && stable < 5; i++) {
          const n = document.querySelectorAll(sel).length;
          stable = (n > 0 && n === last) ? stable + 1 : 0;
          last = n;
          await new Promise(r => setTimeout(r, 300));
        }
        return [...document.querySelectorAll(sel)].map(e => {
          let text = e.innerText;
          const distance = e.querySelector('[class*="location-distance"]')?.innerText ?? '';
          e.querySelectorAll('[class*="location-distance"], [class*="location-select"]').forEach(x => { text = text.replace(x.innerText, ''); });
          const attrs = {};
          [e, ...e.querySelectorAll('*')].forEach(x => { for (const a of x.attributes) if (a.name.startsWith('data-')) attrs[a.name] = a.value; });
          return { text, distance, attrs };
        });
        """
        let raw = await WebBridge.run(js, in: webView) as? [[String: Any]] ?? []
        var seen = Set<String>()
        return raw.enumerated().compactMap { index, row in
            let distance = (row["distance"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = (row["text"] as? String ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("seleccionar") }
            guard let name = lines.first, seen.insert(name).inserted else { return nil }   // nearest one appears twice
            // If the plugin exposes coordinates as data-*lat* / data-*lng* attributes, use them directly.
            let attrs = row["attrs"] as? [String: String] ?? [:]
            func coord(_ keys: [String]) -> Double? {
                attrs.first { k, _ in keys.contains { k.lowercased().contains($0) } }.flatMap { Double($0.value) }
            }
            let address = lines.count > 1 ? lines.dropFirst().joined(separator: " ")
                                           : name.components(separatedBy: " - ").dropFirst().joined(separator: " - ")
            return InventoryOption(id: index, name: name, address: address,
                                   siteDistance: distance.isEmpty ? nil : distance,
                                   lat: coord(["lat"]), lng: coord(["lng", "lon"]))
        }
    }

    /// Clicks the option in the site's popup and waits for the site to confirm; returns the selected branch name.
    func select(_ option: InventoryOption) async -> String? {
        let before = await WebBridge.selectedBranch(in: webView)
        let js = """
        const el = [...document.querySelectorAll('.woocommerce-multi-inventory-popup-locations-location')][index];
        if (!el) return false;
        (el.querySelector('[class*="location-select"]') ?? el).click();
        return true;
        """
        guard await WebBridge.run(js, in: webView, args: ["index": option.id]) as? Bool == true else { return nil }
        for _ in 0..<60 {   // ~15 s: the site saves the choice and usually reloads the page
            try? await Task.sleep(for: .milliseconds(250))
            if pageLoaded, let now = await WebBridge.selectedBranch(in: webView), now != before { return now }
        }
        return await WebBridge.selectedBranch(in: webView) ?? option.name
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
    @State private var selectedID: Int?
    @State private var saving = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var selected: InventoryOption? { options.first { $0.id == selectedID } }

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
                Button("Abrir selector del sitio") {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))   // let this sheet close first
                        shop.pickBranchOnWeb()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollViewReader { proxy in
                List(options) { o in   // the site already lists them nearest first
                    Button { selectedID = o.id } label: { row(o) }
                        .listRowBackground(o.id == selectedID ? Color.brand.opacity(0.15) : nil)
                        .id(o.id)
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

    private func load() async {
        // Light page: the popup is on every page, this one has almost no images.
        let site = picker ?? HiddenSite(path: "/rastrear-pedido/")
        picker = site
        options = await site.inventoryOptions()
        loading = false
        await locateBranches(site)
    }

    /// Fills in coordinates for the map: saved ones, then the popup's own data, then Apple's geocoder.
    private func locateBranches(_ site: HiddenSite) async {
        var saved = UserDefaults.standard.dictionary(forKey: "branchCoordinates") as? [String: [Double]] ?? [:]
        func set(_ i: Int, _ c: CLLocationCoordinate2D) {
            options[i].lat = c.latitude
            options[i].lng = c.longitude
            saved[options[i].name] = [c.latitude, c.longitude]
        }
        for i in options.indices where options[i].coordinate == nil {
            if let c = saved[options[i].name], c.count == 2 { options[i].lat = c[0]; options[i].lng = c[1] }
        }
        if options.contains(where: { $0.coordinate == nil }) {
            let branches = await site.places(attempts: 4)   // the popup is already loaded by now
            let candidates = branches.map { $0.title + " " + $0.address }
            for i in options.indices where options[i].coordinate == nil {
                if let j = AddressMatch.best(options[i].name + " " + options[i].address, in: candidates) { set(i, branches[j].coordinate) }
            }
        }
        camera = .automatic   // frame the user and every pin found so far
        // Apple's geocoder is rate-limited: one at a time, nearest first, pins appear as they resolve.
        let near = location.location.map { CLCircularRegion(center: $0.coordinate, radius: 100_000, identifier: "near") }
        for i in options.indices where options[i].coordinate == nil {
            let street = AddressMatch.streetPart(options[i].address.isEmpty ? options[i].name : options[i].address)
            if let marks = try? await CLGeocoder().geocodeAddressString(street + ", Paraguay", in: near,
                                                                         preferredLocale: Locale(identifier: "es_PY")),
               let c = marks.first?.location?.coordinate {
                set(i, c)
            }
        }
        UserDefaults.standard.set(saved, forKey: "branchCoordinates")
        if selectedID == nil { withAnimation { camera = .automatic } }
    }
}
