import SwiftUI
import WebKit

/// Shows a page of the real website (checkout with Bancard, account/login, order tracking, branch picker…)
/// in the app's shared web session, so the cart and login are the same as in the native screens.
struct WebSheet: View {
    let page: WebPage
    @Environment(Shop.self) private var shop
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            SiteWebView(page: page, loading: $loading,
                        onBranch: { shop.branchName = $0 },
                        onBranchPicked: {
                            shop.show("Sucursal actualizada")
                            dismiss()
                        })
                .overlay { if loading { ProgressView().controlSize(.large) } }
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                }
        }
        // Checkout, login or branch changes affect the cart and the account: re-read both.
        .onDisappear {
            Task {
                await shop.refreshCart()
                await shop.refreshAccount()   // the user may have logged in (e.g. Facebook) or edited data here
            }
        }
    }
}

private struct SiteWebView: UIViewRepresentable {
    let page: WebPage
    @Binding var loading: Bool
    let onBranch: (String) -> Void
    let onBranchPicked: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if page.hideSiteChrome {
            // The app already provides navigation; hide the site's header, footer and side menu.
            let css = ".site-header,.site-footer,.site-canvas,.wcbvs-floating-buttons{display:none!important}"
            let js = "var s=document.createElement('style');s.textContent='\(css)';document.documentElement.appendChild(s);"
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: page.path, relativeTo: WebBridge.site)!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: SiteWebView
        private var initialBranch: String?
        private var loads = 0

        init(_ parent: SiteWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            loads += 1
            Task { @MainActor in
                let branch = await WebBridge.selectedBranch(in: webView)
                if let branch { parent.onBranch(branch) }
                guard parent.page.isBranchPicker else { return }
                if loads == 1 {
                    initialBranch = branch
                    // Open the site's own branch selector (with "nearest branch" geolocation).
                    _ = await WebBridge.run("document.querySelector('.woocommerce-multi-inventory-open-poup')?.click(); return true", in: webView)
                } else if branch != nil, branch != initialBranch || webView.url?.query?.contains("inventory=") == true {
                    parent.onBranchPicked()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // tel:, mailto:, WhatsApp, maps… open in their apps.
            if let url = action.request.url, let scheme = url.scheme, !["http", "https", "about", "blob", "data"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target="_blank" links (e.g. payment pages) open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            guard let top = webView.window?.rootViewController?.topMost else { return completionHandler() }
            top.present(alert, animated: true)
        }
    }
}

private extension UIViewController {
    var topMost: UIViewController { presentedViewController?.topMost ?? self }
}
