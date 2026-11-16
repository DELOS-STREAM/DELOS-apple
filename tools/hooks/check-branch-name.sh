#!/bin/sh
# Checks a branch name against Conventional Branch 1.1.0 as Delos uses it
# (docs/ENGINEERING_RULES.md, "Commit messages and branch names").
#   sh tools/hooks/check-branch-name.sh           the current branch
#   sh tools/hooks/check-branch-name.sh <name>    the named branch
# Exit 0: valid. Exit 1: not valid, with the reason on stderr. Tests: sh tools/hooks/test-check-branch-name.sh
#
# Valid: `main`, or `<type>/<description>` with the type feature, bugfix, hotfix, release or chore and a
# description of lower-case letters and digits in words separated by single hyphens; a word may hold single dots
# (release/v1.2.0). An issue number is a leading word of the description (feature/87-review-rules).

TYPES='feature|bugfix|hotfix|release|chore'
WORD='[a-z0-9]+(\.[a-z0-9]+)*'

name=${1:-$(git symbolic-ref --quiet --short HEAD 2>/dev/null)}
[ -n "$name" ] || { echo "check-branch-name: no branch name (detached HEAD?)" >&2; exit 2; }

[ "$name" = "main" ] && exit 0
if printf '%s' "$name" | grep -Eqx "($TYPES)/$WORD(-$WORD)*"; then
    exit 0
fi

reason="use '<type>/<description>', for example 'feature/87-review-rules'"
case "$name" in
    */*)
        type=${name%%/*}
        if ! printf '%s' "$type" | grep -Eqx "$TYPES"; then
            reason="unknown type '$type'; the types are: $(printf '%s' "$TYPES" | sed 's/|/, /g')"
        else
            reason="the description holds lower-case letters, digits, single hyphens between words and single dots inside a word"
        fi ;;
esac
echo "check-branch-name: '$name' is not a valid branch name: $reason" >&2
echo "check-branch-name: see CONTRIBUTING.md, \"Branch names\"" >&2
exit 1
