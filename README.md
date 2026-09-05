# InstaDesk

A minimal iOS app that is nothing but a `WKWebView` pointed at
**instagram.com forced into desktop mode**, with GPU compositing and
WebRTC media enabled.

Built for: **iPhone 6s / iOS 15.8.8** (`MinimumOSVersion 15.0`, arm64).

## Why this exists

Instagram's native app requires iOS 16.3+, so it won't install on a 6s.
Instagram's **desktop web** interface *does* have audio/video call buttons
in DM threads. Mobile Safari on iOS serves the mobile layout, and its
"Request Desktop Website" toggle is unreliable on Meta properties because
they sniff more than just the user agent.

This app pins a desktop macOS Safari user agent permanently, injects a
viewport override so the desktop layout is legible on a 4.7" screen, and
pre-grants camera/mic so the in-page call UI isn't blocked by a permission
prompt the web view can't surface.

## What's in the box

```
InstaDesk/
├── Sources/
│   ├── AppDelegate.swift        # window + root VC
│   └── WebViewController.swift  # the whole app
├── Info.plist                   # perms, min iOS, background audio
├── Entitlements.plist           # rewritten by your signing tool
├── build.sh                     # macOS-only build script
└── README.md
```

## The Linux problem (read this first)

**You cannot compile this on Linux.** Producing an iOS binary needs
Apple's Swift compiler plus the iOS SDK, and the SDK is macOS-only and
not redistributable. There is no working cross-compiler. Your options:

| Route | Cost | Notes |
|---|---|---|
| **Borrow a Mac** | free | 10 min with Xcode CLT installed. Run `./build.sh`. |
| **GitHub Actions** | free | `macos-latest` runner builds it for you, downloads as an artifact. Easiest Linux-only path — see below. |
| **MacinCloud / MacStadium** | ~$1/hr | Rented Mac in a browser. |
| **macOS VM** | free-ish | Legally grey, and needs decent hardware. |

### GitHub Actions recipe (no Mac needed)

Push this folder to a repo with `.github/workflows/build.yml`:

```yaml
name: build
on: [push, workflow_dispatch]
jobs:
  ipa:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: chmod +x build.sh && ./build.sh
      - uses: actions/upload-artifact@v4
        with:
          name: InstaDesk-ipa
          path: build/InstaDesk.ipa
```

Download the artifact, then sign + install from your Linux box with
Sideloadly (it has a Linux build) over USB.

## Installing

The output IPA is **unsigned**. Sign it with a free Apple ID via:

- **Sideloadly** (`sideloadly.io`) — has a Linux build, GUI, USB install
- **AltStore / AltServer-Linux** — on-device re-signing

Free developer certificates **expire after 7 days**. You'll need to
re-sign weekly. A paid Apple Developer account ($99/yr) extends this to
one year.

## Customising

Change `homeURL` in `WebViewController.swift` to land somewhere other
than the DM inbox. Change `desktopUA` if Instagram starts rejecting the
Safari 16.6 string — bump the `Version/` number.

Change the `initial-scale=0.37` in the injected viewport JS to taste.
0.37 fits a 1024px-wide desktop layout onto a 375pt 6s screen; raise it
for bigger text at the cost of horizontal scrolling.

## Honest expectations

This is the part where I stop selling it to you.

**It may not work, and here's specifically why it might not:**

1. **iOS 15's WebKit is old.** Instagram's web calling uses a current
   WebRTC feature set. Safari 15's implementation predates some of it.
   The call button may appear and then error out.

2. **Meta fingerprints beyond the UA.** They check screen dimensions,
   touch capability, `navigator.platform`, and codec support. A 375pt
   touchscreen claiming to be a desktop Mac is detectable, and they may
   serve the mobile layout anyway or hide the call controls.

3. **The private preference keys are undocumented.** The
   `setValue(_:forKey:)` calls on `WKPreferences` use internal keys.
   They're widely used and work on iOS 15, but they're not API. Most are
   already-default-on anyway — the meaningful ones here are the WebRTC
   toggles.

4. **A9 + 2GB RAM.** Even if everything negotiates, real-time video
   encode on a 2015 chip through a web view will be rough. Voice-only
   has a much better chance than video.

5. **7-day re-signing** is a genuine ongoing chore.

**Before you build any of this:** open Safari on the 6s, go to
instagram.com, tap **ᴀA → Request Desktop Website**, open a DM, and look
for the phone/camera icons. If they don't appear there, this app very
likely won't make them appear either — same WebKit, same Meta
fingerprinting. That 2-minute test tells you whether the build is worth
the effort.

## Legal note

This wraps Instagram's own public website in a web view. It doesn't
modify, decrypt, or redistribute Meta's app. It's the same thing a
"Add to Home Screen" bookmark does, with more control over the UA and
permissions.
