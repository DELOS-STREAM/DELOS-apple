#!/bin/sh
# Tests of tools/hooks/check-branch-name.sh and tools/hooks/pre-push:
#   sh tools/hooks/test-check-branch-name.sh  (exit 0: all passed).

here="$(cd "$(dirname "$0")" && pwd)"
failed=0
count=0
zero=0000000000000000000000000000000000000000
sha=0123456789abcdef0123456789abcdef01234567

# name <accept|reject> <branch name>
name() {
    count=$((count + 1))
    if sh "$here/check-branch-name.sh" "$2" 2> /dev/null; then got=accept; else got=reject; fi
    [ "$got" = "$1" ] || { failed=$((failed + 1)); echo "FAILED: branch '$2': expected $1, got $got"; }
}

# push <accept|reject> <case> <stdin of pre-push>
push() {
    count=$((count + 1))
    if printf '%s\n' "$3" | sh "$here/pre-push" origin url 2> /dev/null; then got=accept; else got=reject; fi
    [ "$got" = "$1" ] || { failed=$((failed + 1)); echo "FAILED: push, $2: expected $1, got $got"; }
}

name accept "main"
name accept "feature/add-login-page"
name accept "feature/87-review-rules"
name accept "bugfix/fix-header-bug"
name accept "hotfix/security-patch"
name accept "release/v1.2.0"
name accept "chore/upgrade-node-v20.11"
name accept "chore/update-dependencies"
name reject "Feature/Add-Login"
name reject "feature/new--login"
name reject "feature/-new-login"
name reject "feature/new-login-"
name reject "release/v1.-2.0"
name reject "release/v1.2.0."
name reject "release/v1..2"
name reject "bugfix/header bug"
name reject "bugfix/header_bug"
name reject "unknown/some-task"
name reject "feature/"
name reject "feature"
name reject "feature/a/b"
name reject "rv-follow-docs"
# Valid in Conventional Branch 1.1.0, not used by Delos
name reject "feat/add-login-page"
name reject "fix/header-bug"
name reject "claude/security-patch"
name reject "master"
name reject "develop"

push accept "new valid branch" "refs/heads/feature/a-b $sha refs/heads/feature/a-b $zero"
push reject "new invalid branch" "refs/heads/my_branch $sha refs/heads/my_branch $zero"
push accept "invalid branch that exists on the remote" "refs/heads/my_branch $sha refs/heads/my_branch $sha"
push accept "deleting an invalid branch" "(delete) $zero refs/heads/my_branch $sha"
push accept "a tag" "refs/tags/v1.0.0 $sha refs/tags/v1.0.0 $zero"
push accept "main" "refs/heads/main $sha refs/heads/main $sha"
push reject "one valid and one new invalid branch" "refs/heads/main $sha refs/heads/main $sha
refs/heads/x $sha refs/heads/x $zero"

if [ "$failed" -eq 0 ]; then
    echo "check-branch-name: $count cases passed"
else
    echo "check-branch-name: $failed of $count cases failed"
    exit 1
fi
