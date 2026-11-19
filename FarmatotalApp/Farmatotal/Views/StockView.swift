import SwiftUI
import MapKit
import CoreLocation

/// Map of the branches that have a product in stock (Farmatotal's stock service), with the user's location.
struct StockView: View {
    let product: Product

    struct Spot: Identifiable {
        let id: String              // store code
        let name: String
        let units: Int
        let option: InventoryOption?   // the site's branch (coordinates) matched by name
        var title: String { option?.shortName ?? name }
    }

    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var spots: [Spot] = []          // only branches with units > 0
    @State private var checked = 0                 // branches whose stock was looked up
    @State private var status: String? = "Buscando sucursales…"
    @State private var error: String?
    @State private var selectedID: String?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var hosted: [HiddenSite] = []
    @State private var location = LocationProvider()

    private var selected: Spot? { spots.first { $0.id == selectedID } }
    private var placed: [Spot] { spots.filter { $0.option?.coordinate != nil } }

    var body: some View {
        NavigationStack {
            Map(position: $camera, selection: $selectedID) {
                UserAnnotation()
                ForEach(placed) { s in
                    Marker("\(s.title) · \(s.units)", systemImage: "cross.case.fill", coordinate: s.option!.coordinate!)
                        .tint(s.id == selectedID ? Color.red : Color.green)
                        .tag(s.id)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .top) { banner }
            .safeAreaInset(edge: .bottom) { if let s = selected { card(s) } }
            .onChange(of: selectedID) { _, _ in frame() }
            .onChange(of: location.location) { _, _ in if selectedID == nil { frame() } }
            .navigationTitle("Stock por sucursal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .background {
                ForEach(hosted, id: \.self) { HiddenWebView(webView: $0.webView).frame(width: 1, height: 1).opacity(0.01) }
            }
        }
        .task {
            location.request()
            await load()
        }
    }

    @ViewBuilder
    private var banner: some View {
        let (icon, text, color): (String, String, Color) = {
            if let error { return ("exclamationmark.triangle.fill", error, .orange) }
            if let status { return ("hourglass", status, .secondary) }
            if spots.isEmpty { return ("xmark.circle.fill", "No hay stock de este producto en ninguna sucursal.", .red) }
            let unplaced = spots.count - placed.count
            return ("checkmark.circle.fill",
                    "Hay stock en \(spots.count) de \(checked) sucursales." + (unplaced > 0 ? " \(unplaced) sin ubicación en el mapa." : ""),
                    .green)
        }()
        HStack(alignment: .top, spacing: 10) {
            if status != nil && error == nil { ProgressView() } else { Image(systemName: icon).foregroundStyle(color) }
            VStack(alignment: .leading, spacing: 2) {
                Text(product.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(text).font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func card(_ s: Spot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.title).font(.headline)
                Spacer()
                Text("\(s.units) unid.").font(.subheadline.weight(.bold)).foregroundStyle(.green)
            }
            if let address = s.option?.address, !address.isEmpty {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            if let here = location.location, let m = s.option?.distance(from: here) {
                Text(m < 1000 ? "A \(Int(m)) m" : "A " + (m / 1000).formatted(.number.precision(.fractionLength(1))) + " km")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
            }
            HStack {
                Button { directions(s) } label: {
                    Label("Cómo llegar", systemImage: "arrow.triangle.turn.up.right.diamond").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { choose(s) } label: { Label("Elegir sucursal", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    /// The selected branch close up; otherwise the user and the 3 nearest branches with stock.
    private func frame() {
        if let c = selected?.option?.coordinate {
            withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000)) }
            return
        }
        let here = location.location
        let nearest = here.map { h in placed.sorted { ($0.option?.distance(from: h) ?? .infinity) < ($1.option?.distance(from: h) ?? .infinity) } } ?? placed
        let points = nearest.prefix(3).compactMap { $0.option?.coordinate } + (here.map { [$0.coordinate] } ?? [])
        if let region = MKCoordinateRegion.fitting(points) { withAnimation { camera = .region(region) } }
    }

    private func directions(_ s: Spot) {
        guard let c = s.option?.coordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = "Farmatotal \(s.title)"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    private func choose(_ s: Spot) {
        guard let id = s.option?.id else { return }
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(600))   // let this sheet close before the picker opens
            shop.showBranchOnMap(id)
        }
    }

    private func load() async {
        guard let sku = product.sku, !sku.isEmpty else {
            status = nil
            error = "Este producto no tiene código para consultar stock."
            return
        }
        let codes = await BranchDirectory.codes { hosted = $0 }
        guard !codes.isEmpty else {
            status = nil
            error = BranchDirectory.codesProblem
            return
        }
        status = "Consultando stock en \(codes.count) sucursales…"
        let options = await BranchDirectory.options { hosted = $0 }
        let names = options.map(\.name)
        var failed = 0
        await withTaskGroup(of: (code: String, name: String, units: Int?).self) { group in
            for c in codes {
                group.addTask { (c.code, c.name, try? await StockAPI.units(sku: sku, branch: c.code)) }
            }
            for await r in group {
                guard let units = r.units else { failed += 1; continue }
                checked += 1
                if units > 0 {
                    spots.append(Spot(id: r.code, name: r.name, units: units,
                                      option: AddressMatch.bestName(r.name, in: names).map { options[$0] }))
                }
            }
        }
        status = nil
        if failed > 0 && checked == 0 { error = "No se pudo consultar el stock. Revisá tu conexión y probá de nuevo." }
        frame()
    }
}
