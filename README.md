<div align="center">
  <img src=".github/Icon-cropped.png" width="200" alt="LumaPilot App icon"/>
  <h1>LumaPilot</h1>
  <p><b>Controls your external display brightness and volume and shows native OSD.</b></p>
  <p>Use menubar extra sliders or the keyboard, and turn off / turn on displays (internal and external monitor feature).</p>
  
  <a href="https://github.com/Achyut198/LumaPilot/releases"><img src="https://img.shields.io/github/downloads/Achyut198/LumaPilot/total.svg" alt="downloads"/></a>
  <a href="https://github.com/Achyut198/LumaPilot/releases"><img src="https://img.shields.io/github/release-pre/Achyut198/LumaPilot.svg" alt="latest version"/></a>
  <a href="https://github.com/Achyut198/LumaPilot/blob/main/License.txt"><img src="https://img.shields.io/github/license/Achyut198/LumaPilot.svg" alt="license"/></a>
</div>

<hr>

## 🚀 Key Features

* **Brightness & Volume Control**: Adjust your external and internal display's brightness, volume, and contrast seamlessly.
* **Native OSD Integration**: Displays the native Apple OSD for brightness and volume changes.
* **Display Toggle**: Turn off and turn on displays (both internal and external monitors).
* **Keyboard & Menubar**: Control your displays via the unobtrusive menubar sliders or using standard Apple keyboard media keys.
* **Automated Sync**: Synchronize brightness from built-in ambient light sensors across all external screens.
* **Smooth Transitions**: Enjoy fluid, smooth brightness adjustments.
* **Custom Shortcuts**: Set up custom keyboard combos simply from the settings.

## 💾 Installation

Download from Releases:

- [Latest release page](https://github.com/Achyut198/LumaPilot/releases/latest)
- [v0.1.0 DMG](https://github.com/Achyut198/LumaPilot/releases/download/v0.1.0/LumaPilot-v0.1.0-macOS.dmg)
- [v0.1.0 SHA-256](https://github.com/Achyut198/LumaPilot/releases/download/v0.1.0/LumaPilot-v0.1.0-macOS.dmg.sha256)

Then open the `.dmg` and drag **LumaPilot.app** into **Applications**.

## 🔐 Gatekeeper & Safety

Current public build is unsigned, so macOS may show:
**"Apple could not verify 'LumaPilot' is free of malware..."**

If that happens, install safely with:
1. Right click `LumaPilot.app` in Applications
2. Click `Open`
3. Click `Open` again in the security prompt

Fallback terminal method:

```bash
xattr -dr com.apple.quarantine /Applications/LumaPilot.app
open /Applications/LumaPilot.app
```

If needed, you can also allow it from:
`System Settings -> Privacy & Security -> Open Anyway`.

This repository includes:
- `scripts/macos_notarized_release.sh` for local notarized DMG builds
- `.github/workflows/release-notarized-dmg.yml` for tag-based CI release uploads

## 🛠 Usage Instructions

1. Launch **LumaPilot** from your Applications folder.
2. Grant **Accessibility Permissions** (System Settings » Privacy & Security) to enable native keyboard shortcuts interactions.
3. Access control sliders from the menubar brightness icon at the top of your screen.
4. Explore **Settings** for deeper customization regarding external display behaviors.

## 💻 Compatibility & Requirements

* **macOS 11 Big Sur** or newer is recommended for optimal performance.
* **macOS Sequoia / Tahoe** requires v4.3.3 or newer.
* Supports most modern external LCD displays (USB-C, DisplayPort, HDMI) using the standard DDC/CI protocol, alongside built-in Apple displays.
* DisplayLink, Airplay, and Sidecar supported via shade control.

## 🏗 Developer & Build Setup

1. **Clone the repository:**
   ```sh
   git clone https://github.com/Achyut198/LumaPilot.git
   ```
2. **Open the project:** Open `LumaPilot.xcodeproj` in Xcode.
3. **Build:** Dependencies resolve automatically via Swift Package Manager.

### Notarized Release (Maintainers)

Set these GitHub Actions secrets:
- `BUILD_CERTIFICATE_BASE64` (Developer ID Application .p12, base64 encoded)
- `P12_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `DEVELOPER_ID_APP_IDENTITY` (exact `codesign` identity string)

Then push a tag like `v0.1.1`; the workflow will build, notarize, staple, and upload `.dmg` + `.sha256` to the matching GitHub Release.

## 📄 Credits

Built and maintained by the **LumaPilot team**. Please see `License.txt` for details.
