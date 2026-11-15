# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-15

### Added

- Composite action and reusable workflow that post a GitHub event summary to
  Telegram: push (branches and tags), pull requests (including draft, label and
  merge transitions), reviews, PR comments, branch/tag create and delete, and
  releases.
- Custom-message mode for CI failure and deploy alerts.
- Optional `chat-id`, `silent`, `project-name` and `dry-run` inputs.
- Graceful skip when the Telegram secrets are absent; hard failure when only
  one of them is set.
- Message clamped to 3500 characters by character, so multi-byte text is never
  split.
- Offline test suite with saved event payloads and a local Bot API mock, plus
  shellcheck and actionlint in CI.
- Documentation for integrating the action in any repository, with ready-made
  templates for the three supported setups.
