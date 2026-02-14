# SSD Cleanup for macOS

A lightweight macOS app that scans your SSD for leftover files, stale data, and reclaimable space — then presents an interactive HTML report in your browser.

![macOS](https://img.shields.io/badge/macOS-Apple_Silicon_%26_Intel-000?logo=apple)
![No Dependencies](https://img.shields.io/badge/dependencies-none-green)
![Shell](https://img.shields.io/badge/built_with-zsh-blue)

## What it does

Double-click the app. It will:

1. **Index every installed app** on your system via Spotlight (`mdfind`), bundle IDs, and running processes
2. **Scan** `~/Library/Application Support`, `Caches`, `Containers`, `Group Containers`, `Saved Application State`, `Logs`, `Preferences`, `~/Downloads`, dotfiles, `/usr/local`, and home-level directories
3. **Cross-reference** each found directory against the installed app index — no hardcoded app lists
4. **Generate** an interactive HTML report and open it in your default browser

## What it finds

| Category | Description |
|---|---|
| **Leftover** | Data from apps that are no longer installed |
| **Cache** | Clearable caches from installed apps and dev tools (npm, pip, Homebrew, Go, Yarn) |
| **Stale** | Files and directories untouched for 1+ year |
| **Large Files** | Files over 50 MB in Downloads, large home directories |

It also estimates reclaimable space from `brew cleanup`.

## The report

- Filter by category (Leftover / Stale / Cache / Large)
- Search by name, path, or app
- Sort by size or date
- Select items and copy `rm` commands or file paths to clipboard
- Disk usage bar with live stats

## Install

No build step. Just copy `SSD-Cleanup.app` to `/Applications` or keep it on your Desktop.

```
git clone https://github.com/YOUR_USERNAME/ssd-cleanup-macos.git
cp -r ssd-cleanup-macos/SSD-Cleanup.app ~/Desktop/
```

On first launch, macOS may block it. Go to **System Settings > Privacy & Security** and click **Open Anyway**, or run:

```
xattr -cr ~/Desktop/SSD-Cleanup.app
```

## How it works

The entire app is a single zsh script (`Contents/MacOS/scan`) that:

- Builds an installed-app index using `mdfind`, `PlistBuddy`, and `ps`
- Walks Library subdirectories and matches each against the index
- Computes sizes with `du` and modification dates with `stat`
- Emits JSON and injects it into a self-contained HTML template
- Opens the result with `open`

No dependencies. No background processes. Nothing is deleted — it only reads and reports.

## Requirements

- macOS 12+ (Monterey or later)
- Spotlight enabled (used for app discovery)

## License

MIT
