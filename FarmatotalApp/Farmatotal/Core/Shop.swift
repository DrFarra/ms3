import SwiftUI

/// A website page shown inside the app (checkout, account, tracking…), sharing the app's session.
struct WebPage: Identifiable {
    let id = UUID()
    let path: String
    let title: String
    var hideSiteChrome = true
    var isBranchPicker = false
}

enum Route: Hashable {
    case product(Product)
    case productID(Int)
    case list(String, ProductQuery)
    case category(Category)
    case favorites
    case compare
    case branches
}

@MainActor @Observable
final class Shop {
    var cart: Cart?
    var cartError: String?
    var toast: String?
    var webPage: WebPage?
    var pickingBranch = false
    /// Branch (inventory ID) the picker should open with selected, e.g. from a product's stock list.
    var preselectedBranchID: String?
    var favorites: [Product] = Shop.load("favorites") { didSet { Shop.save(favorites, "favorites") } }
    var compare: [Product] = Shop.load("compare") { didSet { Shop.save(compare, "compare") } }
    var branchName: String? = UserDefaults.standard.string(forKey: "branch") {
        didSet { UserDefaults.standard.set(branchName, forKey: "branch") }
    }
    @ObservationIgnored private var nonce: String?

    var cartCount: Int { cart?.itemsCount ?? 0 }

    // MARK: Cart (server-side WooCommerce cart, shared with the web checkout)

    func refreshCart() async {
        do {
            let (c, r): (Cart, WebBridge.Response) = try await API.send(WebBridge.storeAPI + "/cart")
            cart = c
            cartError = nil
            nonce = r.headers["nonce"] ?? nonce
        } catch {
            cartError = error.localizedDescription
        }
    }

    func add(_ product: Product, quantity: Int = 1) async {
        await cartAction("add-item", ["id": product.id, "quantity": quantity], success: "Agregado al carrito")
    }

    func setQuantity(_ item: Cart.Item, _ quantity: Int) async {
        await cartAction("update-item", ["key": item.key, "quantity": quantity])
    }

    func remove(_ item: Cart.Item) async {
        await cartAction("remove-item", ["key": item.key])
    }

    private func cartAction(_ action: String, _ body: [String: Any], success: String? = nil) async {
        if nonce == nil { await refreshCart() }
        for attempt in 0..<2 {
            do {
                let (c, r): (Cart, WebBridge.Response) = try await API.send(
                    WebBridge.storeAPI + "/cart/" + action, method: "POST", json: body, headers: ["Nonce": nonce ?? ""])
                cart = c
                nonce = r.headers["nonce"] ?? nonce
                if let success { show(success) }
                return
            } catch let error as APIError where attempt == 0 && (error.status == 401 || error.status == 403) {
                await refreshCart()   // stale nonce: get a fresh one and retry once
            } catch {
                show(error.localizedDescription)
                return
            }
        }
    }

    // MARK: Account (the site's "Mi cuenta", read in the shared session)

    var account: AccountSummary?

    func refreshAccount() async {
        if let s = try? await AccountAPI.summary() { account = s }
    }

    func login(user: String, password: String) async throws {
        if account == nil || account?.loginNonce.isEmpty == true { await refreshAccount() }
        account = try await AccountAPI.login(user: user, password: password, using: account ?? AccountSummary())
        await refreshCart()   // the site merges the guest cart into the account's
    }

    func logout() async {
        if let a = account { await AccountAPI.logout(a) }
        await refreshAccount()
        await refreshCart()
        show("Sesión cerrada")
    }

    func resetSession() async {
        await WebBridge.shared.resetSession()
        branchName = nil
        nonce = nil
        cart = nil
        account = nil
        await refreshCart()
        await refreshAccount()
        show("Sesión reiniciada")
    }

    // MARK: Favorites & compare (kept on the device)

    func isFavorite(_ p: Product) -> Bool { favorites.contains { $0.id == p.id } }

    func toggleFavorite(_ p: Product) {
        if isFavorite(p) {
            favorites.removeAll { $0.id == p.id }
        } else {
            favorites.insert(p, at: 0)
            show("Agregado a favoritos")
        }
    }

    func isCompared(_ p: Product) -> Bool { compare.contains { $0.id == p.id } }

    func toggleCompare(_ p: Product) {
        if isCompared(p) {
            compare.removeAll { $0.id == p.id }
        } else if compare.count >= 4 {
            show("Podés comparar hasta 4 productos")
        } else {
            compare.append(p)
            show("Agregado para comparar")
        }
    }

    // MARK: Misc

    func open(_ path: String, title: String) {
        webPage = WebPage(path: path, title: title)
    }

    /// Native map + list (BranchPickerView); it drives the site's own selector so stock and checkout follow it.
    func pickBranch() { pickingBranch = true }

    func showBranchOnMap(_ inventoryID: String) {
        preselectedBranchID = inventoryID
        pickingBranch = true
    }

    /// Fallback when the native picker can't read the site's branch list: the site's own popup.
    func pickBranchOnWeb() {
        webPage = WebPage(path: "/", title: "Elegir sucursal", hideSiteChrome: false, isBranchPicker: true)
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
        }
    }

    private static func load(_ key: String) -> [Product] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder.wc.decode([Product].self, from: data)) ?? []
    }

    private static func save(_ products: [Product], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder.wc.encode(products), forKey: key)
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .product(let p): ProductDetailView(product: p)
            case .productID(let id): ProductDetailView(productID: id)
            case .list(let title, let q): ProductListView(title: title, query: q)
            case .category(let c): CategoryView(category: c)
            case .favorites: FavoritesView()
            case .compare: CompareView()
            case .branches: BranchesView()
            }
        }
    }
}
