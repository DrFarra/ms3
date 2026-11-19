import SwiftUI

struct ProductCard: View {
    let product: Product
    @Environment(Shop.self) private var shop

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: product.thumb)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if let d = product.prices.discountPercent { DiscountBadge(percent: d).padding(6) }
                }
                .overlay(alignment: .topTrailing) { FavoriteButton(product: product).padding(4) }

            Text(product.title)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)

            // Always reserve the "precio normal" line so cards in a row stay aligned.
            Text(product.prices.regular)
                .font(.caption).strikethrough()
                .foregroundStyle(.secondary)
                .opacity(product.prices.discountPercent == nil ? 0 : 1)
            Text(product.prices.current)
                .font(.headline)
                .foregroundStyle(Color.brand)

            AddToCartButton(product: product, compact: true)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct FavoriteButton: View {
    let product: Product
    @Environment(Shop.self) private var shop

    var body: some View {
        let on = shop.isFavorite(product)
        Button { shop.toggleFavorite(product) } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.red : Color.gray)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Quitar de favoritos" : "Agregar a favoritos")
    }
}

struct AddToCartButton: View {
    let product: Product
    var quantity = 1
    var compact = false
    @Environment(Shop.self) private var shop
    @State private var adding = false

    var body: some View {
        Button {
            Task {
                adding = true
                await shop.add(product, quantity: quantity)
                adding = false
            }
        } label: {
            HStack(spacing: 6) {
                if adding { ProgressView().tint(.white) } else { Image(systemName: "cart.badge.plus") }
                Text(product.inStock ? (compact ? "Agregar" : "Añadir al carrito") : "Sin stock")
            }
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 8 : 14)
            .background(product.inStock ? Color.brand : Color.gray, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!product.inStock || adding)
    }
}

