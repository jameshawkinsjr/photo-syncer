import PhotoSyncerCore
import SwiftUI
import WebKit

/// Each Amazon or Pix-Star account signs in inside its own WebKit data store, so two
/// accounts on the same service (two Pix-Star frames) can stay signed in side by side.
/// The sync reads that store's cookies; nothing else is kept.
@MainActor
enum WebSessions {
    /// Stores are kept for the life of the app. A store made just for one call goes away
    /// before its cookie store answers, and `allCookies()` then comes back empty: the
    /// account looked signed out everywhere except in the sign-in window.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func store(for account: Account) -> WKWebsiteDataStore {
        if let store = stores[account.id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: account.id)
        stores[account.id] = store
        return store
    }

    static func cookies(for account: Account) async -> [HTTPCookie] {
        await store(for: account).httpCookieStore.allCookies()
    }

    /// Writes back cookies the server refreshed during a sync, so the sign-in lasts.
    static func save(_ cookies: [HTTPCookie], for account: Account) async {
        let store = store(for: account).httpCookieStore
        for cookie in cookies { await store.setCookie(cookie) }
    }

    static func remove(_ account: Account) async {
        // WebKit won't remove a store that's still in use.
        stores[account.id] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: account.id)
    }

    static func signInURL(for service: ServiceKind) -> URL {
        switch service {
        case .amazon: return URL(string: "https://www.amazon.com/photos/all")!
        case .pixstar: return URL(string: "https://www.pix-star.com/my_pixstar/")!
        default: return URL(string: "about:blank")!
        }
    }

    /// Whether the page shows a finished sign-in.
    static func looksSignedIn(_ service: ServiceKind, in webView: WKWebView) async -> Bool {
        let path = webView.url?.path ?? ""
        switch service {
        case .amazon:
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let names = Set(cookies.map(\.name))
            return path.hasPrefix("/photos") && (names.contains("at-main") || names.contains("x-main"))
        case .pixstar:
            // Signed-in pages have a "Log out" link; the sign-in page doesn't.
            let html = try? await webView.evaluateJavaScript("document.documentElement.innerHTML") as? String
            return html?.contains("/accounts/logout/") ?? false
        default:
            return false
        }
    }
}

/// A browser window for signing in to Amazon or Pix-Star.
struct SignInView: View {
    let account: Account
    let onFinish: (Bool) -> Void
    @State private var status = "Sign in below. This window closes when you're signed in."
    @State private var signedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: signedIn ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(signedIn ? .green : .secondary)
                Text(status).font(.callout)
                Spacer()
                Button("Cancel") { onFinish(false) }
                Button("Done") { onFinish(true) }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            SignInWebView(account: account) { webView in
                Task {
                    guard !signedIn, await WebSessions.looksSignedIn(account.service, in: webView) else { return }
                    signedIn = true
                    status = "Signed in."
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onFinish(true)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 680)
    }
}

struct SignInWebView: NSViewRepresentable {
    let account: Account
    let onNavigate: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSessions.store(for: account)
        let view = WKWebView(frame: .zero, configuration: configuration)
        // A desktop Safari user agent, so the sites show their normal sign-in pages.
        view.customUserAgent = HTTPClient.safariUserAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: WebSessions.signInURL(for: account.service)))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (WKWebView) -> Void
        init(onNavigate: @escaping (WKWebView) -> Void) { self.onNavigate = onNavigate }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigate(webView)
        }
    }
}
