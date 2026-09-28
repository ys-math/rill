#!/usr/bin/env bash
# Cut a rill release. See .claude/skills/release/SKILL.md for the whole flow.
#
#   scripts/release.sh prepare X.Y.Z   branch, bump versions, commit notes, open the release PR
#   scripts/release.sh check   X.Y.Z   run every preflight check on main; changes nothing
#   scripts/release.sh publish X.Y.Z   check, then create the tag and GitHub release in one step
#
# Releases are source-only: the tag and the release notes are all that get published.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PLIST=Resources/Info.plist
VERSION_SWIFT=Sources/RillCore/Rill.swift

die()  { printf '\n✗ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -eq 2 ] || usage
CMD=$1
VERSION=$2
TAG="v$VERSION"
NOTES="release-notes/$TAG.md"

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like X.Y.Z, got '$VERSION'"

# 0 if $1 > $2 as dotted X.Y.Z versions.
version_gt() {
    local IFS=.
    local a=($1) b=($2) i
    for i in 0 1 2; do
        (( 10#${a[i]} > 10#${b[i]} )) && return 0
        (( 10#${a[i]} < 10#${b[i]} )) && return 1
    done
    return 1
}

latest_tag() {
    git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | while read -r v; do
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$v"
    done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
swift_version() { sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$VERSION_SWIFT"; }

# --- checks shared by prepare and publish -------------------------------------------------

check_on_synced_main() {
    step "On main, in sync with origin"
    git fetch --quiet --tags origin
    [ "$(git symbolic-ref --quiet --short HEAD || true)" = main ] || die "not on main"
    local head origin
    head=$(git rev-parse HEAD)
    origin=$(git rev-parse origin/main)
    [ "$head" = "$origin" ] || die "HEAD ($head) differs from origin/main ($origin); pull or push first"
    ok "main = origin/main = ${head:0:12}"
}

# Prints `git status` lines that block a release: any change to tracked files, and untracked
# files that could feed the build. $1 is a path allowed to be untracked, or empty.
blocking_changes() {
    local allowed=$1 line path
    git status --porcelain --untracked-files=all | while IFS= read -r line; do
        path=${line:3}
        if [ "${line:0:3}" != '?? ' ]; then
            echo "$line"
        elif [ "$path" != "$allowed" ]; then
            case $path in
                Sources/*|Tests/*|Resources/*|Package.swift|Makefile) echo "$line" ;;
            esac
        fi
    done
}

check_clean_tree() {
    step "Working tree is clean"
    local dirty
    dirty=$(blocking_changes "${1:-}")
    [ -z "$dirty" ] || die "uncommitted or untracked build inputs:
$dirty"
    ok "no local changes, no untracked build inputs"
}

check_tag_is_new() {
    step "Tag $TAG is new"
    git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists locally"
    [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || die "$TAG already exists on origin"
    local latest
    latest=$(latest_tag)
    if [ -n "$latest" ]; then
        version_gt "$VERSION" "$latest" || die "$VERSION is not newer than the latest tag v$latest"
        ok "not taken; newer than v$latest"
    else
        ok "not taken; first tag"
    fi
}

check_notes() {
    step "Release notes $NOTES"
    [ -s "$NOTES" ] || die "$NOTES is missing or empty; write it first"
    grep -q "git checkout $TAG\$" "$NOTES" || die "$NOTES has no 'git checkout $TAG' line in its install steps"
    if grep -Eo 'git checkout v[0-9]+\.[0-9]+\.[0-9]+' "$NOTES" | grep -vq "git checkout $TAG\$"; then
        die "$NOTES checks out a different tag somewhere"
    fi
    ok "present, install steps check out $TAG"
}

# --- publish-only checks ------------------------------------------------------------------

check_versions_agree() {
    step "Versions agree with $TAG"
    local short swift
    short=$(plist_get CFBundleShortVersionString)
    swift=$(swift_version)
    [ "$short" = "$VERSION" ] || die "$PLIST CFBundleShortVersionString is $short, not $VERSION"
    [ "$swift" = "$VERSION" ] || die "$VERSION_SWIFT Rill.version is $swift, not $VERSION"
    ok "Info.plist $short (build $(plist_get CFBundleVersion)), Rill.version $swift"
}

check_ci_green() {
    step "CI is green on ${SHA:0:12}"
    local runs
    runs=$(gh run list --commit "$SHA" --workflow ci.yml --json status,conclusion,event,url)
    [ "$(jq length <<<"$runs")" -gt 0 ] || die "no CI run found for $SHA yet"
    jq -e 'all(.status == "completed")' <<<"$runs" >/dev/null \
        || die "CI is still running on $SHA; wait for it: $(jq -r '.[0].url' <<<"$runs")"
    jq -e 'all(.conclusion == "success")' <<<"$runs" >/dev/null \
        || die "CI did not pass on $SHA: $(jq -r '[.[] | select(.conclusion != "success") | .url] | join(" ")' <<<"$runs")"
    ok "$(jq length <<<"$runs") run(s), all successful"
}

check_fresh_clone_builds() {
    step "A fresh clone of ${SHA:0:12} tests and builds"
    CLONE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rill-release.XXXXXX")
    trap 'rm -rf "$CLONE_DIR"' EXIT
    local dir=$CLONE_DIR
    git clone --quiet --no-local "$PWD" "$dir/rill"
    git -C "$dir/rill" checkout --quiet --detach "$SHA"
    local log="$dir/build.log"
    ( cd "$dir/rill" && swift test && make app ) >"$log" 2>&1 \
        || { tail -40 "$log" >&2; die "fresh clone failed to test or build (log tail above)"; }
    ok "swift test and make app pass"
}

run_checks() {
    check_on_synced_main
    SHA=$(git rev-parse HEAD)
    check_clean_tree ""
    check_tag_is_new
    check_versions_agree
    check_notes
    check_ci_green
    check_fresh_clone_builds
    printf '\nAll checks passed for %s at %s.\n' "$TAG" "$SHA"
}

# --- commands -----------------------------------------------------------------------------

prepare() {
    check_on_synced_main
    check_clean_tree "$NOTES"
    check_tag_is_new
    check_notes

    local branch="release/$TAG"
    git rev-parse --quiet --verify "refs/heads/$branch" >/dev/null && die "branch $branch already exists"

    step "Bumping versions on $branch"
    git switch --quiet -c "$branch"
    local build
    build=$(( $(plist_get CFBundleVersion) + 1 ))
    # Edit the values in place; PlistBuddy would re-sort every key in the file.
    perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\\s*<string>)[^<]*|\${1}$VERSION|; s|(<key>CFBundleVersion</key>\\s*<string>)[^<]*|\${1}$build|" "$PLIST"
    sed -i '' "s/\(static let version = \)\".*\"/\1\"$VERSION\"/" "$VERSION_SWIFT"
    [ "$(plist_get CFBundleShortVersionString)" = "$VERSION" ] && [ "$(plist_get CFBundleVersion)" = "$build" ] \
        || die "failed to set the versions in $PLIST"
    [ "$(swift_version)" = "$VERSION" ] || die "failed to set Rill.version in $VERSION_SWIFT"
    ok "Info.plist $VERSION (build $build), Rill.version $VERSION"

    step "Committing and opening the PR"
    git add "$PLIST" "$VERSION_SWIFT" "$NOTES"
    git commit --quiet -m "Release $TAG

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    git push --quiet -u origin "$branch"
    gh pr create --base main --head "$branch" --title "Release $TAG" --body "Bumps the version to $VERSION and adds the release notes, which \`scripts/release.sh publish $VERSION\` will publish verbatim once this is merged.

Review [\`$NOTES\`]($NOTES) before merging.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
}

publish() {
    run_checks

    step "Publishing $TAG"
    gh release create "$TAG" --target "$SHA" --title "rill $TAG" --notes-file "$NOTES" >/dev/null

    git fetch --quiet --tags origin
    local tagged
    tagged=$(git rev-parse "refs/tags/$TAG^{commit}")
    [ "$tagged" = "$SHA" ] || die "$TAG points at $tagged, expected $SHA; investigate before announcing"
    ok "$TAG -> ${SHA:0:12}"
    printf '\nReleased: %s\n' "$(gh release view "$TAG" --json url -q .url)"
}

case $CMD in
    prepare) prepare ;;
    check)   run_checks ;;
    publish) publish ;;
    *)       usage ;;
esac
