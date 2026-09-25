# rill

A keyboard-driven, native macOS PDF viewer for writing LaTeX in Neovim: Skim's native feel with a
sioyek-style keyboard model. See [SPEC.md](SPEC.md) for the full v1 plan.

**Status:** in progress. Rendering, smooth motion, auto-reload, and SyncTeX with Neovim work.
Hint mode, search, marks, config file, and pickers are next.

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
| `j` / `k` (hold to scroll) | Scroll down / up |
| `h` / `l` | Scroll left / right |
| `d` / `u`, `⌃d` / `⌃u` | Half screen down / up |
| `Space` / `⇧Space` | Screen down / up |
| `J` / `K` | Next / previous page |
| `gg` / `G` / `{n}G` | First / last / page n |
| `+` / `-` / `=` | Zoom in / out / 100% |
| `w` / `z` | Fit width / fit page |
| `r` | Reload |
| `g!` | Frame-rate overlay |

Counts work with motions: `5j`, `3J`, `12G`.

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
