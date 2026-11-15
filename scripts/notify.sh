#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# telegram-ci-notify — send a GitHub event summary to Telegram.
#
# Configuration comes from the environment. GitHub Actions provides every
# GITHUB_* variable listed below automatically; the INPUT_* ones are mapped
# from the action's `with:` block, and the two secrets from the caller's env.
#
#   TELEGRAM_TOKEN     bot token from @BotFather              (required)
#   TELEGRAM_TO        target chat id or @channel             (required unless INPUT_CHAT_ID)
#   INPUT_CHAT_ID      overrides TELEGRAM_TO
#   INPUT_MESSAGE      send this text verbatim instead of the event summary
#   INPUT_SILENT       "true" sends without a notification sound
#   INPUT_PROJECT_NAME display name used instead of owner/repo
#   NOTIFY_DRY_RUN     "true" prints the message instead of sending it
#
# Exit status: 0 when the message was sent, or when Telegram is not configured
# at all (notifications are best-effort and must not fail a build).
# ---------------------------------------------------------------------------
set -euo pipefail

MAX_LEN=3500   # Telegram's hard limit is 4096; leave headroom.
PAYLOAD="${GITHUB_EVENT_PATH:-}"

repo="${GITHUB_REPOSITORY:-unknown/repository}"
actor="${GITHUB_ACTOR:-unknown}"
server="${GITHUB_SERVER_URL:-https://github.com}"
run_url="$server/$repo/actions/runs/${GITHUB_RUN_ID:-0}"
api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"

token="${TELEGRAM_TOKEN:-}"
chat_id="${INPUT_CHAT_ID:-${TELEGRAM_TO:-}}"
silent="${INPUT_SILENT:-false}"
project="${INPUT_PROJECT_NAME:-}"
message="${INPUT_MESSAGE:-}"
dry_run="${NOTIFY_DRY_RUN:-false}"

display="${project:-$repo}"

fail() { printf '::error::%s\n' "$*"; exit 1; }
warn() { printf '::warning::%s\n' "$*"; }

