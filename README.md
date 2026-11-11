# TOP75 for macOS

An independent, open-source macOS configurator for the wired Darmoshark TOP75 with device ID **957**. The app speaks directly to the keyboard over USB and works offline. The interface is currently in Turkish.

[Download the latest published build](https://github.com/kreativecenter/top75-macos/releases)

## Connect

1. Plug the keyboard directly into your Mac with a USB data cable. Set the keyboard’s mode switch to **OFF** so its screen shows **USB**.
2. Open **TOP75.app** on macOS 14 or later. Release builds include Apple Silicon and Intel binaries.
3. Open **Aydınlatma** for lighting, **Tuşlar ve profiller** for key assignments and onboard profiles, **Makrolar** for macro slots, **Ekran** for artwork, or **Ayarlar** for device options.
4. Use **Klavyeden oku** to refresh from the device. Changes are written only when you click the relevant apply button.

If macOS prompts for permission to connect the USB accessory, review the prompt before connecting. The downloadable build is ad-hoc signed and distributed as a prerelease. You can also build the app locally.

## Feature coverage

| Feature | Support |
| --- | --- |
| RGB color, rainbow, effects, speed, brightness, direction | USB control with settings readback. Static color and brightness tested on a TOP75. |
| Per-key RGB | Read and write individual colors and activate the custom pattern. Single-key write and restoration verified. |
| Onboard profiles | Switch between three profiles. |
| Key assignments | Base and Fn layers, HID keys, common media keys, macro slots and disabled/pass-through assignments. Base and Fn writes and restoration tested. |
| Keyboard macros | Read and edit keyboard strokes, delays and repeat count. Supports assigning a saved macro to a key. Short macro write and clearing tested. The editor supports keyboard events. |
| Screen artwork | Import a PNG or JPEG into one of five slots, or a GIF of up to 25 frames into the animation slot. A still-image USB transfer was accepted on a TOP75. The device does not expose pixel readback. GIF playback has not been verified on hardware. |
| Device options | Debounce, automatic OS detection, and Bluetooth/2.4 GHz sleep and deep-sleep timers. Debounce and Bluetooth timer write/readback tested. |
| Local presets and export | Five local lighting presets. Export a JSON snapshot of the three keymaps, RGB and device options. |
| Guide | Search the TOP75 shortcuts and setup information with ⌘F. |

The Windows app also offers functions beyond this release. Wireless configuration, firmware flashing, live music/screen-reactive lighting, mouse-event macros, vendor sharing services and JSON restoration are open items. Compatibility is scoped to the USB device reported as 957. The USB VID/PID is shared with other keyboards.

## Build

Install Xcode with Swift 6 support, then run:

```sh
./scripts/build.sh
```

This creates `dist/TOP75.app` and `dist/TOP75-macOS.zip`. The script verifies the app signature and exercises the search, HID report, macro, and screen encoding checks. For development, open `Package.swift` in Xcode or run `swift run TOP75`.

See [protocol and hardware notes](docs/protocol.md) for command provenance and the verification boundary.

## License

MIT. Darmoshark and TOP75 identify the compatible hardware. This is a community project with no vendor affiliation.
