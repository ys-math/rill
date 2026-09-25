# rill — v1 spec

A native macOS PDF viewer for editing LaTeX in Neovim: Skim's native look and feel, driven from the keyboard like sioyek.

**v1 success bar:** rill replaces Skim as the vimtex viewer for daily use. Anything that doesn't serve that goal is out of v1.

---

## 1. Stack

- **Swift 6 + AppKit.** SwiftUI only for trivial overlays, if at all.
- **PDFKit is used only for rendering** (`PDFPage.draw`, text, selection geometry). No `PDFView`.
- **Custom layer-backed document view** with a tiled, zoom-aware render cache filled on a background queue.
- **SyncTeX:** vendored official `synctex_parser.c` from TeX Live.
- **Dependencies:** none, except possibly a TOML parser (TOMLKit or a hand-rolled subset).
- **Deployment target:** the newest macOS that GitHub Actions hosted runners support, raised as they update.
- **Build:** SwiftPM + Xcode.

## 2. Neovim integration

### Forward search (Neovim → rill)

```lua
vim.g.vimtex_view_method = "general"
vim.g.vimtex_view_general_viewer = "rill"
vim.g.vimtex_view_general_options = "--forward @line:@col:@tex @pdf"
```

- The `rill` CLI connects to the running app over a **Unix domain socket** at `~/Library/Application Support/rill/rill.sock` using newline-delimited JSON. It starts the app if it isn't running.
- The app opens or focuses the PDF's window, runs the SyncTeX lookup, and scrolls there with animation. The target line gets a translucent highlight that fades out over about 800 ms.
- **Does not take focus by default** (`activate_on_forward = false`).
- The CLI gets a reply, and errors are reported with a non-zero exit code.

### Inverse search (rill → Neovim)

- Runs a configurable command template. Default:
  `nvim --headless -c "VimtexInverseSearch %line '%file'"`
- Afterwards it activates the configured terminal app (default Ghostty, `com.mitchellh.ghostty`).
- Triggered by `F` (hint mode, line granularity) or `⌘`-click.

## 3. Modes & keybindings

| Mode | Enter | Purpose |
|---|---|---|
| Normal | default / `Esc` | Motion, zoom, jumps, marks, counts |
| Hint | `f` / `F` / `yf` | Letter labels: follow link / inverse search on a line / yank a line |
| Search | `/` `?` | Incremental search, `n` / `N` |
| Picker (overlay) | `o` / `t` | File picker / outline (TOC) picker |

All motions accept a count. All bindings can be remapped in the config.

**Scrolling and pages**

| Key | Action |
|---|---|
| `j` / `k` | Smooth scroll down/up (~1/10 viewport); continuous velocity scroll while held |
| `h` / `l` | Scroll left/right |
| `d` / `u`, `⌃d` / `⌃u` | Half page down/up |
| `Space` / `⇧Space` | Full screen down/up |
| `J` / `K` | Next/previous page (snap to page top) |
| `gg` / `G` / `{n}G` | First / last / page n |

**Zoom and layout**

| Key | Action |
|---|---|
| `+` / `-` / `=` | Zoom in / out / reset to 100% |
| `w` / `z` | Fit width / fit page |
| `s` | Toggle continuous ↔ single page |
| `i` | Toggle dark recolor |

**Jumps and other**

| Key | Action |
|---|---|
| `⌃o` / `⌃i` | Jump list back/forward (links, forward search, `G`, search, marks) |
| `m{a-z}` / `'{a-z}` | Set / go to mark (per document, persisted) |
| `f` / `F` / `yf` | Hint: follow link / inverse search / yank line |
| `/` `?` `n` `N` | Search |
| `o` / `t` / `⌘⇧O` | File picker / outline picker / system open panel |
| `r` | Force reload |
| `q` | Close document |
| `g?` | Keybinding cheatsheet overlay |
| `g.` | Pin status pill |
| `g!` | fps / frame-time HUD |

## 4. Opening files

- **Picker (`o`):** Spotlight/Raycast-style floating fuzzy picker.
  - Recent files are listed first.
  - Then PDFs under the **configured roots only**, found with `mdfind` restricted to those roots (`-onlyin`).
  - Each row shows the file name and a shortened path, plus a first-page thumbnail if it's cheap.
- **Outline picker (`t`):** fuzzy search over the PDF outline (hyperref bookmarks), then jump to the chosen entry. Reuses the picker UI.
- **CLI:** `rill file.pdf`.
- **`⌘⇧O`:** system open panel as a fallback.
- `o` opens in the current window if it's empty, otherwise in a new window.

## 5. Config

`~/.config/rill/config.toml`, live-reloaded. On a parse error rill shows a toast and keeps the last good config. No preferences GUI.

