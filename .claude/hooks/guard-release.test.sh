#!/usr/bin/env bash
# Table test for guard-release.sh. Run: .claude/hooks/guard-release.test.sh
set -uo pipefail
cd "$(dirname "$0")"

fail=0
expect() { # expect block|allow <command> [cwd]
    local want=$1 cmd=$2 cwd=${3:-/}
    jq -n --arg c "$cmd" --arg d "$cwd" '{tool_input: {command: $c}, cwd: $d}' | ./guard-release.sh 2>/dev/null
    local rc=$? got=allow
    [ $rc -eq 2 ] && got=block
    if [ "$got" != "$want" ]; then echo "FAIL: want $want, got $got: $cmd"; fail=1; fi
}

main_repo=$(mktemp -d); git -C "$main_repo" init -q -b main
feature_repo=$(mktemp -d); git -C "$feature_repo" init -q -b feature
trap 'rm -rf "$main_repo" "$feature_repo"' EXIT

expect block 'git tag v0.1.2'
expect block 'git tag -a v0.1.2 -m "rill v0.1.2"'
expect block 'git tag -d v0.1.1'
expect block 'git tag -f v0.1.1 HEAD'
expect block 'git -C ../rill tag v1.0.0'
expect block 'cd x && git tag v1.0.0'
expect block 'git push --tags'
expect block 'git push origin --follow-tags'
expect block 'git push origin v0.1.2'
expect block 'git push origin refs/tags/v0.1.2'
expect block 'git push origin :v0.1.1'
expect block 'git push --delete origin v0.1.1'
expect block 'git push origin main'
expect block 'git push origin HEAD:main'
expect block 'git push -f origin feature:main'
expect block 'git push' "$main_repo"
expect block 'git push -u origin' "$main_repo"
expect block 'gh release create v0.1.2 --notes x'
expect block 'gh release edit v0.1.1 --draft'
expect block 'gh release delete v0.1.1 -y'
expect block 'gh release upload v0.1.1 Rill.zip'
expect block 'gh api repos/ys-math/rill/releases -X POST -f tag_name=v1'
expect block 'gh api -X DELETE repos/ys-math/rill/git/refs/tags/v0.1.1'
expect block 'bash -c "gh release create v1"'
expect block 'bash scripts/release.sh publish 0.1.2'
expect block 'scripts/release.sh publish 0.1.2 && echo done'
expect block 'FOO=1 scripts/release.sh publish 0.1.2'

expect allow 'git tag'
expect allow 'git tag -l'
expect allow "git tag --list 'v*'"
expect allow 'git tag --contains HEAD'
expect allow 'git tag --sort=-v:refname'
expect allow 'git status && git log --oneline -5'
expect allow 'git push -u origin release/v0.1.2'
expect allow 'git push -u origin single-page-overscroll'
expect allow 'git push' "$feature_repo"
expect allow 'git push origin maintenance'
expect allow 'gh release list'
expect allow 'gh release view v0.1.1'
expect allow 'gh api repos/ys-math/rill/releases'
expect allow 'gh pr create --title x --body y'
expect allow 'scripts/release.sh publish 0.1.2'
expect allow './scripts/release.sh publish 0.1.2'
expect allow 'scripts/release.sh check 0.1.2'
expect allow 'scripts/release.sh prepare 0.1.2'
expect allow 'make test'

[ $fail -eq 0 ] && echo "guard-release: all cases pass"
exit $fail
