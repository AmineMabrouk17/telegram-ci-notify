#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# telegram-ci-notify — send a GitHub event summary to Telegram.
#
# Configuration comes from the environment. GitHub Actions provides every
# GITHUB_* variable listed below automatically; the INPUT_* ones are mapped
# from the action's `with:` block, and the two secrets from the caller's env.
#
#   TELEGRAM_TOKEN            bot token from @BotFather        (required)
#   TELEGRAM_TO               chat id or @channel              (required unless INPUT_CHAT_ID)
#   INPUT_CHAT_ID             overrides TELEGRAM_TO
#   INPUT_MESSAGE             send this text verbatim instead of the event summary
#   INPUT_PROJECT_NAME        display name used instead of owner/repo
#   INPUT_FORMAT              html (default) or plain
#   INPUT_SILENT              auto (default), true, false
#   INPUT_PREVIEW_URL         exact preview URL for this PR
#   INPUT_PREVIEW_URL_TEMPLATE URL pattern, with {number} {repo} {branch} {sha} {actor}
#   INPUT_IMAGES_URL_TEMPLATE  URL pattern, additionally understands {preview_url}
#   NOTIFY_DRY_RUN            "true" prints the message instead of sending it
#
# Exit status: 0 when the message was sent, or when Telegram is not configured
# at all (notifications are best-effort and must not fail a build).
# ---------------------------------------------------------------------------
set -euo pipefail

# Bash 5.2+ substitutes `&` in ${var//x/y} with the matched text, which would
# turn `&lt;` into `<lt;` and mangle any URL containing `&`. Restore the old
# (literal) behaviour everywhere in this script.
shopt -u patsub_replacement 2>/dev/null || true

MAX_LEN=3500   # Telegram's hard limit is 4096; leave headroom.
PAYLOAD="${GITHUB_EVENT_PATH:-}"

repo="${GITHUB_REPOSITORY:-unknown/repository}"
actor="${GITHUB_ACTOR:-unknown}"
server="${GITHUB_SERVER_URL:-https://github.com}"
run_url="$server/$repo/actions/runs/${GITHUB_RUN_ID:-0}"
api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"

token="${TELEGRAM_TOKEN:-}"
chat_id="${INPUT_CHAT_ID:-${TELEGRAM_TO:-}}"
project="${INPUT_PROJECT_NAME:-}"
message="${INPUT_MESSAGE:-}"
format="${INPUT_FORMAT:-html}"
silent="${INPUT_SILENT:-auto}"
preview_url="${INPUT_PREVIEW_URL:-}"
preview_template="${INPUT_PREVIEW_URL_TEMPLATE:-}"
images_template="${INPUT_IMAGES_URL_TEMPLATE:-}"
dry_run="${NOTIFY_DRY_RUN:-false}"

display="${project:-$repo}"

# Filled in while the message is built.
BUTTONS=""
NOTIFY_OFF="true"
HTTP_CODE=""
HTTP_BODY=""

fail() { printf '::error::%s\n' "$*"; exit 1; }
warn() { printf '::warning::%s\n' "$*"; }

