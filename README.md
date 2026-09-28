# rill

A keyboard-driven, native macOS PDF viewer for writing LaTeX in Neovim: Skim's native feel with a
sioyek-style keyboard model. See [SPEC.md](SPEC.md) for the full v1 plan.

**Status:** the v1 feature set is in: rendering, smooth motion, auto-reload, SyncTeX with
Neovim, search, hints, marks, the jump list, dark mode, the config file, and the file and outline
pickers.

## Install

### Requirements

- macOS 26 or later
- Xcode 26 or later

rill is built from source; there's no prebuilt download.

### Build and install

```sh
git clone https://github.com/ys-math/rill.git
cd rill
make install
```

This puts:

- `Rill.app` in `/Applications` (ad-hoc signed and registered with Launch Services), and
- `~/.local/bin/rill`, a symlink to the CLI inside the app, so the CLI always matches the
  installed app.

### Add rill to your PATH

If `~/.local/bin` isn't on your `PATH` yet, add this to `~/.zshrc` and open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

vimtex runs `rill` by name, so forward search needs it on the `PATH` Neovim sees.

### Check it works

```sh
rill path/to/some.pdf
```

Rill starts (if it isn't running) and opens the PDF.

### Update

```sh
git pull
make install
```

Then quit and relaunch Rill to pick up the new build.

### Custom locations

```sh
make install APPS_DIR=~/Applications BIN_DIR=~/bin
```

Pass the same variables to `make uninstall`.

### Uninstall

```sh
make uninstall
```

This removes `Rill.app` and the `rill` symlink. Your config (`~/.config/rill/`) and rill's
support folder (`~/Library/Application Support/rill/`) stay; delete them by hand for a full
cleanup.

## Use with vimtex

```lua
vim.g.vimtex_view_method = "general"
vim.g.vimtex_view_general_viewer = "rill"
vim.g.vimtex_view_general_options = "--forward @line:@col:@tex @pdf"
```

- **Forward search** (`\lv`, or `:VimtexView`): rill opens the PDF if needed, scrolls to the line
  only if it isn't already on screen, and briefly highlights it. rill stays in the background; add
  `--activate` to the options to bring it forward.
- **Inverse search:** `⌘`-click a line in the PDF. rill runs
  `nvim --headless -c "VimtexInverseSearch %line '%file'"`, which jumps every Neovim editing that
  file to the line, then brings Ghostty to the front.
- **Auto-reload:** rill watches the PDF and shows each new build in place, at the same position.

Compile with SyncTeX enabled (vimtex's latexmk defaults already pass `-synctex=1`).

## Keys

### Scroll

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` (hold to scroll) | Scroll down / up |
| `h` / `l`, `←` / `→` | Scroll left / right |
| `d` / `u`, `⌃d` / `⌃u` | Half screen down / up |
| `Space` / `⇧Space` | Screen down / up |

### Jump

| Key | Action |
|---|---|
| `J` / `K` | Next / previous page |
| `gg` / `G` / `{n}G` | First / last / page n |
| `⌃o` / `⌃i` | Jump back / forward |
| `m{a-z}` / `'{a-z}` | Set / go to a mark (saved per document) |
| `''` | Back to where the last jump started |
| `t` | Go to a section (the PDF's outline) |

### Zoom & view

| Key | Action |
|---|---|
| `+` / `-` / `=` | Zoom in / out / 100% |
| `w` / `z` | Fit width / fit page |
| `s` | One page at a time ↔ continuous (at a page's edge, `j`/`Space` turn the page) |
| `S` | Two-page spread: pairs (1–2, 3–4, …) → book style (1, 2–3, …) → one page per row |
| `c` | Trim the white margins (measured per document; odd and even pages trimmed separately) |
| `i` | Dark mode on / off |
| `g.` | Keep the page / zoom status visible |

### Search

| Key | Action |
|---|---|
| `/` / `?` | Search forward / backward (smart-case; `Enter` accepts, `Esc` returns) |
| `n` / `N` | Next / previous match |
| `Esc` | Clear search highlights |

### Hints

| Key | Action |
|---|---|
| `f` | Follow a link (labels appear; type one) |
| `F` | Inverse search on a line: jump Neovim to its source |
| `yf` | Copy a line |
| `p` | Preview a link's target (theorem, equation, citation) without leaving your place; `Enter` follows it |
| `v` / `V` | Visual mode: pick a line, then select with `h l w b e j k 0 $` (counts work), `o` swaps ends, `y` copies, `Esc` cancels. `V` selects whole lines |

### Other

| Key | Action |
|---|---|
| `o` / `⌘O` | Open a PDF: recent files, then PDFs under `[picker] roots` |
| `⌘⇧O` | Open with the standard macOS panel |
| `Tab` / `⇧Tab`, `⌃⌘→` / `⌃⌘←` | Next / previous tab |
| `⌃⌘⇧←` / `⌃⌘⇧→` | Move the current tab left / right |
| `⌃^` / `⌃6` | Previous PDF: its window if open, otherwise it replaces this one (press again to toggle back) |
| `g?` | Cheatsheet of every binding (including your remaps) |
| `g,` / `⌘,` | Edit the config (changes apply when you save) |
| `q` | Close the document |
| `r` | Reload |
| `g!` | Frame-rate overlay |

Counts work with motions: `5j`, `3J`, `12G`, `3n`.

With the mouse: click a link to follow it, rest the pointer on one to preview it, `⌘`-click text
for inverse search. After a recompile, a brief bar in the left margin marks what changed on screen
(new or edited lines; text that only moved isn't marked).

## Config

`~/.config/rill/config.toml` (or `$XDG_CONFIG_HOME/rill/config.toml`). `g,` or `⌘,` opens it with
`[config] edit_command`, or without one in the app your Mac uses for `.toml` files (or your default
text editor), creating a commented starter file if there's none yet. Every setting is optional, and changes apply as soon as you save. Mistakes show up as a message in the window; a setting
with a bad value keeps its default, and a file that doesn't parse leaves the previous settings in
place.

```toml
[config]
edit_command = "open -na Ghostty --args -e nvim %file"   # how g, / ⌘, open this file; %file is quoted for you

[view]
default_zoom = "fit-width"   # "fit-page", or a number like 1.25 (for documents opened the first time)
dark_mode = "system"         # "on" | "off" | "system" (follow macOS)
page_gap = 8                 # points between pages
change_markers = true        # mark changed lines in the margin after a recompile
spread = "off"               # "pairs" (1–2, 3–4, …) | "book" (1, 2–3, …): two pages per row
trim = false                 # cut away the white margins around the text
rounded_corners = false      # true (6) | a radius in page points: round the corners of the pages
scroll_step = 0.1            # j/k/h/l: fraction of the window to scroll (0.01–1)
zoom_step = 1.25             # +/-: zoom multiplier (1.01–4)
dark_paper = "#242424"       # page colour in dark mode ("#rrggbb")
dark_ink = "#dbdbdb"         # text colour in dark mode ("#rrggbb")
background = "solid"         # "blur" (the desktop, blurred) | "glass" (Liquid Glass): around the pages
glass_style = "regular"      # "clear": a more see-through glass background
glass_tint = "#00000026"     # tint the glass background toward a colour ("#rrggbb" or "#rrggbbaa"); unset by default
overlays = "blur"            # "glass": Liquid Glass for the search bar, status, toasts, picker, cheatsheet

[synctex]
inverse_command = "nvim --headless -c \"VimtexInverseSearch %line '%file'\""   # also %column
activate_on_inverse = "com.mitchellh.ghostty"   # app to bring forward afterwards; "" for none
activate_on_forward = false                     # bring rill forward on forward search

[picker]
roots = ["~/github", "~/Papers"]   # folders the file picker searches (with Spotlight)

[keys]
# key sequence = action name, as listed by g? ("nop" removes a default binding)
"<S-Down>" = "page_next"
"<S-Up>" = "page_prev"
"<C-f>" = "screen_down"
"J" = "nop"
```

Key notation follows Vim: `<C-d>` (control), `<M-x>` (option), `<S-Space>` (shift), `<Down>`,
`<Esc>`, and plain characters for everything else. Action names: `scroll_down`, `scroll_up`,
`scroll_left`, `scroll_right`, `half_page_down`, `half_page_up`, `screen_down`, `screen_up`,
`page_next`, `page_prev`, `first_page`, `goto_page`, `zoom_in`, `zoom_out`, `zoom_reset`,
`fit_width`, `fit_page`, `jump_back`, `jump_forward`, `set_mark`, `goto_mark`, `search_forward`,
`search_backward`, `search_next`, `search_previous`, `clear_highlights`, `hint_follow_link`,
`hint_inverse_search`, `hint_yank_line`, `toggle_dark_mode`, `toggle_status`, `show_cheatsheet`,
`close_document`, `open_file`, `show_outline`, `toggle_single_page`, `alternate_file`, `next_tab`, `previous_tab`,
`hint_preview_link`, `visual_mode`, `visual_line_mode`, `toggle_spread`, `toggle_trim`, `reload`,
`toggle_frame_hud`, `edit_config`.

In the pickers, type to filter (fuzzy, smart-case), `↑`/`↓` or `⌃p`/`⌃n` to move, `Enter` to
open, `Esc` to close. PDFs with the same name are shown with the folders that tell them apart
(`homological_algebra/main.pdf`), so typing a folder name finds them; window and tab titles use
the same names. To open by path, type one: `~/`, `/`, `./` or `../` (relative to the current PDF)
lists that folder's sub-folders and PDFs; `Tab` completes, `Enter` enters a folder or opens a PDF.
Launching rill from the Dock or Spotlight with nothing open shows the
file picker.

## CLI

```
rill FILE.pdf
rill [--activate] --forward LINE:COL:TEX FILE.pdf
```

The CLI talks to the app over `~/Library/Application Support/rill/rill.sock`, starting it in the
background if needed.

## Development

```sh
swift test         # unit tests
make app           # build/Rill.app
make install
```

Diagnostics: `log stream --level debug --predicate 'subsystem == "io.github.ys-math.rill"'`
(categories `reload` and `synctex`).

## License

MIT. The vendored SyncTeX parser (`Sources/CSynctex`) is MIT-licensed by Jérôme Laurens.
