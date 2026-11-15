#!/usr/bin/env bash
# Offline test suite: runs the notifier against saved event payloads with
# NOTIFY_DRY_RUN=true, so nothing is ever sent to Telegram.
#
#   ./scripts/test-local.sh
#
# Requires bash, jq, grep, iconv and python3. Used by
# .github/workflows/self-test.yml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

failures=0
checks=0

ok()  { checks=$((checks + 1)); printf 'ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); printf 'FAIL %s\n' "$*"; }

# check_contains <output> <needle> <label>
check_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    ok "$3"
  else
    bad "$3"
    printf '%s\n' "$1" | sed 's/^/     /'
  fi
}

# check_absent <output> <needle> <label>
check_absent() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    bad "$3"
    printf '%s\n' "$1" | sed 's/^/     /'
  else
    ok "$3"
  fi
}

# Every GitHub variable the notifier reads is set explicitly here: the suite
# must not inherit the runner's own event (a tag push sets GITHUB_REF_TYPE=tag,
# for example, which changes the message under test).
base_env=(
  TELEGRAM_TOKEN=dummy
  TELEGRAM_TO=dummy
  GITHUB_REPOSITORY=owner/repo
  GITHUB_ACTOR=octocat
  GITHUB_REF_NAME=main
  GITHUB_REF_TYPE=branch
  GITHUB_RUN_ID=123456789
  GITHUB_SERVER_URL=https://github.com
  NOTIFY_DRY_RUN=true
)

# run_notify <event-name> <fixture> [VAR=value ...]
run_notify() {
  local event="$1" fixture="$2"
  shift 2
  env "${base_env[@]}" \
    GITHUB_EVENT_NAME="$event" \
    GITHUB_EVENT_PATH="$root/tests/fixtures/$fixture" \
    "$@" \
    bash scripts/notify.sh 2>&1
}