struct ProductRow: View {
    let title: String
    let products: [Product]
    var more: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if let more { NavigationLink("Ver todos", value: more).font(.subheadline.weight(.semibold)) }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(products) { p in
                        NavigationLink(value: Route.product(p)) { ProductCard(product: p).frame(width: 168) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: Lists

struct ProductListView: View {
    let title: String
    var subcategories: [Category] = []
    @State private var query: ProductQuery
    @State private var loadedQuery: ProductQuery?
    @State private var products: [Product] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0
    @State private var showPriceFilter = false

    init(title: String, query: ProductQuery, subcategories: [Category] = []) {
        self.title = title
        self.subcategories = subcategories
        _query = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            if !subcategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(subcategories) { c in
                            NavigationLink(value: Route.category(c)) {
                                Text(c.title).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color.brand.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 4)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(products) { p in
                    NavigationLink(value: Route.product(p)) { ProductCard(product: p) }
                        .buttonStyle(.plain)
                        .onAppear { if p.id == products.last?.id { Task { await loadMore() } } }
                }
            }
            .padding(.horizontal)

            if loading {
                ProgressView().padding(40)
            } else if let error {
                ErrorView(message: error) { Task { await loadMore() } }
            } else if products.isEmpty && page > 0 && page >= totalPages {
                ContentUnavailableView("Sin resultados", systemImage: "magnifyingglass",
                                       description: Text("Probá con otra búsqueda o quitá los filtros."))
            } else if query.minDiscount != nil && page < totalPages {
                // Discount filtering skips pages without matches, so infinite scroll may need a nudge.
                Button("Buscar más ofertas") { Task { await loadMore() } }
                    .buttonStyle(.bordered).padding(30)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Ordenar por", selection: $query.sort) {
                        ForEach(ProductQuery.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Solo ofertas", isOn: $query.onSale)
                    Button("Rango de precio…") { showPriceFilter = true }
                } label: {
                    Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showPriceFilter) { PriceFilterSheet(minPrice: $query.minPrice, maxPrice: $query.maxPrice) }
        .task(id: query) {
            // .task re-runs when navigating back; only reload if the query really changed.
            if loadedQuery != query {
                loadedQuery = query
                await reset()
            }
        }
    }

    private var hasFilters: Bool { query.onSale || query.minPrice != nil || query.maxPrice != nil || query.sort != .standard }

    private func reset() async {
        generation += 1
        products = []
        page = 0
        totalPages = 1
        error = nil
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        let gen = generation
        loading = true
        error = nil
        do {
            var known = Set(products.map(\.id))
            var fetched = 0
            // With a device-side filter a page can come back empty: keep reading (up to 8 pages per call).
            repeat {
                let r = try await API.products(query, page: page + 1)
                guard gen == generation else { return }   // a newer query replaced this one
                let fresh = r.items.filter { !known.contains($0.id) && query.keeps($0) }
                products += fresh
                known.formUnion(fresh.map(\.id))
                fetched += fresh.count
                page += 1
                totalPages = r.totalPages
            } while fetched == 0 && query.minDiscount != nil && page < totalPages && page % 8 != 0
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct PriceFilterSheet: View {
    @Binding var minPrice: Int?
    @Binding var maxPrice: Int?
    @State private var minText = ""
    @State private var maxText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Precio en guaraníes") {
                    TextField("Mínimo", text: $minText).keyboardType(.numberPad)
                    TextField("Máximo", text: $maxText).keyboardType(.numberPad)
                }
                Section {
                    Button("Quitar filtro de precio", role: .destructive) {
                        minPrice = nil
                        maxPrice = nil
                        dismiss()
                    }
                }
            }
            .navigationTitle("Filtrar por precio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        minPrice = Int(minText.filter(\.isNumber))
                        maxPrice = Int(maxText.filter(\.isNumber))
                        dismiss()
                    }
                }
            }
            .onAppear {
                minText = minPrice.map(String.init) ?? ""
                maxText = maxPrice.map(String.init) ?? ""
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: Detail

struct ProductDetailView: View {
    let productID: Int
    @State private var product: Product?
    @State private var quantity = 1
    @State private var related: [Product] = []
    @State private var details: AttributedString?
    @State private var error: String?
    @Environment(Shop.self) private var shop

    init(product: Product) {
        productID = product.id
        _product = State(initialValue: product)
    }

    init(productID: Int) {
        self.productID = productID
    }

    var body: some View {
        Group {
            if let product {
                content(product)
            } else if let error {
                ErrorView(message: error) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        error = nil
        if product == nil {
            do { product = try await API.product(id: productID) } catch { self.error = error.localizedDescription; return }
        }
        guard let p = product, details == nil, related.isEmpty else { return }
        if let html = p.description, !html.isEmpty { details = htmlAttributed(html) }
        if let cat = p.categories?.last,
           let r = try? await API.products(ProductQuery(category: cat.id), page: 1) {
            related = Array(r.items.filter { $0.id != p.id }.prefix(10))
        }
    }

    private func content(_ p: Product) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TabView {
                    ForEach(p.images.isEmpty ? [WCImage(src: "", thumbnail: nil)] : p.images, id: \.src) { img in
                        RemoteImage(url: img.src.isEmpty ? nil : img.src, preview: img.thumbnail)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: p.images.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .topLeading) {
                    if let d = p.prices.discountPercent { DiscountBadge(percent: d).scaleEffect(1.2).padding(14) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let sku = p.sku, !sku.isEmpty {
                        Text("SKU: \(sku)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(p.title).font(.title3.bold())
                    if p.prices.discountPercent != nil {
                        HStack(spacing: 6) {
                            Text("Precio normal:").foregroundStyle(.secondary)
                            Text(p.prices.regular).strikethrough().foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.prices.current).font(.title.bold()).foregroundStyle(Color.brand)
                        Text("Precio web").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    stockLabel(p)
                }

                if p.inStock {
                    Stepper("Cantidad: \(quantity)", value: $quantity, in: 1...p.maxQuantity)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                AddToCartButton(product: p, quantity: quantity)

                HStack(spacing: 10) {
                    actionButton(shop.isFavorite(p) ? "Favorito" : "Favoritos",
                                 shop.isFavorite(p) ? "heart.fill" : "heart") { shop.toggleFavorite(p) }
                    actionButton(shop.isCompared(p) ? "Comparando" : "Comparar",
                                 shop.isCompared(p) ? "checkmark.square.fill" : "square.split.2x1") { shop.toggleCompare(p) }
                    if let link = p.permalink.flatMap(URL.init(string:)) {
                        ShareLink(item: link) {
                            Label("Compartir", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)

                if let short = p.shortDescription?.withoutWishlistNoise.htmlPlain, !short.isEmpty {
                    Text(short).font(.callout)
                }

                if let details {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Descripción").font(.headline)
                        Text(details)
                    }
                }

                // The site often files a product twice under same-named categories: show each name once.
                let terms = ((p.categories ?? []).map { (key: "c\($0.id)", term: $0, isCategory: true) }
                    + (p.tags ?? []).map { (key: "t\($0.id)", term: $0, isCategory: false) })
                    .reduce(into: [(key: String, term: Term, isCategory: Bool)]()) { list, t in
                        if !list.contains(where: { $0.term.title == t.term.title }) { list.append(t) }
                    }
                if !terms.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(terms, id: \.key) { t in
                                NavigationLink(value: Route.list(t.term.title, t.isCategory ? ProductQuery(category: t.term.id) : ProductQuery(tag: t.term.id))) {
                                    Label(t.term.title, systemImage: t.isCategory ? "folder" : "tag")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.brand.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .padding()

            if !related.isEmpty {
                ProductRow(title: "Productos relacionados", products: related).padding(.bottom)
            }
        }
    }

    private func stockLabel(_ p: Product) -> some View {
        Group {
            if p.inStock {
                if let left = p.lowStockRemaining {
                    Label("Disponible · quedan \(left)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Disponible", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label("No disponible en la sucursal seleccionada", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }
}

// MARK: Favorites & compare

struct FavoritesView: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        ScrollView {
            if shop.favorites.isEmpty {
                ContentUnavailableView("Sin favoritos", systemImage: "heart",
                                       description: Text("Tocá el corazón de un producto para guardarlo acá."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(shop.favorites) { p in
                    NavigationLink(value: Route.product(p)) { ProductCard(product: p) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Mis favoritos")
    }
}

struct CompareView: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        Group {
            if shop.compare.isEmpty {
                ContentUnavailableView("Nada para comparar", systemImage: "square.split.2x1",
                                       description: Text("Agregá hasta 4 productos con “Comparar” desde su ficha."))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(shop.compare) { column($0) }
                    }
                    .padding()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Comparar")
        .toolbar {
            if !shop.compare.isEmpty {
                Button("Limpiar", role: .destructive) { shop.compare.removeAll() }
            }
        }
    }

    private func column(_ p: Product) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: Route.product(p)) {
                RemoteImage(url: p.thumb).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(3, reservesSpace: true)
            field("Precio web", p.prices.current, highlight: true)
            field("Precio normal", p.prices.regular)
            field("Descuento", p.prices.discountPercent.map { "\($0)%" } ?? "—")
            field("Disponibilidad", p.inStock ? "Disponible" : "Sin stock")
            field("SKU", p.sku ?? "—")
            field("Descripción", p.shortDescription?.htmlPlain.isEmpty == false ? p.shortDescription!.htmlPlain : "—", lines: 6)
            AddToCartButton(product: p, compact: true)
            Button(role: .destructive) { shop.toggleCompare(p) } label: {
                Label("Quitar", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(width: 180)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func field(_ label: String, _ value: String, highlight: Bool = false, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value)
                .font(highlight ? .headline : .subheadline)
                .foregroundStyle(highlight ? Color.brand : .primary)
                .lineLimit(lines, reservesSpace: true)
        }
    }
}