# Escape the three characters that matter inside Telegram HTML. The `&` case
# must come first, otherwise the ampersands introduced by the other two get
# escaped again.
esc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# Collapse newlines and runs of whitespace into single spaces.
collapse() { tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

# Print the first N characters of stdin.
clip() { local n="${1:-200}" s; s="$(cat)"; printf '%s' "${s:0:n}"; }

# Strip our own tags and undo the escaping, for the plain-text fallback.
to_plain() {
  sed -e 's/<[^>]*>//g' | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'
}

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

# --- buttons ---------------------------------------------------------------
# Rows are collected as "label<TAB>url" lines; a blank line separates rows.
add_row() {
  local spec row=""
  for spec in "$@"; do
    [ -z "${spec#*|}" ] && continue
    row+="${spec%%|*}"$'\t'"${spec#*|}"$'\n'
  done
  [ -z "$row" ] && return 0
  BUTTONS+="$row"$'\n'
}

keyboard_json() {
  [ -z "$BUTTONS" ] && return 0
  printf '%s' "$BUTTONS" | jq -R -s -c '
    split("\n")
    | reduce .[] as $line ({rows: [], row: []};
        if $line == ""
        then .rows += [.row] | .row = []
        else .row += [($line | split("\t") | {text: .[0], url: .[1]})]
        end)
    | (.rows + [.row]) | map(select(length > 0))
    | {inline_keyboard: .}
  '
}

# --- URLs ------------------------------------------------------------------
# render_url <template> [preview-url]
# Placeholders: {repo} {number} {branch} {sha} {actor} {preview_url}
# On a pull request, {branch}/{sha} are the PR head, not GitHub's `42/merge`.
render_url() {
  local t="$1"
  t="${t//\{repo\}/$repo}"
  t="${t//\{number\}/${PR_NUMBER:-}}"
  t="${t//\{branch\}/${PR_BRANCH:-${GITHUB_REF_NAME:-}}}"
  t="${t//\{sha\}/${PR_SHA:-${GITHUB_SHA:-}}}"
  t="${t//\{actor\}/$actor}"
  t="${t//\{preview_url\}/${2:-}}"
  printf '%s' "$t"
}

# --- message ---------------------------------------------------------------
event_text() {
  local name="${GITHUB_EVENT_NAME:-unknown}"

  if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
    add_row "Run|$run_url"
    printf '<b>%s</b>\n📦 %s · 👤 %s' "$(esc "$name")" "$(esc "$display")" "$(esc "$actor")"
    return
  fi

  local action="" repo_esc signature
  action="$(field '.action')"
  repo_esc="$(esc "$display")"
  signature="📦 ${repo_esc} · 👤 $(esc "$actor")"
  PR_NUMBER="$(field '.pull_request.number')"

  case "$name" in
    push)
      local heading msg sha count commit_url compare
      commit_url="$(field '.head_commit.url')"
      compare="$(field '.compare')"
      count="$(list_len '.commits')"
      sha="$(field '.head_commit.id' | cut -c1-7)"
      msg="$(field '.head_commit.message' | head -n 1 | collapse | clip 120)"

      if [ "${GITHUB_REF_TYPE:-branch}" = "tag" ]; then
        heading="<b>🏷️ Tag · <code>$(esc "${GITHUB_REF_NAME:-}")</code></b>"
      else
        heading="<b>🔀 Push · <code>$(esc "${GITHUB_REF_NAME:-}")</code></b>"
      fi

      printf '%s\n%s\n%s · <code>%s</code>' \
        "$heading" "$(esc "$msg")" "$signature" "$(esc "$sha")"

      local diff_url=""
      [ "${count:-0}" -gt 1 ] && diff_url="$compare"
      add_row "Commit|$commit_url" "Diff|$diff_url" "Run|$run_url"
      ;;

    pull_request)
      local number title url head base commits adds dels sha head_sha merged label
      local preview images
      number="$(field '.pull_request.number')"
      PR_NUMBER="$number"
      title="$(field '.pull_request.title' | collapse | clip 160)"
      url="$(field '.pull_request.html_url')"
      head="$(field '.pull_request.head.ref')"
      base="$(field '.pull_request.base.ref')"
      commits="$(field '.pull_request.commits')"
      adds="$(field '.pull_request.additions')"
      dels="$(field '.pull_request.deletions')"
      head_sha="$(field '.pull_request.head.sha')"
      sha="$(printf '%s' "$head_sha" | cut -c1-7)"
      merged="$(field '.pull_request.merged')"
      label="$(field '.label.name')"

      # {branch}/{sha} in a URL pattern mean the PR head, not refs/pull/42/merge.
      PR_BRANCH="$head"
      PR_SHA="$head_sha"

      [ "$action" = "closed" ] && [ "$merged" = "true" ] && action="merged"
      [ "$action" = "synchronize" ] && action="new commits ($sha)"
      [ -n "$label" ] && action="$action · $label"

      preview="$preview_url"
      if [ -z "$preview" ] && [ -n "$preview_template" ]; then
        preview="$(render_url "$preview_template")"
      fi
      images=""
      if [ -n "$images_template" ]; then
        images="$(render_url "$images_template" "$preview")"
        # A pattern built from the preview URL cannot resolve without one.
        case "$images_template" in
          *'{preview_url}'*) [ -z "$preview" ] && images="" ;;
        esac
      fi

      printf '<b>🔀 PR #%s · %s</b>\n%s\n<code>%s</code> → <code>%s</code>\n%s\n+%s −%s · %s commits' \
        "$(esc "$number")" "$(esc "$action")" "$(esc "$title")" \
        "$(esc "$head")" "$(esc "$base")" "$signature" \
        "$(esc "${adds:-0}")" "$(esc "${dels:-0}")" "$(esc "${commits:-0}")"

      add_row "PR|$url" "Preview|$preview" "Screenshots|$images"
      local files=""
      [ -n "$url" ] && files="${url}/files"
      add_row "Files|$files" "Run|$run_url"
      ;;

    pull_request_review)
      local state title url number
      state="$(field '.review.state' | tr '_' ' ')"
      title="$(field '.pull_request.title' | collapse | clip 160)"
      url="$(field '.review.html_url')"
      [ -z "$url" ] && url="$(field '.pull_request.html_url')"
      number="$(field '.pull_request.number')"
      PR_NUMBER="$number"

      printf '<b>👀 Review %s · PR #%s</b>\n%s\n%s' \
        "$(esc "$state")" "$(esc "$number")" "$(esc "$title")" "$signature"
      add_row "Review|$url" "PR|$(field '.pull_request.html_url')"
      ;;

    issue_comment)
      # Only comments on pull requests; plain issue chatter is noise.
      if [ -z "$(field '.issue.pull_request.url')" ]; then
        return 0
      fi
      local title excerpt url number
      title="$(field '.issue.title' | collapse | clip 160)"
      excerpt="$(field '.comment.body' | collapse | clip 180)"
      url="$(field '.comment.html_url')"
      number="$(field '.issue.number')"
      PR_NUMBER="$number"

      printf '<b>💬 Comment · PR #%s</b>\n%s\n“%s”\n%s' \
        "$(esc "$number")" "$(esc "$title")" "$(esc "$excerpt")" "$signature"
      add_row "Comment|$url" "PR|$(field '.issue.html_url')"
      ;;

    create|delete)
      local ref_type ref verb="created"
      ref_type="$(field '.ref_type')"
      ref="$(field '.ref')"
      [ "$name" = "delete" ] && verb="deleted"
      case "$ref_type" in
        branch) ref_type="Branch" ;;
        tag) ref_type="Tag" ;;
      esac
      printf '<b>🌿 %s %s</b>\n<code>%s</code>\n%s' \
        "$(esc "$ref_type")" "$verb" "$(esc "$ref")" "$signature"
      add_row "Run|$run_url"
      ;;

    release)
      local tag rname url
      tag="$(field '.release.tag_name')"
      rname="$(field '.release.name' | collapse | clip 100)"
      url="$(field '.release.html_url')"
      printf '<b>🏷️ Release %s</b>\n%s\n%s' "$(esc "$tag")" "$(esc "$rname")" "$signature"
      add_row "Release|$url" "Run|$run_url"
      ;;

    workflow_dispatch)
      printf '<b>🧪 Manual notification test</b>\n%s' "$signature"
      add_row "Run|$run_url"
      ;;

    *)
      printf '<b>%s</b>\n%s' "$(esc "$name")" "$signature"
      add_row "Run|$run_url"
      ;;
  esac
}

