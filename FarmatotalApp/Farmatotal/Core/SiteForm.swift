import Foundation

/// Reads one of the site's forms from its page and posts it back like the browser, for the native form screen.
@MainActor
enum SiteFormAPI {
    struct Result {
        var errors: [String] = []
        var message: String?
        var order: OrderDetail?     // order-tracking results show the order
        var redirect: String?       // checkout: the payment page (Bancard) or order-received page
    }

    /// WooCommerce's checkout posts to "?wc-ajax=checkout" and answers JSON: {result, redirect} or {result, messages}.
    static func checkout(_ spec: SiteFormSpec) async throws -> Result {
        let raw = try await WebBridge.shared.scrape("/?wc-ajax=checkout", form: spec.payload, extract: """
        let j;
        try { j = JSON.parse(body); } catch (e) { return { errors: ['El sitio respondió algo inesperado. Probá finalizar la compra en la web.'] }; }
        if (j.result === 'success') return { redirect: j.redirect ?? '' };
        const m = new DOMParser().parseFromString(j.messages ?? '', 'text/html');
        const items = [...m.querySelectorAll('li')].map(t).filter(Boolean);
        return { errors: items.length ? items : [t(m.body) || 'No se pudo confirmar el pedido.'] };
        """) as? [String: Any] ?? [:]
        let redirect = raw["redirect"] as? String
        return Result(errors: raw["errors"] as? [String] ?? [], redirect: redirect?.isEmpty == false ? redirect : nil)
    }

    private static func specJS(_ selector: String) -> String {
        """
        const form = doc.querySelector(\(jsString(selector)));
        if (!form) return null;
        const clean = s => (s ?? '').replace(/\\*/g, '').replace(/\\(opcional\\)/i, '').replace(/\\s+/g, ' ').trim();
        const fields = [], done = new Set();
        for (const el of form.querySelectorAll('input, select, textarea')) {
          const name = el.getAttribute('name');
          if (!name || done.has(name)) continue;
          let type = el.tagName === 'SELECT' ? 'select' : el.tagName === 'TEXTAREA' ? 'textarea' : (el.getAttribute('type') || 'text').toLowerCase();
          if (['submit', 'button', 'image', 'reset', 'file'].includes(type)) continue;
          done.add(name);
          const row = el.closest('.form-row, .woocommerce-form-row, label, p');
          const rowLabel = row?.querySelector('label') ?? (row?.tagName === 'LABEL' ? row : null);
          const forLabel = el.id ? form.querySelector('label[for="' + el.id + '"]') : null;
          let options = [], value = el.value ?? '';
          if (type === 'select') { options = [...el.options].map(o => [o.value, t(o)]); value = el.value; }
          if (type === 'radio') {
            const group = [...form.querySelectorAll('input[type="radio"]')].filter(r => r.getAttribute('name') === name);
            options = group.map(r => [r.value, clean(t(r.id ? form.querySelector('label[for="' + r.id + '"]') : null)) || r.value]);
            value = (group.find(r => r.hasAttribute('checked')) ?? group[0])?.value ?? '';
          }
          if (type === 'checkbox') { options = [[el.value || 'on', '']]; value = el.hasAttribute('checked') ? (el.value || 'on') : ''; }
          if (!['text', 'email', 'tel', 'number', 'password', 'select', 'radio', 'checkbox', 'textarea', 'hidden'].includes(type)) type = 'text';
          const label = clean(t(type === 'radio' ? rowLabel : (forLabel ?? rowLabel))) || el.getAttribute('placeholder') || name;
          fields.push({ name, type, label, placeholder: el.getAttribute('placeholder') ?? '',
            required: el.hasAttribute('required') || !!row?.classList?.contains('validate-required') || /\\*/.test(t(rowLabel)),
            options, value });
        }
        const btn = form.querySelector('button[type="submit"], input[type="submit"], button:not([type])');
        if (btn?.getAttribute('name')) fields.push({ name: btn.getAttribute('name'), type: 'hidden', label: '', placeholder: '',
          required: false, options: [], value: btn.getAttribute('value') ?? t(btn) });
        return { action: new URL(form.getAttribute('action') || url, url).href, submit: (btn ? (t(btn) || btn.value) : '') || 'Enviar', fields };
        """
    }

    /// The form matching `selector` on `page`, or nil if the page has none.
    static func load(_ page: String, selector: String) async throws -> SiteFormSpec? {
        guard let raw = try await WebBridge.shared.scrape(page, extract: specJS(selector)) as? [String: Any] else { return nil }
        let fields = FormField.parse(raw["fields"] as? [[String: Any]] ?? [])
        guard !fields.isEmpty else { return nil }
        return SiteFormSpec(action: raw["action"] as? String ?? page, submitLabel: raw["submit"] as? String ?? "Enviar", fields: fields)
    }

    /// Posts the form; reads the site's errors, confirmation and (for order tracking) the order shown.
    static func submit(_ spec: SiteFormSpec) async throws -> Result {
        let raw = try await WebBridge.shared.scrape(spec.action, form: spec.payload, extract: AccountAPI.orderJS + """
        const items = [...doc.querySelectorAll('.woocommerce-error li')].map(t);
        const errors = items.length ? items : [...doc.querySelectorAll('.woocommerce-error, .wpcf7-validation-errors, .wpcf7-not-valid-tip')].map(t);
        const order = orderData();
        return {
          errors: [...new Set(errors.filter(Boolean))],
          message: t(doc.querySelector('.woocommerce-message')) || t(doc.querySelector('.wpcf7-response-output')) || order.summary
                   || t(doc.querySelector('.woocommerce-info')),
          order: order.items.length ? order : null
        };
        """) as? [String: Any] ?? [:]
        let message = raw["message"] as? String ?? ""
        return Result(errors: raw["errors"] as? [String] ?? [],
                      message: message.isEmpty ? nil : message,
                      order: (raw["order"] as? [String: Any]).map(AccountAPI.parseOrder))
    }

    /// A Swift string as a JavaScript string literal.
    private static func jsString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