# Collapse newlines and runs of whitespace into single spaces.
collapse() { tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

# Print the first N characters of stdin.
clip() { local n="${1:-200}" s; s="$(cat)"; printf '%s' "${s:0:n}"; }

# jq helpers over the event payload. Both degrade to empty output on error so
# a malformed payload never blocks the notification.
field() {
  [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD" ] || return 0
  jq -r "(${1}) // \"\"" "$PAYLOAD" 2>/dev/null || printf ''
}
list_len() {
  if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
    printf '0'
    return 0
  fi
  jq -r "(${1} // []) | length" "$PAYLOAD" 2>/dev/null || printf '0'
}

event_text() {
  local name="${GITHUB_EVENT_NAME:-unknown}"

  if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
    printf '📦 %s\n%s by %s\n%s' "$display" "$name" "$actor" "$run_url"
    return
  fi

  case "$name" in
    push)
      local heading="🔀 Push · ${GITHUB_REF_NAME:-}"
      if [ "${GITHUB_REF_TYPE:-branch}" = "tag" ]; then
        heading="🏷️ Tag · ${GITHUB_REF_NAME:-}"
      fi
      local sha msg url count compare
      sha="$(field '.head_commit.id' | cut -c1-7)"
      msg="$(field '.head_commit.message' | head -n 1 | collapse | clip 120)"
      url="$(field '.head_commit.url')"
      count="$(list_len '.commits')"
      compare="$(field '.compare')"
      printf '📦 %s\n%s\n👤 %s · %s\n%s\n%s' \
        "$display" "$heading" "$actor" "$sha" "$msg" "$url"
      if [ "${count:-0}" -gt 1 ] && [ -n "$compare" ]; then
        printf '\n%s' "$compare"
      fi
      ;;

    pull_request)
      local action="${EVENT_ACTION:-$(field '.action')}"
      local number title url head base commits adds dels sha merged label
      number="$(field '.pull_request.number')"
      title="$(field '.pull_request.title' | collapse | clip 160)"
      url="$(field '.pull_request.html_url')"
      head="$(field '.pull_request.head.ref')"
      base="$(field '.pull_request.base.ref')"
      commits="$(field '.pull_request.commits')"
      adds="$(field '.pull_request.additions')"
      dels="$(field '.pull_request.deletions')"
      sha="$(field '.pull_request.head.sha' | cut -c1-7)"
      merged="$(field '.pull_request.merged')"
      label="$(field '.label.name')"

      [ "$action" = "closed" ] && [ "$merged" = "true" ] && action="merged"
      [ "$action" = "synchronize" ] && action="new commits ($sha)"
      [ -n "$label" ] && action="$action · $label"

      printf '📦 %s\n🔀 PR #%s · %s\n%s\n%s → %s\n👤 %s\n+%s −%s · %s commits\n%s\n%s' \
        "$display" "$number" "$action" "$title" "$head" "$base" \
        "$actor" "$adds" "$dels" "$commits" "$url" "$run_url"
      ;;

    pull_request_review)
      local state number title url
      state="$(field '.review.state' | tr '_' ' ')"
      number="$(field '.pull_request.number')"
      title="$(field '.pull_request.title' | collapse | clip 160)"
      url="$(field '.review.html_url')"
      [ -z "$url" ] && url="$(field '.pull_request.html_url')"
      printf '📦 %s\n👀 Review %s on PR #%s\n%s\n👤 %s\n%s\n%s' \
        "$display" "$state" "$number" "$title" "$actor" "$url" "$run_url"
      ;;

    issue_comment)
      # Only comments on pull requests; plain issue chatter is noise.
      if [ -z "$(field '.issue.pull_request.url')" ]; then
        return 0
      fi
      local number title excerpt url
      number="$(field '.issue.number')"
      title="$(field '.issue.title' | collapse | clip 160)"
      excerpt="$(field '.comment.body' | collapse | clip 180)"
      url="$(field '.comment.html_url')"
      printf '📦 %s\n💬 Comment on PR #%s\n%s\n👤 %s\n“%s”\n%s\n%s' \
        "$display" "$number" "$title" "$actor" "$excerpt" "$url" "$run_url"
      ;;

    create|delete)
      local ref_type ref
      ref_type="$(field '.ref_type')"
      ref="$(field '.ref')"
      printf '📦 %s\n🌿 %s %s · %s\n👤 %s\n%s' \
        "$display" "$ref_type" "$name" "$ref" "$actor" "$run_url"
      ;;

    release)
      local tag rname url
      tag="$(field '.release.tag_name')"
      rname="$(field '.release.name' | collapse | clip 100)"
      url="$(field '.release.html_url')"
      printf '📦 %s\n🏷️ Release %s · %s\n👤 %s\n%s\n%s' \
        "$display" "$tag" "$rname" "$actor" "$url" "$run_url"
      ;;

    workflow_dispatch)
      printf '📦 %s\n🧪 Manual notification test\n👤 %s\n%s' \
        "$display" "$actor" "$run_url"
      ;;

    *)
      printf '📦 %s\n%s by %s\n%s' "$display" "$name" "$actor" "$run_url"
      ;;
  esac
}

send() {
  local text="$1" response body code
  local -a args=(
    -sS
    --retry 2
    --retry-connrefused
    --retry-delay 2
    --data-urlencode "chat_id=${chat_id}"
    --data-urlencode "text=${text}"
    --data-urlencode "disable_web_page_preview=true"
    -w '\n%{http_code}'
  )
  [ "$silent" = "true" ] && args+=(--data-urlencode "disable_notification=true")

  response="$(curl "${args[@]}" "${api_base}/bot${token}/sendMessage")" || true
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [ "$code" != "200" ]; then
    fail "Telegram API returned HTTP ${code:-000}: $(printf '%s' "$body" | clip 500)"
  fi
  if printf '%s' "$body" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
    printf 'Telegram notification sent.\n'
  else
    fail "Telegram API rejected the message: $(printf '%s' "$body" | clip 500)"
  fi
}

main() {
  local configured=0
  [ -n "$token" ] && configured=$((configured + 1))
  [ -n "$chat_id" ] && configured=$((configured + 1))

  if [ "$configured" -eq 1 ]; then
    fail "Only one of TELEGRAM_TOKEN / TELEGRAM_TO is set — both are required."
  fi

  [ -z "$message" ] && message="$(event_text)"

  # Nothing to say: e.g. a comment on a plain issue.
  if [ -z "$message" ]; then
    printf 'Nothing to notify for this event.\n'
    return 0
  fi

  message="${message:0:MAX_LEN}"

  if [ "$dry_run" = "true" ]; then
    printf -- '--- dry run · %d chars ---\n%s\n' "${#message}" "$message"
    return 0
  fi

  if [ "$configured" -eq 0 ]; then
    warn "TELEGRAM_TOKEN and/or TELEGRAM_TO are not set; skipping Telegram notification."
    return 0
  fi

  send "$message"
}

main "$@"
