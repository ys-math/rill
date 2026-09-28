#!/usr/bin/env bash
# PreToolUse hook for Bash: keep Claude on the release path in scripts/release.sh.
#
# Blocks commands Claude types that would create or push tags, touch GitHub releases, or push
# to main. The script's own git/gh calls never pass through here, so the release flow itself
# is unaffected. Read-only commands (git tag -l, gh release list/view) are allowed. A person
# who really needs one of these can run it with `!` in the prompt, which skips hooks.
#
# This is a guard against shortcuts, not a security boundary.
set -uo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")

block() {
    printf 'Blocked by .claude/hooks/guard-release.sh: %s\nReleases go through the release skill (.claude/skills/release/SKILL.md) and scripts/release.sh. If this really must run by hand, ask the user to run it with `!`.\n' "$1" >&2
    exit 2
}

has() { grep -Eq -- "$1" <<<"$cmd"; }

GIT='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+'
REST='([^;&|]*)' # the rest of one simple command

# scripts/release.sh publish must be typed in its canonical form, so the permission prompt
# in .claude/settings.json always catches it.
if has 'release\.sh["'\'']?[[:space:]]+publish'; then
    grep -Eq '^[[:space:]]*(\./)?scripts/release\.sh publish [0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' <<<"$cmd" \
        || block "run the publish step exactly as 'scripts/release.sh publish X.Y.Z', on its own"
fi

# Creating, deleting or moving tags. Listing (no args, -l/--list, --contains, ...) is fine.
if has "${GIT}tag[[:space:]]+(-[a-zA-Z]*[adfsmuF]|--(annotate|delete|force|sign|local-user|message|file|create-reflog)|[^-[:space:];&|])"; then
    block "creating or deleting tags"
fi

# Pushing tags, tag refs, or version-looking refs.
if has "${GIT}push${REST}([[:space:]]--(tags|follow-tags|mirror)|refs/tags|[[:space:]:+]v[0-9]+(\.[0-9]+)*([[:space:]:]|\$))"; then
    block "pushing tags"
fi

# Pushing to main, explicitly or as a bare push from main.
if has "${GIT}push${REST}[[:space:]:+](refs/heads/)?main([[:space:]]|\$)"; then
    block "pushing to main"
fi
if has "${GIT}push([[:space:]]+(-[^[:space:]]+|origin))*[[:space:]]*(\$|[;&|])"; then
    branch=$(git -C "${cwd:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$branch" = main ] && block "pushing to main"
fi

# Mutating GitHub releases, via gh release or the raw API.
if has 'gh[[:space:]]+release[[:space:]]+(create|edit|delete|delete-asset|upload)'; then
    block "creating or changing a GitHub release"
fi
if has 'gh[[:space:]]+api' && has '(releases|git/refs|git/tags)' \
    && has '(-X|--method)[[:space:]]*(POST|PATCH|PUT|DELETE)|[[:space:]]-(f|F)[[:space:]]|--(field|raw-field|input)'; then
    block "changing releases or refs through the GitHub API"
fi

exit 0
