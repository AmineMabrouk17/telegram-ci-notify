#!/usr/bin/env bash
# Offline test suite: runs the notifier against saved event payloads with
# NOTIFY_DRY_RUN=true, so nothing is ever sent to Telegram.
#
#   ./scripts/test-local.sh
#
# Requires bash, jq, grep. Used by .github/workflows/self-test.yml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

failures=0
checks=0

ok()   { checks=$((checks + 1)); printf 'ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf 'FAIL %s\n' "$*"; }

# check_contains <output> <needle> <label>
check_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then
    ok "$3"
  else
    bad "$3"
    printf '%s\n' "$1" | sed 's/^/     /'
  fi
}

# run_case <event-name> <fixture> <expected substring>
run_case() {
  local event="$1" fixture="$2" expect="$3" out
  if ! out="$(env \
      NOTIFY_DRY_RUN=true \
      TELEGRAM_TOKEN=dummy \
      TELEGRAM_TO=dummy \
      GITHUB_EVENT_NAME="$event" \
      GITHUB_EVENT_PATH="$root/tests/fixtures/$fixture" \
      GITHUB_REPOSITORY=AmineMabrouk17/Cast-Cue \
      GITHUB_ACTOR=AmineMabrouk17 \
      GITHUB_REF_NAME=main \
      GITHUB_RUN_ID=123456789 \
      bash scripts/notify.sh 2>&1)"; then
    bad "$fixture — exited non-zero"
    printf '%s\n' "$out" | sed 's/^/     /'
    return
  fi
  if printf '%s' "$out" | grep -qF -- "$expect"; then
    ok "$fixture — has \"$expect\""
  else
    bad "$fixture — missing \"$expect\""
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

echo "event payloads"
run_case push                     push.json                        "🔀 Push · main"
run_case push                     push.json                        "👤 AmineMabrouk17 · 9f3c2d1"
run_case push                     push.json                        "feat: add landing programme"
run_case push                     push.json                        "compare/1111111...9f3c2d1"
run_case pull_request             pull_request-opened.json         "🔀 PR #42 · opened"
run_case pull_request             pull_request-opened.json         "feat/dark-mode → main"
run_case pull_request             pull_request-opened.json         "+12 −3 · 2 commits"
run_case pull_request             pull_request-merged.json         "PR #42 · merged"
run_case pull_request_review      pull_request_review.json         "👀 Review approved on PR #42"
run_case issue_comment            issue_comment.json               "💬 Comment on PR #42"
run_case issue_comment            issue_comment.json               "split this into two commits"
run_case release                  release.json                     "🏷️ Release v1.2.0"
run_case create                   create.json                      "🌿 branch create · feat/new-thing"

# A comment on a plain issue must not ping the chat.
if out="$(env NOTIFY_DRY_RUN=true TELEGRAM_TOKEN=dummy TELEGRAM_TO=dummy \
    GITHUB_EVENT_NAME=issue_comment \
    GITHUB_EVENT_PATH="$root/tests/fixtures/issue_comment-plain-issue.json" \
    bash scripts/notify.sh 2>&1)"; then
  if printf '%s' "$out" | grep -q "Nothing to notify"; then
    ok "issue comment on a plain issue is ignored"
  else
    bad "plain issue comment should be ignored"
  fi
else
  bad "plain issue comment exited non-zero"
fi

echo
echo "behaviour"

# Missing secrets must warn and exit 0, never fail a build.
if out="$(env NOTIFY_DRY_RUN=false TELEGRAM_TOKEN= TELEGRAM_TO= \
    GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$root/tests/fixtures/push.json" \
    bash scripts/notify.sh 2>&1)"; then
  check_contains "$out" "skipping Telegram notification" "missing secrets warn and skip"
else
  bad "missing secrets must not fail the build"
fi

# Half-configured secrets are a real mistake: fail loudly.
if env NOTIFY_DRY_RUN=false TELEGRAM_TOKEN=abc TELEGRAM_TO= \
    GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$root/tests/fixtures/push.json" \
    bash scripts/notify.sh >/dev/null 2>&1; then
  bad "token without chat id should fail"
else
  ok "token without chat id fails loudly"
fi

# Long messages are clamped before they reach Telegram's 4096-char limit.
long="$(printf 'x%.0s' $(seq 1 5000))"
out="$(env NOTIFY_DRY_RUN=true TELEGRAM_TOKEN=d TELEGRAM_TO=d \
    INPUT_MESSAGE="$long" bash scripts/notify.sh 2>&1)"
check_contains "$out" "dry run · 3500 chars" "message clamped to 3500 chars"

# Clamping must not cut a multi-byte character in half.
long="$(printf 'é%.0s' $(seq 1 5000))"
out="$(env NOTIFY_DRY_RUN=true TELEGRAM_TOKEN=d TELEGRAM_TO=d \
    INPUT_MESSAGE="$long" bash scripts/notify.sh 2>&1)"
if printf '%s' "$out" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; then
  ok "clamped message is still valid UTF-8"
else
  bad "clamping produced invalid UTF-8"
fi

echo
echo "transport (against tests/mock_telegram.py)"
port=8973
python3 tests/mock_telegram.py "$port" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
  sleep 0.1
done

if out="$(env NOTIFY_DRY_RUN=false TELEGRAM_TOKEN=ok:token TELEGRAM_TO=123456 \
    TELEGRAM_API_BASE="http://127.0.0.1:$port" \
    GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$root/tests/fixtures/push.json" \
    bash scripts/notify.sh 2>&1)"; then
  check_contains "$out" "notification sent" "successful send reports success"
else
  bad "successful send exited non-zero"
fi

if out="$(env NOTIFY_DRY_RUN=false TELEGRAM_TOKEN=bad:token TELEGRAM_TO=123456 \
    TELEGRAM_API_BASE="http://127.0.0.1:$port" \
    GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$root/tests/fixtures/push.json" \
    bash scripts/notify.sh 2>&1)"; then
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
