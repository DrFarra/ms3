import SwiftUI
import CoreLocation

/// Units of one product at every branch (Farmatotal's stock service). Tapping a branch shows it on the map.
struct StockView: View {
    let product: Product

    struct Row: Identifiable {
        let id: String              // store code
        let name: String
        var units: Int?
        var failed = false
        var option: InventoryOption?   // the site's branch (coordinates, map) matched by name
    }

    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var status: String? = "Buscando sucursales…"
    @State private var error: String?
    @State private var hosted: [HiddenSite] = []
    @State private var location = LocationProvider()

    /// In stock first, then nearest, then by name.
    private var sorted: [Row] {
        rows.sorted { a, b in
            let (sa, sb) = ((a.units ?? 0) > 0, (b.units ?? 0) > 0)
            if sa != sb { return sa }
            if let here = location.location {
                let (da, db) = (a.option?.distance(from: here) ?? .infinity, b.option?.distance(from: here) ?? .infinity)
                if da != db { return da < db }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(product.title).font(.headline)
                    if let status {
                        HStack { ProgressView(); Text(status).foregroundStyle(.secondary) }
                    }
                } footer: {
                    if !rows.isEmpty {
                        let available = rows.filter { ($0.units ?? 0) > 0 }.count
                        Text("Disponible en \(available) de \(rows.count) sucursales. Tocá una para verla en el mapa.")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(sorted) { r in
                        Button { showOnMap(r) } label: { row(r) }
                            .disabled(r.option == nil)
                    }
                }
            }
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

    private func row(_ r: Row) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.option?.shortName ?? r.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let address = r.option?.address, !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let here = location.location, let m = r.option?.distance(from: here) {
                    Text(m < 1000 ? "\(Int(m)) m" : (m / 1000).formatted(.number.precision(.fractionLength(1))) + " km")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                }
            }
            Spacer()
            if let units = r.units {
                Text(units > 0 ? "\(units) unid." : "Sin stock")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((units > 0 ? Color.green : Color.gray).opacity(0.18), in: Capsule())
                    .foregroundStyle(units > 0 ? Color.green : Color.secondary)
            } else if r.failed {
                Text("—").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private func showOnMap(_ r: Row) {
        guard let id = r.option?.id else { return }
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(600))   // let this sheet close before the map opens
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
            error = "El sitio no mostró su lista de sucursales. Iniciá sesión en Cuenta → Mi cuenta (o agregá algo al carrito) y volvé a intentar."
            return
        }
        status = "Consultando stock…"
        let options = await BranchDirectory.options { hosted = $0 }
        let names = options.map(\.name)
        rows = codes.map { c in Row(id: c.code, name: c.name, option: AddressMatch.bestName(c.name, in: names).map { options[$0] }) }

        await withTaskGroup(of: (String, Int?).self) { group in
            for code in codes.map(\.code) {
                group.addTask { (code, try? await StockAPI.units(sku: sku, branch: code)) }
            }
            for await (code, units) in group {
                guard let i = rows.firstIndex(where: { $0.id == code }) else { continue }
                rows[i].units = units
                rows[i].failed = units == nil
            }
        }
        status = nil
    }
}
