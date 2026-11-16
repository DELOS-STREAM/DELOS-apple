#!/bin/sh
# Tests of tools/hooks/commit-msg:  sh tools/hooks/test-commit-msg.sh  (exit 0: all passed).

hook="$(cd "$(dirname "$0")" && pwd)/commit-msg"
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
failed=0
count=0

# expect <accept|reject> <name> <message>
expect() {
    count=$((count + 1))
    printf '%s' "$3" > "$work/message"
    if sh "$hook" "$work/message" 2> "$work/error"; then got=accept; else got=reject; fi
    if [ "$got" != "$1" ]; then
        failed=$((failed + 1))
        echo "FAILED: $2: expected $1, got $got"
        sed 's/^/    /' "$work/error"
    fi
}

seventy_two="fix(stream): keep the value of the bitrate page after an error, abcdefgh"
seventy_three="${seventy_two}f"
[ ${#seventy_two} -eq 72 ] || { echo "test setup: the 72-character subject has ${#seventy_two}"; exit 2; }

expect accept "subject only" "docs: add the build guide"
expect accept "subject, empty line, body" "docs: add the build guide

Replaces the two workstation notes.

[skip ci]"
expect accept "subject of exactly 72 characters" "$seventy_two"
expect reject "subject of 73 characters" "$seventy_three"
expect reject "empty message" ""
expect reject "blank subject" "   

body"
expect reject "only comments" "# Please enter the commit message
# On branch main"
expect accept "comment lines do not count" "# a comment first
docs: add the build guide
# another comment

Body."
expect reject "WIP subject" "WIP"
expect reject "WIP prefix" "WIP: stream menu"
expect reject "WIP inside a conventional subject" "feat(ui): stream menu (WIP)"
expect reject "wip in lower case" "wip stream menu"
expect reject "WIP inside the subject" "Stream menu (WIP)"
expect reject "fixup commit" "fixup! docs: add the build guide"
expect reject "squash commit" "squash! docs: add the build guide"
expect accept "a word that only contains wip" "fix(input): follow the finger in a swipe"
expect reject "body directly under the subject" "docs: add the build guide
Replaces the two workstation notes."
expect reject "[skip ci] in the subject" "docs: add the build guide [skip ci]"
expect accept "long merge subject written by git" "Merge branch 'feature/a-very-long-branch-name-that-goes-on-and-on-and-on' into main-line"
expect accept "long revert subject written by git" "Revert \"fix(stream): keep the value of the bitrate page after an error, abcdefghie\"

This reverts commit 0123456."
expect accept "text below the scissors line is ignored" "docs: add the build guide

Body.
# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/x b/x
+a line that is not part of the message"

# Conventional Commits header
expect accept "every type" "feat: add the streaming time block"
for type in fix docs test refactor perf build ci chore style revert; do
    expect accept "type $type" "$type: change one thing"
done
for scope in ui stream pyrowave input host l10n deps docs ci tools release; do
    expect accept "scope $scope" "fix($scope): change one thing"
done
expect accept "breaking change mark" "feat!: drop Android 10"
expect accept "scope and breaking change mark" "feat(host)!: require the encrypted control stream"
expect reject "no type" "Add the build guide"
expect reject "old area prefix" "Stream menu: keep the bitrate after a failed request"
expect reject "unknown type" "feature: add the build guide"
expect reject "type in upper case" "Fix: keep the bitrate"
expect reject "unknown scope" "fix(menu): keep the bitrate"
expect reject "empty scope" "fix(): keep the bitrate"
expect reject "no space after the colon" "fix:keep the bitrate"
expect reject "space before the colon" "fix : keep the bitrate"
expect reject "two spaces after the colon" "fix:  keep the bitrate"
expect reject "no description" "fix: "
expect reject "mark before the scope" "fix!(stream): keep the bitrate"
expect reject "trailing period" "fix(stream): keep the bitrate."
expect accept "footers and [skip ci] last" "fix(stream): keep the bitrate after a failed request

The page reset its slider.

Refs: #123

[skip ci]"
expect accept "breaking change footer" "feat(host): require the encrypted control stream

BREAKING CHANGE: hosts older than 7.1.431 no longer connect.

[skip ci]"
expect accept "breaking change footer with a hyphen" "feat: drop Android 10

BREAKING-CHANGE: Android 10 is no longer supported."
expect reject "breaking change footer in lower case" "feat: drop Android 10

Breaking change: Android 10 is no longer supported."
expect reject "breaking change footer without a colon" "feat: drop Android 10

BREAKING CHANGE Android 10 is no longer supported."
expect reject "[skip ci] before a footer" "fix: keep the bitrate

[skip ci]

Refs: #123"
expect reject "[skip ci] inside a line" "fix: keep the bitrate

Body. [skip ci]"

if [ "$failed" -eq 0 ]; then
    echo "commit-msg: $count cases passed"
else
    echo "commit-msg: $failed of $count cases failed"
    exit 1
fi