# --- transport -------------------------------------------------------------
post() { # <text> <parse_mode>
  local text="$1" parse="${2:-}" response
  local -a args=(
    -sS
    --retry 2
    --retry-connrefused
    --max-time 20
    --data-urlencode "chat_id=${chat_id}"
    --data-urlencode "text=${text}"
    --data-urlencode "disable_web_page_preview=true"
    --data-urlencode "disable_notification=${NOTIFY_OFF}"
    -w '\n%{http_code}'  )
  if [ -n "$parse" ]; then args+=(--data-urlencode "parse_mode=${parse}"); fi
  if [ -n "${REPLY_MARKUP:-}" ]; then args+=(--data-urlencode "reply_markup=${REPLY_MARKUP}"); fi

  response="$(curl "${args[@]}" "${api_base}/bot${token}/sendMessage")" || true
  HTTP_CODE="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"

  [ "$HTTP_CODE" = "200" ] || return 1
  printf '%s' "$HTTP_BODY" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'
}

api_error() {
  fail "Telegram API returned HTTP ${HTTP_CODE:-000}: $(printf '%s' "$HTTP_BODY" | clip 500)"
}

send() {
  local html="$1" plain="$2"

  if [ "$format" = "plain" ]; then
    post "$plain" "" || api_error
    printf 'Telegram notification sent (plain).\n'
    return 0
  fi

  if post "$html" "HTML"; then
    printf 'Telegram notification sent.\n'
    return 0
  fi

  # A malformed entity is the one failure worth retrying: the message itself is
  # fine, only the markup was rejected. Never lose a notification over a `<`.
  # Match Telegram's own wording, not the whole body: a chat id can contain
  # "parse" and would trigger a pointless retry that masks the real error.
  if printf '%s' "$HTTP_BODY" | grep -qi 'parse entities'; then
    warn "Telegram rejected the HTML markup; retrying as plain text."
    # Drop the keyboard too: if anything in the payload is what it dislikes,
    # a second rejection would lose the message entirely.
    REPLY_MARKUP=""
    post "$plain" "" || api_error
    printf 'Telegram notification sent (plain fallback).\n'
    return 0
  fi

  api_error
}

