# rill

A keyboard-driven, native macOS PDF viewer for writing LaTeX in Neovim: Skim's native feel with a
sioyek-style keyboard model. See [SPEC.md](SPEC.md) for the full v1 plan.

**Status:** in progress. Rendering, smooth motion, auto-reload, SyncTeX with Neovim, search,
hints, marks, the jump list, dark mode and the config file work. The file and outline pickers
are next.

## Install

Requires macOS 26+ and Xcode.

```sh
make install   # builds Rill.app into /Applications and links the `rill` CLI into ~/.local/bin
```

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

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` (hold to scroll) | Scroll down / up |
| `h` / `l`, `←` / `→` | Scroll left / right |
| `d` / `u`, `⌃d` / `⌃u` | Half screen down / up |
| `Space` / `⇧Space` | Screen down / up |
| `J` / `K` | Next / previous page |
| `gg` / `G` / `{n}G` | First / last / page n |
| `+` / `-` / `=` | Zoom in / out / 100% |
| `w` / `z` | Fit width / fit page |
| `/` / `?` | Search forward / backward (smart-case; `Enter` accepts, `Esc` returns) |
| `n` / `N` | Next / previous match |
| `Esc` | Clear search highlights |
| `f` | Follow a link (labels appear; type one) |
| `F` | Inverse search on a line: jump Neovim to its source |
| `yf` | Copy a line |
| `⌃o` / `⌃i` | Jump back / forward |
| `m{a-z}` / `'{a-z}` | Set / go to a mark (saved per document) |
| `''` | Back to where the last jump started |
| `i` | Dark mode on / off |
| `g.` | Keep the page / zoom status visible |
| `g?` | Cheatsheet of every binding (including your remaps) |
| `q` | Close the document |
| `r` | Reload |
| `g!` | Frame-rate overlay |

Counts work with motions: `5j`, `3J`, `12G`, `3n`.

## Config

`~/.config/rill/config.toml` (or `$XDG_CONFIG_HOME/rill/config.toml`). Every setting is optional,
and changes apply as soon as you save. Mistakes show up as a message in the window; a setting
with a bad value keeps its default, and a file that doesn't parse leaves the previous settings in
place.

```toml
[view]
default_zoom = "fit-width"   # "fit-page", or a number like 1.25 (for documents opened the first time)
dark_mode = "system"         # "on" | "off" | "system" (follow macOS)
page_gap = 8                 # points between pages

[synctex]
inverse_command = "nvim --headless -c \"VimtexInverseSearch %line '%file'\""   # also %column
activate_on_inverse = "com.mitchellh.ghostty"   # app to bring forward afterwards; "" for none
activate_on_forward = false                     # bring rill forward on forward search

[picker]
roots = ["~/github", "~/Papers"]   # folders the file picker searches (coming soon)

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
`close_document`, `reload`, `toggle_frame_hud`.

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