# run_case <event-name> <fixture> <expected substring> [VAR=value ...]
run_case() {
  local event="$1" fixture="$2" expect="$3" label="$3" out
  shift 3
  if ! out="$(run_notify "$event" "$fixture" "$@")"; then
    bad "$fixture — exited non-zero"
    printf '%s\n' "$out" | sed 's/^/     /'
    return
  fi
  if printf '%s' "$out" | grep -qF -- "$expect"; then
    ok "$fixture — has \"$label\""
  else
    bad "$fixture — missing \"$label\""
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

echo "message rendering"

run_case push                push.json                  "<b>🔀 Push · <code>main</code></b>"
run_case push                push.json                  "<code>9f3c2d1</code>"
run_case push                push.json                  "feat: add landing programme"
run_case push                push.json                  "📦 owner/repo · 👤 octocat"
run_case push                push.json                  "<b>🏷️ Tag · <code>v1.0.0</code></b>" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.0.0

run_case pull_request        pull_request-opened.json   "<b>🔀 PR #42 · opened</b>"
run_case pull_request        pull_request-opened.json   "<code>feat/dark-mode</code> → <code>main</code>"
run_case pull_request        pull_request-opened.json   "+12 −3 · 2 commits"
run_case pull_request        pull_request-merged.json   "<b>🔀 PR #42 · merged</b>"
run_case pull_request        pull_request-labeled.json  "<b>🔀 PR #42 · labeled · ready-for-agent</b>"

run_case pull_request_review pull_request_review.json   "<b>👀 Review approved · PR #42</b>"
run_case issue_comment       issue_comment.json         "<b>💬 Comment · PR #42</b>"
run_case issue_comment       issue_comment.json         "split this into two commits"
run_case release             release.json               "<b>🏷️ Release v1.2.0</b>"
run_case create              create.json                "<b>🌿 Branch created</b>"
run_case workflow_dispatch   push.json                  "<b>🧪 Manual notification test</b>"

echo
echo "escaping"

out="$(run_notify push push.json INPUT_MESSAGE='<script> & a_b *c*')"
check_contains "$out" "&lt;script&gt; &amp; a_b *c*" "HTML metacharacters are escaped"
check_contains "$out" "*c*" "asterisks are left alone (no Markdown)"

echo
echo "buttons"

out="$(run_notify push push.json)"
check_contains "$out" '"text":"Commit"' "push offers Commit"
check_contains "$out" '"text":"Diff"' "multi-commit push offers Diff"
check_contains "$out" '"text":"Run"' "push offers Run"

out="$(run_notify push push-single.json)"
check_absent "$out" '"text":"Diff"' "single-commit push omits Diff"
check_contains "$out" '"text":"Commit"' "single-commit push still offers Commit"

out="$(run_notify push push.json INPUT_PREVIEW_URL_TEMPLATE='https://pr-{number}.example.dev')"
check_absent "$out" '"text":"Preview"' "preview button is PR-only"

out="$(run_notify pull_request pull_request-opened.json)"
check_contains "$out" '"text":"PR"' "PR offers PR"
check_contains "$out" '"text":"Files"' "PR offers Files"
check_absent "$out" '"text":"Preview"' "no preview button when unconfigured"

out="$(run_notify pull_request pull_request-opened.json \
  INPUT_PREVIEW_URL_TEMPLATE='https://pr-{number}.example.dev')"
check_contains "$out" '"text":"Preview"' "preview template adds a button"
check_contains "$out" '"url":"https://pr-42.example.dev"' "preview template substitutes {number}"

out="$(run_notify pull_request pull_request-opened.json \
  INPUT_PREVIEW_URL_TEMPLATE='https://pr-{number}.example.dev' \
  INPUT_IMAGES_URL_TEMPLATE='https://shots.example.dev/{preview_url}')"
check_contains "$out" '"text":"Screenshots"' "images template adds a button"
check_contains "$out" '"url":"https://shots.example.dev/https://pr-42.example.dev"' \
  "images template substitutes {preview_url}"

out="$(run_notify pull_request pull_request-opened.json \
  INPUT_PREVIEW_URL='https://manual.example.dev')"
check_contains "$out" '"url":"https://manual.example.dev"' "explicit preview URL wins"

# A pattern that needs no preview URL resolves on its own.
out="$(run_notify pull_request pull_request-opened.json \
  INPUT_IMAGES_URL_TEMPLATE='https://shots.example.dev/latest.png')"
check_contains "$out" '"text":"Screenshots"' "static screenshots pattern needs no preview"

# {branch}/{sha} must be the PR head, not GitHub's 42/merge ref.
out="$(run_notify pull_request pull_request-opened.json \
  INPUT_PREVIEW_URL_TEMPLATE='https://{repo}/{branch}/{sha}/{actor}/{number}.dev')"
check_contains "$out" '"url":"https://owner/repo/feat/dark-mode/abc1234def5678901234567890abcdef12345678/octocat/42.dev"' \
  "all URL placeholders resolve from the PR head"
check_absent "$out" "42/merge" "branch placeholder is not the merge ref"

# Regression: bash 5.2+ rewrote `&` in ${var//x/y}, mangling query strings.
out="$(run_notify pull_request pull_request-opened.json \
  INPUT_PREVIEW_URL='https://pr-42.dev/?a=1&b=2' \
  INPUT_IMAGES_URL_TEMPLATE='https://shots.example.dev/{preview_url}')"
check_contains "$out" '"url":"https://shots.example.dev/https://pr-42.dev/?a=1&b=2"' \
  "ampersands in {preview_url} survive"

out="$(run_notify pull_request_review pull_request_review.json)"
check_contains "$out" '"text":"Review"' "review offers Review"

out="$(run_notify issue_comment issue_comment.json)"
check_contains "$out" '"text":"Comment"' "comment offers Comment"

out="$(run_notify release release.json)"
check_contains "$out" '"text":"Release"' "release offers Release"

echo
echo "sound"

out="$(run_notify push push.json)"
check_contains "$out" "silent=true" "push is silent"

out="$(run_notify pull_request pull_request-opened.json)"
check_contains "$out" "silent=false" "PR opened rings"

out="$(run_notify pull_request pull_request-merged.json)"
check_contains "$out" "silent=false" "PR merged rings"

out="$(run_notify pull_request pull_request-synchronize.json)"
check_contains "$out" "silent=true" "PR synchronize is silent"

out="$(run_notify pull_request pull_request-opened.json INPUT_SILENT=false)"
check_contains "$out" "silent=false" "silent=false forces a ring"

out="$(run_notify pull_request pull_request-opened.json INPUT_SILENT=true)"
check_contains "$out" "silent=true" "silent=true mutes a ring"

echo
echo "behaviour"

if out="$(run_notify issue_comment issue_comment-plain-issue.json)"; then
  check_contains "$out" "Nothing to notify" "issue comment on a plain issue is ignored"
else
  bad "plain issue comment exited non-zero"
fi

if out="$(run_notify push push.json TELEGRAM_TOKEN= TELEGRAM_TO= NOTIFY_DRY_RUN=false)"; then
  check_contains "$out" "skipping Telegram notification" "missing secrets warn and skip"
else
  bad "missing secrets must not fail the build"
fi

if run_notify push push.json TELEGRAM_TOKEN=abc TELEGRAM_TO= NOTIFY_DRY_RUN=false >/dev/null; then
  bad "token without chat id should fail"
else
  ok "token without chat id fails loudly"
fi

long="$(printf 'x%.0s' $(seq 1 5000))"
out="$(run_notify push push.json INPUT_MESSAGE="$long")"
check_contains "$out" "3500 chars" "message clamped to 3500 chars"

long="$(printf 'é%.0s' $(seq 1 5000))"
out="$(run_notify push push.json INPUT_MESSAGE="$long")"
if printf '%s' "$out" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; then
  ok "clamped message is still valid UTF-8"
else
  bad "clamping produced invalid UTF-8"
fi

out="$(run_notify push push.json INPUT_FORMAT=plain)"
check_absent "$out" "<b>" "format=plain strips tags"

echo
echo "transport (against tests/mock_telegram.py)"
log="$(mktemp)"
portfile="$(mktemp)"
MOCK_LOG="$log" python3 tests/mock_telegram.py "$portfile" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f "$log" "$portfile"' EXIT

port=""
for _ in $(seq 1 50); do
  if [ -s "$portfile" ]; then port="$(cat "$portfile")"; break; fi
  sleep 0.1
done
[ -n "$port" ] || { echo "mock server did not start" >&2; exit 1; }
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
  sleep 0.1
done

# sendForReal <token> <event> <fixture>
sendForReal() {
  run_notify "$2" "$3" NOTIFY_DRY_RUN=false \
    TELEGRAM_TOKEN="$1" TELEGRAM_TO=123456 \
    TELEGRAM_API_BASE="http://127.0.0.1:$port"
}

if out="$(sendForReal ok:token push push.json)"; then
  check_contains "$out" "notification sent" "successful send reports success"
  check_contains "$(tail -n 1 "$log")" "disable_notification=true" "push is sent muted"
  check_contains "$(tail -n 1 "$log")" "reply_markup=" "keyboard is sent with the message"
else
  bad "successful send exited non-zero"
fi

if out="$(sendForReal ok:token pull_request pull_request-opened.json)"; then
  check_contains "$(tail -n 1 "$log")" "disable_notification=false" "PR opened rings"
else
  bad "PR send exited non-zero"
fi

if out="$(sendForReal parse:token push push.json)"; then
  check_contains "$out" "plain fallback" "invalid markup falls back to plain text"
  check_absent "$(tail -n 1 "$log")" "parse_mode=" "fallback retry drops parse_mode"
  check_absent "$(tail -n 1 "$log")" "reply_markup=" "fallback retry drops the keyboard"
else
  bad "fallback exited non-zero"
fi

if out="$(sendForReal bad:token push push.json)"; then
  bad "a Telegram API error should fail the step"
else
  check_contains "$out" "chat not found" "Telegram API error is surfaced"
fi

echo
if [ "$failures" -gt 0 ]; then
  printf '%d of %d checks failed\n' "$failures" "$checks"
  exit 1
fi
printf 'all %d checks passed\n' "$checks"
