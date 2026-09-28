# Getting your IPA — step by step (from Linux, no Mac)

You have no Mac, so we use a free GitHub Actions macOS runner to compile,
then sign and install from your Linux box.

---

## Step 1 — Put the project on GitHub

```bash
cd /home/user/InstaDesk
git init
git add .
git commit -m "InstaDesk: desktop-mode Instagram web shell"
git branch -M main
git remote add origin https://github.com/YOURNAME/instadesk.git
git push -u origin main
```

Create the empty repo on github.com first. It can be private — Actions
minutes are free for public repos and generous for private ones.

## Step 2 — Let it build

The workflow at `.github/workflows/build.yml` runs automatically on push.

- Go to your repo → **Actions** tab
- Watch "Build InstaDesk IPA" — takes about 2 minutes
- When green, open the run → **Artifacts** → download **InstaDesk-ipa**
- Unzip it → you have `InstaDesk.ipa`

If the build fails, open the failed step's log and paste it to me — the
Swift compiler messages are usually a one-line fix.

## Step 3 — Install Sideloadly on Linux

```bash
# from sideloadly.io — grab the Linux build
chmod +x Sideloadly*.AppImage
./Sideloadly*.AppImage
```

You also want the iOS USB stack:

```bash
sudo apt install libimobiledevice-utils usbmuxd ideviceinstaller
sudo systemctl enable --now usbmuxd
```

## Step 4 — Sign and install

1. Plug the 6s in over USB
2. On the phone: **Trust This Computer** → enter passcode
3. Verify Linux sees it: `ideviceinfo -k ProductVersion` → should print `15.8.8`
4. In Sideloadly: drag in `InstaDesk.ipa`
5. Enter your **Apple ID** (a throwaway one is fine and safer)
6. Hit **Start**

Sideloadly re-signs the IPA with a free development certificate and
pushes it to the phone.

## Step 5 — Trust the certificate

On the 6s:

**Settings → General → VPN & Device Management → [your Apple ID] → Trust**

Without this the app icon appears but launching it does nothing.

## Step 6 — Launch

Tap InstaDesk. It should open straight into Instagram's **desktop** DM
inbox. Log in. Open a thread. The phone and camera icons should be at
the top right.

First call will prompt for camera + mic — allow both.

---

## The 7-day thing

Free Apple developer certificates expire after **7 days**. When the app
stops launching, plug in and re-run Sideloadly. Takes 30 seconds.

Ways to reduce the pain:
- **AltStore + AltServer-Linux** can re-sign automatically over Wi-Fi
  while the phone is on the same network
- A **paid Apple Developer account** ($99/yr) extends certs to 1 year
- Free Apple IDs are limited to **3 sideloaded apps** at a time

---

## Troubleshooting

**Build fails on `@main`** — already handled via `-parse-as-library` in
`build.sh`. If it still complains, tell me the exact error.

**Sideloadly: "Could not find device"** — `usbmuxd` isn't running, or you
didn't tap Trust. Run `idevicepair pair` manually.

**App installs but crashes instantly** — usually a missing usage-string
in `Info.plist`. All four are present, but grab the crash log
(Settings → Privacy → Analytics → Analytics Data) and send it; you're
already good at reading those.

**App opens but shows the MOBILE Instagram layout** — Meta's fingerprinting
beat the UA. Fixes to try, in order:
1. Bump the `Version/16.6` in `desktopUA` to `Version/17.0`
2. Add `navigator.platform` spoofing to the injected JS
3. Raise the viewport `width=1024` to `width=1280`

Tell me which and I'll patch it.

**Call icons appear but the call errors** — iOS 15 WebKit's WebRTC gap.
This is the failure mode I can't engineer around from here. Safari
already worked for you, so this is unlikely.