```toml
[picker]
roots = ["~/github", "~/Papers"]

[synctex]
inverse_command = "nvim --headless -c \"VimtexInverseSearch %line '%file'\""
activate_on_inverse = "com.mitchellh.ghostty"
activate_on_forward = false

[view]
default_zoom = "fit-width"   # "fit-page" | number, e.g. 1.25
dark_mode = "system"         # "on" | "off" | "system"
page_gap = 8

[keys]
"J" = "page_next"
"<C-d>" = "half_page_down"
```

## 6. Auto-reload

1. **Detect:** watch the file with FSEvents / `DispatchSource`, which also handles atomic rename-replace.
2. **Check completeness:** debounce about 50 ms, then require that the file ends with `%%EOF` **and** that `PDFDocument` opens it. On failure, retry with backoff for up to 2 s while the old version stays on screen. Never show a blank or error screen mid-compile.
3. **Swap:** render the new document's visible tiles offscreen, then swap in a single frame (no flicker).
4. **Preserve:** page index + fractional offset within the page, zoom, dark mode, marks, jump list.

## 7. "Smooth": concrete targets

**Frame rate**
- 120 fps on ProMotion displays (60 elsewhere), with no dropped frames during scroll, zoom, or jumps on a 300-page document.
- No blank tiles: a scaled low-res tile is shown until the sharp tile is ready, then the sharp one fades in over about 100 ms.

**Motion**
- `j`/`k` held: continuous velocity scroll that starts immediately, with no stepping from key repeat. About 80 ms of easing at the start and on release.
- Discrete jumps: critically damped spring, 180–220 ms.
- Jumps longer than about 3 screens: short crossfade plus a small slide instead of scrolling the whole distance.
- Zoom: animated over about 150 ms. Keys anchor at the viewport center, pinch anchors at the cursor.
- Trackpad: native momentum and rubber-banding, matching Preview.
- **Reduce Motion** makes jumps instant or crossfaded.

**Latency**

| Path | Target |
|---|---|
| Keypress → first moving frame | ≤ 8 ms (< 1 frame) |
| Forward search → target visible + highlight (doc open) | < 100 ms |
| Cold launch → first page visible | < 300 ms |
| PDF written → updated view visible | < 150 ms |

## 8. "Minimal": what's on screen

- Hidden title bar with full-size content. Traffic lights appear on hover near the top-left. The window can be dragged from the top strip.
- No toolbar, no sidebar, only overlay scrollers.
- Neutral gray background (near-black in dark mode). Pages are centered with a soft shadow and an 8 pt gap.
- **Transient overlays** in one shared style (SF Mono, rounded, vibrancy, about 120 ms fades):
  - Status pill at the bottom right, `12 / 148 · 125%`, visible for about 1.5 s after a change. `g.` pins it.
  - Mode indicator outside Normal mode (`HINT`, `/query 3/17`).
  - Echo of pending keys and counts.
  - Toasts for errors.
- **Dark mode:** a smart "dark paper" recolor (white → dark gray, black → light gray, hue preserved) applied to tiles through Core Image / Metal, not a plain invert. Follows the system setting by default.
- **Windows:** one document per window, with native macOS tabs allowed.
- **Persistence:** last position, zoom, and marks are saved per document across launches.

## 9. Scope

**v1:** everything above.

**v1.1**
- Visual mode (keyboard text selection)
- Changed-region marker after reload
- `⌃^` alternate file
- Link / reference preview popovers

**Later**
- Two-page spread and presentation mode
- `reload_anchor = "synctex"` (keep position by source line instead of by page)

**Never**
- Annotations and highlights

## 10. Repo & distribution

- Public GitHub repo `rill`, MIT license.
- GitHub Actions builds and runs unit tests on every push and PR. Tests cover the SyncTeX bridge, the key-sequence parser, config loading, and reload-completeness detection.
- `make install` copies `Rill.app` to `/Applications` and symlinks the `rill` CLI.
- No releases for v1.
- Naming note: Rill Data also ships a `rill` CLI. The name is kept regardless.

## 11. Milestones

1. **Skeleton.** SwiftPM/Xcode project, app plus CLI targets, CI, `make install`.
2. **Renderer + smooth motion.** Tiled cache, low-res fallback, continuous layout, `j/k/d/u/J/K/gg/G`, zoom and fit modes, springs, trackpad, fps HUD. *This is the core risk, so it comes first.*
3. **Auto-reload.** Watcher, completeness check, flicker-free swap, position preservation, per-document persistence.
4. **SyncTeX + socket.** Vendored parser, `rill --forward`, highlight, inverse-search command, Ghostty activation. *At this point rill can replace Skim for basic use.*
5. **Modes.** Key-sequence engine with counts and remapping, hint mode (`f`/`F`/`yf`), search, marks, jump list.
6. **Overlays and config.** Status pill, toasts, `g?`, TOML config with live reload, dark recolor.
7. **Pickers.** File picker (recent + `mdfind` roots), outline picker, window and tab behavior.
