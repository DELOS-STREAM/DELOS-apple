# Contributing to DELOS for Apple

Thanks for your interest. DELOS for Apple is at an early stage and is maintained by one person
([@Meitoncz](https://github.com/Meitoncz)). The permanent rules are in [docs/ENGINEERING_RULES.md](docs/ENGINEERING_RULES.md);
this page says how to take part.

## Reporting bugs and ideas

Open an [issue](https://github.com/Meitoncz/DELOS-apple/issues). Search existing issues first. Problems of the Android
app belong to [Meitoncz/DELOS](https://github.com/Meitoncz/DELOS/issues); problems on the PC side belong to
[Vibepollo](https://github.com/Nonary/Vibepollo), [Apollo](https://github.com/ClassicOldSong/Apollo) or
[Sunshine](https://github.com/LizardByte/Sunshine). Remove IP addresses, PC and account names from logs and screenshots.

## Security problems

Do not open a public issue for a vulnerability. Report it privately as described in [SECURITY.md](SECURITY.md).

## Tests

A bug fix comes with a regression test that fails without the fix; new logic comes with tests. Where a test cannot reach
the code (behaviour that needs a device), say so in the commit body with a line `No test: <reason>`.

| Command | What it checks |
|---|---|
| `python3 tools/docs/check_links.py` | Relative links and anchors of the Markdown files |
| `python3 -m unittest discover -s tools/docs` | The tests of the link check |
| `sh tools/hooks/test-commit-msg.sh` | The tests of the commit message hook |

## Commit messages and branch names

The same convention as DELOS for Android, described in its
[CONTRIBUTING.md](https://github.com/Meitoncz/DELOS/blob/main/CONTRIBUTING.md#commit-messages): Conventional Commits
with a subject of at most 72 characters, `[skip ci]` as the last line of the body on `main`, and Conventional Branch names
such as `feature/1-swift-skeleton`. Two hooks check both; enable them once per clone:

```sh
git config core.hooksPath tools/hooks
```

## Principles

- Controller first. Every screen must be usable with a game controller; touch works too.
- No confirmation dialogs in normal flows.
- Visual changes start as a prototype or a discussion in an issue, before code. DELOS for Android is the visual reference.
- The app is called DELOS in every language: the name is never translated or inflected.
- DELOS is GPL-3.0. By contributing you agree your work is released under the same license.

## Pull requests

Please discuss in an issue first: the app is being written from scratch, and most areas are not settled yet. Keep pull
requests small and focused. A new dependency or binary needs its origin, version, license and checksum recorded in
[docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).

## AI tools

The maintainer works with AI coding agents and reviews all changes. If you use AI tools for a pull request, you are
still responsible for understanding and testing what you submit.
