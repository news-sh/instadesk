import UIKit
import WebKit
import AVFoundation
import UserNotifications
import CallKit
import LocalAuthentication

/// A single-purpose WKWebView shell for Instagram.
///
/// TWO-PHASE DESIGN:
///
///   Phase 1 "login"   — presents as a normal iPhone Safari. No spoofing.
///                       Meta's login flow issues a session cookie bound to
///                       a consistent fingerprint, so the captcha/redirect
///                       loop doesn't happen.
///
///   Phase 2 "desktop" — once a valid `sessionid` cookie exists, switch to a
///                       desktop UA + fingerprint spoof so Instagram serves
///                       the desktop DM UI with audio/video call buttons.
///
/// Plus a browser-style ZOOM control. Zoom is implemented by rewriting the
/// viewport meta's logical width: a narrower logical width means the same
/// physical screen shows fewer CSS pixels, i.e. everything looks bigger.
/// This keeps Instagram's desktop layout intact (unlike CSS `zoom`, which
/// breaks position:fixed overlays such as the in-call controls).
final class WebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate,
                               WKScriptMessageHandler,
                               UNUserNotificationCenterDelegate,
                               CXProviderDelegate {

    private var webView: WKWebView!

    private let mobileUA  = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) " +
                            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
                            "Version/15.6 Mobile/15E148 Safari/604.1"

    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
                            "Version/16.6 Safari/605.1.15"

    private let loginURL   = URL(string: "https://www.instagram.com/accounts/login/")!
    private let desktopURL = URL(string: "https://www.instagram.com/direct/inbox/")!

    // MARK: Zoom

    /// Logical viewport widths. Narrower = more zoomed in.
    /// Index 3 (1024) is the default and matches a small laptop window.
    private let zoomWidths: [Int] = [1600, 1440, 1280, 1024, 900, 800, 700, 600, 500, 420]
    private let defaultZoomIndex = 3

    private var zoomIndex: Int {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "InstaDeskZoom") == nil { return defaultZoomIndex }
            return min(max(d.integer(forKey: "InstaDeskZoom"), 0), zoomWidths.count - 1)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), zoomWidths.count - 1),
                                      forKey: "InstaDeskZoom")
        }
    }

    /// Percentage shown in the toolbar, relative to the 1024 default.
    private var zoomPercent: Int {
        Int((Double(zoomWidths[defaultZoomIndex]) / Double(zoomWidths[zoomIndex]) * 100).rounded())
    }

    // MARK: Phase

    private var desktopMode: Bool {
        get { UserDefaults.standard.bool(forKey: "InstaDeskDesktopMode") }
        set { UserDefaults.standard.set(newValue, forKey: "InstaDeskDesktopMode") }
    }

    private var didSwitchThisLaunch = false

    /// Spoofed desktop dimensions in landscape orientation, computed from the
    /// real screen in buildWebView(). Swapped on rotation.
    private var landscapeW = 1440
    private var landscapeH = 810

    // MARK: UI

    private var toolbar: UIView!
    private var modeButton: UIButton!
    private var zoomOutButton: UIButton!
    private var zoomInButton: UIButton!
    private var zoomLabel: UILabel!
    private var callButton: UIButton!
    private var callModeOn = false
    /// Identifier of the local notification currently on screen, so we can
    /// pull it down as soon as the call is answered or stops ringing.
    private var ringNotificationID: String? = nil
    private var notificationsReady = false
    /// Accept/Decline tapped from the lock screen or another app cannot run
    /// immediately: WKWebView suspends JavaScript while backgrounded, so
    /// evaluateJavaScript is silently dropped. We queue the action and flush
    /// it once the app is actually active and the web view is live again.
    private var pendingRingAction: String? = nil
    private var pendingRingDeadline: Date? = nil
    /// Native answer screen shown when the user accepts from the lock screen
    /// or another app. We no longer try to auto-press Instagram's button from
    /// the background (WKWebView suspends JS there, so it silently failed).
    /// Instead we surface a real UIKit Accept button once the app is up.
    private var answerOverlay: UIView? = nil
    private var answerName: String = "Someone"
    private var answerKind: String = "voice"
    private var pendingAnswerOverlay = false
    /// When true the ringer is INFORMATIONAL only: it shows who is calling
    /// but its Accept button does not answer. Answering is deliberately
    /// routed through the notification's Accept action instead, which is the
    /// path that reliably works. Set false once we arrive via that action.
    private var answerDisplayOnly = true
    private var lastRingName = "Someone"
    private var lastRingKind = "voice"
    /// When on, answering a call requires Touch ID / Face ID first.
    private var requireBiometric: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "InstaDeskBiometric") == nil { return true }
            return d.bool(forKey: "InstaDeskBiometric")
        }
        set { UserDefaults.standard.set(newValue, forKey: "InstaDeskBiometric") }
    }
    private var didAutoOpenCallMode = false
    /// While a call is on screen we force 244% zoom (the 420pt viewport
    /// rung: 1024/420 = 244%) and restore the user's zoom afterwards.
    private let callZoomIndex = 9
    private var zoomBeforeCall: Int? = nil
    private var inCallNow = false
    /// Kept so we can re-inject Call Mode if the page load raced the
    /// user script (Instagram is an SPA and sometimes swaps <body>).
    private var callModeSource = ""

    // Incoming-call banner ("widget")
    private var ringBanner: UIView!
    private var ringLabel: UILabel!
    private var ringSubLabel: UILabel!
    private var ringAccept: UIButton!
    private var ringDecline: UIButton!
    private var isRinging = false
    private var lastRingSignature = ""

    private let toolbarHeight: CGFloat = 46

    /// Total height of the native chrome below the web view.
    private var chromeHeight: CGFloat { toolbarHeight + ringBannerHeight }

    /// The frame the web view should occupy: everything above the chrome.
    private var webContentFrame: CGRect {
        CGRect(x: 0, y: 0,
               width: view.bounds.width,
               height: max(120, view.bounds.height - chromeHeight))
    }

    /// Recompute the spoofed desktop dimensions so their aspect ratio matches
    /// the web view's real visible area, not the whole screen.
    private func recomputeSpoofedGeometry() {
        let area = webContentFrame.size
        let long  = max(area.width, area.height)
        let short = min(area.width, area.height)
        let aspect = Double(long / max(short, 1))
        landscapeW = 1440
        landscapeH = Int((1440.0 / max(aspect, 1.0)).rounded())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNotifications()
        // If iOS never asked (common on a sideloaded first launch), ask again
        // shortly after startup so the app appears under Settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                guard s.authorizationStatus == .notDetermined else { return }
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async { self?.notificationsReady = granted }
                }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushPendingRingAction),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        view.backgroundColor = .black
        buildWebView()
        buildToolbar()
        buildRingBanner()
        layoutRingBanner()
        loadCurrentPhase()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestMediaPermissions()
        configureAudioSession()
    }

    // MARK: - Phase handling

    private func loadCurrentPhase() {
        if desktopMode {
            webView.customUserAgent = desktopUA
            webView.load(URLRequest(url: desktopURL))
        } else {
            webView.customUserAgent = mobileUA
            webView.load(URLRequest(url: loginURL))
        }
        refreshToolbar()
    }

    private func checkForSessionAndPromote() {
        guard !desktopMode, !didSwitchThisLaunch else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let loggedIn = cookies.contains {
                $0.name == "sessionid" && !$0.value.isEmpty &&
                $0.domain.contains("instagram.com")
            }
            guard loggedIn else { return }
            self.didSwitchThisLaunch = true
            self.desktopMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.webView.customUserAgent = self.desktopUA
                self.webView.load(URLRequest(url: self.desktopURL))
                self.refreshToolbar()
            }
        }
    }

    // MARK: - Web view

    private func buildWebView() {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true

        // --- Real geometry of the VISIBLE web area ---------------------
        // The web view does not fill the screen: the mode/zoom toolbar and
        // the call banner sit below it. Spoofing the full screen ratio made
        // Instagram lay out for a taller viewport than it actually gets, so
        // we derive the ratio from the area the page really occupies.
        let dpr = Int(UIScreen.main.scale.rounded())
        recomputeSpoofedGeometry()
        let startLandscape = view.bounds.width > view.bounds.height
        let geomJS = "window.__idW=\(startLandscape ? landscapeW : landscapeH);" +
                     "window.__idH=\(startLandscape ? landscapeH : landscapeW);" +
                     "window.__idDPR=\(dpr);"
        config.userContentController.addUserScript(
            WKUserScript(source: geomJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))

        // Desktop fingerprint spoof, inert unless the UA claims Macintosh
        // (so it does nothing during the mobile login phase).
        let spoofJS = """
        (function () {
          try {
            if (navigator.userAgent.indexOf('Macintosh') === -1) { return; }
            var d = function (o, k, v) {
              try { Object.defineProperty(o, k, { get: function () { return v; }, configurable: true }); } catch (e) {}
            };
            d(navigator, 'platform', 'MacIntel');
            d(navigator, 'maxTouchPoints', 0);
            d(navigator, 'vendor', 'Apple Computer, Inc.');
            // Screen geometry comes from the native side (window.__idW/__idH)
            // and is derived from the real device screen, so the aspect ratio
            // we claim matches the hardware. Mismatched dimensions are a
            // fingerprinting signal, and a wrong ratio makes Instagram's
            // desktop layout land badly.
            var sw = window.__idW || 1440, sh = window.__idH || 810;
            d(screen, 'width',       sw);
            d(screen, 'height',      sh);
            d(screen, 'availWidth',  sw);
            d(screen, 'availHeight', sh - 25);
            d(window, 'devicePixelRatio', window.__idDPR || 2);
            d(screen, 'colorDepth', 24);
            d(screen, 'pixelDepth', 24);
            if (screen.orientation) {
              d(screen.orientation, 'type',  sw >= sh ? 'landscape-primary' : 'portrait-primary');
              d(screen.orientation, 'angle', 0);
            }
            try { delete window.ontouchstart; } catch (e) {}
            try { delete window.ontouchmove; } catch (e) {}
            try { delete window.orientation; } catch (e) {}
            if (window.matchMedia) {
              var mm = window.matchMedia.bind(window);
              window.matchMedia = function (q) {
                if (/pointer\\s*:\\s*coarse|hover\\s*:\\s*none/.test(q)) {
                  return { matches: false, media: q, addListener: function () {}, removeListener: function () {},
                           addEventListener: function () {}, removeEventListener: function () {} };
                }
                return mm(q);
              };
            }
          } catch (e) {}
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: spoofJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))

        // Zoom engine. Defines window.__instadeskZoom(width) which rewrites
        // the viewport meta, and re-applies on SPA route changes (Instagram
        // replaces <head> contents when navigating between DM threads).
        let zoomEngineJS = """
        (function () {
          try {
            if (navigator.userAgent.indexOf('Macintosh') === -1) { return; }
            window.__instadeskWidth = window.__instadeskWidth || 1024;

            window.__instadeskZoom = function (w) {
              window.__instadeskWidth = w;
              var meta = document.querySelector('meta[name=viewport]');
              if (!meta) {
                meta = document.createElement('meta');
                meta.setAttribute('name', 'viewport');
                (document.head || document.documentElement).appendChild(meta);
              }
              meta.setAttribute('content',
                'width=' + w + ', initial-scale=' + (window.innerWidth ? 1 : 1) +
                ', minimum-scale=0.1, maximum-scale=10, user-scalable=yes');
              // Nudge WebKit into re-evaluating the viewport immediately.
              document.documentElement.style.zoom = '';
              window.dispatchEvent(new Event('resize'));
              return w;
            };

            var applyStyle = function () {
              if (document.getElementById('__instadesk_style')) { return; }
              var style = document.createElement('style');
              style.id = '__instadesk_style';
              style.textContent =
                'div[role=dialog], section main {' +
                '  transform: translateZ(0);' +
                '  will-change: transform;' +
                '  backface-visibility: hidden; }' +
                'html { -webkit-text-size-adjust: none !important; }';
              (document.head || document.documentElement).appendChild(style);
            };

            var reapply = function () {
              applyStyle();
              window.__instadeskZoom(window.__instadeskWidth);
            };

            document.addEventListener('DOMContentLoaded', reapply);
            window.addEventListener('load', reapply);

            // Instagram is a single-page app: patch history so we re-apply
            // the viewport after client-side navigations too.
            ['pushState', 'replaceState'].forEach(function (m) {
              var orig = history[m];
              history[m] = function () {
                var r = orig.apply(this, arguments);
                setTimeout(reapply, 60);
                return r;
              };
            });
            window.addEventListener('popstate', function () { setTimeout(reapply, 60); });

            reapply();
          } catch (e) {}
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: zoomEngineJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))

        // --- CALL MODE -------------------------------------------------
        // A full-screen overlay listing your DM threads. Pick a person, pick
        // Voice or Video, and it drives Instagram's own UI: opens the thread,
        // then clicks the real call button. We do NOT reimplement calling --
        // that's Meta's private WebRTC signalling and is not reachable from
        // page JS. This is a friendlier front-end onto their controls.
        //
        // Desktop mode only: the call buttons don't exist in the mobile UI.
        let callModeJS = """
        (function () {
          try {
            if (window.__idCM2) { return; }
            window.__idCM2 = true;
            // The lobby watcher must run in EVERY frame, but the bar and
            // panel must only be built once, in the top document.
            var IS_TOP = (function () { try { return window.top === window; } catch (e) { return true; } })();

            var BAR = '__id_callbar';
            var DIAG = '__id_diagbox';

            function style() {
              if (document.getElementById('__id_cm2_style')) { return; }
              var s = document.createElement('style');
              s.id = '__id_cm2_style';
              s.textContent =
                '#' + BAR + '{position:fixed;left:0;right:0;bottom:0;z-index:2147483000;' +
                'background:#15151a;border-top:1px solid #2b2b33;padding:8px 10px;' +
                'display:none;box-sizing:border-box;' +
                'font:14px -apple-system,system-ui,sans-serif;}' +
                '#' + BAR + '.on{display:flex;gap:8px;align-items:center;}' +
                '#' + BAR + ' button{flex:1;padding:11px 6px;border:none;border-radius:10px;' +
                'color:#fff;font-size:14px;font-weight:700;}' +
                '#' + BAR + ' .v{background:#2e7d32;}' +
                '#' + BAR + ' .d{background:#1565c0;}' +
                '#' + BAR + ' .q{background:#3a3a44;flex:0 0 auto;width:52px;font-weight:600;font-size:12px;}' +
                '#' + BAR + ' .x{background:#3a3a44;flex:0 0 auto;width:40px;font-weight:700;}' +
                '#' + DIAG + '{position:fixed;left:0;right:0;top:0;bottom:0;z-index:2147483002;' +
                'background:#0d0d11;color:#d8d8e0;display:none;flex-direction:column;' +
                'font:12px ui-monospace,Menlo,monospace;}' +
                '#' + DIAG + '.on{display:flex;}' +
                '#' + DIAG + ' .h{padding:12px 14px;font:600 15px -apple-system,system-ui,sans-serif;' +
                'color:#fff;border-bottom:1px solid #26262c;flex:0 0 auto;}' +
                '#' + DIAG + ' textarea{flex:1 1 auto;width:100%;box-sizing:border-box;border:none;' +
                'background:#0d0d11;color:#c8c8d2;padding:12px 14px;font:12px ui-monospace,Menlo,monospace;' +
                'resize:none;outline:none;}' +
                '#' + DIAG + ' .f{flex:0 0 auto;padding:10px 14px 14px;display:flex;gap:8px;' +
                'border-top:1px solid #26262c;}' +
                '#' + DIAG + ' .f button{flex:1;padding:11px;border:none;border-radius:9px;' +
                'background:#2c2c33;color:#fff;font:600 14px -apple-system,system-ui,sans-serif;}' +
                '#__id_panel{position:fixed;left:0;right:0;top:0;bottom:0;z-index:2147483001;' +
                'background:#101014;color:#fff;display:none;flex-direction:column;' +
                'font:15px -apple-system,system-ui,sans-serif;}' +
                '#__id_panel.on{display:flex;}' +
                '#__id_panel .idhdr{padding:12px 14px;font-size:16px;font-weight:700;' +
                'border-bottom:1px solid #26262c;flex:0 0 auto;}' +
                '#__id_panel .idhdr .ver{font-size:10px;font-weight:700;color:#0b0b0e;' +
                'background:#0095f6;border-radius:5px;padding:2px 6px;' +
                'vertical-align:middle;margin-left:5px;}' +
                '#__id_panel .idhdr .sub{display:block;font-size:11px;font-weight:400;' +
                'color:#8e8e93;margin-top:2px;}' +
                '#__id_panel .idlist{flex:1 1 auto;overflow-y:auto;-webkit-overflow-scrolling:touch;}' +
                '#__id_panel .idrow{display:flex;align-items:center;padding:9px 10px;' +
                'flex-wrap:nowrap;' +
                'border-bottom:1px solid #1e1e24;}' +
                '#__id_panel .idav{width:44px;height:44px;border-radius:50%;background:#2c2c33;' +
                'flex:0 0 auto;margin-right:11px;object-fit:cover;}' +
                '#__id_panel .idavf{display:flex;align-items:center;justify-content:center;' +
                'font-weight:700;font-size:18px;color:#cfcfd6;' +
                'background:linear-gradient(135deg,#3a3a44,#22222a);}' +
                '#__id_panel .idmeta{flex:1 1 auto;min-width:0;margin-right:6px;}' +
                '#__id_panel .idhandle{font-size:12px;color:#8e8e93;overflow:hidden;' +
                'text-overflow:ellipsis;white-space:nowrap;margin-top:1px;}' +
                '#__id_panel .idname{overflow:hidden;text-overflow:ellipsis;' +
                'white-space:nowrap;font-weight:600;}' +
                '#__id_panel .idcta{margin:14px 12px;padding:13px;border:none;border-radius:10px;' +
                'background:#0095f6;color:#fff;font:700 15px -apple-system,system-ui,sans-serif;' +
                'display:block;width:calc(100% - 24px);}' +
                '#__id_panel .idsec{padding:9px 14px 4px;font-size:11px;font-weight:700;' +
                'letter-spacing:.6px;color:#6e6e76;text-transform:uppercase;}' +
                '#__id_panel .idbtn{flex:0 0 auto;width:36px;height:36px;border-radius:50%;' +
                'border:none;color:#fff;font-size:14px;font-weight:700;margin-left:5px;}' +
                '#__id_panel .idvoice{background:#2e7d32;}' +
                '#__id_panel .idvideo{background:#1565c0;}' +
                '#__id_panel .idrm{background:#3a3a44;}' +
                '#__id_panel .idedit{background:#4a4a55;width:auto;padding:0 10px;' +
                'border-radius:15px;font-size:11px;}' +
                '#__id_edit{position:fixed;left:0;right:0;top:0;bottom:0;z-index:2147483040;' +
                'background:rgba(0,0,0,.72);display:flex;align-items:center;' +
                'justify-content:center;padding:18px;' +
                'font:15px -apple-system,system-ui,sans-serif;}' +
                '#__id_edit .idcard{background:#1c1c22;border-radius:14px;padding:16px;' +
                'width:100%;max-width:330px;box-shadow:0 10px 40px rgba(0,0,0,.6);}' +
                '#__id_edit .idct{color:#fff;font-weight:700;font-size:16px;margin-bottom:12px;}' +
                '#__id_edit .idinp{width:100%;box-sizing:border-box;padding:12px;' +
                'border-radius:9px;border:1px solid #3a3a44;background:#101014;color:#fff;' +
                'font-size:16px;outline:none;}' +
                '#__id_edit .idhint{color:#6e6e76;font-size:11px;margin-top:7px;' +
                'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
                '#__id_edit .idcbtns{display:flex;gap:9px;margin-top:15px;}' +
                '#__id_edit .idcbtns button{flex:1;padding:12px;border:none;border-radius:9px;' +
                'font:700 14px -apple-system,system-ui,sans-serif;}' +
                '#__id_edit .idcancel{background:#2c2c33;color:#fff;}' +
                '#__id_edit .idok{background:#0095f6;color:#fff;}' +
                '#__id_panel .idmsg{padding:22px 18px;color:#8e8e93;text-align:center;' +
                'line-height:1.55;font-size:14px;}' +
                '#__id_panel .idfoot{flex:0 0 auto;padding:10px 12px 14px;display:flex;gap:8px;' +
                'border-top:1px solid #26262c;}' +
                '#__id_panel .idfoot button{flex:1;padding:11px 4px;border:none;border-radius:9px;' +
                'background:#2c2c33;color:#fff;font:600 13px -apple-system,system-ui,sans-serif;}' +
                '#__id_callui{position:fixed;left:0;right:0;top:0;bottom:0;z-index:2147483020;' +
                'background:#0b0b0b;display:flex;flex-direction:column;align-items:center;' +
                'font:15px -apple-system,system-ui,sans-serif;color:#fff;' +
                'padding:14px 12px 18px;box-sizing:border-box;}' +
                '#__id_callui .idctop{width:100%;display:flex;}' +
                '#__id_callui .idmini{width:44px;height:44px;border-radius:50%;border:none;' +
                'background:#2a2a2a;color:#fff;font-size:19px;}' +
                '#__id_callui .idcname{font-size:27px;font-weight:700;margin-top:-30px;' +
                'text-align:center;max-width:88%;overflow:hidden;text-overflow:ellipsis;' +
                'white-space:nowrap;}' +
                '#__id_callui .idcstat{font-size:16px;color:#b0b0b0;margin-top:3px;}' +
                '#__id_callui .idcavw{flex:1 1 auto;display:flex;align-items:center;' +
                'justify-content:center;width:100%;}' +
                '#__id_callui .idcav{width:190px;height:190px;border-radius:50%;' +
                'object-fit:cover;background:#222;}' +
                '#__id_callui .idcavf{display:flex;align-items:center;justify-content:center;' +
                'font-size:70px;font-weight:700;color:#8e8e93;}' +
                '#__id_callui .idcgrid{width:100%;max-width:420px;background:#1c1c1e;' +
                'border-radius:22px;padding:18px 6px;display:flex;flex-wrap:wrap;' +
                'box-sizing:border-box;}' +
                '#__id_callui .idcw{width:33.33%;display:flex;flex-direction:column;' +
                'align-items:center;padding:9px 0;}' +
                '#__id_callui .idcbtn{width:66px;height:66px;border-radius:50%;border:none;' +
                'background:#3a3a3c;color:#fff;font-size:25px;line-height:1;}' +
                '#__id_callui .idend{background:#f5233b;}' +
                '#__id_callui .idclab{margin-top:8px;font-size:14px;color:#e8e8e8;}' +
                '#__id_toast{position:fixed;left:50%;transform:translateX(-50%);bottom:130px;' +
                'z-index:2147483003;background:rgba(0,0,0,.92);color:#fff;padding:10px 15px;' +
                'border-radius:18px;font:13px -apple-system,system-ui,sans-serif;display:none;' +
                'max-width:84%;text-align:center;}';
              (document.head || document.documentElement).appendChild(s);
            }

            function toast(t, ms) {
              try {
                var el = document.getElementById('__id_toast');
                if (!el) {
                  el = document.createElement('div');
                  el.id = '__id_toast';
                  (document.body || document.documentElement).appendChild(el);
                }
                el.textContent = t;
                el.style.display = 'block';
                clearTimeout(el.__t);
                el.__t = setTimeout(function () { el.style.display = 'none'; }, ms || 3000);
              } catch (e) {}
            }
            window.__idToast = toast;

            function labelOf(n) {
              var l = (n.getAttribute && (n.getAttribute('aria-label') || n.getAttribute('title'))) || '';
              if (!l && n.querySelector) {
                var sv = n.querySelector('svg[aria-label]');
                if (sv) { l = sv.getAttribute('aria-label') || ''; }
              }
              return String(l).toLowerCase().trim();
            }

            function clickable(n) {
              var el = n;
              for (var d = 0; d < 5 && el; d++) {
                if (el.tagName === 'BUTTON') { return el; }
                if (el.getAttribute && el.getAttribute('role') === 'button') { return el; }
                if (el.tagName === 'A') { return el; }
                el = el.parentElement;
              }
              return n;
            }

            function findCallButton(kind) {
              var video = (kind === 'video');
              var nodes = document.querySelectorAll(
                'div[role="button"], button, a[role="button"], svg[aria-label], [aria-label]');
              for (var i = 0; i < nodes.length; i++) {
                var l = labelOf(nodes[i]);
                if (!l) { continue; }
                var hit = video
                  ? (l.indexOf('video call') !== -1 || l.indexOf('video chat') !== -1 ||
                     l === 'video')
                  : (l.indexOf('audio call') !== -1 || l.indexOf('voice call') !== -1 ||
                     l === 'call' || l === 'audio');
                if (hit) { return clickable(nodes[i]); }
              }
              return null;
            }

            function fire(el) {
              try { el.click(); return true; } catch (e) {}
              try {
                el.dispatchEvent(new MouseEvent('click',
                  { bubbles: true, cancelable: true, view: window }));
                return true;
              } catch (e) {}
              return false;
            }

            // Instagram opens a pre-call "lobby" ("Ready to call?" + a
            // Start Call button) before dialling. We watch for it CONTINUOUSLY
            // -- not just for a few seconds after tapping -- because it can
            // appear late, after a re-render, or in a nested frame.
            function visible(el) {
              try {
                var r = el.getBoundingClientRect();
                if (r.width < 8 || r.height < 8) { return false; }
                var st = window.getComputedStyle(el);
                if (!st) { return true; }
                if (st.visibility === 'hidden' || st.display === 'none') { return false; }
                if (parseFloat(st.opacity || '1') < 0.05) { return false; }
                return true;
              } catch (e) { return true; }
            }

            function normText(n) {
              var t = (n.textContent || '');
              return t.replace(/[\\s\\u00a0]+/g, ' ').toLowerCase().trim();
            }

            var START_EXACT = {
              'start call': 1, 'start': 1, 'join call': 1, 'join': 1,
              'call now': 1, 'ring': 1, 'start video call': 1,
              'start audio call': 1, 'join video call': 1,
              'join audio call': 1, 'start chat': 1
            };

            function findStartButton() {
              var nodes = document.querySelectorAll(
                'div[role="button"], button, [role="button"], [aria-label], a[role="button"]');
              for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                var l = labelOf(n);
                var t = normText(n);
                if (l && START_EXACT[l] && visible(n)) { return clickable(n); }
                if (t && START_EXACT[t] && visible(n)) { return clickable(n); }
                // "Start Call" rendered inside a wrapper with extra text.
                if (t && t.length <= 28 && t.indexOf('start call') !== -1 && visible(n)) {
                  return clickable(n);
                }
              }
              return null;
            }

            // True once the call is actually up (leave/end control present).
            function inCall() {
              var nodes = document.querySelectorAll('div[role="button"], button, [aria-label]');
              for (var i = 0; i < nodes.length; i++) {
                var l = labelOf(nodes[i]);
                if (!l) { continue; }
                if (l.indexOf('end call') !== -1 || l.indexOf('leave call') !== -1 ||
                    l.indexOf('hang up') !== -1 || l === 'leave' ||
                    l.indexOf('end video chat') !== -1) { return true; }
              }
              return false;
            }

            // Permanent lobby auto-dismisser. Runs in every frame, forever.
            var lastStartClick = 0;
            function killLobby() {
              try {
                if (inCall()) { return; }
                var s = findStartButton();
                if (!s) { return; }
                var now = Date.now();
                if (now - lastStartClick < 700) { return; }
                lastStartClick = now;
                fire(s);
              } catch (e) {}
            }

            // Tell Swift when the call UI opens/closes so it can force the
            // 244% call zoom and restore the previous zoom afterwards.
            var lastCallState = null;
            function reportCallState() {
              try {
                if (!IS_TOP) { return; }
                var on = inCall() || !!findStartButton();
                if (on === lastCallState) { return; }
                lastCallState = on;
                // Swap Instagram's call screen for ours as soon as we connect.
                if (on) {
                  if (!document.getElementById(CALLUI)) { showInCallUI(); }
                } else {
                  hideInCallUI();
                }
                if (window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.idcall) {
                  window.webkit.messageHandlers.idcall.postMessage(on ? 1 : 0);
                }
              } catch (e) {}
            }

            (function () {
              try {
                var mo = new MutationObserver(function () { killLobby(); reportCallState(); });
                mo.observe(document.documentElement,
                           { childList: true, subtree: true });
              } catch (e) {}
              setInterval(function () { killLobby(); reportCallState(); }, 400);
              killLobby();
              reportCallState();
            })();

            function autoStart(tries) {
              if (tries <= 0) { return; }
              if (inCall()) { return; }
              killLobby();
              setTimeout(function () { autoStart(tries - 1); }, 300);
            }

            function doCall(kind) {
              var b = findCallButton(kind);
              if (!b) {
                toast('No ' + kind + ' button on this screen. Open a chat first, then tap again.', 4500);
                return;
              }
              toast('Calling...', 2000);
              fire(b);
              // Poll for the lobby's Start/Join control for a few seconds.
              setTimeout(function () { autoStart(16); }, 500);
            }

            // ---------------- diagnostics ----------------
            function collect() {
              var L = [];
              L.push('URL: ' + location.href);
              L.push('UA-desktop: ' + (navigator.userAgent.indexOf('Macintosh') !== -1));
              L.push('platform: ' + navigator.platform +
                     '  touch: ' + navigator.maxTouchPoints);
              L.push('viewport: ' + window.innerWidth + 'x' + window.innerHeight +
                     '  screen: ' + screen.width + 'x' + screen.height);
              L.push('');
              var counts = {
                'a[href*=/direct/t/]': document.querySelectorAll('a[href*="/direct/t/"]').length,
                'a total': document.querySelectorAll('a').length,
                'div[role=button]': document.querySelectorAll('div[role="button"]').length,
                'button': document.querySelectorAll('button').length,
                'div[role=listitem]': document.querySelectorAll('div[role="listitem"]').length,
                'div[role=list]': document.querySelectorAll('div[role="list"]').length,
                '[aria-label]': document.querySelectorAll('[aria-label]').length,
                'svg[aria-label]': document.querySelectorAll('svg[aria-label]').length,
                'img': document.querySelectorAll('img').length,
                'img[alt]': document.querySelectorAll('img[alt]').length
              };
              L.push('--- element counts ---');
              for (var k in counts) { L.push(k + ' = ' + counts[k]); }
              L.push('');
              L.push('--- aria-labels (first 60) ---');
              var al = document.querySelectorAll('[aria-label]');
              var seen = {}, n = 0;
              for (var i = 0; i < al.length && n < 60; i++) {
                var v = al[i].getAttribute('aria-label');
                if (!v || seen[v]) { continue; }
                seen[v] = 1; n++;
                L.push('  "' + v + '"  <' + al[i].tagName.toLowerCase() + '>');
              }
              L.push('');
              L.push('--- svg aria-labels (first 40) ---');
              var sv = document.querySelectorAll('svg[aria-label]');
              var s2 = {}, m2 = 0;
              for (var j = 0; j < sv.length && m2 < 40; j++) {
                var w = sv[j].getAttribute('aria-label');
                if (!w || s2[w]) { continue; }
                s2[w] = 1; m2++;
                L.push('  "' + w + '"');
              }
              L.push('');
              L.push('--- first 25 img alts ---');
              var im = document.querySelectorAll('img[alt]');
              for (var q = 0; q < im.length && q < 25; q++) {
                L.push('  "' + im[q].getAttribute('alt') + '"');
              }
              L.push('');
              L.push('--- candidate rows (role=button with img) ---');
              var bt = document.querySelectorAll('div[role="button"]');
              var shown = 0;
              for (var r = 0; r < bt.length && shown < 20; r++) {
                if (!bt[r].querySelector('img')) { continue; }
                var rc = bt[r].getBoundingClientRect();
                shown++;
                L.push('  ' + Math.round(rc.width) + 'x' + Math.round(rc.height) +
                       '  "' + (bt[r].textContent || '').replace(/[ ]+/g, ' ').trim().slice(0, 44) + '"');
              }
              if (!shown) { L.push('  (none)'); }
              return L.join('\\n');
            }

            function showDiag() {
              style();
              var box = document.getElementById(DIAG);
              if (!box) {
                box = document.createElement('div');
                box.id = DIAG;
                var h = document.createElement('div');
                h.className = 'h';
                h.textContent = 'InstaDesk diagnostics';
                var ta = document.createElement('textarea');
                ta.id = '__id_diag_ta';
                ta.readOnly = false;
                var f = document.createElement('div');
                f.className = 'f';
                var sel = document.createElement('button');
                sel.textContent = 'Select all';
                sel.onclick = function () {
                  ta.focus(); ta.setSelectionRange(0, ta.value.length);
                  try { document.execCommand('copy'); toast('Copied', 1600); } catch (e) {}
                };
                var cl = document.createElement('button');
                cl.textContent = 'Close';
                cl.onclick = function () { box.classList.remove('on'); };
                f.appendChild(sel); f.appendChild(cl);
                box.appendChild(h); box.appendChild(ta); box.appendChild(f);
                document.body.appendChild(box);
              }
              document.getElementById('__id_diag_ta').value = collect();
              box.classList.add('on');
            }
            window.__idDiagShow = showDiag;

            // ---------------- saved contacts ----------------
            // The old version tried to scrape your inbox and kept failing
            // because Instagram's markup varies. Instead we let you SAVE the
            // chat you're currently in; saved chats persist in localStorage
            // and are reopened by URL, which is stable.
            var LSKEY = '__idSavedChats_v1';

            // Logged in? sessionid isn't readable (httpOnly), so infer from
            // the DOM: a login form means logged out.
            function loggedOut() {
              try {
                if (/[/]accounts[/](login|emailsignup)/.test(location.pathname)) { return true; }
                if (document.querySelector('input[name="password"]')) { return true; }
                return false;
              } catch (e) { return false; }
            }

            function loadSaved() {
              try {
                var raw = localStorage.getItem(LSKEY);
                var a = raw ? JSON.parse(raw) : [];
                return Object.prototype.toString.call(a) === '[object Array]' ? a : [];
              } catch (e) { return []; }
            }
            function storeSaved(a) {
              try { localStorage.setItem(LSKEY, JSON.stringify(a)); } catch (e) {}
            }

            function currentThreadPath() {
              var mm = location.pathname.match(/\\/direct\\/t\\/[0-9]+/);
              return mm ? mm[0] + '/' : '';
            }

            // Pull name, @handle and avatar out of the open thread header.
            // Instagram's header markup varies, so we try several routes and
            // keep the best result rather than giving up at the first miss.
            function headerEl() {
              var sels = ['header', 'div[role="banner"]', 'section header',
                          'div[role="main"] header'];
              for (var i = 0; i < sels.length; i++) {
                var h = document.querySelector(sels[i]);
                if (h) { return h; }
              }
              return null;
            }

            function cleanPersonName(s) {
              if (!s) { return ''; }
              return (s + '')
                .replace(/profile picture/ig, '')
                .replace(/\\u2019s photo/ig, '').replace(/'s photo/ig, '')
                .replace(/\\u2019s/g, '').replace(/'s\\b/g, '')
                .replace(/[\\s\\u00a0]+/g, ' ')
                .trim();
            }

            var NAME_NOISE = {
              'instagram': 1, 'direct': 1, 'messages': 1, 'message': 1,
              'chats': 1, 'inbox': 1, 'active now': 1, 'call': 1,
              'video call': 1, 'audio call': 1, 'conversation information': 1,
              'back': 1, 'close': 1, 'details': 1, 'new message': 1
            };

            // The thread avatar: prefer the header, else the newest message row.
            function currentThreadAvatar() {
              var h = headerEl();
              var imgs = h ? h.querySelectorAll('img') : [];
              for (var i = 0; i < imgs.length; i++) {
                var src = imgs[i].src || '';
                if (src && src.indexOf('data:') !== 0) { return src; }
              }
              var canvas = h ? h.querySelector('canvas') : null;
              if (canvas) {
                try { return canvas.toDataURL('image/png'); } catch (e) {}
              }
              var all = document.querySelectorAll('div[role="main"] img, img');
              for (var j = 0; j < all.length; j++) {
                var s2 = all[j].src || '';
                var a2 = (all[j].getAttribute('alt') || '').toLowerCase();
                if (s2 && s2.indexOf('data:') !== 0 &&
                    a2.indexOf('profile picture') !== -1) { return s2; }
              }
              return '';
            }

            // Returns { name, handle }.
            function currentThreadIdentity() {
              var name = '', handle = '';
              var h = headerEl();

              if (h) {
                var im = h.querySelector('img[alt]');
                if (im) {
                  var alt = cleanPersonName(im.getAttribute('alt'));
                  if (alt && !NAME_NOISE[alt.toLowerCase()]) { name = alt; }
                }
                // A link to the person's profile gives us the @handle.
                var links = h.querySelectorAll('a[href]');
                for (var i = 0; i < links.length; i++) {
                  var href = links[i].getAttribute('href') || '';
                  var mm = href.match(/^\\/([A-Za-z0-9._]+)\\/?$/);
                  if (mm && mm[1] && mm[1] !== 'direct' && mm[1] !== 'explore') {
                    handle = mm[1];
                    if (!name) { name = cleanPersonName(links[i].textContent); }
                    break;
                  }
                }
                if (!name) {
                  // Some layouts only expose the name via aria-label.
                  var lb = h.querySelectorAll('[aria-label]');
                  for (var z = 0; z < lb.length; z++) {
                    var al = cleanPersonName(lb[z].getAttribute('aria-label'));
                    if (!al || al.length > 40) { continue; }
                    if (NAME_NOISE[al.toLowerCase()]) { continue; }
                    if (al.toLowerCase().indexOf('call') !== -1) { continue; }
                    if (al.toLowerCase().indexOf('open the') !== -1) { continue; }
                    name = al; break;
                  }
                }
                if (!name) {
                  var sp = h.querySelectorAll('span, div, h1, h2');
                  for (var k = 0; k < sp.length; k++) {
                    if (sp[k].children.length) { continue; }
                    var t = cleanPersonName(sp[k].textContent);
                    if (!t || t.length > 40) { continue; }
                    if (NAME_NOISE[t.toLowerCase()]) { continue; }
                    name = t; break;
                  }
                }
              }

              if (!name) {
                var ti = (document.title || '').split('\\u2022')[0];
                ti = cleanPersonName(ti.replace(/on Instagram.*/i, '')
                                       .replace(/[(][0-9]+[)]/g, ''));
                if (ti && ti.toLowerCase().indexOf('instagram') === -1) { name = ti; }
              }
              if (!name && handle) { name = handle; }
              return { name: name || 'Chat', handle: handle };
            }

            function currentThreadName() { return currentThreadIdentity().name; }

            function saveCurrent() {
              var path = currentThreadPath();
              if (!path) {
                toast('Open a chat first, then tap Save.', 3400);
                return;
              }
              var id = currentThreadIdentity();
              var img = currentThreadAvatar();
              var list = loadSaved();
              for (var i = 0; i < list.length; i++) {
                if (list[i].path === path) {
                  // Already there - refresh its details instead of bailing.
                  if (id.name && id.name !== 'Chat') { list[i].name = id.name; }
                  if (id.handle) { list[i].handle = id.handle; }
                  if (img) { list[i].img = img; }
                  storeSaved(list);
                  renderList();
                  toast('Updated ' + list[i].name, 2200);
                  return;
                }
              }
              list.push({ path: path, name: id.name, handle: id.handle, img: img });
              storeSaved(list);
              toast('Saved ' + id.name, 2200);
              renderList();
            }

            // Re-capture details for a saved chat we happen to be viewing.
            function refreshCurrentDetails() {
              var path = currentThreadPath();
              if (!path) { return; }
              var list = loadSaved(), hit = null;
              for (var i = 0; i < list.length; i++) {
                if (list[i].path === path) { hit = list[i]; break; }
              }
              if (!hit) { return; }
              var id = currentThreadIdentity();
              var img = currentThreadAvatar();
              var changed = false;
              if ((!hit.name || hit.name === 'Chat') && id.name && id.name !== 'Chat') {
                hit.name = id.name; changed = true;
              }
              if (!hit.handle && id.handle) { hit.handle = id.handle; changed = true; }
              if (!hit.img && img) { hit.img = img; changed = true; }
              if (changed) { storeSaved(list); renderList(); }
            }

            // In-page rename sheet. We must NOT use prompt(): WKWebView
            // suppresses it unless the host app implements the text-input
            // panel delegate, so it silently returns null.
            function editName(it) {
              var old = document.getElementById('__id_edit');
              if (old && old.parentNode) { old.parentNode.removeChild(old); }

              var wrap = document.createElement('div');
              wrap.id = '__id_edit';

              var card = document.createElement('div');
              card.className = 'idcard';

              var t = document.createElement('div');
              t.className = 'idct';
              t.textContent = 'Rename chat';

              var inp = document.createElement('input');
              inp.className = 'idinp';
              inp.type = 'text';
              inp.value = it.name && it.name !== 'Chat' ? it.name : '';
              inp.placeholder = 'Enter a name';
              inp.setAttribute('autocomplete', 'off');
              inp.setAttribute('autocorrect', 'off');
              inp.setAttribute('spellcheck', 'false');

              var hint = document.createElement('div');
              hint.className = 'idhint';
              hint.textContent = it.handle ? ('@' + it.handle) : it.path;

              var row = document.createElement('div');
              row.className = 'idcbtns';

              function close() {
                if (wrap.parentNode) { wrap.parentNode.removeChild(wrap); }
              }
              function save() {
                var nn = (inp.value + '').replace(/[\\s\\u00a0]+/g, ' ').trim();
                if (!nn) { close(); return; }
                var l2 = loadSaved();
                for (var q = 0; q < l2.length; q++) {
                  if (l2[q].path === it.path) { l2[q].name = nn; }
                }
                storeSaved(l2);
                close();
                renderList();
                toast('Renamed to ' + nn, 1800);
              }

              var cancel = document.createElement('button');
              cancel.className = 'idcancel';
              cancel.textContent = 'Cancel';
              cancel.onclick = close;

              var ok = document.createElement('button');
              ok.className = 'idok';
              ok.textContent = 'Save';
              ok.onclick = save;

              inp.onkeydown = function (e) {
                if (e.keyCode === 13) { e.preventDefault(); save(); }
              };
              wrap.onclick = function (e) { if (e.target === wrap) { close(); } };

              row.appendChild(cancel); row.appendChild(ok);
              card.appendChild(t); card.appendChild(inp);
              card.appendChild(hint); card.appendChild(row);
              wrap.appendChild(card);
              document.body.appendChild(wrap);
              setTimeout(function () { try { inp.focus(); inp.select(); } catch (e) {} }, 60);
            }

            function removeSaved(path) {
              var list = loadSaved(), out = [];
              for (var i = 0; i < list.length; i++) {
                if (list[i].path !== path) { out.push(list[i]); }
              }
              storeSaved(out);
              renderList();
            }

            // Open a saved chat, then place the call once loaded.
            function callSaved(item, kind) {
              hidePanel();
              if (currentThreadPath() === item.path) {
                doCall(kind);
                return;
              }
              toast('Opening ' + item.name + '...', 4000);
              try { sessionStorage.setItem('__idPending', kind); } catch (e) {}
              location.href = item.path;
            }

            // After an SPA/URL navigation, fire any pending call.
            function runPending() {
              var k = null;
              try { k = sessionStorage.getItem('__idPending'); } catch (e) {}
              if (!k) { return; }
              if (!currentThreadPath()) { return; }
              try { sessionStorage.removeItem('__idPending'); } catch (e) {}
              waitFor(function () { return findCallButton(k); }, 12000, function (b) {
                if (b) { doCall(k); }
                else { toast('Chat open - tap Voice or Video.', 3600); }
              });
            }

            var PANEL = '__id_panel';

            function renderList() {
              var box = document.getElementById('__id_panel_list');
              if (!box) { return; }
              box.innerHTML = '';
              var list = loadSaved();

              if (loggedOut()) {
                var lw = document.createElement('div');
                lw.className = 'idmsg';
                lw.textContent = 'You are signed out of Instagram.';
                box.appendChild(lw);
                var lb = document.createElement('button');
                lb.className = 'idcta';
                lb.textContent = 'Log in to Instagram';
                lb.onclick = function () {
                  hidePanel();
                  location.href = '/accounts/login/';
                };
                box.appendChild(lb);
                return;
              }

              var add = document.createElement('button');
              add.className = 'idcta';
              add.textContent = currentThreadPath()
                ? '+ Save this chat' : '+ Add a chat';
              add.onclick = function () {
                if (currentThreadPath()) { saveCurrent(); }
                else { hidePanel(); location.href = '/direct/inbox/'; }
              };
              box.appendChild(add);

              if (list.length) {
                var sec = document.createElement('div');
                sec.className = 'idsec';
                sec.textContent = 'Saved chats';
                box.appendChild(sec);
              }

              if (!list.length) {
                var m0 = document.createElement('div');
                m0.className = 'idmsg';
                m0.textContent = 'No saved chats yet.\\n\\nOpen a chat in Instagram, then tap "Save this chat" below. It will appear here for one-tap calling.';
                m0.style.whiteSpace = 'pre-wrap';
                box.appendChild(m0);
                return;
              }
              for (var i = 0; i < list.length; i++) {
                (function (it) {
                  var row = document.createElement('div');
                  row.className = 'idrow';

                  var av;
                  if (it.img) {
                    av = document.createElement('img');
                    av.className = 'idav';
                    av.src = it.img;
                    av.onerror = function () {
                      var f = document.createElement('div');
                      f.className = 'idav idavf';
                      f.textContent = (it.name || '?').charAt(0).toUpperCase();
                      if (av.parentNode) { av.parentNode.replaceChild(f, av); }
                    };
                  } else {
                    av = document.createElement('div');
                    av.className = 'idav idavf';
                    av.textContent = (it.name || '?').charAt(0).toUpperCase();
                  }

                  var meta = document.createElement('div');
                  meta.className = 'idmeta';
                  var nm = document.createElement('div');
                  nm.className = 'idname';
                  nm.textContent = it.name || 'Chat';
                  meta.appendChild(nm);
                  if (it.handle) {
                    var hd = document.createElement('div');
                    hd.className = 'idhandle';
                    hd.textContent = '@' + it.handle;
                    meta.appendChild(hd);
                  }
                  meta.onclick = function () { editName(it); };

                  var be = document.createElement('button');
                  be.className = 'idbtn idedit';
                  be.textContent = 'Rename';
                  be.title = 'Rename';
                  be.onclick = function (ev) {
                    if (ev && ev.stopPropagation) { ev.stopPropagation(); }
                    editName(it);
                  };


                  var bv = document.createElement('button');
                  bv.className = 'idbtn idvoice';
                  bv.textContent = 'V';
                  bv.title = 'Voice call';
                  bv.onclick = function () { callSaved(it, 'voice'); };

                  var bd = document.createElement('button');
                  bd.className = 'idbtn idvideo';
                  bd.textContent = 'C';
                  bd.title = 'Video call';
                  bd.onclick = function () { callSaved(it, 'video'); };

                  var bx = document.createElement('button');
                  bx.className = 'idbtn idrm';
                  bx.textContent = 'x';
                  bx.onclick = function () { removeSaved(it.path); };

                  row.appendChild(av); row.appendChild(meta);
                  row.appendChild(be); row.appendChild(bv);
                  row.appendChild(bd); row.appendChild(bx);
                  box.appendChild(row);
                })(list[i]);
              }
            }

            function buildPanel() {
              if (!IS_TOP) { return false; }
              if (document.getElementById(PANEL)) { return true; }
              if (!document.body) { return false; }
              var p = document.createElement('div');
              p.id = PANEL;

              var h = document.createElement('div');
              h.className = 'idhdr';
              h.innerHTML = 'Call Mode <span class="ver">v26</span>' +
                            '<span class="sub">tap Rename to fix a name - V voice - C video</span>';

              var list = document.createElement('div');
              list.id = '__id_panel_list';
              list.className = 'idlist';

              var f = document.createElement('div');
              f.className = 'idfoot';
              var sv = document.createElement('button');
              sv.textContent = 'Save this chat';
              sv.onclick = function () { saveCurrent(); };
              var inf = document.createElement('button');
              inf.textContent = 'Info';
              inf.onclick = function () { showDiag(); };
              var cl = document.createElement('button');
              cl.textContent = 'Close';
              cl.onclick = function () { hidePanel(); };
              f.appendChild(sv); f.appendChild(inf); f.appendChild(cl);

              p.appendChild(h); p.appendChild(list); p.appendChild(f);
              document.body.appendChild(p);
              return true;
            }

            function showPanel() {
              style();
              if (!buildPanel()) { return -2; }
              renderList();
              document.getElementById(PANEL).classList.add('on');
              return 1;
            }
            function hidePanel() {
              var p = document.getElementById(PANEL);
              if (p) { p.classList.remove('on'); }
              return 0;
            }

            // ---------------- custom in-call UI ----------------
            // Replaces Instagram's own call screen with a simple layout:
            // avatar + name + status on top, a 3x2 control grid below.
            // Every control drives Instagram's real button underneath.

            function ctlByWords(words, exclude) {
              var nodes = document.querySelectorAll(
                'div[role="button"], button, [role="button"], [aria-label], svg[aria-label]');
              for (var i = 0; i < nodes.length; i++) {
                var l = labelOf(nodes[i]);
                if (!l) { continue; }
                var skip = false;
                if (exclude) {
                  for (var e = 0; e < exclude.length; e++) {
                    if (l.indexOf(exclude[e]) !== -1) { skip = true; break; }
                  }
                }
                if (skip) { continue; }
                for (var w = 0; w < words.length; w++) {
                  if (l.indexOf(words[w]) !== -1) { return clickable(nodes[i]); }
                }
              }
              return null;
            }

            function ctlEnd()   { return ctlByWords(['end call', 'leave call', 'hang up', 'end video chat']); }
            function ctlMute()  { return ctlByWords(['mute', 'unmute']); }
            function ctlVideo() { return ctlByWords(['turn off camera', 'turn on camera',
                                                     'camera off', 'camera on', 'toggle camera']); }
            function ctlSpeaker() { return ctlByWords(['speaker', 'audio output', 'switch audio']); }
            function ctlShare() { return ctlByWords(['share screen', 'screen share',
                                                     'share your screen', 'present']); }
            function ctlFlip()  { return ctlByWords(['switch camera', 'flip camera', 'rotate camera']); }

            // Caller identity while a call is on screen.
            function callPeer() {
              var name = '', img = '';
              try {
                var scope = document.querySelector('div[role="dialog"]') || document.body;
                var im = scope.querySelector('img[alt]');
                if (im) {
                  img = im.src || '';
                  name = cleanPersonName(im.getAttribute('alt'));
                }
                if (!name) {
                  var id = currentThreadIdentity();
                  name = id.name; 
                }
              } catch (e) {}
              return { name: name || 'Instagram call', img: img };
            }

            function callStatusText() {
              try {
                var b = (document.body.textContent || '').toLowerCase();
                if (b.indexOf('ringing') !== -1) { return 'Ringing...'; }
                if (b.indexOf('calling') !== -1) { return 'Calling...'; }
                if (b.indexOf('connecting') !== -1) { return 'Connecting...'; }
              } catch (e) {}
              return 'In call';
            }

            var CALLUI = '__id_callui';

            function ctlBtn(icon, label, cls, fn) {
              var w = document.createElement('div');
              w.className = 'idcw';
              var b = document.createElement('button');
              b.className = 'idcbtn ' + (cls || '');
              b.innerHTML = icon;
              b.onclick = fn;
              var t = document.createElement('div');
              t.className = 'idclab';
              t.textContent = label;
              w.appendChild(b); w.appendChild(t);
              return w;
            }

            function tapCtl(getter, label) {
              var el = getter();
              if (el) { fire(el); return true; }
              toast(label + ' is not available in this call.', 2200);
              return false;
            }

            function showInCallUI() {
              style();
              if (!IS_TOP || !document.body) { return -2; }
              var old = document.getElementById(CALLUI);
              if (old) { old.parentNode.removeChild(old); }

              var peer = callPeer();
              var root = document.createElement('div');
              root.id = CALLUI;

              var top = document.createElement('div');
              top.className = 'idctop';
              var mini = document.createElement('button');
              mini.className = 'idmini';
              mini.innerHTML = '&#8600;';
              mini.title = 'Hide';
              mini.onclick = function () { hideInCallUI(); };
              top.appendChild(mini);

              var nm = document.createElement('div');
              nm.className = 'idcname';
              nm.textContent = peer.name;
              var st = document.createElement('div');
              st.className = 'idcstat';
              st.id = '__id_cstat';
              st.textContent = callStatusText();

              var avw = document.createElement('div');
              avw.className = 'idcavw';
              if (peer.img) {
                var ai = document.createElement('img');
                ai.className = 'idcav';
                ai.src = peer.img;
                avw.appendChild(ai);
              } else {
                var af = document.createElement('div');
                af.className = 'idcav idcavf';
                af.textContent = (peer.name || '?').charAt(0).toUpperCase();
                avw.appendChild(af);
              }

              var grid = document.createElement('div');
              grid.className = 'idcgrid';
              grid.appendChild(ctlBtn('&#9974;', 'Video', '',
                function () { tapCtl(ctlVideo, 'Camera'); }));
              grid.appendChild(ctlBtn('&#128266;', 'Speaker', '',
                function () { tapCtl(ctlSpeaker, 'Speaker'); }));
              grid.appendChild(ctlBtn('&#127908;', 'Mute', '',
                function () { tapCtl(ctlMute, 'Mute'); }));
              grid.appendChild(ctlBtn('&#8943;', 'More', '',
                function () { tapCtl(ctlFlip, 'Switch camera'); }));
              grid.appendChild(ctlBtn('&#128421;', 'Share', '',
                function () { tapCtl(ctlShare, 'Screen share'); }));
              grid.appendChild(ctlBtn('&#9990;', 'End', 'idend',
                function () {
                  tapCtl(ctlEnd, 'End call');
                  hideInCallUI();
                }));

              root.appendChild(top);
              root.appendChild(nm); root.appendChild(st);
              root.appendChild(avw); root.appendChild(grid);
              document.body.appendChild(root);

              // Keep the status line and lifetime in sync with the real call.
              if (window.__idCUITimer) { clearInterval(window.__idCUITimer); }
              window.__idCUITimer = setInterval(function () {
                var s = document.getElementById('__id_cstat');
                if (s) { s.textContent = callStatusText(); }
                if (!inCall() && !findStartButton()) { hideInCallUI(); }
              }, 1000);
              return 1;
            }

            function hideInCallUI() {
              var el = document.getElementById(CALLUI);
              if (el && el.parentNode) { el.parentNode.removeChild(el); }
              if (window.__idCUITimer) {
                clearInterval(window.__idCUITimer);
                window.__idCUITimer = null;
              }
              return 0;
            }

            window.__idShowInCallUI = showInCallUI;
            window.__idHideInCallUI = hideInCallUI;
            window.__idShareScreen = function () { return tapCtl(ctlShare, 'Screen share'); };

            // ---------------- the bar ----------------
            function build() {
              if (!IS_TOP) { return false; }
              style();
              if (!document.body) { return false; }
              if (document.getElementById(BAR)) { return true; }
              var bar = document.createElement('div');
              bar.id = BAR;

              var v = document.createElement('button');
              v.className = 'v';
              v.textContent = 'Voice';
              v.onclick = function () { doCall('voice'); };

              var d = document.createElement('button');
              d.className = 'd';
              d.textContent = 'Video';
              d.onclick = function () { doCall('video'); };

              var l = document.createElement('button');
              l.className = 'q';
              l.textContent = 'Chats';
              l.onclick = function () { showPanel(); };

              var x = document.createElement('button');
              x.className = 'x';
              x.textContent = 'X';
              x.onclick = function () { hide(); };

              bar.appendChild(v); bar.appendChild(d); bar.appendChild(l); bar.appendChild(x);
              document.body.appendChild(bar);
              return true;
            }

            function show() {
              if (!build()) { return -2; }
              document.getElementById(BAR).classList.add('on');
              if (!currentThreadPath()) {
                showPanel();
              }
              return 1;
            }
            function hide() {
              var b = document.getElementById(BAR);
              if (b) { b.classList.remove('on'); }
              hidePanel();
              return 0;
            }

            window.__idCallModeShow = show;
            window.__idCallModeHide = hide;
            window.__idSaveCurrent = saveCurrent;
            window.__idCallModeToggle = function () {
              var b = document.getElementById(BAR);
              if (b && b.classList.contains('on')) { return hide(); }
              return show();
            };

            // Watch for navigation so a pending call fires on arrival.
            (function () {
              var last = location.href;
              setInterval(function () {
                if (location.href !== last) {
                  last = location.href;
                  setTimeout(runPending, 900);
                  setTimeout(refreshCurrentDetails, 2200);
                }
              }, 500);
              setTimeout(runPending, 1200);
            })();

            window.__idCallDiag = 'ready-v26';
          } catch (e) {
            window.__idCallDiag = 'error:' + (e && e.message ? e.message : '?');
          }
        })();
        """
        self.callModeSource = callModeJS
        config.userContentController.addUserScript(
            WKUserScript(source: callModeJS,
                         injectionTime: .atDocumentEnd,
                         // false: the lobby can render in a nested frame, and
                         // the watcher has to be there to dismiss it.
                         forMainFrameOnly: false))

        // --- INCOMING CALL WATCHER -------------------------------------
        // Watches the DOM for Instagram's own incoming-call UI and reports
        // it to the native side over a message handler. The native banner
        // then drives Instagram's real Accept / Decline buttons.
        //
        // IMPORTANT: this only works while the app is OPEN and on an
        // Instagram page. There is no push notification -- see the Swift
        // comment on `startCallPolling()` for why.
        let incomingJS = """
        (function () {
          try {
            if (window.__idRing) { return; }
            window.__idRing = true;

            function txt(n) { return ((n && n.textContent) || '').trim(); }

            function findAcceptDecline() {
              var accept = null, decline = null;
              var nodes = document.querySelectorAll('div[role="button"], button');
              for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                var l = ((n.getAttribute('aria-label') || '') + ' ' + txt(n)).toLowerCase();
                if (!l) { continue; }
                if (!accept && (l.indexOf('accept') !== -1 || l.indexOf('answer') !== -1 ||
                                l.indexOf('join') !== -1)) { accept = n; }
                if (!decline && (l.indexOf('decline') !== -1 || l.indexOf('reject') !== -1 ||
                                 l.indexOf('ignore') !== -1 ||
                                 l.indexOf('dismiss') !== -1)) { decline = n; }
              }
              return { accept: accept, decline: decline };
            }

            // Heuristic: Instagram renders incoming calls in a dialog whose
            // text contains a calling phrase. We look for that plus at least
            // one accept-ish control.
            function detect() {
              var dialogs = document.querySelectorAll('div[role="dialog"], div[role="alertdialog"]');
              for (var i = 0; i < dialogs.length; i++) {
                var d = dialogs[i];
                var t = txt(d);
                if (!t) { continue; }
                var lower = t.toLowerCase();
                var ringing = lower.indexOf('incoming') !== -1 ||
                              lower.indexOf('is calling') !== -1 ||
                              lower.indexOf('calling you') !== -1 ||
                              lower.indexOf('video call') !== -1 ||
                              lower.indexOf('audio call') !== -1;
                if (!ringing) { continue; }
                var ctrls = findAcceptDecline();
                if (!ctrls.accept && !ctrls.decline) { continue; }

                var name = '';
                var img = d.querySelector('img[alt]');
                if (img) {
                  name = (img.getAttribute('alt') || '')
                           .replace(/'s profile picture/i, '').trim();
                }
                if (!name) {
                  var m = t.match(/([^\\n]{1,40}?)\\s+is calling/i);
                  if (m) { name = m[1].trim(); }
                }
                if (!name) { name = 'Someone'; }

                var kind = lower.indexOf('video') !== -1 ? 'video' : 'voice';
                return { ringing: true, name: name, kind: kind,
                         canAccept: !!ctrls.accept, canDecline: !!ctrls.decline };
              }
              return { ringing: false };
            }

            window.__idRingState = function () { return detect(); };

            window.__idRingAct = function (what) {
              var c = findAcceptDecline();
              var target = (what === 'accept') ? c.accept : c.decline;
              if (target) { target.click(); return true; }
              return false;
            };

            // ---------------- unread message monitor ----------------
            // Mirror Instagram's own unread badge. We read the DM badge and
            // the per-thread unread rows, and tell Swift when new ones show
            // up so it can raise a notification.
            var seenMsgKeys = {};
            var msgPrimed = false;

            function unreadBadgeCount() {
              // Most reliable: Instagram puts the unread count in the tab
              // title, e.g. "(3) Instagram". This survives markup changes.
              try {
                var tm = (document.title || '').match(/^[(]([0-9]+)[)]/);
                if (tm) { return parseInt(tm[1], 10) || 0; }
              } catch (e) {}
              try {
                var els = document.querySelectorAll('[aria-label]');
                for (var i = 0; i < els.length; i++) {
                  var l = (els[i].getAttribute('aria-label') || '').toLowerCase();
                  var mm = l.match(/([0-9]+)[ ]+unread/);
                  if (mm) { return parseInt(mm[1], 10) || 0; }
                }
              } catch (e) {}
              return 0;
            }

            // Rows in the inbox that look unread, with sender + preview.
            function unreadThreads() {
              var out = [];
              try {
                var rows = document.querySelectorAll(
                  'div[role="listitem"], a[href*="/direct/t/"]');
                for (var i = 0; i < rows.length && out.length < 8; i++) {
                  var r = rows[i];
                  var t = (r.textContent || '').replace(/[^\u{0021}-\u{FFFF}]+/g, ' ').trim();
                  if (!t || t.length > 160) { continue; }
                  var lower = t.toLowerCase();
                  var isUnread = lower.indexOf('unread') !== -1;
                  if (!isUnread) {
                    // Instagram marks unread rows with a blue dot; look for a
                    // small circular element with no text next to the row.
                    var dot = r.querySelector('[data-visualcompletion="ignore"]');
                    if (!dot) { continue; }
                  }
                  var href = r.getAttribute ? (r.getAttribute('href') || '') : '';
                  var im = r.querySelector('img[alt]');
                  var nm = im ? (im.getAttribute('alt') || '')
                                  .replace(/profile picture/ig, '')
                                  .replace(/[\u{2019}]s/g, '').replace(/'s/g, '').trim()
                              : '';
                  if (!nm) { nm = t.split(' ').slice(0, 3).join(' '); }
                  out.push({ name: nm || 'Instagram',
                             preview: t.slice(0, 90),
                             href: href,
                             key: (href || nm) + '|' + t.slice(0, 40) });
                }
              } catch (e) {}
              return out;
            }

            // If the unread count in the title goes UP we know a message
            // arrived, even when no inbox rows are on screen (e.g. you are
            // sitting inside a different thread).
            var lastTitleCount = -1;
            function reportTitleCount() {
              try {
                if (!window.webkit || !window.webkit.messageHandlers ||
                    !window.webkit.messageHandlers.idmsg) { return; }
                var c = unreadBadgeCount();
                if (lastTitleCount < 0) { lastTitleCount = c; return; }
                if (c > lastTitleCount) {
                  window.webkit.messageHandlers.idmsg.postMessage({
                    count: c,
                    items: [{ name: 'Instagram',
                              preview: c === 1 ? 'You have a new message'
                                               : ('You have ' + c + ' unread messages'),
                              href: '/direct/inbox/',
                              key: 'title-' + c }]
                  });
                } else if (c !== lastTitleCount) {
                  // Count dropped - just resync the badge, no notification.
                  window.webkit.messageHandlers.idmsg.postMessage(
                    { count: c, items: [] });
                }
                lastTitleCount = c;
              } catch (e) {}
            }

            function reportMessages() {
              try {
                if (!window.webkit || !window.webkit.messageHandlers ||
                    !window.webkit.messageHandlers.idmsg) { return; }
                var list = unreadThreads();
                var fresh = [];
                for (var i = 0; i < list.length; i++) {
                  if (!seenMsgKeys[list[i].key]) {
                    seenMsgKeys[list[i].key] = 1;
                    fresh.push(list[i]);
                  }
                }
                // First pass only records what is already there, so opening
                // the app does not fire a burst of stale notifications.
                if (!msgPrimed) { msgPrimed = true; return; }
                if (!fresh.length) { return; }
                window.webkit.messageHandlers.idmsg.postMessage({
                  count: unreadBadgeCount(),
                  items: fresh
                });
              } catch (e) {}
            }

            function report() {
              try {
                var s = detect();
                if (window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.idring) {
                  window.webkit.messageHandlers.idring.postMessage(s);
                }
              } catch (e) {}
            }

            // MutationObserver catches the dialog appearing; the interval is
            // a safety net for renders the observer misses.
            try {
              var mo = new MutationObserver(function () { report(); });
              mo.observe(document.documentElement,
                         { childList: true, subtree: true });
            } catch (e) {}
            setInterval(report, 1500);
            setInterval(reportMessages, 4000);
            setInterval(reportTitleCount, 2500);
            report();
            setTimeout(reportMessages, 3000);
          } catch (e) {}
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: incomingJS,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        config.userContentController.add(self, name: "idring")
        config.userContentController.add(self, name: "idcall")
        config.userContentController.add(self, name: "idmsg")

        webView = WKWebView(frame: webContentFrame, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Let the user pinch-zoom on top of the chosen level, like a browser.
        webView.scrollView.bouncesZoom = true

        view.addSubview(webView)
    }

    /// Push the current zoom level into the page.
    ///
    /// In landscape the screen is physically wider, so the same logical
    /// viewport width yields smaller-looking content. We widen the logical
    /// viewport proportionally so a given zoom percentage looks consistent
    /// in both orientations.
    private func applyZoom() {
        guard desktopMode else { return }
        var w = Double(zoomWidths[zoomIndex])
        let b = webContentFrame.size
        if b.width > b.height, b.height > 0 {
            let factor = Double(b.width / b.height) / (Double(landscapeW) / Double(landscapeH))
            w *= max(0.5, min(2.0, factor))
        }
        webView.evaluateJavaScript("window.__instadeskZoom && window.__instadeskZoom(\(Int(w.rounded())));",
                                   completionHandler: nil)
        refreshToolbar()
    }

    /// Called from the `idcall` handler when Instagram's call UI appears
    /// or disappears. Saves and restores the user's chosen zoom.
    private func setCallZoom(active: Bool) {
        guard desktopMode else { return }
        if active {
            if inCallNow { return }
            inCallNow = true
            zoomBeforeCall = zoomIndex
            zoomIndex = callZoomIndex
            applyZoom()
        } else {
            if !inCallNow { return }
            inCallNow = false
            if let prev = zoomBeforeCall { zoomIndex = prev }
            zoomBeforeCall = nil
            applyZoom()
        }
    }

    // MARK: - CallKit (native lock-screen call UI)

    /// CallKit shows the real full-screen incoming-call card, including on the
    /// lock screen, with system Accept / Decline buttons. It needs no paid
    /// account and no VoIP certificate -- but the app MUST already be running
    /// (foreground, or backgrounded under the audio mode) to report the call.
    /// Waking a terminated app requires PushKit + a VoIP cert + a push server.
    private lazy var callProvider: CXProvider = {
        let cfg: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            cfg = CXProviderConfiguration()
        } else {
            cfg = CXProviderConfiguration(localizedName: "InstaDesk")
        }
        cfg.supportsVideo = true
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        let p = CXProvider(configuration: cfg)
        p.setDelegate(self, queue: nil)
        return p
    }()

    private var activeCallUUID: UUID? = nil
    /// Why CallKit last refused to show the full-screen call UI.
    private var lastCallKitError: String = "none"
    /// True once CallKit has accepted a reported call. Free sideloaded builds
    /// often cannot present the system call UI at all, so we watch for this
    /// and fall back to a full-screen in-app ringer.
    private var callKitPresented = false
    private var testCallTimer: Timer? = nil

    /// Ask CallKit to display an incoming call from `name`.
    private func reportIncomingCall(name: String, kind: String) {
        guard activeCallUUID == nil else { return }
        // CallKit needs a configured session before it will present.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoChat,
            options: [.allowBluetooth, .defaultToSpeaker])
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = (kind == "video")
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        activeCallUUID = uuid
        callKitPresented = false
        callProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self = self else { return }
            if error == nil { self.callKitPresented = true }
            if let error = error {
                // CallKit is unavailable in some regions (notably mainland
                // China) and refuses on misconfiguration. Fall back to the
                // banner + notification, and say so rather than failing mute.
                self.activeCallUUID = nil
                let ns = error as NSError
                // Codes: 2 = filtered by Do Not Disturb, 3 = filtered by
                // blocked-number list, 4 = CallKit unavailable/unsupported.
                self.lastCallKitError = "code \(ns.code): \(ns.localizedDescription)"
                DispatchQueue.main.async {
                    self.flashToast("Lock-screen call UI failed - \(self.lastCallKitError)")
                }
            }
        }
    }

    /// Tear down the CallKit card when the call ends or stops ringing.
    private func endCallKitCall(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = activeCallUUID else { return }
        activeCallUUID = nil
        callProvider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    // MARK: - Incoming-call notifications

    /// Ask once for permission and register the Accept/Decline actions.
    /// These are *local* notifications: they can fire while InstaDesk is
    /// running (foreground or briefly in the background under the audio
    /// mode). A fully terminated app cannot be woken without a push server
    /// and a paid VoIP certificate, which this build does not have.
    private func setupNotifications() {
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self

        let accept = UNNotificationAction(
            identifier: "ID_ACCEPT",
            title: "Accept",
            options: [.foreground])
        let decline = UNNotificationAction(
            identifier: "ID_DECLINE",
            title: "Decline",
            options: [.destructive])
        let category = UNNotificationCategory(
            identifier: "ID_INCOMING_CALL",
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [.customDismissAction])
        let open = UNNotificationAction(
            identifier: "ID_OPEN_MSG", title: "Open", options: [.foreground])
        let msgCategory = UNNotificationCategory(
            identifier: "ID_MESSAGE",
            actions: [open],
            intentIdentifiers: [],
            options: [])
        centre.setNotificationCategories([category, msgCategory])

        centre.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.notificationsReady = granted }
        }
    }

    /// Register (or re-register) the notification categories. Called again
    /// right before posting, because if the category is not known to iOS at
    /// delivery time the Accept / Decline buttons are silently dropped.
    private func registerCategories() {
        let accept = UNNotificationAction(
            identifier: "ID_ACCEPT", title: "Accept", options: [.foreground])
        let decline = UNNotificationAction(
            identifier: "ID_DECLINE", title: "Decline", options: [.destructive])
        let call = UNNotificationCategory(
            identifier: "ID_INCOMING_CALL",
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [.customDismissAction])
        let open = UNNotificationAction(
            identifier: "ID_OPEN_MSG", title: "Open", options: [.foreground])
        let msg = UNNotificationCategory(
            identifier: "ID_MESSAGE", actions: [open],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([call, msg])
    }

    private func postRingNotification(name: String, kind: String) {
        guard notificationsReady else { return }
        registerCategories()
        clearRingNotification()

        let content = UNMutableNotificationContent()
        content.title = name
        content.body  = (kind == "video")
            ? "Incoming video call on Instagram"
            : "Incoming voice call on Instagram"
        content.categoryIdentifier = "ID_INCOMING_CALL"
        if #available(iOS 15.2, *) {
            content.sound = .defaultRingtone
        } else {
            content.sound = .default
        }
        content.userInfo = ["name": name, "kind": kind]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let id = "idring-" + UUID().uuidString
        ringNotificationID = id
        // nil trigger = deliver immediately.
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Raise a notification for a newly-arrived DM.
    private func postMessageNotification(name: String, preview: String, path: String) {
        guard notificationsReady else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = preview.isEmpty ? "New message" : preview
        content.categoryIdentifier = "ID_MESSAGE"
        content.sound = .default
        content.userInfo = ["path": path]
        let req = UNNotificationRequest(identifier: "idmsg-" + UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func clearRingNotification() {
        guard let id = ringNotificationID else { return }
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [id])
        centre.removeDeliveredNotifications(withIdentifiers: [id])
        ringNotificationID = nil
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        toolbar = UIView(frame: CGRect(x: 0,
                                       y: view.bounds.height - toolbarHeight,
                                       width: view.bounds.width,
                                       height: toolbarHeight))
        toolbar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        toolbar.backgroundColor = UIColor(white: 0.07, alpha: 0.97)

        let sep = UIView(frame: CGRect(x: 0, y: 0, width: toolbar.bounds.width, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.25, alpha: 1)
        sep.autoresizingMask = [.flexibleWidth]
        toolbar.addSubview(sep)

        func makeButton(_ title: String, _ sel: Selector, size: CGFloat) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: size, weight: .medium)
            b.addTarget(self, action: sel, for: .touchUpInside)
            return b
        }

        modeButton    = makeButton("", #selector(togglePhase), size: 11)
        zoomOutButton = makeButton("−", #selector(zoomOut),    size: 26)
        zoomInButton  = makeButton("+", #selector(zoomIn),     size: 24)
        callButton    = makeButton("Call Mode v26", #selector(toggleCallMode), size: 13)
        // Long-press Call Mode to open the permissions panel.
        callButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(callButtonLongPress(_:))))
        callButton.setTitleColor(UIColor(red: 0.30, green: 0.72, blue: 0.40, alpha: 1), for: .normal)
        callButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)

        zoomLabel = UILabel()
        zoomLabel.textColor = UIColor(white: 0.8, alpha: 1)
        zoomLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        zoomLabel.textAlignment = .center
        zoomLabel.isUserInteractionEnabled = true
        zoomLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(zoomReset)))

        [modeButton, callButton, zoomOutButton, zoomLabel, zoomInButton].forEach { toolbar.addSubview($0!) }
        view.addSubview(toolbar)

        layoutToolbar()
        refreshToolbar()

        // No content inset: the web view is physically sized to sit above
        // the chrome, so the page gets a viewport that matches what it can
        // actually paint into.
        webView.scrollView.contentInset.bottom = 0
        webView.scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    private func layoutToolbar() {
        let w = toolbar.bounds.width
        let h = toolbar.bounds.height
        let zoomBlock: CGFloat = 146
        let callW: CGFloat = 86

        zoomOutButton.frame = CGRect(x: w - zoomBlock,       y: 0, width: 42, height: h)
        zoomLabel.frame     = CGRect(x: w - zoomBlock + 42,  y: 0, width: 56, height: h)
        zoomInButton.frame  = CGRect(x: w - zoomBlock + 98,  y: 0, width: 42, height: h)

        let callX = w - zoomBlock - callW - 4
        callButton.frame = CGRect(x: callX, y: 0, width: callW, height: h)

        modeButton.frame = CGRect(x: 6, y: 0, width: max(40, callX - 10), height: h)
        modeButton.contentHorizontalAlignment = .left
    }

    @objc private func callButtonLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        showPermissions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutToolbar()
        layoutRingBanner()
    }

    // MARK: - Incoming call banner

    /// A always-present status strip above the toolbar.
    /// Idle  -> "No calls".
    /// Ringing -> caller name + Accept / Decline, which drive Instagram's
    /// own buttons via JS.
    private func buildRingBanner() {
        ringBanner = UIView()
        ringBanner.backgroundColor = UIColor(white: 0.11, alpha: 0.98)

        let sep = UIView()
        sep.backgroundColor = UIColor(white: 0.25, alpha: 1)
        sep.tag = 771
        ringBanner.addSubview(sep)

        ringLabel = UILabel()
        ringLabel.textColor = .white
        ringLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        ringSubLabel = UILabel()
        ringSubLabel.textColor = UIColor(white: 0.62, alpha: 1)
        ringSubLabel.font = .systemFont(ofSize: 11)

        func pill(_ title: String, _ color: UIColor, _ sel: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
            b.backgroundColor = color
            b.layer.cornerRadius = 15
            b.addTarget(self, action: sel, for: .touchUpInside)
            b.isHidden = true
            return b
        }
        ringAccept  = pill("Accept",  UIColor(red: 0.18, green: 0.65, blue: 0.28, alpha: 1),
                           #selector(acceptCall))
        ringDecline = pill("Decline", UIColor(red: 0.80, green: 0.22, blue: 0.22, alpha: 1),
                           #selector(declineCall))

        [ringLabel, ringSubLabel, ringAccept, ringDecline].forEach { ringBanner.addSubview($0!) }
        view.addSubview(ringBanner)
        setRingIdle()
    }

    private var ringBannerHeight: CGFloat { isRinging ? 58 : 30 }

    private func layoutRingBanner() {
        guard ringBanner != nil, toolbar != nil else { return }
        let h = ringBannerHeight
        let w = view.bounds.width
        ringBanner.frame = CGRect(x: 0, y: view.bounds.height - toolbarHeight - h,
                                  width: w, height: h)
        ringBanner.viewWithTag(771)?.frame = CGRect(x: 0, y: 0, width: w, height: 0.5)

        if isRinging {
            ringLabel.frame    = CGRect(x: 14, y: 8,  width: w - 190, height: 19)
            ringSubLabel.frame = CGRect(x: 14, y: 28, width: w - 190, height: 15)
            ringDecline.frame  = CGRect(x: w - 172, y: 14, width: 78, height: 30)
            ringAccept.frame   = CGRect(x: w - 88,  y: 14, width: 78, height: 30)
        } else {
            ringLabel.frame    = CGRect(x: 14, y: 0, width: w - 28, height: h)
            ringSubLabel.frame = .zero
        }

        // Resize the web view so the banner never overlaps the page.
        let target = webContentFrame
        if webView.frame != target {
            webView.frame = target
            recomputeSpoofedGeometry()
            pushGeometry()
        }
    }

    private func setRingIdle() {
        isRinging = false
        ringLabel.text = "No calls"
        ringLabel.textColor = UIColor(white: 0.55, alpha: 1)
        ringLabel.font = .systemFont(ofSize: 12, weight: .medium)
        ringSubLabel.text = nil
        ringAccept.isHidden = true
        ringDecline.isHidden = true
        ringBanner.backgroundColor = UIColor(white: 0.11, alpha: 0.98)
        layoutRingBanner()
        clearRingNotification()
        endCallKitCall()
        dismissAnswerOverlay()
    }

    private func setRinging(name: String, kind: String, canAccept: Bool, canDecline: Bool) {
        isRinging = true
        ringLabel.text = "\(name) is calling"
        ringLabel.textColor = .white
        ringLabel.font = .systemFont(ofSize: 15, weight: .bold)
        ringSubLabel.text = (kind == "video" ? "Incoming video call" : "Incoming voice call")
        ringAccept.isHidden = !canAccept
        ringDecline.isHidden = !canDecline
        ringBanner.backgroundColor = UIColor(red: 0.10, green: 0.19, blue: 0.12, alpha: 0.99)
        layoutRingBanner()
        // Mirror the banner as a real notification (with Accept / Decline)
        // so the call is visible even when InstaDesk isn't frontmost.
        lastRingName = name
        lastRingKind = kind
        postRingNotification(name: name, kind: kind)
        reportIncomingCall(name: name, kind: kind)
        // If CallKit could not present (common on free sideloads), show our
        // own full-screen ringer so there is always an Accept / Decline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.isRinging else { return }
            if !self.callKitPresented,
               UIApplication.shared.applicationState == .active {
                self.enterAnswerMode(name: name, kind: kind, armed: false)
            }
        }
    }

    @objc private func acceptCall() { ringAction("accept") }
    @objc private func declineCall() { ringAction("decline") }

    private func ringAction(_ what: String) {
        clearRingNotification()
        // If we are not frontmost the web view is suspended - queue it.
        if UIApplication.shared.applicationState != .active {
            pendingRingAction = what
            pendingRingDeadline = Date().addingTimeInterval(20)
            return
        }
        runRingAction(what, attempt: 0)
    }

    /// Actually drive Instagram's button. Retries: after returning from the
    /// lock screen the page needs a moment before the control is hittable.
    private func runRingAction(_ what: String, attempt: Int) {
        let js = "window.__idRingAct && window.__idRingAct('\(what)');"
        webView.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self = self else { return }
            let ok = (r as? Bool) ?? ((r as? NSNumber)?.boolValue ?? false)
            if ok {
                if what == "accept" { self.showInCallUI() }
                if what == "decline" { self.setRingIdle() }
                return
            }
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.runRingAction(what, attempt: attempt + 1)
                }
                return
            }
            self.flashToast("Couldn't reach Instagram's \(what) button - use the on-screen one.")
            if what == "decline" { self.setRingIdle() }
        }
    }

    // MARK: - Permissions diagnostics

    /// Re-request notification permission. If the user was never asked (the
    /// prompt can be missed on a sideloaded first launch) this shows it; if
    /// they were already asked, iOS will not prompt again and we deep-link
    /// them into Settings instead.
    @objc private func showPermissions() {
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { s in
            let mic = AVAudioSession.sharedInstance().recordPermission
            let ctx = LAContext()
            var lerr: NSError?
            let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                            error: &lerr)
            var bioName = "none"
            if #available(iOS 11.0, *) {
                switch ctx.biometryType {
                case .touchID: bioName = "Touch ID"
                case .faceID:  bioName = "Face ID"
                default:       bioName = "none"
                }
            }

            func word(_ v: UNNotificationSetting) -> String {
                switch v {
                case .enabled: return "ON"
                case .disabled: return "OFF"
                default: return "n/a"
                }
            }
            let auth: String
            switch s.authorizationStatus {
            case .authorized: auth = "AUTHORIZED"
            case .denied: auth = "DENIED"
            case .notDetermined: auth = "NEVER ASKED"
            case .provisional: auth = "PROVISIONAL"
            default: auth = "unknown"
            }

            let body = """
            Notifications: \(auth)
            Lock Screen: \(word(s.lockScreenSetting))
            Banners: \(word(s.alertSetting))
            Sound: \(word(s.soundSetting))
            Critical: \(word(s.criticalAlertSetting))
            Microphone: \(mic == .granted ? "ON" : (mic == .denied ? "DENIED" : "not asked"))
            Biometry: \(bioName) \(bio ? "available" : "unavailable")
            CallKit last error: \(self.lastCallKitError)
            Build: v26
            """

            DispatchQueue.main.async {
                let a = UIAlertController(title: "InstaDesk permissions",
                                          message: body, preferredStyle: .alert)
                if s.authorizationStatus == .notDetermined {
                    a.addAction(UIAlertAction(title: "Ask now", style: .default) { _ in
                        UNUserNotificationCenter.current().requestAuthorization(
                            options: [.alert, .sound, .badge]) { granted, _ in
                            DispatchQueue.main.async {
                                self.notificationsReady = granted
                                self.flashToast(granted ? "Notifications enabled"
                                                        : "Notifications refused")
                            }
                        }
                    })
                }
                a.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    }
                })
                a.addAction(UIAlertAction(title: "Test call (60s)", style: .default) { _ in
                    self.startTestCall()
                })
                let bioTitle = self.requireBiometric
                    ? "Turn OFF Touch ID for calls" : "Turn ON Touch ID for calls"
                a.addAction(UIAlertAction(title: bioTitle, style: .default) { _ in
                    self.requireBiometric.toggle()
                    self.flashToast(self.requireBiometric
                                    ? "Touch ID required to answer"
                                    : "Touch ID off")
                })
                a.addAction(UIAlertAction(title: "Close", style: .cancel))
                self.presentSafely(a, fallback: {})
            }
        }
    }

    /// Fire a test incoming call AFTER a delay, so the phone can be locked
    /// first. This matters: when the app is frontmost iOS deliberately shows
    /// CallKit as a small banner, and only shows the full-screen call card if
    /// the device is locked or another app is in front. Testing it while
    /// staring at InstaDesk will always look "broken".
    private func startTestCall() {
        testCallTimer?.invalidate()
        lastCallKitError = "none"
        notificationsReady = true
        endCallKitCall()

        flashToast("LOCK YOUR PHONE NOW - test call rings in 10s")

        var countdown = 10
        testCallTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                             repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            countdown -= 1
            if countdown > 0 {
                if countdown <= 5 { self.flashToast("Ringing in \(countdown)...") }
                return
            }
            t.invalidate()
            self.fireTestCall()
        }
    }

    private func fireTestCall() {
        postRingNotification(name: "Test Caller", kind: "voice")
        reportIncomingCall(name: "Test Caller", kind: "voice")
        setRinging(name: "Test Caller", kind: "voice",
                   canAccept: true, canDecline: true)

        // Hold it for a minute, re-posting the notification so it does not
        // vanish after a few seconds.
        var ticks = 0
        testCallTimer?.invalidate()
        testCallTimer = Timer.scheduledTimer(withTimeInterval: 10.0,
                                             repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            ticks += 1
            if ticks >= 6 {
                t.invalidate()
                self.testCallTimer = nil
                self.endCallKitCall()
                self.setRingIdle()
                return
            }
            self.postRingNotification(name: "Test Caller", kind: "voice")
        }
    }

    // MARK: - Native answer screen

    /// Called when Accept is tapped on the lock screen / notification.
    /// Rather than firing JS into a suspended web view, we bring the app
    /// forward and show a native Accept button the user taps once here.
    private func enterAnswerMode(name: String, kind: String, armed: Bool = true) {
        answerName = name
        answerKind = kind
        answerDisplayOnly = !armed
        // Rebuild if the mode changed while it is already on screen.
        if answerOverlay != nil {
            dismissAnswerOverlay()
        }
        // If we are already active we can show it straight away, otherwise
        // didBecomeActive will call showAnswerOverlay() for us.
        if UIApplication.shared.applicationState == .active {
            showAnswerOverlay()
        } else {
            pendingAnswerOverlay = true
        }
    }

    private func showAnswerOverlay() {
        pendingAnswerOverlay = false
        guard answerOverlay == nil else { return }

        let ov = UIView(frame: view.bounds)
        ov.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ov.backgroundColor = UIColor(white: 0.04, alpha: 1)

        let title = UILabel()
        title.text = answerName
        title.textColor = .white
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textAlignment = .center
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.6

        let sub = UILabel()
        sub.text = (answerKind == "video")
            ? "Incoming Instagram video call"
            : "Incoming Instagram voice call"
        sub.textColor = UIColor(white: 0.72, alpha: 1)
        sub.font = .systemFont(ofSize: 16, weight: .medium)
        sub.textAlignment = .center

        let hint = UILabel()
        hint.text = answerDisplayOnly
            ? "Swipe down on the notification and tap Accept to answer"
            : "Tap Accept to answer"
        hint.textColor = UIColor(white: 0.5, alpha: 1)
        hint.font = .systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.numberOfLines = 2

        let accept = UIButton(type: .system)
        accept.setTitle("Accept", for: .normal)
        accept.setTitleColor(.white, for: .normal)
        accept.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        // In display-only mode the Accept button is intentionally inert: it
        // is dimmed and just reminds the user to use the notification.
        accept.backgroundColor = answerDisplayOnly
            ? UIColor(red: 0.16, green: 0.72, blue: 0.30, alpha: 0.35)
            : UIColor(red: 0.16, green: 0.72, blue: 0.30, alpha: 1)
        accept.setTitleColor(answerDisplayOnly
            ? UIColor(white: 1, alpha: 0.6) : .white, for: .normal)
        accept.layer.cornerRadius = 36
        accept.addTarget(self, action: #selector(answerAcceptTapped), for: .touchUpInside)

        let decline = UIButton(type: .system)
        decline.setTitle("Decline", for: .normal)
        decline.setTitleColor(.white, for: .normal)
        decline.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        decline.backgroundColor = UIColor(red: 0.96, green: 0.14, blue: 0.23, alpha: 1)
        decline.layer.cornerRadius = 36
        decline.addTarget(self, action: #selector(answerDeclineTapped), for: .touchUpInside)

        [title, sub, hint, accept, decline].forEach { ov.addSubview($0) }
        view.addSubview(ov)
        answerOverlay = ov

        let w = ov.bounds.width
        let h = ov.bounds.height
        title.frame   = CGRect(x: 20, y: h * 0.22, width: w - 40, height: 40)
        sub.frame     = CGRect(x: 20, y: h * 0.22 + 44, width: w - 40, height: 22)
        hint.frame    = CGRect(x: 20, y: h * 0.22 + 74, width: w - 40, height: 34)
        let bw: CGFloat = min(150, (w - 60) / 2)
        accept.frame  = CGRect(x: w / 2 + 10, y: h * 0.66, width: bw, height: 72)
        decline.frame = CGRect(x: w / 2 - 10 - bw, y: h * 0.66, width: bw, height: 72)
    }

    private func dismissAnswerOverlay() {
        answerOverlay?.removeFromSuperview()
        answerOverlay = nil
        pendingAnswerOverlay = false
    }

    @objc private func answerAcceptTapped() {
        if answerDisplayOnly {
            flashToast("Swipe down on the notification, then tap Accept")
            return
        }
        authenticateThen { [weak self] in
            guard let self = self else { return }
            self.dismissAnswerOverlay()
            self.endCallKitCall(reason: .answeredElsewhere)
            // We are definitely active and the web view is live here.
            self.runRingAction("accept", attempt: 0)
        }
    }

    /// Run `action` after a successful Touch ID / Face ID check. If the device
    /// has no biometry enrolled we fall through to the passcode, and if that
    /// is unavailable too we simply proceed rather than locking the user out
    /// of their own call.
    private func authenticateThen(_ action: @escaping () -> Void) {
        guard requireBiometric else { action(); return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        var err: NSError?
        var policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        if !ctx.canEvaluatePolicy(policy, error: &err) {
            policy = .deviceOwnerAuthentication
            if !ctx.canEvaluatePolicy(policy, error: &err) {
                action(); return
            }
        }
        ctx.evaluatePolicy(policy,
                           localizedReason: "Confirm it is you to answer this call") { ok, _ in
            DispatchQueue.main.async {
                if ok {
                    action()
                } else {
                    self.flashToast("Not verified - call not answered")
                }
            }
        }
    }

    @objc private func answerDeclineTapped() {
        dismissAnswerOverlay()
        endCallKitCall(reason: .declinedElsewhere)
        runRingAction("decline", attempt: 0)
    }

    /// Bring up our own in-call screen instead of Instagram's.
    private func showInCallUI() {
        webView.evaluateJavaScript(
            "window.__idShowInCallUI ? window.__idShowInCallUI() : -1",
            completionHandler: nil)
    }

    /// Flush a queued Accept/Decline once we are active again.
    @objc private func flushPendingRingAction() {
        if pendingAnswerOverlay {
            // Give the window a beat to finish becoming key after unlock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showAnswerOverlay()
            }
            return
        }
        guard let what = pendingRingAction else { return }
        if let dl = pendingRingDeadline, Date() > dl {
            pendingRingAction = nil; pendingRingDeadline = nil
            return
        }
        pendingRingAction = nil
        pendingRingDeadline = nil
        // Give WebKit a beat to resume JS timers after foregrounding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.runRingAction(what, attempt: 0)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "idcall" {
            let on = (message.body as? NSNumber)?.boolValue
                ?? ((message.body as? String) == "1")
            DispatchQueue.main.async { self.setCallZoom(active: on) }
            return
        }
        if message.name == "idmsg" {
            guard let b = message.body as? [String: Any],
                  let items = b["items"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber =
                    (b["count"] as? Int) ?? 0
                // Cap the burst so a bulk sync cannot spam the lock screen.
                for it in items.prefix(3) {
                    self.postMessageNotification(
                        name: (it["name"] as? String) ?? "Instagram",
                        preview: (it["preview"] as? String) ?? "",
                        path: (it["href"] as? String) ?? "")
                }
            }
            return
        }
        guard message.name == "idring",
              let body = message.body as? [String: Any] else { return }

        let ringing = (body["ringing"] as? Bool) ?? false
        guard ringing else {
            if isRinging || lastRingSignature != "" {
                lastRingSignature = ""
                setRingIdle()
            }
            return
        }

        let name = (body["name"] as? String) ?? "Someone"
        let kind = (body["kind"] as? String) ?? "voice"
        let canAccept  = (body["canAccept"]  as? Bool) ?? false
        let canDecline = (body["canDecline"] as? Bool) ?? false
        let sig = "\(name)|\(kind)"
        guard sig != lastRingSignature else { return }
        lastRingSignature = sig
        setRinging(name: name, kind: kind, canAccept: canAccept, canDecline: canDecline)
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
    }

    /// Green button on the native call screen.
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        DispatchQueue.main.async {
            self.clearRingNotification()
            // Do NOT try to press Instagram's Accept from here: answering on
            // the lock screen leaves the web view suspended, so the tap was
            // being dropped. Open InstaDesk to a native Accept button and let
            // the user confirm with one tap in a live web view.
            self.enterAnswerMode(name: self.lastRingName,
                                 kind: self.lastRingKind, armed: true)
        }
        action.fulfill()
    }

    /// Red button, or the user ending an answered call.
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        DispatchQueue.main.async {
            self.clearRingNotification()
            // Only push Instagram's decline if the call never got answered.
            if self.isRinging { self.ringAction("decline") }
            self.activeCallUUID = nil
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // WebKit owns the audio route; nothing to do, but the callback is
        // required for the session to stay active.
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while InstaDesk is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    /// Accept / Decline tapped straight from the notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            self.ringNotificationID = nil
            switch action {
            case "ID_ACCEPT":
                // Arrived via the notification's Accept action - this is the
                // supported path, so the in-app Accept button is live.
                self.enterAnswerMode(name: self.lastRingName,
                                     kind: self.lastRingKind, armed: true)
            case "ID_DECLINE":
                self.endCallKitCall(reason: .declinedElsewhere)
                self.ringAction("decline")
            case "ID_OPEN_MSG", UNNotificationDefaultActionIdentifier:
                let cat = response.notification.request.content.categoryIdentifier
                if cat == "ID_INCOMING_CALL" {
                    // Tapping the body of a call notification must open the
                    // answer screen -- previously it fell through here and
                    // did nothing at all.
                    let info = response.notification.request.content.userInfo
                    self.enterAnswerMode(
                        name: (info["name"] as? String) ?? self.lastRingName,
                        kind: (info["kind"] as? String) ?? self.lastRingKind,
                        armed: true)
                    return
                }
                let info = response.notification.request.content.userInfo
                if let path = info["path"] as? String, !path.isEmpty,
                   let url = URL(string: "https://www.instagram.com" + path) {
                    self.webView.load(URLRequest(url: url))
                }
            default:
                break
            }
            completionHandler()
        }
    }

    // MARK: - Rotation

    /// Allow every orientation except upside-down (matches how iPhone Safari
    /// behaves). Landscape is genuinely better for video calls on a 4.7".
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    override var shouldAutorotate: Bool { true }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            self.webView.frame = self.webContentFrame
            self.recomputeSpoofedGeometry()
            self.layoutToolbar()
            self.layoutRingBanner()
            self.applyOrientation(landscape: size.width > size.height)
        }
    }

    /// Swap the spoofed screen dimensions to match the new orientation, tell
    /// the page to re-layout, then re-apply zoom (a resize wipes the viewport
    /// meta the same way an SPA navigation does).
    /// Send the current spoofed dimensions into the page and re-apply zoom.
    private func pushGeometry() {
        guard desktopMode else { return }
        let landscape = view.bounds.width > view.bounds.height
        let w = landscape ? landscapeW : landscapeH
        let h = landscape ? landscapeH : landscapeW
        let js = "window.__idW=\(w);window.__idH=\(h);" +
                 "window.dispatchEvent(new Event('resize'));"
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.applyZoom()
            }
        }
    }

    private func applyOrientation(landscape: Bool) {
        guard desktopMode else { return }
        let w = landscape ? landscapeW : landscapeH
        let h = landscape ? landscapeH : landscapeW
        let js = """
        (function(){
          try {
            window.__idW = \(w);
            window.__idH = \(h);
            if (screen.orientation) {
              try {
                Object.defineProperty(screen.orientation, 'type', {
                  get: function(){ return \(landscape ? "'landscape-primary'" : "'portrait-primary'"); },
                  configurable: true });
              } catch (e) {}
            }
            window.dispatchEvent(new Event('orientationchange'));
            window.dispatchEvent(new Event('resize'));
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            // Small delay so Instagram's own resize handlers settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.applyZoom()
            }
        }
    }

    private func refreshToolbar() {
        modeButton.setTitle(desktopMode ? "Desktop  ·  tap to re-login"
                                        : "Login mode  ·  tap for desktop", for: .normal)
        zoomLabel.text = desktopMode ? "\(zoomPercent)%" : "—"
        let on = desktopMode
        zoomInButton.isEnabled  = on && zoomIndex < zoomWidths.count - 1
        zoomOutButton.isEnabled = on && zoomIndex > 0
        zoomLabel.alpha = on ? 1 : 0.4

        // Call Mode is desktop-only: the call buttons simply don't exist in
        // Instagram's mobile web UI, so there'd be nothing to drive.
        callButton.isEnabled = on
        callButton.alpha = on ? 1 : 0.35
        callButton.setTitle(callModeOn ? "Close" : "Call Mode v26", for: .normal)
    }

    @objc private func toggleCallMode() {
        guard desktopMode else {
            flashToast("Call Mode needs desktop mode — Instagram's mobile web has no call buttons.")
            return
        }
        // The user script can be lost if Instagram replaced the document
        // after injection, so make sure it's present before toggling.
        webView.evaluateJavaScript("typeof window.__idCallModeToggle === 'function'") { [weak self] present, _ in
            guard let self = self else { return }
            let ok = (present as? Bool) ?? ((present as? NSNumber)?.boolValue ?? false)
            if ok {
                self.doToggleCallMode()
            } else {
                self.webView.evaluateJavaScript(self.callModeSource) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.doToggleCallMode()
                    }
                }
            }
        }
    }

    private func doToggleCallMode() {
        webView.evaluateJavaScript("window.__idCallModeToggle ? window.__idCallModeToggle() : -1") { [weak self] result, err in
            guard let self = self else { return }
            var n = -99
            if let i = result as? Int { n = i }
            else if let num = result as? NSNumber { n = num.intValue }

            if n == 1 {
                self.callModeOn = true
            } else if n == 0 {
                self.callModeOn = false
            } else {
                self.callModeOn = false
                // Surface why, using the diagnostic the script sets.
                self.webView.evaluateJavaScript("window.__idCallDiag || 'no-script'") { diag, _ in
                    let d = (diag as? String) ?? "unknown"
                    self.flashToast("Call Mode unavailable (\(d)). Open your DM inbox, let it load, then try again.")
                }
                if let err = err { NSLog("InstaDesk callmode error: \(err)") }
            }
            self.refreshToolbar()
        }
    }

    private func flashToast(_ text: String) {
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\")
                      .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.__idToast && window.__idToast('\(esc)', 3400);",
                                   completionHandler: nil)
    }

    @objc private func zoomIn()  { zoomIndex += 1; applyZoom() }
    @objc private func zoomOut() { zoomIndex -= 1; applyZoom() }
    @objc private func zoomReset() { zoomIndex = defaultZoomIndex; applyZoom() }

    @objc private func togglePhase() {
        desktopMode.toggle()
        didSwitchThisLaunch = true
        callModeOn = false
        loadCurrentPhase()
    }

    // MARK: - Permissions

    private func requestMediaPermissions() {
        AVCaptureDevice.requestAccess(for: .video)  { _ in }
        AVCaptureDevice.requestAccess(for: .audio)  { _ in }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .videoChat,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        if origin.host.hasSuffix("instagram.com") || origin.host.hasSuffix("cdninstagram.com") {
            decisionHandler(.grant)
        } else {
            decisionHandler(.prompt)
        }
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - JS dialogs
    // WKWebView drops alert/confirm/prompt unless the host implements these.
    // Without them prompt() silently returns null, so any JS relying on it
    // appears to do nothing at all.

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentSafely(a, fallback: { completionHandler() })
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentSafely(a, fallback: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { tf in
            tf.text = defaultText
            tf.clearButtonMode = .whileEditing
            tf.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in
            completionHandler(a?.textFields?.first?.text)
        })
        presentSafely(a, fallback: { completionHandler(nil) })
    }

    private func presentSafely(_ vc: UIAlertController, fallback: @escaping () -> Void) {
        var top: UIViewController = self
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        if top.isViewLoaded && top.view.window != nil {
            top.present(vc, animated: true, completion: nil)
        } else {
            fallback()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSessionAndPromote()
        applyZoom()
        // A full page load tears down the overlay; keep the button label honest.
        callModeOn = false
        refreshToolbar()

        // On the first load of the session, open Call Mode automatically so
        // the app starts on the contact list (with Log in / Add a chat)
        // instead of dumping the user into the raw Instagram inbox.
        if !didAutoOpenCallMode, desktopMode {
            didAutoOpenCallMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self = self, !self.callModeOn else { return }
                self.webView.evaluateJavaScript(self.callModeSource) { _, _ in
                    self.webView.evaluateJavaScript(
                        "window.__idCallModeShow ? window.__idCallModeShow() : -1") { r, _ in
                        if let n = r as? NSNumber, n.intValue == 1 {
                            self.callModeOn = true
                            self.refreshToolbar()
                        }
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        showError(error.localizedDescription)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showError(error.localizedDescription)
    }

    private func showError(_ message: String) {
        let label = UILabel(frame: view.bounds.insetBy(dx: 20, dy: 70))
        label.text = "Load failed:\n\(message)"
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.tag = 9911
        view.viewWithTag(9911)?.removeFromSuperview()
        view.insertSubview(label, belowSubview: toolbar)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}
