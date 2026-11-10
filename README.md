# HiDpiSwitcher

**English** | [Русский](README_RU.md)

HiDpiSwitcher is a lightweight, native macOS menu bar application designed to easily switch displays into crisp HiDPI (Retina 2x) modes, unlock custom virtual resolutions, and manage refresh rates.

---

## Features

- **Instant HiDPI Switching (`⌃⌥⌘H`)**: Toggle smoothly between 1x and 2x Retina modes while maintaining the current refresh rate.
- **Independent Resolution and Refresh Rate Control**: Resolutions are cleanly grouped by dimensions, while refresh rates are selected in a dedicated submenu with hardware frequency validation.
- **Favorites & Fast Cycling (`⌃⌥⌘F`)**: Pin frequently used display modes to the top of the menu and cycle through them using a global keyboard shortcut.
- **Safe Mode Rollback (10-second countdown)**: When switching to an untested mode, a floating confirmation panel appears. Confirm with `Enter` or cancel with `Esc`. If the signal is lost, the display automatically reverts after 10 seconds.
- **Profile Auto-Restoration**: Automatically reapplies your chosen resolution and HiDPI profile upon system wake, login, or cable reconnection.
- **HiDPI for External & Ultrawide Displays**:
  - **Virtual Framebuffer (`CGVirtualDisplay` + Hardware Mirroring)**: Enables Retina scaling without requiring reboots or disabling System Integrity Protection (SIP).
  - **Fractional Supersampling**: Crisp typography and subpixel clarity for 2K (2560×1440) and Ultrawide (3440×1440, 5120×1440) monitors.
  - **Aspect Ratio Filtering**: Excludes incompatible aspect ratios and oversized backing buffers.
  - **System Override Generator**: Produces binary `scale-resolutions` plists for macOS display override catalogs.
- **Safety Protections**: Built-in guardrails prevent unintended override activation on built-in MacBook displays.
- **Portrait Orientation Support**: Fully compatible with vertical displays (such as 1080×1920) and includes an optional filter for low resolutions.
- **In-App Auto-Updates**: Seamless check, download, verification, and atomic replacement powered by GitHub Releases.

---

## Keyboard Shortcuts

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| `⌃⌥⌘H` | Toggle HiDPI | Quick switch between 1x and 2x Retina mode |
| `⌃⌥⌘F` | Cycle Favorites | Fast cycle between saved favorite presets |
| `Enter` | Confirm Mode | Keep the newly selected mode in the rollback prompt |
| `Esc` | Revert Mode | Immediately cancel and revert to the previous mode |

---

## Architecture & Implementation

HiDpiSwitcher is developed with modern Swift 6 paradigms:

- **Strict Concurrency**: Fully compliant with Swift 6 strict concurrency checks and Sendable domain models.
- **Low-Overhead CGS Integration**: Direct SkyLight private CGS interface via `@_silgen_name` and stack-allocated structures, eliminating heap overhead during display enumeration.
- **Four-Layer Architecture**:
  - `Sources/Domain`: Core models (`DisplayDevice`, `DisplayMode`, `ModeCatalog`), resolution matching, and version parsing.
  - `Sources/Infrastructure`: CGS display client, display reconfiguration listener, virtual display manager, hotkey handlers, and GitHub release service.
  - `Sources/Application`: Main-actor stores (`DisplayStore`, `LaunchAtLoginStore`, `UpdateStore`) coordinating user actions and state.
  - `Sources/Presentation`: Declarative SwiftUI menu bar extra, custom AppKit countdown modal dialog, and update dialogs.
- **Comprehensive Unit Testing**: Includes unit test coverage for memory layouts, mode deduplication, portrait filtering, and updater logic.

---

## Requirements

- macOS 14.0 or later (Sonoma, Sequoia, and newer)
- Apple Silicon or Intel Mac

---

## Building and Installation

### Build from Source

```bash
# Run unit tests
./build.sh test

# Build Universal Binary (.app)
./build.sh

# Install into /Applications
./build.sh install
```

---

## License

This project is distributed under the terms of the MIT License.
