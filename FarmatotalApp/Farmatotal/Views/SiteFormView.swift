import SwiftUI

/// Any of the site's forms (address, account details, password, sign-up, order tracking, contact) shown natively.
/// Fields, options and hidden security values come from the site's page, so it keeps working if the site changes them.
struct SiteFormView: View {
    let title: String
    let page: String
    let selector: String
    /// Edit-type forms close after saving; lookup forms (tracking, contact) stay to show the result.
    var closesOnSuccess = true
    /// Shown above the fields (e.g. the order summary at checkout).
    var intro: String?
    /// Problems found before posting (e.g. no stock at the chosen branch); non-empty blocks the submit.
    var precheck: ((SiteFormSpec) async -> [String])?
    /// How to post; defaults to a regular form post. Checkout posts to WooCommerce's ajax endpoint instead.
    var submitter: ((SiteFormSpec) async throws -> SiteFormAPI.Result)?
    var onSuccess: () async -> Void = {}

    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var spec: SiteFormSpec?
    @State private var loading = true
    @State private var sending = false
    @State private var result: SiteFormAPI.Result?
    @State private var loadError: String?

    var body: some View {
        Form {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if spec == nil {
                ContentUnavailableView {
                    Label("No se pudo cargar el formulario", systemImage: "doc.questionmark")
                } description: {
                    Text(loadError ?? "El sitio no mostró este formulario.")
                } actions: {
                    Button("Abrir en la web") { shop.open(page, title: title) }.buttonStyle(.borderedProminent)
                }
            } else {
                if let intro { Section { Text(intro).font(.subheadline) } }
                if let r = result {
                    if !r.errors.isEmpty {
                        Section {
                            ForEach(r.errors, id: \.self) { Label($0, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                        }
                    } else if let m = r.message {
                        Section { Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if let order = r.order { OrderSections(detail: order) }
                }
                Section {
                    let visible = Set(spec?.visibleFields.map(\.name) ?? [])
                    ForEach(Binding(get: { spec?.fields ?? [] }, set: { spec?.fields = $0 })) { $field in
                        if visible.contains(field.name) { FormFieldRow(field: $field) }
                    }
                }
                Section {
                    Button { Task { await send() } } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text(spec?.submitLabel ?? "Enviar").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(sending)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { shop.open(page, title: title) } label: { Image(systemName: "safari") }
                .accessibilityLabel("Abrir en la web")
        }
        .task { if spec == nil { await load() } }
    }

    private func load() async {
        loading = true
        do { spec = try await SiteFormAPI.load(page, selector: selector) } catch { loadError = error.localizedDescription }
        loading = false
    }

    private func send() async {
        guard let s = spec else { return }
        if !s.missing.isEmpty {
            result = .init(errors: s.missing.map { "Completá “\($0)”." })
            return
        }
        sending = true
        if let precheck {
            let problems = await precheck(s)
            if !problems.isEmpty {
                result = .init(errors: problems)
                sending = false
                return
            }
        }
        do {
            let r = try await (submitter ?? SiteFormAPI.submit)(s)
            result = r
            if r.errors.isEmpty, let redirect = r.redirect {
                // Checkout accepted: continue on the payment page (Bancard) or the order-received page.
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    shop.open(redirect, title: "Pago")
                }
            } else if r.errors.isEmpty {
                await onSuccess()
                if closesOnSuccess {
                    shop.show(r.message ?? "Listo")
                    dismiss()
                }
            }
        } catch {
            result = .init(errors: [error.localizedDescription])
        }
        sending = false
    }
}

struct FormFieldRow: View {
    @Binding var field: FormField

    var body: some View {
        let title = field.label + (field.required ? " *" : "")
        switch field.kind {
        case .select:
            Picker(title, selection: $field.value) {
                ForEach(field.options, id: \.value) { Text($0.label.isEmpty ? "—" : $0.label).tag($0.value) }
            }
        case .radio:
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if field.options.count <= 3 {
                    Picker(title, selection: $field.value) {
                        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker(title, selection: $field.value) {
                        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
            }
        case .checkbox:
            Toggle(title, isOn: Binding(get: { !field.value.isEmpty },
                                        set: { field.value = $0 ? (field.options.first?.value ?? "on") : "" }))
        case .textarea:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextField(field.placeholder, text: $field.value, axis: .vertical).lineLimit(3...8)
            }
        case .password:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                SecureField(field.placeholder, text: $field.value)
                    .textContentType(field.name.contains("new") || field.name.contains("_1") ? .newPassword : .password)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextField(field.placeholder, text: $field.value)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(field.kind == .email ? .never : .sentences)
                    .autocorrectionDisabled(field.kind != .text)
            }
        }
    }

    private var keyboard: UIKeyboardType {
        switch field.kind {
        case .email: .emailAddress
        case .tel: .phonePad
        case .number: .numberPad
        default: field.name.contains("nro_doc") || field.name.contains("order") && field.name.contains("id") ? .numbersAndPunctuation : .default
        }
    }

    /// Autofill hints from WooCommerce's standard field names.
    private var contentType: UITextContentType? {
        let n = field.name
        if field.kind == .email || n.contains("email") { return .emailAddress }
        if field.kind == .tel || n.contains("phone") { return .telephoneNumber }
        if n.hasSuffix("first_name") { return .name }
        if n.hasSuffix("last_name") { return .familyName }
        if n.hasSuffix("address_1") { return .streetAddressLine1 }
        if n.hasSuffix("address_2") { return .streetAddressLine2 }
        if n.hasSuffix("city") { return .addressCity }
        if n.hasSuffix("postcode") { return .postalCode }
        if n.hasSuffix("company") { return .organizationName }
        return nil
    }
}

/// Order products, totals, addresses and updates (account order page and order-tracking result).
struct OrderSections: View {
    let detail: OrderDetail
    @Environment(Shop.self) private var shop

    var body: some View {
        if !detail.items.isEmpty {
            Section("Productos") {
                ForEach(Array(detail.items.enumerated()), id: \.offset) { _, item in
                    LabeledContent { Text(item.total).font(.subheadline.weight(.semibold)) } label: { Text(item.name).font(.subheadline) }
                }
            }
        }
        if !detail.totals.isEmpty {
            Section("Totales") {
                ForEach(Array(detail.totals.enumerated()), id: \.offset) { i, row in
                    LabeledContent(row.label.replacingOccurrences(of: ":", with: ""), value: row.value)
                        .font(i == detail.totals.count - 1 ? .headline : .subheadline)
                }
            }
        }
        if !detail.actions.isEmpty {
            Section {
                ForEach(Array(detail.actions.enumerated()), id: \.offset) { _, a in
                    Button(a.label) { shop.open(a.url, title: a.label) }   // e.g. "Pagar": Bancard's payment page
                }
            }
        }
        if !detail.addresses.isEmpty {
            Section("Direcciones") { ForEach(detail.addresses, id: \.self) { Text($0).font(.subheadline) } }
        }
        if !detail.notes.isEmpty {
            Section("Novedades") { ForEach(detail.notes, id: \.self) { Text($0).font(.subheadline) } }
        }
    }
}
