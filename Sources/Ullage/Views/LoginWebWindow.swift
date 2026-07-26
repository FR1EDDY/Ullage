import AppKit
import WebKit

/// A self-contained sign-in window: it loads a provider's real login page in an
/// embedded browser and watches the cookie jar, calling `onCapture` the moment
/// the credential we're after appears. This is what makes the app usable by
/// anyone who installs it — no scripts, no hand-pasted cookies, no dependency
/// on some other app already being signed in. They click "Connect", log in on
/// the genuine site (so it's as safe and familiar as any browser login), and
/// the app quietly lifts the session credential into the Keychain.
///
/// Cookies are read from `WKHTTPCookieStore`, not `document.cookie`, so
/// `HttpOnly` session cookies — the ones that actually matter — are visible to
/// us. `capture` inspects the current cookie jar and returns the credential
/// string once login is complete, or `nil` while it isn't; Cursor keys off
/// `WorkosCursorSessionToken`, Claude off `sessionKey`.
@MainActor
final class LoginWebWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var captured = false

    private let windowTitle: String
    private let startURL: URL
    private let capture: ([HTTPCookie]) -> String?
    private let onCapture: (String) -> Void
    private let onDismiss: (() -> Void)?

    init(
        title: String,
        startURL: URL,
        captureCookie capture: @escaping ([HTTPCookie]) -> String?,
        onCapture: @escaping (String) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.windowTitle = title
        self.startURL = startURL
        self.capture = capture
        self.onCapture = onCapture
        self.onDismiss = onDismiss
        super.init()
    }

    func show() {
        if window == nil {
            let config = WKWebViewConfiguration()
            // The default store is persistent, so the login behaves like a real
            // browser session (and a returning user often lands already signed
            // in). The credential we capture is copied into our own Keychain
            // item; the web session is incidental.
            config.websiteDataStore = .default()
            let web = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 460, height: 660),
                configuration: config
            )
            // A desktop Safari UA avoids login pages that refuse "embedded
            // browser" user agents and downgrade to a broken flow.
            web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

            let win = NSWindow(
                contentRect: web.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = windowTitle
            win.contentView = web
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self

            self.webView = web
            self.window = win
            web.load(URLRequest(url: startURL))
        }

        // The app runs as a menu-bar accessory with no Dock icon and can't take
        // keyboard focus in that mode — a login form you can't type into is
        // useless. Promote to a regular app for the duration of the login so the
        // window accepts text input, then demote again when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// Poll rather than rely solely on navigation callbacks: session cookies are
    /// often set a beat after the page finishes loading (or via a background
    /// request), so a steady 1s check catches the credential whenever it lands.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCookies() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func checkCookies() {
        guard !captured, let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            return
        }
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.captured, let value = self.capture(cookies) else { return }
                self.captured = true
                self.onCapture(value)
                self.dismiss()
            }
        }
    }

    private func dismiss() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.close()
    }

    /// Fires whenever the window goes away — success (after `dismiss()`
    /// programmatically closes it) or the user cancelling by hand. Either way
    /// the owner should drop its reference to this controller; without this,
    /// a cancelled sign-in left a dead instance retained until the next
    /// connect attempt happened to overwrite it.
    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        webView = nil
        window = nil
        // Back to a silent menu-bar accessory once the login window is gone.
        NSApp.setActivationPolicy(.accessory)
        onDismiss?()
    }
}
