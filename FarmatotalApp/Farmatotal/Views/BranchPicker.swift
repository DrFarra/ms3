import SwiftUI
import MapKit
import WebKit

/// One branch as offered by the site's own selector (multi-inventory plugin popup).
struct InventoryOption: Identifiable, Hashable {
    let id: Int              // position in the popup's list; used to click it
    let name: String
    let address: String
    let siteDistance: String?
    var branch: Branch?      // store-locator entry with coordinates, matched by address words

    var shortName: String { name.components(separatedBy: " - ").first ?? name }
}

/// Runs the site's branch popup in a hidden web view: reads its list and clicks the chosen entry,
/// so the site stores the branch exactly as if the user had picked it on the web.
@MainActor @Observable
final class InventoryPicker: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    private var pageLoaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Light page: the popup is on every page, this one has almost no images.
        webView.load(URLRequest(url: WebBridge.site.appending(path: "rastrear-pedido/")))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { pageLoaded = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageLoaded = true }

    private func waitForPage() async -> Bool {
        for _ in 0..<150 where !pageLoaded { try? await Task.sleep(for: .milliseconds(200)) }   // ~30 s on slow networks
        return pageLoaded
    }

    func options() async -> [InventoryOption] {
        guard await waitForPage() else { return [] }
        let js = """
        document.querySelector('.woocommerce-multi-inventory-open-poup')?.click();
        for (let i = 0; i < 50; i++) {
          const els = [...document.querySelectorAll('.woocommerce-multi-inventory-popup-locations-location')];
          if (els.length) return els.map(e => ({ text: e.innerText,
            distance: e.querySelector('[class*="location-distance"]')?.innerText ?? '' }));
          await new Promise(r => setTimeout(r, 300));
        }
        return [];
        """
        let raw = await WebBridge.run(js, in: webView) as? [[String: Any]] ?? []
        var seen = Set<String>()
        return raw.enumerated().compactMap { index, row in
            let distance = (row["distance"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = (row["text"] as? String ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != distance }
            guard let name = lines.first, seen.insert(name).inserted else { return nil }   // nearest one appears twice
            return InventoryOption(id: index, name: name, address: lines.dropFirst().joined(separator: " "),
                                   siteDistance: distance.isEmpty ? nil : distance, branch: nil)
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

private struct HiddenWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BranchPickerView: View {
    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var picker = InventoryPicker()
    @State private var location = LocationProvider()
    @State private var options: [InventoryOption] = []
    @State private var loading = true
    @State private var selectedID: Int?
    @State private var saving = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var selected: InventoryOption? { options.first { $0.id == selectedID } }

    private var sorted: [InventoryOption] {
        guard let here = location.location else { return options }   // the site already lists nearest first
        return options.sorted {
            ($0.branch?.distance(from: here) ?? .infinity) < ($1.branch?.distance(from: here) ?? .infinity)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map.frame(height: 320)
                list
            }
            .background(HiddenWebView(webView: picker.webView).frame(width: 1, height: 1).opacity(0.01))
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
            ForEach(options.filter { $0.branch != nil }) { o in
                Marker(o.shortName, systemImage: "cross.case.fill", coordinate: o.branch!.coordinate)
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
            if let c = options.first(where: { $0.id == id })?.branch?.coordinate {
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
                List(sorted) { o in
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
        if let here = location.location, let b = o.branch {
            let km = b.distance(from: here) / 1000
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
                    if let name = await picker.select(o) {
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
        async let fromSite = picker.options()
        let branches = (try? await API.branches()) ?? []   // coordinates for the map; the list works without them
        var list = await fromSite
        let candidates = branches.map { $0.title + " " + $0.address }
        for i in list.indices {
            if let j = AddressMatch.best(list[i].name + " " + list[i].address, in: candidates) { list[i].branch = branches[j] }
        }
        options = list
        loading = false
    }
}
