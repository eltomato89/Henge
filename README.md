<p align="center">
  <img src="docs/icon.png" width="120" height="120" alt="Henge">
</p>

<h1 align="center">Henge</h1>

<p align="center">macOS on your iPhone and iPad.</p>

<p align="center">
  <a href="#install">Install</a>
  ·
  <a href="docs/architecture.md">How it works</a>
  ·
  <a href="https://itslevii.dev">Website</a>
  ·
  <a href="https://github.com/Leviidev/Henge/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/Leviidev/Henge/releases"><img src="https://img.shields.io/github/downloads/Leviidev/Henge/total?style=flat-square&color=2E6BFF&labelColor=111111" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Leviidev/Henge?style=flat-square&color=2E6BFF&labelColor=111111" alt="GPL-2.0-or-later"></a>
</p>

> [!NOTE]
> **This is a personal fork of [Leviidev/Henge](https://github.com/Leviidev/Henge).** The `local` branch is the upstream `main` plus the changes below, tested on an iPad with a Magic Keyboard. Fixes that are useful upstream go back as pull requests. For the official app, releases and support, use the [original repository](https://github.com/Leviidev/Henge).

## What this fork adds

### Larger disks
A stopped Mac's disk can be made larger: in a Mac's settings, **Make the Disk Larger…** offers sizes from 96 GB up to 2 TB. A disk can only grow, never shrink. The image is sparse, so it takes only the space macOS actually writes.

This is upstream's [#139](https://github.com/Leviidev/Henge/pull/139), extended here from 256 GB to 2 TB. After growing the file, Henge moves the recovery partition to the new end of the disk and rewrites the partition table. Then one command in the Mac's Terminal is enough for macOS to use the space:

```bash
sudo diskutil apfs resizeContainer disk0s2 0
```

This also works on a disk whose recovery container was deleted earlier: then only the partition table moves.

### Smooth trackpad scrolling on iPad
Two-finger scrolling on a Magic Keyboard trackpad or a mouse wheel used to arrive as coarse wheel clicks, so a small swipe could jump far down a page. Now Henge plays it on the Mac's virtual Magic Trackpad 2 as two fingers moving, so macOS scrolls the way a real Mac trackpad does: pixel-smooth, with its own momentum and rubber-banding.
- The fingers start at the far edge of the virtual pad. When they reach the other side, they rest briefly before re-gripping, so macOS doesn't start momentum or speed up partway through a long swipe.
- **Settings → Mouse and Trackpad → Reverse scrolling** and **Scroll speed** still apply.

### Steady clicks on a hardware trackpad
Pressing a Magic Keyboard trackpad rolls the finger a little. iPadOS reports that roll as motion, so the Mac's pointer jumped a few pixels just as a click arrived. A Mac's own trackpad ignores this, and now Henge does too:
- **Before a press:** a nudge of up to 6 px in the last 60 ms before the press is taken back.
- **While a button is down:** motion is held until it passes 8 px. Past that, it's a drag and the held motion is sent. Released before that, it was a wobble and is dropped.

### The iPad's battery in macOS
The Mac sees the iPad's battery as a USB UPS (a HID power device on a third xHCI port). macOS shows its charge, whether it's charging, and whether it's on power in the menu bar and in System Settings → Battery. It can use its normal UPS settings to shut down when the iPad runs low.

### Keeps running in the background
iOS only keeps an app with the audio background mode running while it actually plays sound, and a quiet Mac plays none. So while a Mac runs, Henge plays silence (inaudible, and mixed with other apps). This keeps the Mac running when you switch to another app. Turn it off in **Settings → Background**. iOS can still end Henge when memory runs short.

### Built-in JIT with other Apple devices nearby
Built-in StikJIT looked up the device's RemotePairing port over Bonjour and took the first answer. That answer could come from another Apple device on the same Wi-Fi, such as an iPhone, and JIT then failed with *"Henge couldn't reach this device"* even though LocalDevVPN was connected. Henge now uses only a port that is actually open on this device. Sent upstream as [#166](https://github.com/Leviidev/Henge/pull/166).

### Merged pull requests from upstream
These open pull requests on Leviidev/Henge are merged here:
- [#91](https://github.com/Leviidev/Henge/pull/91): **Microphone**. The Mac gets the device's microphone as a sound input (opt-in, Settings → Sound).
- [#88](https://github.com/Leviidev/Henge/pull/88): **Pick the shared folder**. Serve any folder to the Mac instead of only the built-in one. Henge's own working files are never served.
- [#139](https://github.com/Leviidev/Henge/pull/139): **Larger disks**. See above.
- [#72](https://github.com/Leviidev/Henge/pull/72): **Mac shortcuts**. Optional Control-Tab, Control-Q and Control-Space for the app switcher, Quit and Spotlight (Settings → Keyboard).

### Building this fork
First run the dependency and engine steps under [Building](#building) below (`fetch_deps.sh`, `build_ios_restore.sh`, `make ios-lib`). Then, to sign with your own paid developer team and install directly:

```bash
cd ios && xcodegen
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release \
  -destination 'id=<device UDID>' -derivedDataPath build/DD -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM ID> HENGE_BUNDLE_IDENTIFIER=com.<you>.henge \
  HENGE_ENTITLEMENTS=$PWD/build/Henge.dev.entitlements build
xcrun devicectl device install app --device <device UDID> build/DD/Build/Products/Release-iphoneos/Henge.app
```

`Henge.dev.entitlements` holds `get-task-allow`, `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing`. Built-in JIT needs LocalDevVPN and a pairing file from Henge's JIT setup.

---

Download macOS, install it on the device, and use it.

- **Own emulator** — iOS gives apps no hypervisor, so Henge runs the Mac's arm64 code through its own JIT, with its own MMU and devices. It doesn't use QEMU or Virtualization.framework.
- **Installs on the device** — Henge downloads Apple's restore image and restores it the way a Mac does. No Mac needed, and nothing is decrypted or patched.
- **Graphics** — macOS draws through a virtual GPU, and Henge replays its commands with Metal. Safari and Electron apps like Discord draw on it.
- **Touch** — The screen is a Magic Trackpad 2: two fingers to scroll, and the Mac's own gestures work on it — three-finger swipes for Spaces and Mission Control and more. The volume buttons are its buttons: up clicks, down right-clicks, hold to drag. Esc, Tab, Control, Option and Command sit above the keyboard.
- **Keyboard and mouse** — On iPad, a Magic Keyboard or a Bluetooth keyboard and mouse drive the Mac directly. In Settings → Keyboard, opt in to Control-Tab for the Mac app switcher, Control-Q to quit the current Mac app, or Control-Space for Spotlight.
- **External display** — During a Mac session, connect a display with a video-capable USB-C cable or a USB-C/HDMI dock. The mode activates automatically: the monitor shows the Mac, while the iPhone or iPad keeps its trackpad and keyboard controls. Disconnect to return the image to the device. The existing guest resolution is preserved. On iOS 17–26 the same happens through an older iOS route, not yet tried on hardware; outside a Mac session the display mirrors the device. USB-C video is user-confirmed on an iPhone 17 Pro running iOS 27 (development build 0.1/2).
- **Sharing** — Copy and paste between macOS and the device, and a shared folder that shows up in Files and on the Mac.
- **Fits the screen** — On iPad, a new Mac gets a screen the shape of the iPad's, so there are no black bars.

On an iPhone 17 Pro, macOS reaches the lock screen in about 15 seconds. Discord installs, opens in about 15 seconds, logs in and sends messages.

## Install

Sideload `Henge.ipa` from [Releases](https://github.com/Leviidev/Henge/releases) with SideStore or AltStore, or install `Henge.tipa` with TrollStore or TrollStore Lite. To get updates in SideStore or AltStore, add Henge's source, `https://raw.githubusercontent.com/Leviidev/Henge/main/repo.json`, or `https://itslevii.dev/repo.json` for all of Leviidev's apps. iOS or iPadOS 17 or later, on an A14 or M1 chip or newer. So far it's tested only on an iPhone 17 Pro: iPad support is new and hasn't run on a real iPad yet.

- **JIT** is required: StikDebug, TrollStore (which stops at iOS 17.0), TrollStore Lite (which needs a jailbreak), a jailbreak on its own, or the StikJIT helper built into Henge (iOS 26 or later).
- **Storage:** about 43 GB free for macOS Sequoia. That's 17 GB for the download, which you can delete afterwards, and 26 GB for the Mac.
- **Memory:** a Mac gets 4, 6 or 8 GB. Sign Henge with the increased memory limit entitlement if your certificate has it.

Then open the Install tab, pick macOS Sequoia 15.6.1, and keep Henge open with the device plugged in. Tahoe 26.6.2 and macOS 27.2 are offered too: both install and run on an iPhone 17 Pro, though Tahoe's first setup is slow and macOS 27 is the slowest (Safari's pages may stay blank on it). Sonoma 14.6.1 and Ventura 13.6 are smaller downloads (14.1 and 12.3 GB) for devices short on storage: they install, set up, and run Safari (both tested on an iPhone 17 Pro). Monterey isn't offered yet: it installs, but its desktop never appears.

## Sharing with the Mac

Do this once for each Mac: open Terminal on the Mac, then in Henge open Details and tap **Type the Set Up Command**. Press Return on the Mac, and choose Allow when macOS asks about `henge-agent` and local networks. It needs the Mac's keyboard layout to be U.S.

Then a Henge folder in the Mac's home folder is the same folder as Files › Henge › Shared. What you copy on the Mac is copied on the device too, and the paste button pastes from the device into the Mac.

## Known limits

- Signing in to an Apple Account inside macOS fails with a verification error.
- Graphics are tested on macOS's own apps, Chrome, Firefox, VS Code and Discord. Other apps may draw wrongly.
- On macOS Sonoma, switching to a dynamic wallpaper (such as Sonoma) can stop the screen updating; opening any app brings it back. On Ventura, the Calendar icon in the Dock is missing its date.
- For the first few minutes after you log in, macOS is busy starting up in the background, so apps open more slowly.
- Only one Mac can start per launch. Quit Henge and open it again to start another, and to start one again after restarting or shutting down macOS.
- iPadOS keeps some keyboard shortcuts for itself, such as Command-Tab.
- It's emulation, so it runs slower than a real Mac.

## Screenshots

<table>
  <tr>
    <td align="center" colspan="3"><img src="Screenshots/ipad.jpg" alt="Discord on an iPad"><br><sub>iPad</sub></td>
  </tr>
  <tr>
    <td align="center" width="33%"><img src="Screenshots/macs.png" alt="Macs"><br><sub>Macs</sub></td>
    <td align="center" width="33%"><img src="Screenshots/trackpad.png" alt="Trackpad"><br><sub>Trackpad</sub></td>
    <td align="center" width="33%"><img src="Screenshots/install.png" alt="Install macOS"><br><sub>Install macOS</sub></td>
  </tr>
</table>

<sub>Captured on a Mac: the app's own screens with sample data, at iPad and iPhone sizes, showing a frame from Henge's renderer.</sub>

## Building

To use Henge, install the [latest release](https://github.com/Leviidev/Henge/releases). Every change lands on `main` as it's made, so `main` can be unfinished between releases.

On a Mac with Xcode 27 or later and `xcodegen`. Henge takes StikJIT, on-device pairing, libslirp and glib from a built [Husk](https://github.com/Leviidev/Husk) checkout at `~/Documents/Coding/Husk` (set `HUSK` to use another path):

```bash
ios/scripts/fetch_deps.sh
tools/build_ios_restore.sh
make ios-lib
ios/scripts/package_ipa.sh
```

That produces `~/Desktop/Henge.ipa`, and `package_ipa.sh --trollstore` writes `Henge.tipa`.

`make` builds the engine for the Mac, `build/hengevm`, and `make test` runs its tests.

## Licence

GPL-2.0-or-later. Henge compiles in usbmuxd (GPLv2 or GPLv3) and code from Husk (GPL-2.0-or-later), so the shipped binary is a combined GPL work. It cannot go on the App Store. See [docs/licensing.md](docs/licensing.md).

macOS and the Mac's boot ROM are Apple's and aren't part of Henge. Henge downloads both from Apple when you install.
