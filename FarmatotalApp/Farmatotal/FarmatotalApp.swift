import SwiftUI

@main
struct FarmatotalApp: App {
    @State private var shop = Shop()
    @State private var bridge = WebBridge.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(shop)
                .environment(bridge)
                .tint(.brand)
        }
    }
}

enum AppTab: Hashable { case home, categories, search, cart, account }

struct RootView: View {
    @Environment(Shop.self) private var shop
    @Environment(WebBridge.self) private var bridge
    @State private var tab: AppTab = .home

    var body: some View {
        @Bindable var shop = shop
        ZStack {
            TabView(selection: $tab) {
                NavigationStack { HomeView(tab: $tab).withRoutes() }
                    .tabItem { Label("Inicio", systemImage: "house.fill") }.tag(AppTab.home)
                NavigationStack { CategoriesView().withRoutes() }
                    .tabItem { Label("Categorías", systemImage: "square.grid.2x2.fill") }.tag(AppTab.categories)
                NavigationStack { SearchView().withRoutes() }
                    .tabItem { Label("Buscar", systemImage: "magnifyingglass") }.tag(AppTab.search)
                CartView(tab: $tab)
                    .tabItem { Label("Carrito", systemImage: "cart.fill") }.tag(AppTab.cart)
                    .badge(shop.cartCount)
                AccountView()
                    .tabItem { Label("Cuenta", systemImage: "person.crop.circle.fill") }.tag(AppTab.account)
            }

            humanCheckLayer
        }
        .overlay(alignment: .top) {
            if let toast = shop.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: shop.toast)
        .sheet(item: $shop.webPage) { WebSheet(page: $0) }
        .task { await shop.refreshCart() }
    }

    /// Same view in both states (only size/opacity change) so the shared WKWebView is never re-parented.
    private var humanCheckLayer: some View {
        let visible = bridge.needsHumanCheck
        return VStack(spacing: 0) {
            if visible {
                VStack(spacing: 4) {
                    Text("Verificación de seguridad").font(.headline)
                    Text("El sitio de Farmatotal pide confirmar que sos una persona. Completá la verificación para continuar.")
                        .font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(LinearGradient.brand)
            }
            BridgeWebView()
                .frame(width: visible ? nil : 1, height: visible ? nil : 1)
        }
        .background(visible ? Color(.systemBackground) : .clear)
        .opacity(visible ? 1 : 0.01)
        .allowsHitTesting(visible)
    }
}
