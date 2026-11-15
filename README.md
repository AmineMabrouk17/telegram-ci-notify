# telegram-ci-notify

GitHub Actions → Telegram, in one file. Pushes, pull requests, reviews, PR
comments, branches, tags and releases land in your chat as a short plain-text
message with links back to GitHub.

[![Self test](https://github.com/AmineMabrouk17/telegram-ci-notify/actions/workflows/self-test.yml/badge.svg)](https://github.com/AmineMabrouk17/telegram-ci-notify/actions/workflows/self-test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

- **No third-party action.** ~200 lines of bash + `curl`, nothing to audit but this repo.
- **Plain text, no Markdown.** Nothing breaks when a commit message contains `_`, `*` or a backtick.
- **Never blocks a build.** Missing secrets produce a warning and a green step.
- **Message is clamped before sending**, so a long commit or comment can't trip Telegram's 4096-character limit.

## What it looks like

```text
📦 AmineMabrouk17/Cast-Cue
🔀 Push · main
👤 AmineMabrouk17 · 9f3c2d1
feat: add landing programme
https://github.com/AmineMabrouk17/Cast-Cue/commit/9f3c2d1…
https://github.com/AmineMabrouk17/Cast-Cue/compare/1111111...9f3c2d1
```

```text
📦 AmineMabrouk17/My-Portfolio
🔀 PR #42 · merged
feat: add dark mode
feat/dark-mode → main
👤 AmineMabrouk17
+12 −3 · 2 commits
https://github.com/AmineMabrouk17/My-Portfolio/pull/42
https://github.com/AmineMabrouk17/My-Portfolio/actions/runs/123456789
```

## Why not one of the popular Telegram actions

They work, until they don't. The usual failure modes are:

| Problem | What happens | Here |
| --- | --- | --- |
| PR body forwarded verbatim | Telegram rejects anything over 4096 chars → `400 Bad Request` | only a short summary is sent, clamped to 3500 |
| `parse_mode: Markdown` by default | a `_` in a branch name or commit message breaks formatting → 400 | plain text, no escaping needed |
| One message per commit | a 12-commit push floods the chat | one message per push |

## Before you start

### 1. Create a bot and copy its token

1. Open [@BotFather](https://t.me/BotFather) in Telegram.
2. Send `/newbot`, pick a name and a username.
3. Copy the token it replies with (`123456789:AAH…`). This is `TELEGRAM_TOKEN`.

### 2. Find the chat id

Send any message to the bot (or add it to the group), then:

```bash
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" \
  | jq '.result[-1].message.chat.id'
```

- Private chat → positive number, e.g. `123456789`.
- Group → negative number, e.g. `-1001234567890`. The bot must be in the group.
- Public channel → `@channelusername` works too; otherwise add the bot as an
  admin and use the numeric id.

If the response is `{"ok":true,"result":[]}`, no update has reached the bot yet
(message it again), or a webhook is swallowing updates — clear it with
`curl "https://api.telegram.org/bot<TOKEN>/deleteWebhook"`.

### 3. Add both values as repository secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
| --- | --- |
| `TELEGRAM_TOKEN` | the token from @BotFather |
| `TELEGRAM_TO` | the chat id from step 2 |

Organisation secrets work as well; so do environment secrets if the job sets
`environment:`.

## Add it to a repository

Every option needs the same two secrets. Pick one.

### Option A — copy one file (recommended)

Copy [`templates/telegram-notify.yml`](templates/telegram-notify.yml) to
`.github/workflows/telegram-notify.yml`, commit, done. Twenty-odd lines, all
triggers included, no dependency on this repo staying public.

```yaml
name: Telegram Notify

on:
  workflow_dispatch:
  push:
  create:
  delete:
  pull_request:
    types: [opened, reopened, synchronize, closed, ready_for_review,
            converted_to_draft, labeled, unlabeled]
  pull_request_review:
    types: [submitted]
  issue_comment:
    types: [created]
  release:
    types: [published]

permissions:
  contents: read

concurrency:
  group: telegram-${{ github.event_name }}-${{ github.event.pull_request.number || github.event.issue.number || github.ref }}
  cancel-in-progress: false

jobs:
  notify:
    name: Telegram
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: AmineMabrouk17/telegram-ci-notify@v1
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_TO: ${{ secrets.TELEGRAM_TO }}
```

Trim the `on:` list to the events you actually care about — nothing else needs
to change.

### Option B — reuse the workflow

Same behaviour, but the job lives upstream, so fixes arrive by bumping a tag
instead of editing every repo. Add
[`examples/call-notify.yml`](examples/call-notify.yml) as
`.github/workflows/telegram-notify.yml`:

```yaml
name: Telegram Notify

on:
  push:
  pull_request:
    types: [opened, reopened, synchronize, closed, ready_for_review]
  pull_request_review:
    types: [submitted]
  issue_comment:
    types: [created]
  release:
    types: [published]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  notify:
    uses: AmineMabrouk17/telegram-ci-notify/.github/workflows/notify.yml@v1
    secrets: inherit
    # with:
    #   project-name: Cast n Cue
    #   silent: true
```

`secrets: inherit` passes `TELEGRAM_TOKEN` and `TELEGRAM_TO` through. If you
prefer to be explicit:

```yaml
    secrets:
      TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
      TELEGRAM_TO: ${{ secrets.TELEGRAM_TO }}
```

Note that the caller owns the `on:` block — a reusable workflow cannot declare
triggers for you.

### Option C — custom messages and failure alerts

The action also sends any text you give it, so it doubles as a deploy or CI
alert inside an existing workflow ([`examples/alert-on-failure.yml`](examples/alert-on-failure.yml)):

```yaml
  alert-on-failure:
    needs: [ci]
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - uses: AmineMabrouk17/telegram-ci-notify@v1
        with:
          message: |
            ❌ CI failed
            📦 ${{ github.repository }}
            🌿 ${{ github.ref_name }}
            👤 ${{ github.actor }}
            ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_TO: ${{ secrets.TELEGRAM_TO }}
```

`if: failure()` on the job (not the step) keeps the alert working when an
earlier job is skipped or cancelled, and `needs:` decides what "failure" means.

## Configuration

### Secrets (passed as environment variables, not inputs)

| Variable | Required | Description |
| --- | --- | --- |
| `TELEGRAM_TOKEN` | yes | bot token from @BotFather |
| `TELEGRAM_TO` | yes | chat id or `@channel` |

Secrets are read from the environment so they never show up in the action's
`with:` block in the job log.

### Inputs

| Input | Default | Description |
| --- | --- | --- |
| `message` | `""` | text to send; empty means "summarise the current event" |
| `chat-id` | `""` | overrides `TELEGRAM_TO` for this step |
| `silent` | `false` | send without a notification sound |
| `project-name` | `""` | display name instead of `owner/repo` |
| `dry-run` | `false` | print the message in the log instead of sending |

### Other environment variables

| Variable | Description |
| --- | --- |
| `EVENT_ACTION` | overrides the action from the payload (tests only) |
| `TELEGRAM_API_BASE` | point at a self-hosted Bot API server, default `https://api.telegram.org` |
| `NOTIFY_DRY_RUN` | same as `dry-run: true`, for running the script locally |

## Events

| Event | Trigger types | Message |
| --- | --- | --- |
| `push` | all branches, all tags | branch/tag, short SHA, commit subject, commit link (+ compare link when several commits) |
| `pull_request` | opened, reopened, synchronize, closed, ready_for_review, converted_to_draft, labeled, unlabeled | PR number and action (`closed` + merged shows `merged`), title, `head → base`, author, `+adds −dels`, commit count, links |
| `pull_request_review` | submitted | review state (approved / changes requested / commented), PR title |
| `issue_comment` | created | comments on pull requests only — plain-issue chatter is ignored |
| `create` / `delete` | branch, tag | ref type and name |
| `release` | published | tag and release name |
| `workflow_dispatch` | manual | "manual notification test", so you can verify the wiring |

## Behaviour worth knowing

- **Missing secrets skip, they don't fail.** The step logs
  `::warning::… skipping Telegram notification` and succeeds. A notification
  outage should never turn a green build red.
- **Half-configured secrets fail.** Only the token, or only the chat id, is a
  mistake and fails the step with a clear error.
- **Fork PRs are silent.** GitHub never exposes secrets to `pull_request` runs
  from forks, so nothing is sent — the check still passes.
- **Plain text only.** No `parse_mode`, so no escaping bugs. Markdown in your
  `message` is sent literally.
- **Clamped to 3500 characters**, by character (not byte), so emoji are never
  cut in half.
- **One job per event**, with a `concurrency` group that serialises them.
  `cancel-in-progress: false` means a burst of pushes delivers a few messages
  instead of losing them.
- **Needs `jq` and `bash`.** Both are on `ubuntu-latest` and `macos-latest`.
  Windows runners work if `jq` is installed.
- **Read-only.** `permissions: contents: read` is enough; the action never
  calls the GitHub API.

### Pinning a version

```yaml
uses: AmineMabrouk17/telegram-ci-notify@v1        # latest v1.x — gets fixes
uses: AmineMabrouk17/telegram-ci-notify@v1.2.0    # exact release
uses: AmineMabrouk17/telegram-ci-notify@<full-sha> # immutable, safest
```

The reusable workflow in Option B calls the action at `v1` internally, so
pinning that workflow to `v1.2.0` still tracks action fixes within `v1`. For a
fully immutable setup, use Option A or C and pin the action by SHA.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `401 Unauthorized` / `Not Found` in the log | wrong token, or the token was revoked. Re-copy it from @BotFather. |
| `400 Bad Request: chat not found` | the bot is not in that chat, or the id is wrong. Groups need a negative id; a group upgraded to a supergroup gets a new id. |
| Step logs `skipping Telegram notification` | `TELEGRAM_TOKEN` / `TELEGRAM_TO` missing — check the secret names, and that the run is not a fork PR. |
| No message on a push to a new branch | `create`/`push` runs use the workflow file **from that branch**. A brand-new branch that does not contain the file yet cannot notify. |
| No notification when a branch is deleted | `delete` runs the **default-branch** copy of the workflow, so it must exist on `main`. |
| The workflow never runs at all | the file must be on the default branch for the event types you expect; check the `on:` block and that Actions are enabled for the repo. |
| Job appears as a pending check and blocks merges | it is a normal job — add it to branch protection as non-required, or use `if:` to skip it on forks. |
| Nothing arrives but the step is green | `chat-id`/`TELEGRAM_TO` points at a chat you are not looking at. Run the workflow manually and compare the id. |

## Development

```bash
# dry-run without sending anything
NOTIFY_DRY_RUN=true TELEGRAM_TOKEN=x TELEGRAM_TO=y ./scripts/notify.sh

# full offline suite: event fixtures, clamping, error handling
./scripts/test-local.sh
```

Layout:

```
action.yml                     composite action (single source of truth)
scripts/notify.sh              event → message → Telegram
scripts/test-local.sh          offline test suite
templates/telegram-notify.yml  copy-paste workflow (Option A)
.github/workflows/notify.yml   reusable workflow (Option B)
examples/                      caller examples (Options B and C)
tests/fixtures/                saved event payloads
tests/mock_telegram.py         local Bot API stand-in
```

CI runs `shellcheck`, `actionlint`, the test suite and a dry-run of the action
itself on every push.

## License

MIT — see [LICENSE](LICENSE).
