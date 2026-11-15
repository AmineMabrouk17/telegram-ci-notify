# telegram-ci-notify

GitHub Actions → Telegram, in one file. Pushes, pull requests, reviews, PR
comments, branches, tags and releases land in your chat as a short message with
buttons back to GitHub.

[![Self test](https://github.com/AmineMabrouk17/telegram-ci-notify/actions/workflows/self-test.yml/badge.svg)](https://github.com/AmineMabrouk17/telegram-ci-notify/actions/workflows/self-test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## The problem

| What breaks today | What this repo does instead |
| --- | --- |
| You find out a deploy broke the next time you open GitHub | one message per event, with a link straight to the commit, PR or run |
| Telegram actions forward the PR body verbatim, so anything over 4096 characters is rejected with `400` | sends a 5-line summary, clamped to 3500 characters |
| `parse_mode: Markdown` breaks on a `_` in a branch name or a `*` in a commit message | plain-text-safe HTML, escaped, with automatic fallback to plain text |
| One message per commit gets the channel muted within a week | one message per push, silent unless a PR needs you to act |
| A notification failure turns a green build red | missing secrets warn and skip; the step never fails the job |
| Adopting a notifications action means trusting a stranger's code | no dependencies: `bash` + `curl`, ~250 lines in this repository |

## Install

**1.** Drop the workflow in, from the repository you want notifications for:

```bash
mkdir -p .github/workflows
curl -fsSL https://raw.githubusercontent.com/AmineMabrouk17/telegram-ci-notify/v1/templates/telegram-notify.yml \
  -o .github/workflows/telegram-notify.yml
```

No terminal? Create `.github/workflows/telegram-notify.yml` in the GitHub web
editor and paste the same file from
[`templates/telegram-notify.yml`](templates/telegram-notify.yml).

**2.** Add two repository secrets (`Settings → Secrets and variables → Actions`):

| Secret | Value |
| --- | --- |
| `TELEGRAM_TOKEN` | the bot token from [@BotFather](https://t.me/BotFather) — send `/newbot` |
| `TELEGRAM_TO` | the chat id, e.g. `123456789`, `-1001234567890`, or `@channel` |

**3.** `Actions → Telegram Notify → Run workflow`. If a message arrives, you are
done. If it does not, one row of the [troubleshooting](#troubleshooting) table
is your answer.

<details>
<summary>How to find <code>TELEGRAM_TO</code></summary>

Send a message to the bot (or add it to the group), then:

```bash
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" \
  | jq '.result[-1].message.chat.id'
```

- Private chat → positive number.
- Group → negative number. The bot must be in the group.
- Public channel → `@channelusername`, or add the bot as admin and use the
  numeric id.

An empty `result` means no update reached the bot yet, or a webhook is holding
them: `curl "https://api.telegram.org/bot<TOKEN>/deleteWebhook"`.
</details>

## What you get

```text
🔀 Push · main
feat: add landing programme
📦 owner/repo · 👤 octocat · 9f3c2d1
[ Commit ]  [ Diff ]  [ Run ]
```

```text
🔀 PR #42 · opened
feat: add dark mode
feat/dark-mode → main
📦 owner/repo · 👤 octocat
+12 −3 · 2 commits
[ PR ]  [ Preview ]  [ Screenshots ]
[ Files ]  [ Run ]
```

Headline bold, branch names and SHAs monospace, every link a button — no bare
URLs eating three lines. `Diff` only appears when a push carries more than one
commit.

## Events

| Event | Trigger types | Buttons |
| --- | --- | --- |
| `push` | branches and tags | `Commit` · `Diff`* · `Run` |
| `pull_request` | opened, reopened, synchronize, closed, ready_for_review, converted_to_draft, labeled, unlabeled | `PR` · `Preview`* · `Screenshots`* / `Files` · `Run` |
| `pull_request_review` | submitted | `Review` · `PR` |
| `issue_comment` | created, on pull requests only | `Comment` · `PR` |
| `create` / `delete` | branches and tags | `Run` |
| `release` | published | `Release` · `Run` |
| `workflow_dispatch` | manual | `Run` |

`*` only when configured — see below.

## Preview and Screenshots buttons

Both are opt-in URL patterns, filled per pull request:

```yaml
        with:
          # Cloudflare alias, Vercel, Netlify — anything predictable.
          preview-url-template: https://pr-{number}-my-worker.my-subdomain.workers.dev
          # A live screenshot of that preview, no CI job required.
          images-url-template: https://image.thum.io/get/width/1200/crop/900/{preview_url}
```

Placeholders: `{number}`, `{repo}`, `{branch}`, `{sha}`, `{actor}` — plus
`{preview_url}` for the images pattern. An empty template means no button, so
nothing breaks in repositories that do not have previews.

The preview is deployed by a *different* workflow, so the button can 404 for a
minute or two after `opened`. If that bothers you, pass the exact URL instead,
from the workflow that builds it: `with: preview-url: ${{ steps.deploy.outputs.url }}`.

## Sound

`silent` defaults to `auto`: **only `pull_request.opened` and
`pull_request.closed` ring**. Pushes, comments, reviews and labels arrive
silently. Set `silent: false` to ring on everything, `true` to mute everything.

## Configuration

Secrets are read from the environment, so they never appear in the action's
`with:` block in the job log.

| Variable | Required | Description |
| --- | --- | --- |
| `TELEGRAM_TOKEN` | yes | bot token from @BotFather |
| `TELEGRAM_TO` | yes | chat id or `@channel` |

| Input | Default | Description |
| --- | --- | --- |
| `message` | `""` | text to send; empty means "summarise the current event" |
| `chat-id` | `""` | overrides `TELEGRAM_TO` for this step |
| `silent` | `auto` | `auto` \| `true` \| `false` |
| `project-name` | `""` | display name instead of `owner/repo` |
| `format` | `html` | `html` for bold + monospace, `plain` for no markup |
| `preview-url` | `""` | exact preview URL, wins over the template |
| `preview-url-template` | `""` | pattern for the `Preview` button |
| `images-url-template` | `""` | pattern for the `Screenshots` button |
| `dry-run` | `false` | print the message and keyboard instead of sending |

`message` is treated as plain text: `<`, `>` and `&` are escaped for you. Use
it for CI and deploy alerts:

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

See [`examples/alert-on-failure.yml`](examples/alert-on-failure.yml) for the
whole workflow.

## Behaviour worth knowing

- **Missing secrets skip, they do not fail.** `::warning::… skipping Telegram
  notification`, step green. A notifications outage must not turn a build red.
- **Half-configured secrets fail.** Only the token, or only the chat id, is a
  mistake and fails with a clear error.
- **Fork PRs are silent.** GitHub never exposes secrets to `pull_request` runs
  from forks; the check still passes.
- **HTML falls back to plain text.** If Telegram ever rejects the markup, the
  message is resent unformatted instead of being lost.
- **Clamped to 3500 characters by character**, so emoji are never cut in half.
- **One job per event**, serialised by a `concurrency` group.
- **Needs `jq` and `bash`.** Both ship on `ubuntu-latest` and `macos-latest`;
  Windows runners need `jq` installed.
- **Read-only.** `permissions: contents: read` is enough; no GitHub API calls.

### Pinning

```yaml
uses: AmineMabrouk17/telegram-ci-notify@v1        # latest v1.x — gets fixes
uses: AmineMabrouk17/telegram-ci-notify@v1.1.0    # exact release
uses: AmineMabrouk17/telegram-ci-notify@<full-sha> # immutable
```

Forking? Run `sed -i 's/AmineMabrouk17/your-user/g'` over the template and the
`uses:` lines above.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `401 Unauthorized` / `Not Found` | wrong or revoked token. Re-copy it from @BotFather. |
| `400 Bad Request: chat not found` | bot not in that chat, or wrong id. Groups need a negative id; a group upgraded to a supergroup changes id. |
| Step logs `skipping Telegram notification` | secrets missing, or the run is a fork PR. |
| No message on a push to a new branch | `push`/`create` runs use the workflow file **from that branch**; a brand-new branch without the file cannot notify. |
| No message when a branch is deleted | `delete` runs the **default-branch** copy of the workflow. |
| `Preview` button returns 404 | normal for the first minute or two after `opened`; see [above](#preview-and-screenshots-buttons). |
| `Screenshots` button missing | the pattern uses `{preview_url}` and no preview URL resolved — set a preview template or pass `preview-url`. |
| The job blocks merges as a required check | it is a normal job; mark it non-required in branch protection. |

## Development

```bash
# dry-run without sending anything
NOTIFY_DRY_RUN=true TELEGRAM_TOKEN=x TELEGRAM_TO=y ./scripts/notify.sh

# full offline suite: event fixtures, escaping, buttons, sound, clamping
./scripts/test-local.sh
```

```
action.yml                     composite action
scripts/notify.sh              event → HTML message + keyboard → Telegram
scripts/test-local.sh          offline test suite
templates/telegram-notify.yml  copy-paste workflow
examples/                      CI failure alert
tests/fixtures/                saved event payloads
tests/mock_telegram.py         local Bot API stand-in
```

CI runs `shellcheck`, `actionlint`, the test suite and a dry-run of the action
itself on every push.

## License

MIT — see [LICENSE](LICENSE).
