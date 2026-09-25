# Vendored: SyncTeX parser

- Source: https://github.com/jlaurens/synctex (the official SyncTeX repository, also used by TeX Live)
- Commit: `04cf8e3e8665ff203248d7af78ee1129afbc1b64`
- License: MIT (see `LICENSE`)
- Files: `synctex_parser.c`, `synctex_parser_utils.{c,h}`, `synctex_parser_advanced.h`,
  `include/synctex_parser.h`, `include/synctex_version.h`, unmodified except that the two public
  headers were moved into `include/` for SwiftPM.

To update, replace these files from a newer commit and update the hash above.
