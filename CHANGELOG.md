# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-15

### Added

- HTML rendering: bold headline, monospace branch names and SHAs, no bare URLs
  in the body.
- One row of inline keyboard buttons per event — `PR`, `Files`, `Preview`,
  `Screenshots`, `Commit`, `Diff`, `Review`, `Comment`, `Release`, `Run`.
- `preview-url`, `preview-url-template` and `images-url-template` inputs, so a
  pull request can link to its deployment and a screenshot of it.
- `format` input (`html` / `plain`) and an automatic plain-text retry when
  Telegram rejects the markup, so a stray `<` never loses a message.
- `silent: auto` — only `pull_request.opened` and `pull_request.closed` ring.

### Changed

- `silent` defaults to `auto` instead of ringing on every event.
- Long messages are clamped by character, and a partially written tag is
  trimmed at the cut point.

### Removed

- The reusable workflow (`notify.yml`) and `examples/call-notify.yml`. The
  template is stable and the action carries the updates, so a second entry
  point only added a versioning caveat. Nothing had adopted it.

## [1.0.0] - 2026-11-15

### Added

- Composite action that posts a GitHub event summary to Telegram: push
  (branches and tags), pull requests (including draft, label and merge
  transitions), reviews, PR comments, branch/tag create and delete, and
  releases.
- Custom-message mode for CI failure and deploy alerts.
- Optional `chat-id`, `silent`, `project-name` and `dry-run` inputs.
- Graceful skip when the Telegram secrets are absent; hard failure when only
  one of them is set.
- Offline test suite with saved event payloads and a local Bot API mock, plus
  shellcheck and actionlint in CI.
- Documentation for integrating the action in any repository, with ready-made
  templates.
