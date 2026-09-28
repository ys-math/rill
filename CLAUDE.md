# Rill

## Commands

- `make test` — run the test suite
- `make install` — build Rill.app, install it to /Applications, and link the `rill` CLI into ~/.local/bin

## After changing code

Whenever you change code under `Sources/`:

1. Run `make test`.
2. If tests pass, run `make install` so the installed Rill matches the working tree.
   If tests fail, do not install — report the failures and leave the installed app alone.
3. Don't quit or relaunch a running Rill. Tell the user to relaunch it to pick up the new build.

## Releasing

Use the `release` skill (`.claude/skills/release/SKILL.md`). Releases go only through
`scripts/release.sh`; `.claude/hooks/guard-release.sh` blocks hand-made tags, tag pushes,
pushes to main, and GitHub release edits. After changing the hook, run
`.claude/hooks/guard-release.test.sh`.
