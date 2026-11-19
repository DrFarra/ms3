import Foundation

/// The customer's account, read from the site's "Mi cuenta" pages in the app's shared session
/// (WooCommerce has no public login/account API). Endpoint URLs come from the page's own menu,
/// so they work whatever slugs the site uses.
struct AccountSummary {
    var loggedIn = false
    var name = ""
    var links: [String: String] = [:]   // WooCommerce endpoint key → URL: orders, edit-address, edit-account, customer-logout…
    var loginNonce = ""
    var referer = ""
    var lostPassword: String?
    var error: String?
}

struct OrderRow: Identifiable, Hashable {
    let id: String          // "#12345"
    let url: String
    let date: String
    let status: String
    let total: String
}

struct OrderDetail {
    var summary = ""
    var items: [(name: String, total: String)] = []
    var totals: [(label: String, value: String)] = []
    var addresses: [String] = []
    var notes: [String] = []
    var actions: [(label: String, url: String)] = []   // e.g. "Pagar" for pending orders
}

struct AddressCard: Identifiable {
    var id: String { title }
    let title: String
    let text: String
    let editURL: String?
}

@MainActor
enum AccountAPI {
    static let page = "/mi-cuenta/"

    private static let summaryJS = """
    const nav = {};
    doc.querySelectorAll('.woocommerce-MyAccount-navigation-link').forEach(li => {
      const m = li.className.match(/woocommerce-MyAccount-navigation-link--([\\w-]+)/);
      const a = li.querySelector('a');
      if (m && a) nav[m[1]] = a.href;
    });
    const login = doc.querySelector('form.woocommerce-form-login, form.login');
    return {
      loggedIn: !!doc.querySelector('.woocommerce-MyAccount-navigation') && !login,
      name: t(doc.querySelector('.woocommerce-MyAccount-content p strong')),
      links: nav,
      nonce: login?.querySelector('[name="woocommerce-login-nonce"]')?.value ?? '',
      referer: login?.querySelector('[name="_wp_http_referer"]')?.value ?? '',
      lost: doc.querySelector('a[href*="lost-password"], a[href*="contrasena"]')?.href ?? '',
      error: t(doc.querySelector('.woocommerce-error'))
    };
    """

    static func summary() async throws -> AccountSummary {
        parseSummary(try await WebBridge.shared.scrape(page, extract: summaryJS))
    }

    /// Posts the site's own login form (same fields the browser sends).
    static func login(user: String, password: String, using current: AccountSummary) async throws -> AccountSummary {
        let form = ["username": user, "password": password, "rememberme": "forever",
                    "woocommerce-login-nonce": current.loginNonce,
                    "_wp_http_referer": current.referer.isEmpty ? page : current.referer,
                    "login": "Acceder"]
        let result = parseSummary(try await WebBridge.shared.scrape(page, form: form, extract: summaryJS))
        guard result.loggedIn else {
            throw APIError(message: result.error ?? "No se pudo iniciar sesión. Revisá tu usuario y contraseña.", status: 0)
        }
        return result
    }

    static func logout(_ s: AccountSummary) async {
        if let url = s.links["customer-logout"] { _ = try? await WebBridge.shared.scrape(url, extract: "return true;") }
    }

    /// One page of the orders table; `next` is the following page's URL, if any.
    static func orders(_ url: String) async throws -> (rows: [OrderRow], next: String?) {
        let raw = try await WebBridge.shared.scrape(url, extract: """
        const rows = [...doc.querySelectorAll('table.woocommerce-orders-table tbody tr')].map(tr => {
          const cell = k => tr.querySelector('[class*="woocommerce-orders-table__cell-order-' + k + '"]');
          return { number: t(cell('number')), url: cell('number')?.querySelector('a')?.href ?? '',
                   date: t(cell('date')), status: t(cell('status')), total: t(cell('total')) };
        });
        return { rows, next: doc.querySelector('a.woocommerce-button--next')?.href ?? '' };
        """) as? [String: Any] ?? [:]
        let rows = (raw["rows"] as? [[String: String]] ?? []).compactMap { r -> OrderRow? in
            guard let number = r["number"], !number.isEmpty else { return nil }
            return OrderRow(id: number, url: r["url"] ?? "", date: r["date"] ?? "", status: r["status"] ?? "", total: r["total"] ?? "")
        }
        let next = raw["next"] as? String
        return (rows, next?.isEmpty == false ? next : nil)
    }

