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

Download the latest DMG:

- [LumaPilot v0.1.0 DMG](https://raw.githubusercontent.com/Achyut198/LumaPilot/main/dist/LumaPilot-v0.1.0-macOS.dmg)
- [SHA-256](https://raw.githubusercontent.com/Achyut198/LumaPilot/main/dist/LumaPilot-v0.1.0-macOS.dmg.sha256)

Then open the `.dmg` and drag **LumaPilot.app** into **Applications**.

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

## 📄 Credits

Built and maintained by the **LumaPilot team**. Please see `License.txt` for details.
