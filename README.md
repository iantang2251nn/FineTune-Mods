<img src="assets/icon.png" width="170" height="170" alt="FineTune app icon" align="left"/>

<h3>FineTune-Mods</h3>

Control the volume of every app independently, route audio to different speakers, and shape your sound with EQ and headphone correction. Lives in your menu bar. Free and open-source.

A fork of [FineTune](https://github.com/ronitsingh10/FineTune) by Ronit Singh, adding a per-device parametric EQ, L/R channel trims and seamless output switching. See [About this fork](#about-this-fork).

<a href="https://github.com/iantang2251nn/FineTune-Mods/releases/latest/download/FineTune-Mods.dmg"><img src="assets/download-badge.svg" alt="Download for macOS" height="48"/></a>

<br clear="all"/>

<p align="center">
  <a href="https://github.com/iantang2251nn/FineTune-Mods/releases/latest"><img src="https://img.shields.io/github/v/release/iantang2251nn/FineTune-Mods?style=for-the-badge&labelColor=1c1c1e&color=0A84FF&logo=github&logoColor=white" alt="Latest Release"></a>
  <a href="https://github.com/iantang2251nn/FineTune-Mods/releases"><img src="https://img.shields.io/github/downloads/iantang2251nn/FineTune-Mods/total?style=for-the-badge&labelColor=1c1c1e&color=3a3a3c" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-3a3a3c?style=for-the-badge&labelColor=1c1c1e" alt="License: GPL v3"></a>
  <a href="https://ko-fi.com/ronitsingh10"><img src="https://img.shields.io/badge/Tip_on_Ko--fi-FF5E5B?style=for-the-badge&labelColor=1c1c1e&logo=ko-fi&logoColor=white" alt="Tip on
  Ko-fi"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15.4%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15.4+"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="assets/screenshot-main.png" alt="FineTune popup showing per-app volume control, multi-device output routing with picker popover, AutoEQ headphone correction, and device-level volume sliders" width="700">
</p>
<p align="center">
  <img src="assets/screenshot-eq.png" alt="FineTune showing the Brave Browser app row expanded with the EQ panel open and a Vocal Clarity preset selected" width="700">
</p>

## Install

**Easiest: one line in Terminal** (recommended)

Open **Terminal** (⌘Space, type "Terminal", press Return), paste this line and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/iantang2251nn/FineTune-Mods/main/scripts/install.sh | bash
```

It downloads the latest release, installs it into Applications and opens it — no security prompts to click through. Run the same line again to update.

**Or download the DMG** — [latest release](https://github.com/iantang2251nn/FineTune-Mods/releases/latest)

1. Open the DMG and drag **FineTune** into **Applications**.
2. Open FineTune. macOS says it can't verify the app: click **Done** (not Move to Trash).
3. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to FineTune and enter your password.

This only happens once. The app isn't notarized by Apple, which needs a paid developer account; the one-line install avoids the prompt because files downloaded in Terminal aren't flagged.

> **Note:** `brew install --cask finetune` and the original project's downloads install upstream FineTune, without this fork's changes. FineTune-Mods replaces FineTune if both are installed (same app, same settings), and doesn't update itself: run the install line again for a new version.

## Quick Start

1. Install FineTune and launch it from your Applications folder
2. Grant **Screen & System Audio Recording** permission when prompted
3. Click the FineTune icon in your menu bar. Apps playing audio appear automatically.

That's it. Adjust sliders, route audio, and explore EQ from the menu bar.

> **Tip:** Want FineTune to auto-switch to a specific device when you connect it? Open edit mode (pencil icon) and drag it above the built-in speakers. This is a one-time setup. Your preferred order is saved permanently.

## About this fork

FineTune-Mods is based on FineTune v1.9.0. Everything below in Features still applies; this fork adds:

- **Device parametric EQ** — A 10-band parametric EQ per output device (low shelf, 8 peaks, high shelf) with a live response curve. Drag a node to set frequency and gain, scroll over it for Q, double-click to reset; type or drag exact values. Saved per device and re-applied when the device reconnects.
- **Import and export** — Load EqualizerAPO or REW filter files into the device EQ, and export your curve as EqualizerAPO text.
- **L/R channel trims** — Raise or lower the left or right channel of a device by up to 12 dB in 0.1 dB steps, for matching monitors.
- **EQ on every interface** — The EQ chain runs on multichannel and split-channel audio interfaces, on the device's stereo pair.
- **Seamless output switching** — No dip when switching outputs from FineTune, and the level returns exactly when you switch back. "System Audio" and picking the same device by name sound identical. Switches that fail while a device starts up are retried, apps return to a replugged device once it's ready, and the new device gets its EQ, AutoEQ and loudness settings from the first sample.
- **Graphic EQ reset** — Double-click a band label to reset it to 0 dB.
- **No per-app boost** — The 2x–4x per-app volume boost is removed; it drove the limiter into audible clipping.

## Features

### 🎚 Volume Control
- **Per-app volume** — Individual sliders and mute for each application
- **Pinned apps** — Keep apps visible in the menu bar even when they're not playing, so you can configure volume, EQ, and routing in advance
- **Ignore apps** — Completely disengage FineTune from specific apps. Tears down the audio tap so the app returns to normal macOS audio
- **Scroll-wheel volume** — Hover any slider in the popup, the HUD, or the EQ panel and scroll to adjust.

### ⌨️ Keyboard
- **Global volume hotkeys** — Bind your own keys to **App Volume Up**, **App Volume Down**, and **App Mute** from Settings → Shortcuts. The "app" is whichever is currently making sound, so volume-down while a YouTube tab plays behind a foreground Terminal turns down YouTube, not the terminal. If nothing is audible, the hotkey falls through to the frontmost app.
- **Toggle the popup from anywhere** — Bind a hotkey to **Toggle FineTune Popup** and the menu bar opens or closes on demand, including from full-screen apps.
- **Configurable step size** — Pick **Coarse / Normal / Fine / Extra-Fine** under Settings → Shortcuts → Volume Step. The same setting governs the F10–F12 media keys, the global hotkeys, and the popup's arrow-key navigation.
- **Hold to ramp, auto-unmute on volume-up** — Holding App Volume Up or Down emits repeats the way macOS does for arrow keys. Volume-up while muted unmutes and sets the new level in one keystroke.
- **Drive the popup with the keyboard** — Once the popup is open, **↑ / ↓** move between rows, **← / →** adjusts the focused row's volume (Shift = 2× step), **M** toggles mute, **Return / Space** activates, **Tab** switches between Output and Input device tabs, **Esc** closes. The focused row autoscrolls to center as you arrow through.

### 🔀 Audio Routing
- **Multi-device output** — Route audio to multiple devices simultaneously
- **Audio routing** — Send apps to different outputs or follow system default
- **Device priority** — Choose which device FineTune switches to when a new device connects; auto-fallback on disconnect
- **Auto-restore** — When a device reconnects, apps automatically return to it with their volume, routing, and EQ intact

### 🎛 EQ & Correction
- **10-band EQ** — 20 presets across 5 categories
- **User EQ presets** — Save, rename, and manage custom EQ configurations per app
- **AutoEQ headphone correction** — Search thousands of headphone profiles or import your own ParametricEQ.txt files for per-device frequency response correction
- **Loudness compensation** — Automatic bass and treble correction at low volumes using ISO 226:2023 equal-loudness contours, with real-time level management to keep perceived loudness consistent

### 🖥 Devices & System
- **Input device control** — Monitor and adjust microphone levels
- **Alert volume** — Control macOS notification and alert volume from settings
- **Smart volume backend** — FineTune auto-picks hardware, DDC, or software volume per device. If the hardware slider on a USB DAC or HDMI output doesn't actually control level, force software volume from the device inspector and FineTune remembers the choice for that device
- **Device inspector** — Tap the info button on any device row for sample rate (with picker), transport, UID copy, hog-mode banner, and the software-volume override
- **Hide devices** — Eye toggle in edit mode hides output and input devices you don't want in the list, mirroring the app-hide flow
- **Bluetooth device management** — Connect paired devices directly from the menu bar
- **Monitor speaker control** — Adjust volume on external displays via DDC
- **Media keys & Volume HUD** — Opt-in F10–F12 control for the default output device, with a Tahoe-style or Classic-style on-screen HUD. The write goes through FineTune's volume pipeline, so keys keep working on USB interfaces and HDMI outputs where macOS's own keys are greyed out because the hardware slider is broken.
- **Dynamic menu bar icon** — Pick from four styles in Settings (Default, Speaker, Waveform, Equalizer). The **Speaker** style tracks volume live (zero / low / mid / high glyphs) and switches to a slashed speaker when muted. All styles briefly flash the new output's SF Symbol on device switch. Changing style applies instantly, no relaunch required.
- **Menu bar app** — Lightweight, always accessible
- **URL schemes** — Automate volume, mute, device routing, and more from scripts

### 🎨 Appearance
- **Light or Dark theme** — Settings → General → Theme matches macOS or locks FineTune to Light or Dark. The menu bar popup, every popover, and the volume HUD switch immediately.
- **Popup density** — Settings → General → Popup Size picks **Compact / Comfortable / Spacious** with a live tile preview. Compact fits more apps on small screens; Spacious gives bigger hit areas for trackpads.

## Documentation

- **[AutoEQ & Headphone Correction](guide/autoeq.md)** — Apply frequency correction from the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project, import [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) profiles, or browse [autoeq.app](https://www.autoeq.app/)
- **[URL Schemes](guide/url-schemes.md)** — Automate FineTune from Terminal, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or scripts
- **[Troubleshooting](guide/troubleshooting.md)** — Permission issues, missing apps, audio problems

## Contributing

- **Star this repo** — Help others discover FineTune
- **Report bugs** — [Open an issue](https://github.com/iantang2251nn/FineTune-Mods/issues) for this fork; for issues that also happen in upstream FineTune, see [its tracker](https://github.com/ronitsingh10/FineTune/issues)
- **Contribute code** — See [CONTRIBUTING.md](CONTRIBUTING.md)

### Build from Source

```bash
git clone https://github.com/iantang2251nn/FineTune-Mods.git
cd FineTune-Mods
open FineTune.xcodeproj
```

## Requirements

- macOS 15.4 (Sequoia) or later
- Audio capture permission (prompted on first launch)

## Support

FineTune is free and open source, forever. If it made your day a little easier, you can support its original author, Ronit Singh — but genuinely not expected 🙏

[![Buy me a coffee](https://img.shields.io/badge/Buy_me_a_coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/ronitsingh10)


## License

[GPL v3](LICENSE)
