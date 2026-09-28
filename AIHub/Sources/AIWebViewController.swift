import UIKit
import WebKit

/// Hosts one assistant's website.
///
/// GPU notes: WKWebView composites through Core Animation and renders with
/// Metal on every device this app supports, so there is no switch to "turn
/// on" the GPU -- it is already the default path. What actually costs frames
/// on an older device is the work we pile on top of it, so this controller
/// removes that work instead of pretending to flip a flag:
///
///   * isOpaque = true and a matching background, so the compositor never
///     blends the whole web layer against what is behind it.
///   * drawsAsynchronously on the scroll layer, moving rasterisation off the
///     main thread.
///   * A shared WKProcessPool, so switching assistants reuses one warm
///     content process instead of spawning a cold one each time.
///   * suppressesIncrementalRendering = false, so frames paint as they
///     arrive rather than waiting for a complete layout.
///   * "Fast mode" (on by default) neutralises the long CSS animations and
///     transitions these chat UIs use, which is the single biggest win on an
///     A9-class device.
final class AIWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private let service: AIService
    private var webView: WKWebView!
    private var toolbar: UIView!
    private var progress: UIProgressView!
    private var titleLabel: UILabel!
    private var backBtn: UIButton!
    private var fwdBtn: UIButton!
    private var progressObs: NSKeyValueObservation?
    private var titleObs: NSKeyValueObservation?

    private let toolbarHeight: CGFloat = 50

    /// One content process shared by every assistant in this app.
    private static let sharedPool = WKProcessPool()

    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    private var desktopMode: Bool {
        get {
            let k = "AIHubDesktop_" + service.id
            if UserDefaults.standard.object(forKey: k) == nil {
                return service.prefersDesktop
            }
            return UserDefaults.standard.bool(forKey: k)
        }
        set { UserDefaults.standard.set(newValue, forKey: "AIHubDesktop_" + service.id) }
    }

    private var fastMode: Bool {
        get {
            if UserDefaults.standard.object(forKey: "AIHubFastMode") == nil { return true }
            return UserDefaults.standard.bool(forKey: "AIHubFastMode")
        }
        set { UserDefaults.standard.set(newValue, forKey: "AIHubFastMode") }
    }

    init(service: AIService, forceDesktop: Bool?) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        if let f = forceDesktop { self.desktopMode = f }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        progressObs?.invalidate()
        titleObs?.invalidate()
    }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        buildWebView()
        buildToolbar()
        load()
    }

    private func buildWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = AIWebViewController.sharedPool
        // Persistent store: stay logged in between launches.
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.suppressesIncrementalRendering = false

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs

        if fastMode {
            let css = """
            var s=document.createElement('style');
            s.textContent='*,*::before,*::after{animation-duration:0.01s !important;' +
              'animation-delay:0s !important;transition-duration:0.01s !important;' +
              'transition-delay:0s !important;}';
            (document.head||document.documentElement).appendChild(s);
            """
            cfg.userContentController.addUserScript(
                WKUserScript(source: css,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true))
        }

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Opaque: the compositor can skip blending the page against the app.
        webView.isOpaque = true
        webView.backgroundColor = UIColor(white: 0.04, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(white: 0.04, alpha: 1)
        webView.scrollView.layer.drawsAsynchronously = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        applyUserAgent()
        view.addSubview(webView)

        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            let p = Float(wv.estimatedProgress)
            self.progress.setProgress(p, animated: true)
            self.progress.isHidden = (p >= 0.99)
        }
        titleObs = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            let t = wv.title ?? ""
            self.titleLabel.text = t.isEmpty ? self.service.name : t
        }
    }

    private func applyUserAgent() {
        webView.customUserAgent = desktopMode ? AIWebViewController.desktopUA : nil
    }

    private func buildToolbar() {
        toolbar = UIView()
        toolbar.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.addSubview(toolbar)

        let sep = UIView()
        sep.backgroundColor = UIColor(white: 0.22, alpha: 1)
        sep.tag = 55
        toolbar.addSubview(sep)

        progress = UIProgressView(progressViewStyle: .bar)
        progress.progressTintColor = service.tint
        progress.trackTintColor = .clear
        progress.isHidden = true
        view.addSubview(progress)

        func button(_ title: String, _ sel: Selector, _ size: CGFloat) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(UIColor(white: 0.3, alpha: 1), for: .disabled)
            b.titleLabel?.font = .systemFont(ofSize: size, weight: .medium)
            b.addTarget(self, action: sel, for: .touchUpInside)
            toolbar.addSubview(b)
            return b
        }

        let home = button("Hub", #selector(closeTapped), 15)
        home.tag = 61
        home.setTitleColor(service.tint, for: .normal)
        home.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)

        backBtn = button("\u{2039}", #selector(goBack), 30)
        backBtn.tag = 62
        fwdBtn = button("\u{203A}", #selector(goForward), 30)
        fwdBtn.tag = 63

        titleLabel = UILabel()
        titleLabel.text = service.name
        titleLabel.textColor = UIColor(white: 0.75, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.tag = 64
        toolbar.addSubview(titleLabel)

        let more = button("\u{22EF}", #selector(moreTapped), 22)
        more.tag = 65

        refreshNavButtons()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let bottomSafe = view.safeAreaInsets.bottom
        let tbH = toolbarHeight + bottomSafe
        let w = view.bounds.width

        toolbar.frame = CGRect(x: 0, y: view.bounds.height - tbH, width: w, height: tbH)
        toolbar.viewWithTag(55)?.frame = CGRect(x: 0, y: 0, width: w, height: 0.5)

        webView.frame = CGRect(x: 0, y: 0, width: w,
                               height: view.bounds.height - tbH)
        progress.frame = CGRect(x: 0, y: view.safeAreaInsets.top,
                                width: w, height: 2)

        toolbar.viewWithTag(61)?.frame = CGRect(x: 8, y: 0, width: 54, height: toolbarHeight)
        toolbar.viewWithTag(62)?.frame = CGRect(x: 66, y: 0, width: 42, height: toolbarHeight)
        toolbar.viewWithTag(63)?.frame = CGRect(x: 110, y: 0, width: 42, height: toolbarHeight)
        toolbar.viewWithTag(65)?.frame = CGRect(x: w - 52, y: 0, width: 44, height: toolbarHeight)
        toolbar.viewWithTag(64)?.frame = CGRect(x: 158, y: 0,
                                                width: max(40, w - 158 - 56),
                                                height: toolbarHeight)
    }

    private func load() {
        guard let url = URL(string: service.url) else { return }
        webView.load(URLRequest(url: url))
    }

    private func refreshNavButtons() {
        backBtn.isEnabled = webView.canGoBack
        fwdBtn.isEnabled = webView.canGoForward
    }

    // MARK: - Actions

    @objc private func closeTapped() { dismiss(animated: true, completion: nil) }
    @objc private func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc private func goForward() { if webView.canGoForward { webView.goForward() } }

    @objc private func moreTapped() {
        let a = UIAlertController(title: service.name, message: nil,
                                  preferredStyle: .actionSheet)

        a.addAction(UIAlertAction(title: "Reload", style: .default) { _ in
            self.webView.reload()
        })

        let uaTitle = desktopMode ? "Switch to mobile site" : "Switch to desktop site"
        a.addAction(UIAlertAction(title: uaTitle, style: .default) { _ in
            self.desktopMode.toggle()
            self.applyUserAgent()
            self.webView.reload()
        })

        let fastTitle = fastMode ? "Fast mode: ON" : "Fast mode: OFF"
        a.addAction(UIAlertAction(title: fastTitle, style: .default) { _ in
            self.fastMode.toggle()
            let msg = self.fastMode
                ? "Fast mode on. Reopen this assistant to apply."
                : "Fast mode off. Reopen this assistant to apply."
            let t = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
            t.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(t, animated: true)
        })

        a.addAction(UIAlertAction(title: "Home page", style: .default) { _ in
            self.load()
        })

        a.addAction(UIAlertAction(title: "Clear this site's data", style: .destructive) { _ in
            self.clearSiteData()
        })

        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad/regular-width safety.
        if let pop = a.popoverPresentationController {
            pop.sourceView = toolbar
            pop.sourceRect = toolbar.viewWithTag(65)?.frame ?? toolbar.bounds
        }
        present(a, animated: true)
    }

    private func clearSiteData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
            guard let host = URL(string: self.service.url)?.host else { return }
            let base = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let hits = records.filter { $0.displayName.contains(base) }
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: hits) {
                self.webView.reload()
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshNavButtons()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshNavButtons()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showError(error)
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        // -999 is "cancelled", which happens on every redirect; ignore it.
        if ns.code == NSURLErrorCancelled { return }
        let a = UIAlertController(title: "Could not load",
                                  message: ns.localizedDescription,
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
            self.webView.reload()
        })
        a.addAction(UIAlertAction(title: "Back to Hub", style: .cancel) { _ in
            self.dismiss(animated: true, completion: nil)
        })
        present(a, animated: true)
    }

    // MARK: - WKUIDelegate

    /// Keep target="_blank" links inside this web view instead of dropping them.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in
            completionHandler(a?.textFields?.first?.text)
        })
        present(a, animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}
