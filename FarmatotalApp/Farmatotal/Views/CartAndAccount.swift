import SwiftUI

struct CartView: View {
    @Binding var tab: AppTab
    @Environment(Shop.self) private var shop

    var body: some View {
        NavigationStack {
            Group {
                if let cart = shop.cart, !cart.items.isEmpty {
                    List {
                        Section {
                            ForEach(cart.items, id: \.key) { CartRow(item: $0) }
                                .onDelete { offsets in
                                    let items = offsets.map { cart.items[$0] }
                                    Task { for item in items { await shop.remove(item) } }
                                }
                        }
                        Section {
                            let minor = cart.totals.currencyMinorUnit ?? 0
                            LabeledContent("Subtotal", value: Gs.format(cart.totals.totalItems, minor: minor))
                            if let d = cart.totals.totalDiscount, (Double(d) ?? 0) > 0 {
                                LabeledContent("Descuento", value: "− " + Gs.format(d, minor: minor))
                            }
                            LabeledContent {
                                Text(Gs.format(cart.totals.totalPrice, minor: minor)).font(.title3.bold()).foregroundStyle(Color.brand)
                            } label: {
                                Text("Total").font(.headline)
                            }
                        } footer: {
                            Text("En el siguiente paso elegís la sucursal, cargás tu CI o RUC y pagás con Bancard, igual que en la web.")
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Button { shop.open("/caja/", title: "Finalizar compra") } label: {
                            Label("Finalizar compra", systemImage: "lock.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(LinearGradient.brand, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(.white)
                        }
                        .padding()
                        .background(.bar)
                    }
                } else if shop.cart != nil {
                    ContentUnavailableView {
                        Label("Tu carrito está vacío", systemImage: "cart")
                    } description: {
                        Text("Agregá productos para comprarlos.")
                    } actions: {
                        Button("Ver ofertas") { tab = .home }.buttonStyle(.borderedProminent)
                    }
                } else if let error = shop.cartError {
                    ErrorView(message: error) { Task { await shop.refreshCart() } }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Carrito")
            .refreshable { await shop.refreshCart() }
            .withRoutes()
        }
    }
}

private struct CartRow: View {
    let item: Cart.Item
    @Environment(Shop.self) private var shop
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.productID(item.id)) {
                RemoteImage(url: item.images.first?.thumbnail ?? item.images.first?.src)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.subheadline).lineLimit(2)
                Text(item.prices.current).font(.caption).foregroundStyle(.secondary)
                HStack {
                    stepButton("minus", enabled: item.quantity > 1) { await shop.setQuantity(item, item.quantity - 1) }
                    Text("\(item.quantity)").font(.subheadline.monospacedDigit().weight(.semibold)).frame(minWidth: 24)
                    stepButton("plus", enabled: item.quantity < item.maxQuantity) { await shop.setQuantity(item, item.quantity + 1) }
                    Spacer()
                    if busy { ProgressView() }
                    Text(Gs.format(item.totals.lineTotal, minor: item.totals.currencyMinorUnit ?? 0))
                        .font(.subheadline.weight(.bold))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                busy = true
                await action()
                busy = false
            }
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || busy)
    }
}

struct AccountView: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { shop.pickBranch() } label: {
                        HStack {
                            Label("Mi sucursal", systemImage: "mappin.and.ellipse").foregroundStyle(.primary)
                            Spacer()
                            Text(shop.branchName ?? "Elegir").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } footer: {
                    Text("El stock y los precios se muestran según la sucursal elegida.")
                }

                Section("Mi cuenta") {
                    webRow("Ingresar / Mi cuenta", "person.crop.circle", "/mi-cuenta/")
                    NavigationLink(value: Route.favorites) {
                        Label("Mis favoritos", systemImage: "heart").badge(shop.favorites.count)
                    }
                    NavigationLink(value: Route.compare) {
                        Label("Comparar productos", systemImage: "square.split.2x1").badge(shop.compare.count)
                    }
                    webRow("¿Dónde está mi pedido?", "shippingbox", "/rastrear-pedido/")
                }

                Section("Farmatotal") {
                    NavigationLink(value: Route.branches) { Label("Sucursales", systemImage: "building.2") }
                    webRow("Contacto", "envelope", "/contacto/")
                    Link(destination: WebBridge.site) {
                        Label("Abrir el sitio web", systemImage: "safari").foregroundStyle(.primary)
                    }
                }

                Section {
                    Text("© Defensores S.A. Todos los derechos reservados.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cuenta")
            .withRoutes()
        }
    }

    private func webRow(_ title: String, _ icon: String, _ path: String) -> some View {
        Button { shop.open(path, title: title) } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}
