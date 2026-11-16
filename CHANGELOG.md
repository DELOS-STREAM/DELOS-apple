# Changelog

All notable changes to DELOS for Apple are documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). The first version will be 0.1.0.

## [Unreleased]

### Changed

- The repository is set up for DELOS: README, contribution and security policy, third-party record, commit and branch
  hooks. CI runs only for release tags.

### Removed

- The inherited Moonlight workflow that ran on every push and pull request, and the Moonlight bot configurations.

### Fixed

- The Moonlight reference app starts on iOS and tvOS 27, which stop apps without the scene lifecycle.