    static func order(_ url: String) async throws -> OrderDetail {
        let raw = try await WebBridge.shared.scrape(url, extract: """
        const table = doc.querySelector('.woocommerce-table--order-details');
        return {
          summary: t(doc.querySelector('.woocommerce-MyAccount-content > p')),
          items: [...(table?.querySelectorAll('tbody tr') ?? [])].map(tr => [t(tr.querySelector('.product-name')), t(tr.querySelector('.product-total'))]),
          totals: [...(table?.querySelectorAll('tfoot tr') ?? [])].map(tr => [t(tr.querySelector('th')), t(tr.querySelector('td'))]),
          addresses: [...doc.querySelectorAll('.woocommerce-customer-details address')].map(lines),
          notes: [...doc.querySelectorAll('.woocommerce-OrderUpdates li, .woocommerce-OrderUpdate')].map(t),
          actions: [...doc.querySelectorAll('.order-actions-button, .woocommerce-orders-table__cell-order-actions a, a.pay, a.cancel')]
            .map(a => [t(a), a.href]).filter(a => a[0] && a[1])
        };
        """) as? [String: Any] ?? [:]
        func pairs(_ k: String) -> [(String, String)] {
            (raw[k] as? [[String]] ?? []).compactMap { $0.count == 2 && !$0[0].isEmpty ? ($0[0], $0[1]) : nil }
        }
        return OrderDetail(summary: raw["summary"] as? String ?? "",
                           items: pairs("items").map { (name: $0.0, total: $0.1) },
                           totals: pairs("totals").map { (label: $0.0, value: $0.1) },
                           addresses: (raw["addresses"] as? [String] ?? []).filter { !$0.isEmpty },
                           notes: (raw["notes"] as? [String] ?? []).filter { !$0.isEmpty },
                           actions: pairs("actions").map { (label: $0.0, url: $0.1) })
    }

    static func addresses(_ url: String) async throws -> [AddressCard] {
        let raw = try await WebBridge.shared.scrape(url, extract: """
        return [...doc.querySelectorAll('.woocommerce-Address')].map(d => ({
          title: t(d.querySelector('h2, h3')), text: lines(d.querySelector('address')), edit: d.querySelector('a.edit, a[href*="edit-address/"]')?.href ?? ''
        }));
        """) as? [[String: String]] ?? []
        return raw.map { AddressCard(title: $0["title"] ?? "Dirección", text: $0["text"] ?? "",
                                     editURL: ($0["edit"]?.isEmpty == false) ? $0["edit"] : nil) }
    }

    /// Name and email from the account-details form.
    static func details(_ url: String) async throws -> (name: String, email: String) {
        let raw = try await WebBridge.shared.scrape(url, extract: """
        const v = n => doc.querySelector('[name="' + n + '"]')?.value ?? '';
        return [[v('account_first_name'), v('account_last_name')].filter(Boolean).join(' '), v('account_email')];
        """) as? [String] ?? []
        return (raw.first ?? "", raw.count > 1 ? raw[1] : "")
    }

    private static func parseSummary(_ raw: Any?) -> AccountSummary {
        let d = raw as? [String: Any] ?? [:]
        let lost = d["lost"] as? String ?? ""
        let error = d["error"] as? String ?? ""
        return AccountSummary(loggedIn: (d["loggedIn"] as? Bool) ?? ((d["loggedIn"] as? NSNumber)?.boolValue ?? false),
                              name: d["name"] as? String ?? "",
                              links: d["links"] as? [String: String] ?? [:],
                              loginNonce: d["nonce"] as? String ?? "",
                              referer: d["referer"] as? String ?? "",
                              lostPassword: lost.isEmpty ? nil : lost,
                              error: error.isEmpty ? nil : error)
    }
}
