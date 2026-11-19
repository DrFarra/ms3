import SwiftUI

struct HomeView: View {
    @Binding var tab: AppTab
    @Environment(Shop.self) private var shop
    @State private var categories: [Category] = []
    @State private var offers: [Product] = []
    @State private var bestSellers: [Product] = []
    @State private var pointsRewards: [Product] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                searchField
                banners
                if !categories.isEmpty { categoryGrid }

                if let error, offers.isEmpty {
                    ErrorView(message: error) { Task { await load() } }
                } else if offers.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                if !offers.isEmpty {
                    ProductRow(title: "Ofertas", products: offers, more: .list("Ofertas", ProductQuery(onSale: true)))
                }
                if !bestSellers.isEmpty {
                    ProductRow(title: "Más vendidos", products: bestSellers,
                               more: .list("Más vendidos", ProductQuery(sort: .popularity)))
                }
                if !pointsRewards.isEmpty {
                    ProductRow(title: "Canjeá tus puntos", products: pointsRewards)
                }

                Text("© Defensores S.A. — Farmatotal")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { if offers.isEmpty { await load() } }
        .onChange(of: shop.branchName) { Task { await load() } }   // stock and offers depend on the branch
    }

    private var header: some View {
        HStack {
            (Text("farma").foregroundStyle(.primary) + Text("total").foregroundStyle(Color.brand))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Spacer()
            Button { shop.pickBranch() } label: {
                Label(shop.branchName ?? "Elegir sucursal", systemImage: "mappin.circle.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.brand.opacity(0.12), in: Capsule())
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var searchField: some View {
        Button { tab = .search } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                Text("Buscar medicamentos, marcas…")
                Spacer()
                Image(systemName: "barcode.viewfinder")
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var banners: some View {
        TabView {
            NavigationLink(value: Route.list("Ofertas", ProductQuery(onSale: true))) {
                banner("¡Super Rombo!", "Descuentos increíbles en toda la farmacia", "tag.fill")
            }
            NavigationLink(value: Route.list("70% OFF o más", ProductQuery(onSale: true, minDiscount: 70))) {
                banner("Hasta 70% OFF", "Aprovechá los mejores descuentos", "percent")
            }
            NavigationLink(value: Route.list("50% OFF o más", ProductQuery(onSale: true, minDiscount: 50))) {
                banner("Hasta 50% OFF", "Cuidado personal, belleza y más", "sparkles")
            }
        }
        .buttonStyle(.plain)
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 150)
    }

    private func banner(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.heavy))
                Text(subtitle).font(.subheadline)
                Text("Ver ahora →").font(.caption.weight(.bold)).padding(.top, 4)
            }
            Spacer()
            Image(systemName: icon).font(.system(size: 54, weight: .bold)).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient.brand, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categorías").font(.title3.bold()).padding(.horizontal)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                ForEach(categories) { c in
                    NavigationLink(value: Route.category(c)) {
                        VStack(spacing: 6) {
                            Image(systemName: c.symbol)
                                .font(.title2)
                                .foregroundStyle(Color.brand)
                                .frame(width: 58, height: 58)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                            Text(c.title).font(.caption2.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func load() async {
        error = nil
        async let cats = API.categories()
        async let sale = API.products(ProductQuery(onSale: true), page: 1)
        async let popular = API.products(ProductQuery(sort: .popularity), page: 1)
        async let points = API.products(ProductQuery(search: "puntos"), page: 1)
        do {
            categories = topLevel(try await cats)
            offers = try await sale.items
            bestSellers = try await popular.items
            // Reward items are named like "Vaso Térmico 100 puntos + Gs.20.000".
            pointsRewards = (try? await points)?.items.filter { $0.title.localizedCaseInsensitiveContains("puntos +") } ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func topLevel(_ all: [Category]) -> [Category] {
    let menu = Category.mainMenu
    let main = all.filter { $0.parent == 0 && menu.contains($0.slug) }
        .sorted { (menu.firstIndex(of: $0.slug) ?? 0) < (menu.firstIndex(of: $1.slug) ?? 0) }
    // shortcut: if the site renames its menu slugs, show every top-level category rather than none.
    return main.isEmpty ? all.filter { $0.parent == 0 && $0.count > 0 } : main
}

struct CategoriesView: View {
    @State private var categories: [Category] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error, categories.isEmpty {
                ErrorView(message: error) { Task { await load() } }
            } else if categories.isEmpty {
                ProgressView()
            } else {
                List(categories) { c in
                    NavigationLink(value: Route.category(c)) {
                        HStack(spacing: 14) {
                            Image(systemName: c.symbol)
                                .foregroundStyle(Color.brand)
                                .frame(width: 40, height: 40)
                                .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading) {
                                Text(c.title).font(.body.weight(.medium))
                                Text("\(c.count) productos").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Categorías")
        .task { if categories.isEmpty { await load() } }
    }

    private func load() async {
        error = nil
        do { categories = topLevel(try await API.categories()) } catch { self.error = error.localizedDescription }
    }
}

struct CategoryView: View {
    let category: Category
    @State private var children: [Category] = []

    var body: some View {
        ProductListView(title: category.title, query: ProductQuery(category: category.id), subcategories: children)
            .task {
                children = (try? await API.categories())?
                    .filter { $0.parent == category.id && $0.count > 0 }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } ?? []
            }
    }
}
