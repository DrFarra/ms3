import SwiftUI

/// "Mi cuenta" section of the Cuenta tab: native login, orders, addresses; site forms only for editing.
struct MyAccountSection: View {
    @Environment(Shop.self) private var shop
    @State private var showLogin = false
    @State private var email = ""

    var body: some View {
        Section("Mi cuenta") {
            if let a = shop.account, a.loggedIn {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hola, \(a.name.isEmpty ? "cliente" : a.name)").font(.headline)
                    if !email.isEmpty { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
                if let url = a.links["orders"] {
                    NavigationLink { OrdersView(firstPage: url) } label: { Label("Mis pedidos", systemImage: "bag") }
                }
                if let url = a.links["edit-address"] {
                    NavigationLink { AddressesView(url: url) } label: { Label("Direcciones", systemImage: "house") }
                }
                if let url = a.links["edit-account"] {
                    Button { shop.open(url, title: "Datos y contraseña") } label: {
                        Label("Datos y contraseña", systemImage: "person.text.rectangle").foregroundStyle(.primary)
                    }
                }
                Button(role: .destructive) { Task { await shop.logout() } } label: {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else if shop.account == nil {
                HStack { ProgressView(); Text("Cargando tu cuenta…").foregroundStyle(.secondary) }
            } else {
                Button { showLogin = true } label: { Label("Iniciar sesión", systemImage: "person.crop.circle.badge.checkmark") }
                Button { shop.open(AccountAPI.page, title: "Crear cuenta") } label: {
                    Label("Crear cuenta", systemImage: "person.badge.plus").foregroundStyle(.primary)
                }
            }
        }
        .task(id: shop.account?.loggedIn) {
            if shop.account == nil { await shop.refreshAccount() }
            if let a = shop.account, a.loggedIn, let url = a.links["edit-account"] {
                email = (try? await AccountAPI.details(url))?.email ?? ""
            } else {
                email = ""
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
    }
}

struct LoginView: View {
    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Correo o usuario", text: $user)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Contraseña", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await submit() } }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Ingresar").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(user.isEmpty || password.isEmpty || busy)
                }
                Section {
                    Button("¿Olvidaste tu contraseña?") {
                        openOnWeb(shop.account?.lostPassword ?? AccountAPI.page + "lost-password/", "Recuperar contraseña")
                    }
                    Button("Ingresar con Facebook o Google") { openOnWeb(AccountAPI.page, "Ingresar") }
                    Button("Crear una cuenta") { openOnWeb(AccountAPI.page, "Crear cuenta") }
                } footer: {
                    Text("Estas opciones usan las páginas del sitio. Google puede no permitir ingresar desde una app.")
                }
            }
            .navigationTitle("Iniciar sesión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .task { if shop.account?.loginNonce.isEmpty != false { await shop.refreshAccount() } }
    }

    private func submit() async {
        guard !user.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        do {
            try await shop.login(user: user, password: password)
            shop.show("¡Hola, \(shop.account?.name ?? "")!")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func openOnWeb(_ url: String, _ title: String) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(600))   // let this sheet close first
            shop.open(url, title: title)
        }
    }
}

struct OrdersView: View {
    let firstPage: String
    @State private var orders: [OrderRow] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(orders) { o in
                NavigationLink { OrderDetailView(order: o) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pedido \(o.id)").font(.headline)
                            Spacer()
                            StatusChip(status: o.status)
                        }
                        HStack {
                            Text(o.date).foregroundStyle(.secondary)
                            Spacer()
                            Text(o.total).font(.subheadline.weight(.semibold))
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let next, !loading {
                Button("Ver pedidos anteriores") { Task { await load(next) } }
            }
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .overlay {
            if let error, orders.isEmpty {
                ErrorView(message: error) { Task { await load(firstPage) } }
            } else if !loading && orders.isEmpty && error == nil {
                ContentUnavailableView("Todavía no hiciste pedidos", systemImage: "bag")
            }
        }
        .navigationTitle("Mis pedidos")
        .refreshable { orders = []; await load(firstPage) }
        .task { if orders.isEmpty { await load(firstPage) } }
    }

    private func load(_ url: String) async {
        loading = true
        error = nil
        do {
            let page = try await AccountAPI.orders(url)
            orders += page.rows.filter { r in !orders.contains { $0.id == r.id } }
            next = page.next
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct StatusChip: View {
    let status: String
    var body: some View {
        let s = status.lowercased()
        let color: Color = s.contains("complet") ? .green
            : (s.contains("cancel") || s.contains("fall") || s.contains("reembols")) ? .red : .orange
        Text(status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct OrderDetailView: View {
    let order: OrderRow
    @Environment(Shop.self) private var shop
    @State private var detail: OrderDetail?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text(order.date).foregroundStyle(.secondary)
                    Spacer()
                    StatusChip(status: order.status)
                }
                if let s = detail?.summary, !s.isEmpty { Text(s).font(.subheadline) }
            }
            if let d = detail {
                if !d.items.isEmpty {
                    Section("Productos") {
                        ForEach(Array(d.items.enumerated()), id: \.offset) { _, item in
                            LabeledContent { Text(item.total).font(.subheadline.weight(.semibold)) } label: {
                                Text(item.name).font(.subheadline)
                            }
                        }
                    }
                }
                if !d.totals.isEmpty {
                    Section("Totales") {
                        ForEach(Array(d.totals.enumerated()), id: \.offset) { i, row in
                            LabeledContent(row.label.replacingOccurrences(of: ":", with: ""), value: row.value)
                                .font(i == d.totals.count - 1 ? .headline : .subheadline)
                        }
                    }
                }
                if !d.actions.isEmpty {
                    Section {
                        ForEach(Array(d.actions.enumerated()), id: \.offset) { _, a in
                            Button(a.label) { shop.open(a.url, title: a.label) }
                        }
                    }
                }
                if !d.addresses.isEmpty {
                    Section("Direcciones") {
                        ForEach(d.addresses, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
                if !d.notes.isEmpty {
                    Section("Novedades") {
                        ForEach(d.notes, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
            } else if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Pedido \(order.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !order.url.isEmpty {
                Button { shop.open(order.url, title: "Pedido \(order.id)") } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Ver en la web")
            }
        }
        .task {
            guard detail == nil, !order.url.isEmpty else { return }
            do { detail = try await AccountAPI.order(order.url) } catch { self.error = error.localizedDescription }
        }
    }
}

struct AddressesView: View {
    let url: String
    @Environment(Shop.self) private var shop
    @State private var cards: [AddressCard] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(cards) { c in
                Section(c.title) {
                    Text(c.text.isEmpty ? "Todavía no cargaste esta dirección." : c.text)
                        .font(.subheadline)
                        .foregroundStyle(c.text.isEmpty ? .secondary : .primary)
                    if let edit = c.editURL {
                        Button { shop.open(edit, title: c.title) } label: { Label("Editar", systemImage: "pencil") }
                    }
                }
            }
        }
        .overlay {
            if let error, cards.isEmpty { ErrorView(message: error) { Task { await load() } } }
            else if !loaded { ProgressView() }
        }
        .navigationTitle("Direcciones")
        .refreshable { await load() }
        .task { await load() }   // also re-reads after editing on the site
    }

    private func load() async {
        error = nil
        do { cards = try await AccountAPI.addresses(url) } catch { self.error = error.localizedDescription }
        loaded = true
    }
}