# --- main ------------------------------------------------------------------
main() {
  local configured=0
  [ -n "$token" ] && configured=$((configured + 1))
  [ -n "$chat_id" ] && configured=$((configured + 1))

  if [ "$configured" -eq 1 ]; then
    fail "Only one of TELEGRAM_TOKEN / TELEGRAM_TO is set — both are required."
  fi

  if [ -z "$message" ]; then
    # NOT a command substitution: event_text fills the BUTTONS global, which
    # would be lost in a subshell.
    local out
    out="$(mktemp)"
    event_text >"$out"
    message="$(cat "$out")"
    rm -f "$out"
  fi

  # Nothing to say: e.g. a comment on a plain issue.
  if [ -z "$message" ]; then
    printf 'Nothing to notify for this event.\n'
    return 0
  fi

  # `message:` is plain text, so it gets escaped like every other user string.
  if [ -n "${INPUT_MESSAGE:-}" ]; then
    message="$(esc "$message")"
  fi

  REPLY_MARKUP="$(keyboard_json)"
  message="${message:0:MAX_LEN}"
  # Do not leave a tag cut in half at the truncation point.
  message="$(printf '%s' "$message" | sed -e 's/<[^>]*$//')"

  local plain
  plain="$(printf '%s' "$message" | to_plain)"

  # auto: only a PR being opened or closed is worth a sound.
  if [ "$silent" = "true" ]; then
    NOTIFY_OFF="true"
  elif [ "$silent" = "false" ]; then
    NOTIFY_OFF="false"
  elif [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    case "$(field '.action')" in
      opened|closed) NOTIFY_OFF="false" ;;
      *) NOTIFY_OFF="true" ;;
    esac
  else
    NOTIFY_OFF="true"
  fi

  if [ "$dry_run" = "true" ]; then
    local shown="$message"
    [ "$format" = "plain" ] && shown="$plain"
    printf -- '--- dry run · %d chars · silent=%s ---\n%s\n' \
      "${#shown}" "$NOTIFY_OFF" "$shown"
    [ -n "$REPLY_MARKUP" ] && printf -- '--- keyboard ---\n%s\n' "$REPLY_MARKUP"
    return 0
  fi

  if [ "$configured" -eq 0 ]; then
    warn "TELEGRAM_TOKEN and/or TELEGRAM_TO are not set; skipping Telegram notification."
    return 0
  fi

  send "$message" "$plain"
}

main "$@"
