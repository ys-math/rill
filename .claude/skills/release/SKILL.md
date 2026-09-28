---
name: release
description: Cut and publish a rill release (version bump, release notes, tag, GitHub release). Use when the user asks to release, publish, tag, or ship a new version of rill.
---

# Releasing rill

Releases are source-only: a `vX.Y.Z` tag plus a GitHub release whose notes tell people to
build that tag. Everything goes through `scripts/release.sh`; never tag, push tags, or touch
GitHub releases by hand. `.claude/hooks/guard-release.sh` blocks those commands, and
`scripts/release.sh publish` always needs the user's approval at a permission prompt.

## 1. Propose the version, and wait

Read `git log --oneline $(git tag -l 'v*' --sort=-v:refname | head -1)..origin/main` and
the merged PRs. Propose a version with one line of reasoning:

- patch (`0.1.1 → 0.1.2`): fixes only
- minor (`0.1.1 → 0.2.0`): any new user-visible feature, key, or config option
- major: only if the user asks

Wait for the user to confirm the number before going on.

## 2. Draft the release notes

On an up-to-date, clean `main`, write `release-notes/vX.Y.Z.md` in the format of the
earlier releases (`gh release view v0.1.1`):

1. A short paragraph on what changed since the last release, citing PR numbers.
2. `## Features`: the full, current feature list, one bolded category per bullet. Start
   from the previous release's list and fold in what's new; don't just list the delta.
3. `## Install`: the source-build steps, whose `git checkout` line names this tag, and the
   README link.
4. The `🤖 Generated with [Claude Code](https://claude.com/claude-code)` line.

Show the user the draft.

## 3. Prepare the release PR

```sh
scripts/release.sh prepare X.Y.Z
```

This checks that `main` is synced and clean, that the tag is new and higher than the last
one, and that the notes check out the right tag. It then branches `release/vX.Y.Z`, sets
`CFBundleShortVersionString` and `Rill.version` to `X.Y.Z`, raises `CFBundleVersion` by 1,
commits these with the notes, and opens a PR. Give the user the PR link, and tell them to
review the notes there and merge it themselves. Don't merge it for them.

## 4. Publish, after the user has merged

```sh
git switch main && git pull --ff-only
scripts/release.sh publish X.Y.Z
```

Type the publish command exactly like this, on its own. The hook rejects any other form,
because the permission prompt only matches this one. `publish` runs every check:

1. On `main`, same commit as `origin/main`
2. No local changes, and no untracked files under `Sources/`, `Tests/`, `Resources/`
3. The tag is new locally and on origin, and higher than the latest tag
4. `Info.plist` and `Rill.version` both say `X.Y.Z`
5. The notes file exists and checks out `vX.Y.Z`
6. CI (`ci.yml`) finished green on this exact commit
7. A fresh clone of the commit passes `swift test` and `make app`

Then it runs one `gh release create --target <sha>`, which creates the tag and the release
together, and verifies that the tag points at the checked commit. Run
`scripts/release.sh check X.Y.Z` first when you want the checks alone.

## When something fails

- **A check fails:** stop and report the check and its message. Fix the cause through a
  normal PR, never by editing files on `main`, then run `publish` again. If CI is still
  running, wait for it and retry.
- **`publish` fails after `gh release create`:** the tag may exist on GitHub. Don't try to
  repair it yourself; the hook blocks deleting tags and releases anyway. Report what
  `gh release view vX.Y.Z` and `git ls-remote --tags origin` show, and let the user decide.
- **A published release turns out broken:** don't delete it. Propose a patch release, and
  suggest the user add a warning to the broken one (as v0.1.0 has), which they run with `!`.
