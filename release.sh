#!/usr/bin/env bash
# Build, sign and publish a FirstFocus update (ADR 0044): the zip and the
# appcast.xml Sparkle reads, uploaded as a GitHub release.
#
# Usage: ./release.sh <version> [notes-file]   e.g. ./release.sh 0.2.0 ~/notes.txt
#
# The version is MAJOR.MINOR.PATCH. It becomes the tag (v0.2.0) and the
# version the app shows (CFBundleShortVersionString).
#
# The notes file is plain text, used as written on the GitHub release page
# and in Sparkle's update window, where a line starting "- " is a list item
# and any other line a paragraph. Without one, the notes are the commit
# subjects since the last v* tag. Keep the file outside the repo: the
# script refuses to run with uncommitted or untracked files.
#
# Info.plist's SUFeedURL points at the latest GitHub release's appcast.xml,
# so the release tagged v<version> in RELEASE_REPO (default
# bhatiashash/FirstFocus) becomes the feed as soon as it's created. Copies
# from before 0.1.7 read bhatiashash/DailyOS-releases instead.
#
# The appcast is signed with the Sparkle EdDSA key in the login Keychain
# (created by Sparkle's generate_keys). Without that key no update can be
# signed, and installed copies refuse unsigned ones.
set -euo pipefail

VERSION="${1:?Usage: ./release.sh <version> [notes-file]}"
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must use MAJOR.MINOR.PATCH format (e.g., 0.1.0)" >&2
    exit 1
fi
NOTES_FILE=""
if [[ -n "${2:-}" ]]; then
    # Resolved before the cd below, so a path relative to where the script
    # was run from still works.
    [[ -f "$2" ]] || { echo "No notes file at $2." >&2; exit 1; }
    NOTES_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
cd "$(dirname "$0")"

REPO="${RELEASE_REPO:-bhatiashash/FirstFocus}"
TAG="v$VERSION"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

# The build number is the commit count, so the build has to be a commit.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash your changes first: the build number comes from the commit count." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists. The script creates the tag itself, after the upload." >&2
    exit 1
fi

VERSION="$VERSION" ./build.sh release

OUT=".build/releases/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/FirstFocus-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent .build/FirstFocus.app "$ZIP"

# Release notes: the notes file, or the commit subjects since the last v*
# tag. notes.md goes on the GitHub release page. The same text as HTML, in
# a file with the zip's name and no <body>, is embedded in the appcast item.
if [[ -n "$NOTES_FILE" ]]; then
    cp "$NOTES_FILE" "$OUT/notes.md"
else
    PREVIOUS=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
    git log --no-merges --format='- %s' "${PREVIOUS:+$PREVIOUS..}HEAD" > "$OUT/notes.md"
fi
sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$OUT/notes.md" | awk '
    /^- / { if (!inList) { print "<ul>"; inList = 1 } print "<li>" substr($0, 3) "</li>"; next }
    inList { print "</ul>"; inList = 0 }
    NF { print "<p>" $0 "</p>" }
    END { if (inList) print "</ul>" }
' > "$OUT/FirstFocus-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    -o "$OUT/appcast.xml" \
    "$OUT"

echo "Built $ZIP and $OUT/appcast.xml"

gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" \
    --repo "$REPO" --title "FirstFocus $VERSION" --notes-file "$OUT/notes.md"
# The next release's notes start after this tag.
git tag "$TAG"
echo "Published $TAG to $REPO"
