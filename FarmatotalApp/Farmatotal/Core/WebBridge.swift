import SwiftUI
import WebKit

/// The site sits behind Cloudflare, which rejects plain HTTP clients. All API calls therefore run as
/// `fetch()` inside one WKWebView: same cookies, same browser, same session cart as the website.
/// If Cloudflare asks for its human check, the web view is shown so the user can complete it.
@MainActor @Observable
final class WebBridge: NSObject, WKNavigationDelegate {
    static let shared = WebBridge()
    static let site = URL(string: "https://www.farmatotal.com.py")!
    nonisolated static let storeAPI = "/wp-json/wc/store/v1"

    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]
        var url = ""
        var redirected = false
    }

    @ObservationIgnored let webView: WKWebView
    private(set) var isReady = false
    private(set) var needsHumanCheck = false
    private(set) var connectionError: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        super.init()
        webView.navigationDelegate = self
        reload()
    }

    /// Default is the lightest same-origin page; only needed to obtain the origin + Cloudflare clearance.
    func reload(_ url: URL = WebBridge.site.appending(path: "robots.txt")) {
        isReady = false
        webView.load(URLRequest(url: url))
    }

    /// Forgets the site's cookies (login, cart, chosen branch, Cloudflare clearance) and starts a fresh session.
    func resetSession() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        reload()
    }

    // MARK: Requests

    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil,
                 headers: [String: String] = [:], retryOnChallenge: Bool = true) async throws -> Response {
        try await waitUntilReady()
        var sendHeaders = headers
        var body: Any = NSNull()
        if let json {
            sendHeaders["Content-Type"] = "application/json"
            body = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        }
        let url = path.hasPrefix("http") ? path : Self.site.absoluteString + path
        let script = """
        const r = await fetch(url, { method, headers, body: body ?? undefined, credentials: 'include' });
        const h = {}; r.headers.forEach((v, k) => { h[k] = v; });
        return { status: r.status, body: await r.text(), headers: h, url: r.url, redirected: r.redirected };
        """
        let raw = try await webView.callAsyncJavaScript(
            script, arguments: ["url": url, "method": method, "headers": sendHeaders, "body": body],
            in: nil, contentWorld: .defaultClient)
        guard let dict = raw as? [String: Any] else { throw APIError(message: "Respuesta inválida del sitio", status: 0) }
        let response = Response(status: (dict["status"] as? NSNumber)?.intValue ?? 0,
                                body: Data((dict["body"] as? String ?? "").utf8),
                                headers: dict["headers"] as? [String: String] ?? [:],
                                url: dict["url"] as? String ?? url,
                                redirected: (dict["redirected"] as? NSNumber)?.boolValue ?? false)
        let blockedPage = response.headers["cf-mitigated"] != nil || response.headers["content-type"]?.contains("text/html") == true
        if response.status == 403, blockedPage, retryOnChallenge {
            // Cloudflare may challenge only some paths (e.g. /wp-json) and a fetch() can't show its check.
            // Navigating to the blocked address lets it show the check; the clearance then covers every request.
            let target = method == "GET" ? url : Self.site.absoluteString + Self.storeAPI + "/cart"
            reload(URL(string: target) ?? Self.site)
            return try await request(path, method: method, json: json, headers: headers, retryOnChallenge: false)
        }
        return response
    }

    /// Loads a site page in the shared session (as the browser would; optionally POSTing a form) and runs `extract`,
    /// a JavaScript function body that gets `doc` (the parsed page) and `status`, returning its result.
    func scrape(_ path: String, form: [String: String]? = nil, extract: String) async throws -> Any? {
        try await waitUntilReady()
        let url = path.hasPrefix("http") ? path : Self.site.absoluteString + path
        let script = """
        const r = await fetch(url, form ? { method: 'POST', body: new URLSearchParams(form), credentials: 'include' }
                                        : { credentials: 'include' });
        const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
        const status = r.status;
        const t = el => (el?.textContent ?? '').replace(/\\s+/g, ' ').trim();
        const lines = el => {
          if (!el) return '';
          el.querySelectorAll('br').forEach(b => b.replaceWith('\\n'));
          return el.textContent.split('\\n').map(s => s.replace(/\\s+/g, ' ').trim()).filter(Boolean).join('\\n');
        };
        \(extract)
        """
        let formArg: Any = form ?? NSNull()
        return try await webView.callAsyncJavaScript(script, arguments: ["url": url, "form": formArg], in: nil, contentWorld: .defaultClient)
    }

    /// Runs JavaScript that must `return` a value (callAsyncJavaScript tolerates undefined, evaluateJavaScript does not).
    static func run(_ script: String, in webView: WKWebView, args: [String: Any] = [:]) async -> Any? {
        try? await webView.callAsyncJavaScript(script, arguments: args, in: nil, contentWorld: .page)
    }

    /// Name of the branch the site has selected (its "Sucursal más cercana: …" header), or nil if none.
    static func selectedBranch(in webView: WKWebView) async -> String? {
        let js = "return document.querySelector('.woocommerce-multi-inventory-selected-location')?.innerText ?? ''"
        let raw = (await run(js, in: webView) as? String ?? "")
            .replacingOccurrences(of: "Sucursal más cercana:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw.localizedCaseInsensitiveContains("Seleccionar") ? nil : raw
    }

    private func waitUntilReady() async throws {
        // Up to ~3 min: the user may be completing Cloudflare's check.
        for _ in 0..<900 where !isReady {
            try await Task.sleep(for: .milliseconds(200))
        }
        if !isReady { throw APIError(message: connectionError ?? "No se pudo conectar con Farmatotal", status: 0) }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkPage() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryLater(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryLater(error)
    }

    private func retryLater(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }   // the challenge page redirects itself
        connectionError = "Sin conexión con Farmatotal. Reintentando…"
        Task {
            try? await Task.sleep(for: .seconds(3))
            reload()
        }
    }

    private func checkPage() async {
        // Only the interstitial defines _cf_chl_opt; normal pages also load a "challenge-platform" script, so don't match on that.
        let challenged = await Self.run("return typeof window._cf_chl_opt !== 'undefined'", in: webView) as? Bool ?? false
        needsHumanCheck = challenged
        guard !challenged else { return }
        connectionError = nil
        // Images load through URLSession: give it the browser's cookies + user agent (Cloudflare binds clearance to both).
        ImageLoader.userAgent = await Self.run("return navigator.userAgent", in: webView) as? String ?? ""
        for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        isReady = true
    }
}

/// Hosts the bridge web view. It must stay inside the window for its JavaScript to keep running.
struct BridgeWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WebBridge.shared.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: Images

enum ImageLoader {
    static var userAgent = ""
    private static let cache = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let cached = cached(url) { return cached }
        var request = URLRequest(url: url)
        if !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        // Decode off the main thread so scrolling doesn't stutter on big product photos.
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = await UIImage(data: data)?.byPreparingForDisplay() else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct RemoteImage: View {
    let url: String?
    /// Smaller image (usually already cached from a list) shown while `url` loads.
    var preview: String? = nil
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.white   // product photos are shot on white
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else if failed {
                Image(systemName: "photo").font(.title).foregroundStyle(.gray.opacity(0.5))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            if image == nil, let p = preview.flatMap(URL.init(string:)) { image = ImageLoader.cached(p) }
            guard let s = url, let u = URL(string: s) else { failed = image == nil; return }
            if let full = await ImageLoader.load(u) { image = full }
            failed = image == nil
        }
    }
}
