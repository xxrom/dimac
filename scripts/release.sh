#!/bin/zsh
# Bumps the version, moves Unreleased CHANGELOG notes under it, commits, and tags.
# Usage: scripts/release.sh [patch|minor|major|X.Y.Z] [--push]
# Pushing the tag triggers .github/workflows/release.yml, which builds and publishes the release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/Dimac/Resources/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"
BUMP="${1:-patch}"
PUSH="${2:-}"
cd "$ROOT"

fail() { echo "release: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == "master" ]] || fail "run from master"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean"

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
IFS=. read -r major minor patch <<< "$current"

case "$BUMP" in
    patch) version="$major.$minor.$((patch + 1))" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    major) version="$((major + 1)).0.0" ;;
    <->.<->.<->) version="$BUMP" ;;
    *) fail "expected patch, minor, major, or X.Y.Z; got '$BUMP'" ;;
esac
tag="v$version"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "tag $tag already exists"

notes="$(awk '/^## Unreleased/ { inside = 1; next } /^## / { inside = 0 } inside' "$CHANGELOG" | sed '/^[[:space:]]*$/d')"
[[ -n "$notes" && "$notes" != "- No changes yet." ]] || fail "add release notes under '## Unreleased' in CHANGELOG.md first"

# Edit values in place; PlistBuddy would reformat the whole file.
set_plist_string() {
    perl -0pi -e "s|(<key>\Q$1\E</key>\s*<string>)[^<]*(</string>)|\${1}$2\${2}|" "$PLIST"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST")" == "$2" ]] || fail "could not set $1 in Info.plist"
}
set_plist_string CFBundleShortVersionString "$version"
set_plist_string CFBundleVersion "$((build + 1))"
awk -v heading="## $version - $(date +%Y-%m-%d)" '
    { print }
    /^## Unreleased/ && !done { print ""; print "- No changes yet."; print ""; print heading; done = 1 }
' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

git add "$PLIST" "$CHANGELOG"
git commit -q -m "Release $version"
git tag -a "$tag" -m "Dimac $version"
echo "Tagged $tag ($current -> $version, build $((build + 1)))."

if [[ "$PUSH" == "--push" ]]; then
    git push --atomic origin master "$tag"
else
    echo "Publish with: git push --atomic origin master $tag"
fi
