import SwiftUI
import MapKit
import CoreLocation

struct BranchesView: View {
    @Environment(Shop.self) private var shop
    @State private var branches: [Branch] = []
    @State private var error: String?
    @State private var location = LocationProvider()
    @State private var site: HiddenSite?   // created on load: @State initializers run on every view re-init

    private var sorted: [Branch] {
        guard let here = location.location else { return branches }
        return branches.sorted { $0.distance(from: here) < $1.distance(from: here) }
    }

    var body: some View {
        Group {
            if let error, branches.isEmpty {
                ContentUnavailableView {
                    Label("No se pudieron cargar las sucursales", systemImage: "building.2")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reintentar") { Task { await load() } }.buttonStyle(.borderedProminent)
                    Button("Ver en la web") { shop.open("/sucursales/", title: "Sucursales") }
                }
            } else if branches.isEmpty {
                ProgressView()
            } else {
                List {
                    Section {
                        Map(initialPosition: .automatic) {
                            ForEach(branches) { b in
                                Marker(b.title, systemImage: "cross.case.fill", coordinate: b.coordinate).tint(Color.brand)
                            }
                            UserAnnotation()
                        }
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                        }
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    }
                    Section(location.location == nil ? "\(branches.count) sucursales" : "Más cercanas primero") {
                        ForEach(sorted) { BranchRow(branch: $0, here: location.location) }
                    }
                }
            }
        }
        .background { if let site { HiddenWebView(webView: site.webView).frame(width: 1, height: 1).opacity(0.01) } }
        .navigationTitle("Sucursales")
        .toolbar {
            Button { location.request() } label: { Label("Más cercana", systemImage: "location.fill") }
        }
        .task {
            location.request()   // blue "you are here" dot and nearest-first order
            if branches.isEmpty { await load() }
        }
    }

    private func load() async {
        error = nil
        // The store locator only loads its list through its own scripts: run the page hidden and capture it.
        let page = HiddenSite(path: "/sucursales/")
        site = page
        branches = await page.places()
        if branches.isEmpty { error = "El sitio no devolvió la lista de sucursales." }
    }
}

private struct BranchRow: View {
    let branch: Branch
    let here: CLLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(branch.title).font(.headline)
                Spacer()
                if let here {
                    Text(Measurement(value: branch.distance(from: here) / 1000, unit: UnitLength.kilometers)
                        .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                }
            }
            if !branch.address.isEmpty { Text(branch.address).font(.subheadline).foregroundStyle(.secondary) }
            if let hours = branch.hours { Label(hours, systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                Button { directions() } label: { Label("Cómo llegar", systemImage: "arrow.triangle.turn.up.right.diamond") }
                if let phone = branch.phone, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    Link(destination: url) { Label("Llamar", systemImage: "phone") }
                }
                if let email = branch.email, let url = URL(string: "mailto:" + email) {
                    Link(destination: url) { Label("Email", systemImage: "envelope") }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func directions() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: branch.coordinate))
        item.name = branch.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    var location: CLLocation?
    @ObservationIgnored private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()   // the delegate requests the location once allowed
        } else {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
