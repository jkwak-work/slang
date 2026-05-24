#!/usr/bin/env bash
set -u -o pipefail

# Watches configured GitHub PRs for new comments. When a new comment appears, it
# starts or reuses a tmux Codex session rooted in the configured PR worktree and
# sends the configured skill prompt to that session.

default_gh_command() {
  if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version &&
    command -v gh.exe >/dev/null 2>&1; then
    printf 'gh.exe\n'
    return 0
  fi

  printf 'gh\n'
}

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${CONFIG_FILE:-./pr-watch.conf}"
STATE_DIR="${STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pr-comment-codex-watch}"
POLL_SECONDS="${POLL_SECONDS:-60}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-prime}" # prime or trigger
CI_BOOTSTRAP_MODE="${CI_BOOTSTRAP_MODE:-$BOOTSTRAP_MODE}" # prime or trigger
WATCH_CI="${WATCH_CI:-true}"
COMMENT_PAGE_SIZE="${COMMENT_PAGE_SIZE:-100}"
CAPTURE_LINES="${CAPTURE_LINES:-250}"
MATCH_TAIL_LINES="${MATCH_TAIL_LINES:-50}"
GH_COMMAND="${GH_COMMAND:-$(default_gh_command)}"
CODEX_COMMAND="${CODEX_COMMAND:-codex}"
CODEX_FLAGS="${CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
SKILL_PREFIX="${SKILL_PREFIX:-}"
CODEX_SKILL="${CODEX_SKILL:-slang-resolve-pr-comments}"
FORK_REPO_SKILL="${FORK_REPO_SKILL:-review-on-fork-repo}"
CODEX_EXTRA_ARGS="${CODEX_EXTRA_ARGS:-}"
CODEX_START_WAIT_SECONDS="${CODEX_START_WAIT_SECONDS:-10}"
CODEX_START_ATTEMPTS="${CODEX_START_ATTEMPTS:-5}"
SEND_VERIFY_WAIT_SECONDS="${SEND_VERIFY_WAIT_SECONDS:-2}"
PROMPT_ENTER_DELAY_SECONDS="${PROMPT_ENTER_DELAY_SECONDS:-3}"
PROMPT_SEND_ATTEMPTS="${PROMPT_SEND_ATTEMPTS:-3}"
PROMPT_ENTER_ATTEMPTS="${PROMPT_ENTER_ATTEMPTS:-3}"
STATUS_ENABLED="${STATUS_ENABLED:-false}"
STATUS_ISSUE_REPO="${STATUS_ISSUE_REPO:-shader-slang/slang}"
STATUS_ISSUE_NUMBER="${STATUS_ISSUE_NUMBER:-}"
STATUS_UPDATE_SECONDS="${STATUS_UPDATE_SECONDS:-300}"
STATUS_BLOCK_START="<!-- pr-watch-status:start -->"
STATUS_BLOCK_END="<!-- pr-watch-status:end -->"
ONCE=false

declare -a REPOS=()
declare -a PRS=()
declare -a WORKTREES=()
declare -a SESSIONS=()
declare -a SKILLS=()
declare -A APPROVED_SIGNATURES=()
LAST_STATUS_UPDATE_EPOCH=0
LAST_STATUS_ISSUE_MESSAGE=""
STATUS_LINE_ACTIVE=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--config FILE] [--once]

Config format, one PR per line:
  https://github.com/owner/repo/pull/PR_NUMBER /absolute/worktree/path [tmux-session] [skill]

The skill field is a bare skill name. The watcher adds the CLI-specific prefix
when it sends the prompt ('$' for codex, '/' for claude).

Example:
  https://github.com/shader-slang/slang/pull/12345 /mnt/d/sbf/git/slang/pr-12345 slang-pr-12345 slang-resolve-pr-comments
  https://github.com/jkwak-work/slang/pull/175 /mnt/d/sbf/git/slang/pr-175 slang-pr-175 review-on-fork-repo

Environment knobs:
  POLL_SECONDS=60
  BOOTSTRAP_MODE=prime        # first run records existing comments without firing
  CI_BOOTSTRAP_MODE=prime     # first run records current CI failure state
  WATCH_CI=true
  GH_COMMAND="$GH_COMMAND"
  SKILL_PREFIX=             # default: '$' for codex, '/' for claude
  CODEX_SKILL="$CODEX_SKILL"
  FORK_REPO_SKILL="$FORK_REPO_SKILL"
  CODEX_FLAGS="$CODEX_FLAGS"
  CODEX_EXTRA_ARGS=--single-pass
  PROMPT_ENTER_DELAY_SECONDS=3
  PROMPT_SEND_ATTEMPTS=3
  PROMPT_ENTER_ATTEMPTS=3
  STATUS_ENABLED=false
  STATUS_ISSUE_REPO=$STATUS_ISSUE_REPO
  STATUS_ISSUE_NUMBER=$STATUS_ISSUE_NUMBER
  STATUS_UPDATE_SECONDS=$STATUS_UPDATE_SECONDS
  STATE_DIR=$STATE_DIR
EOF
}

print_startup_warning() {
  cat >&2 <<EOF
WARNING: $SCRIPT_NAME dispatches local agent sessions from GitHub PR comments and CI changes.
Run it only for trusted repositories/authors, preferably inside a sandboxed system; untrusted comments can attempt prompt injection.
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

finish_status_line() {
  if "$STATUS_LINE_ACTIVE" && [[ -t 2 ]]; then
    printf '\n' >&2
  fi
  STATUS_LINE_ACTIVE=false
}

print_replacing_status_line() {
  local status="$1"
  local cols pad

  [[ -t 2 ]] || return 0
  cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=80
  if [[ "${#status}" -ge "$cols" && "$cols" -gt 1 ]]; then
    status="${status:0:$((cols - 1))}"
  fi
  pad=$((cols - ${#status}))

  printf '\r\033[K%s' "$status" >&2
  if [[ "$pad" -gt 0 ]]; then
    printf '%*s' "$pad" '' >&2
  fi
  printf '\r' >&2
  STATUS_LINE_ACTIVE=true
}

print_status_line() {
  local watched_count="$1"
  local next_poll_seconds="$2"
  local status

  status="$(printf '[%s] last poll completed; watching %s PR(s); next poll in %ss' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$watched_count" \
    "$next_poll_seconds")"
  if [[ -n "$LAST_STATUS_ISSUE_MESSAGE" ]]; then
    status="$status; $LAST_STATUS_ISSUE_MESSAGE"
  fi
  print_replacing_status_line "$status"
}

record_status_issue_update() {
  LAST_STATUS_ISSUE_MESSAGE="$(printf 'status issue updated at %s' "$(date '+%H:%M:%S')")"
}

log() {
  finish_status_line
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

shell_quote() {
  printf '%q' "$1"
}

sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9_.-]+#-#g; s#^-+|-+$##g' \
    | cut -c 1-80 \
    | sed -E 's#-+$##'
}

state_key_for() {
  sanitize_name "$1-pr-$2"
}

line_count() {
  awk 'END { print NR + 0 }' "$1"
}

short_status_date() {
  date '+%m-%d %H:%M'
}

status_field_file_for() {
  local key="$1"
  local field="$2"
  printf '%s/%s.%s\n' "$STATE_DIR" "$key" "$field"
}

write_status_field() {
  local key="$1"
  local field="$2"
  local value="$3"
  printf '%s\n' "$value" >"$(status_field_file_for "$key" "$field")"
}

write_status_field_if_absent() {
  local key="$1"
  local field="$2"
  local value="$3"
  local file
  file="$(status_field_file_for "$key" "$field")"
  [[ -f "$file" ]] || printf '%s\n' "$value" >"$file"
}

read_status_field() {
  local key="$1"
  local field="$2"
  local fallback="${3:-}"
  local file value

  file="$(status_field_file_for "$key" "$field")"
  if [[ -f "$file" ]]; then
    IFS= read -r value <"$file" || value=""
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

ensure_status_defaults() {
  local key="$1"
  write_status_field_if_absent "$key" "date" "$(short_status_date)"
  write_status_field_if_absent "$key" "trigger" "none"
  write_status_field_if_absent "$key" "ci" "unknown"
}

record_status_event() {
  local key="$1"
  local trigger="$2"

  write_status_field "$key" "date" "$(short_status_date)"
  write_status_field "$key" "trigger" "$trigger"
}

ci_status_for_counts() {
  local failure_count="$1"
  local pending_count="$2"

  if [[ "$WATCH_CI" != "true" ]]; then
    printf 'not watched\n'
  elif [[ "$failure_count" -gt 0 && "$pending_count" -gt 0 ]]; then
    printf '%s failing, %s pending\n' "$failure_count" "$pending_count"
  elif [[ "$failure_count" -gt 0 ]]; then
    printf '%s failing\n' "$failure_count"
  elif [[ "$pending_count" -gt 0 ]]; then
    printf '%s pending\n' "$pending_count"
  else
    printf 'passing\n'
  fi
}

default_skill_for() {
  local repo="$1"

  if [[ "$repo" == jkwak-work/* ]]; then
    printf '%s\n' "$FORK_REPO_SKILL"
    return 0
  fi

  printf '%s\n' "$CODEX_SKILL"
}

skill_prefix_for_agent() {
  local command_name

  if [[ -n "$SKILL_PREFIX" ]]; then
    printf '%s\n' "$SKILL_PREFIX"
    return 0
  fi

  command_name="$(basename "${CODEX_COMMAND%% *}")"
  case "$command_name" in
    codex)
      printf '$\n'
      ;;
    claude|claude-code)
      printf '/\n'
      ;;
    *)
      printf '$\n'
      ;;
  esac
}

normalize_skill_name() {
  local skill="$1"
  skill="${skill#/}"
  skill="${skill#\$}"
  printf '%s\n' "$skill"
}

skill_invocation_for() {
  local repo="$1"
  local pr="$2"
  local skill="$3"
  local extra prefix

  [[ -n "$skill" ]] || skill="$(default_skill_for "$repo")"
  skill="$(normalize_skill_name "$skill")"
  prefix="$(skill_prefix_for_agent)"

  extra=""
  [[ -n "$CODEX_EXTRA_ARGS" ]] && extra=" $CODEX_EXTRA_ARGS"
  printf '%s%s %s%s\n' "$prefix" "$skill" "$pr" "$extra"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config|-c)
        [[ $# -ge 2 ]] || die "--config requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --once)
        ONCE=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

parse_config_line() {
  local raw line first second third fourth fifth extra repo pr worktree session skill
  raw="$1"
  line="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$line" ]] || return 0
  [[ "$line" =~ ^# ]] && return 0

  read -r first second third fourth fifth extra <<<"$line"
  [[ -z "${extra:-}" ]] || die "too many fields in config line: $raw"
  [[ -n "${first:-}" ]] || return 0

  if [[ "$first" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)/*$ ]]; then
    [[ -z "${fifth:-}" ]] || die "too many fields in config line: $raw"
    repo="${BASH_REMATCH[1]}"
    pr="${BASH_REMATCH[2]}"
    worktree="${second:-}"
    session="${third:-}"
    skill="${fourth:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^#[:space:]]+)#([0-9]+)$ ]]; then
    [[ -z "${fifth:-}" ]] || die "too many fields in config line: $raw"
    repo="${BASH_REMATCH[1]}"
    pr="${BASH_REMATCH[2]}"
    worktree="${second:-}"
    session="${third:-}"
    skill="${fourth:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)$ ]]; then
    [[ -z "${fifth:-}" ]] || die "too many fields in config line: $raw"
    repo="${BASH_REMATCH[1]}"
    pr="${BASH_REMATCH[2]}"
    worktree="${second:-}"
    session="${third:-}"
    skill="${fourth:-}"
  else
    repo="${first:-}"
    pr="${second:-}"
    worktree="${third:-}"
    session="${fourth:-}"
    skill="${fifth:-}"
  fi

  [[ -n "$repo" && -n "$pr" && -n "$worktree" ]] || die "bad config line: $raw"
  [[ "$pr" =~ ^[0-9]+$ ]] || die "bad PR number in config line: $raw"

  if [[ ( "${session:-}" == \$* || "${session:-}" == /* ) && -z "${skill:-}" ]]; then
    skill="$session"
    session=""
  fi
  skill="$(normalize_skill_name "${skill:-}")"

  if [[ -z "$session" ]]; then
    session="$(sanitize_name "codex-${repo}-pr-${pr}")"
  else
    session="$(sanitize_name "$session")"
  fi
  [[ -n "$session" ]] || die "empty tmux session name for config line: $raw"

  REPOS+=("$repo")
  PRS+=("$pr")
  WORKTREES+=("$worktree")
  SESSIONS+=("$session")
  SKILLS+=("${skill:-}")
}

read_config() {
  local line
  REPOS=()
  PRS=()
  WORKTREES=()
  SESSIONS=()
  SKILLS=()

  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_config_line "$line"
  done <"$CONFIG_FILE"

  [[ "${#REPOS[@]}" -gt 0 ]] || die "config contains no PRs: $CONFIG_FILE"
}

fetch_events() {
  local repo="$1"
  local pr="$2"
  local tmp raw
  tmp="$(mktemp)"

  raw="$(mktemp)"
  if ! "$GH_COMMAND" api --paginate "repos/$repo/issues/$pr/comments?per_page=$COMMENT_PAGE_SIZE" >"$raw"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  if ! jq -c '
        .[] |
        {
          id: ("issue:" + (.id | tostring)),
          kind: "issue-comment",
          createdAt: .created_at,
          updatedAt: .updated_at,
          author: (.user.login // ""),
          url: .html_url,
          body: (.body // "")
        } |
        select(((.body // "") | test("^\\s*\\[Agent\\]")) | not)
      ' "$raw" >>"$tmp"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  rm -f "$raw"

  raw="$(mktemp)"
  if ! "$GH_COMMAND" api --paginate "repos/$repo/pulls/$pr/comments?per_page=$COMMENT_PAGE_SIZE" >"$raw"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  if ! jq -c '
        .[] |
        {
          id: ("review-comment:" + (.id | tostring)),
          kind: "review-comment",
          createdAt: .created_at,
          updatedAt: .updated_at,
          author: (.user.login // ""),
          url: .html_url,
          body: (.body // "")
        } |
        select(((.body // "") | test("^\\s*\\[Agent\\]")) | not)
      ' "$raw" >>"$tmp"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  rm -f "$raw"

  raw="$(mktemp)"
  if ! "$GH_COMMAND" api --paginate "repos/$repo/pulls/$pr/reviews?per_page=$COMMENT_PAGE_SIZE" >"$raw"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  if ! jq -c '
        .[] |
        select((.body // "") | length > 0) |
        {
          id: ("review:" + (.id | tostring)),
          kind: "review",
          createdAt: .submitted_at,
          updatedAt: .submitted_at,
          author: (.user.login // ""),
          url: .html_url,
          body: (.body // "")
        } |
        select(((.body // "") | test("^\\s*\\[Agent\\]")) | not)
      ' "$raw" >>"$tmp"; then
    rm -f "$tmp" "$raw"
    return 1
  fi
  rm -f "$raw"

  jq -sc 'sort_by(.createdAt // .updatedAt // "") | .[]' "$tmp"
  rm -f "$tmp"
}

fetch_ci_attention_checks() {
  local repo="$1"
  local pr="$2"
  local raw rc
  raw="$(mktemp)"

  "$GH_COMMAND" pr checks "$pr" --repo "$repo" \
    --json bucket,completedAt,description,event,link,name,startedAt,state,workflow \
    >"$raw"
  rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 8 ]]; then
    rm -f "$raw"
    return 1
  fi

  if ! jq -c '
      .[] |
      select(.bucket == "fail" or .bucket == "cancel" or .bucket == "pending") |
      {
        bucket,
        workflow: (.workflow // ""),
        name: (.name // ""),
        state: (.state // ""),
        completedAt: (.completedAt // ""),
        startedAt: (.startedAt // ""),
        link: (.link // ""),
        description: (.description // ""),
        event: (.event // "")
      }
    ' "$raw"; then
    rm -f "$raw"
    return 1
  fi

  rm -f "$raw"
}

ci_attention_signature() {
  local checks_file="$1"
  jq -rsc '
    sort_by(.workflow, .name, .state, .completedAt, .link) |
    map([.bucket, .workflow, .name, .state, .completedAt, .link] | @tsv) |
    .[]
  ' "$checks_file" | signature_for
}

append_seen_ids() {
  local state_file="$1"
  local events_file="$2"
  local tmp
  tmp="$(mktemp)"
  {
    [[ -f "$state_file" ]] && cat "$state_file"
    jq -r '.id' "$events_file"
  } | awk 'NF' | sort -u >"$tmp"
  mv "$tmp" "$state_file"
}

collect_new_events() {
  local state_file="$1"
  local events_file="$2"
  local new_file="$3"
  local event id

  : >"$new_file"
  while IFS= read -r event; do
    [[ -n "$event" ]] || continue
    id="$(jq -r '.id' <<<"$event")" || continue
    if ! grep -Fxq -- "$id" "$state_file" 2>/dev/null; then
      printf '%s\n' "$event" >>"$new_file"
    fi
  done <"$events_file"
}

tmux_session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

tmux_window_exists() {
  local session="$1"
  local window="$2"
  tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -Fxq "$window"
}

target_for_session() {
  local session="$1"
  if tmux_window_exists "$session" "codex"; then
    printf '%s\n' "$session:codex.0"
  else
    printf '%s\n' "$session:0.0"
  fi
}

session_pane_targets() {
  local session="$1"
  local window_index

  while IFS= read -r window_index; do
    [[ -n "$window_index" ]] || continue
    tmux list-panes -t "$session:$window_index" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
  done < <(tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null)
}

pane_tail() {
  local target="$1"
  tmux capture-pane -p -J -S "-$CAPTURE_LINES" -t "$target" 2>/dev/null
}

pane_looks_like_codex() {
  local text="$1"
  local prompt_re
  prompt_re=$'(^|[[:space:]])\342\200\272[[:space:]]*$'
  printf '%s\n' "$text" | grep -qiE 'Codex|gpt-[0-9]|dangerously-bypass-approvals-and-sandbox' && return 0
  printf '%s\n' "$text" | grep -Eq "$prompt_re"
}

codex_prompt_has_pending_input() {
  local text="$1"
  codex_pending_input_line "$text" >/dev/null
}

codex_pending_input_line() {
  local text="$1"
  local line last_prompt_line prompt_re
  prompt_re=$'\342\200\272[[:space:]]*[^[:space:]]'

  last_prompt_line=""
  while IFS= read -r line; do
    if [[ "$line" == *$'\342\200\272'* ]]; then
      last_prompt_line="$line"
    fi
  done < <(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")

  [[ -n "$last_prompt_line" ]] || return 1
  [[ "$last_prompt_line" =~ $prompt_re ]] || return 1
  printf '%s\n' "$last_prompt_line"
}

prompt_visible_in_current_input() {
  local text="$1"
  local prompt="$2"
  local input_line

  input_line="$(codex_pending_input_line "$text")" || return 1
  [[ "$input_line" == *"$prompt"* ]]
}

pane_looks_working() {
  local text="$1"
  printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES" \
    | grep -Eq 'Working \(|esc to interrupt|background terminal running|^• (Ran|Explored|Edited|Read|Searched|Thinking|Working)'
}

last_prompt_file_for_target() {
  local target="$1"
  local safe_target
  safe_target="$(sanitize_name "$target")"
  printf '%s/%s.last-prompt\n' "$STATE_DIR" "$safe_target"
}

save_last_prompt_for_target() {
  local target="$1"
  local prompt="$2"
  printf '%s\n' "$prompt" >"$(last_prompt_file_for_target "$target")"
}

load_last_prompt_for_target() {
  local target="$1"
  cat "$(last_prompt_file_for_target "$target")" 2>/dev/null || true
}

clear_pending_codex_input() {
  local target="$1"
  tmux send-keys -t "$target" C-u
  sleep 1
}

paste_prompt_once() {
  local target="$1"
  local buffer_name="$2"
  local tmp="$3"

  tmux load-buffer -b "$buffer_name" "$tmp" || return 1
  tmux paste-buffer -b "$buffer_name" -t "$target" || {
    tmux delete-buffer -b "$buffer_name" 2>/dev/null || true
    return 1
  }
  tmux delete-buffer -b "$buffer_name" 2>/dev/null || true
}

submit_pending_prompt() {
  local target="$1"
  local prompt="$2"
  local attempt text

  for ((attempt = 1; attempt <= PROMPT_ENTER_ATTEMPTS; attempt++)); do
    sleep "$PROMPT_ENTER_DELAY_SECONDS"
    tmux send-keys -t "$target" Enter
    sleep "$SEND_VERIFY_WAIT_SECONDS"
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"

    if pane_looks_working "$text"; then
      return 0
    fi
    if ! codex_prompt_has_pending_input "$text"; then
      return 0
    fi
    if ! prompt_visible_in_current_input "$text" "$prompt"; then
      return 0
    fi
  done

  return 1
}

wait_for_codex_ready() {
  local target="$1"
  local attempt text
  for ((attempt = 1; attempt <= CODEX_START_ATTEMPTS; attempt++)); do
    sleep "$CODEX_START_WAIT_SECONDS"
    text="$(pane_tail "$target" || true)"
    if pane_looks_like_codex "$text"; then
      return 0
    fi
  done
  return 1
}

start_codex_in_pane() {
  local target="$1"
  local worktree="$2"
  local command
  command="cd $(shell_quote "$worktree") && $CODEX_COMMAND $CODEX_FLAGS"
  tmux send-keys -t "$target" "$command" Enter
  wait_for_codex_ready "$target"
}

ensure_codex_target() {
  local session="$1"
  local worktree="$2"
  local target text

  [[ -d "$worktree" ]] || {
    log "worktree does not exist: $worktree"
    return 1
  }

  if ! tmux_session_exists "$session"; then
    log "creating tmux session $session in $worktree"
    tmux new-session -d -s "$session" -n codex -c "$worktree" bash || return 1
    target="$session:codex.0"
    if ! start_codex_in_pane "$target" "$worktree"; then
      log "Codex did not become ready in $target"
      pane_tail "$target" >&2 || true
      return 1
    fi
    printf '%s\n' "$target"
    return 0
  fi

  if ! tmux_window_exists "$session" "codex"; then
    target="$(target_for_session "$session")"
    text="$(pane_tail "$target" || true)"
    if ! pane_looks_like_codex "$text"; then
      log "session $session exists; creating codex window in $worktree"
      tmux new-window -d -t "$session:" -n codex -c "$worktree" bash || return 1
      target="$session:codex.0"
      if ! start_codex_in_pane "$target" "$worktree"; then
        log "Codex did not become ready in $target"
        pane_tail "$target" >&2 || true
        return 1
      fi
    fi
  fi

  target="$(target_for_session "$session")"
  text="$(pane_tail "$target" || true)"
  if ! pane_looks_like_codex "$text"; then
    if ! start_codex_in_pane "$target" "$worktree"; then
      log "Codex did not become ready in existing target $target"
      pane_tail "$target" >&2 || true
      return 1
    fi
  fi

  printf '%s\n' "$target"
}

approval_prompt_present() {
  local text="$1"
  local tail_text
  tail_text="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"

  #printf '%s\n' "$tail_text" | grep -Fq "Permission rule Bash requires confirmation for this command." || return 1
  #printf '%s\n' "$tail_text" | grep -Fq "Do you want to proceed?" || return 1
  printf '%s\n' "$tail_text" | grep -Eq $'(^|[[:space:]])\342\235\257[[:space:]]+1[.] Yes' || return 1

  return 0
}

signature_for() {
  cksum | awk '{ print $1 ":" $2 }'
}

maybe_approve_prompt() {
  local target="$1"
  local text="$2"
  local prompt_tail signature

  if approval_prompt_present "$text"; then
    prompt_tail="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"
    signature="$(printf '%s\n' "$prompt_tail" | signature_for)"
    if [[ "${APPROVED_SIGNATURES[$target]:-}" != "$signature" ]]; then
      tmux send-keys -t "$target" Enter
      APPROVED_SIGNATURES["$target"]="$signature"
      log "approved Codex prompt in $target"
    fi
  fi
}

tmux_state_for_session() {
  local session="$1"
  local target text state

  if ! tmux_session_exists "$session"; then
    printf 'no session\n'
    return 0
  fi

  state="unknown"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    text="$(pane_tail "$target" || true)"
    [[ -n "$text" ]] || continue

    if approval_prompt_present "$text"; then
      printf 'needs approval\n'
      return 0
    fi

    if codex_prompt_has_pending_input "$text"; then
      state="pending input"
      continue
    fi

    if [[ "$state" != "pending input" ]]; then
      if pane_looks_working "$text"; then
        state="working"
      elif [[ "$state" == "unknown" ]] && pane_looks_like_codex "$text"; then
        state="idle"
      fi
    fi
  done < <(session_pane_targets "$session")

  printf '%s\n' "$state"
}

markdown_cell() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

render_status_dashboard_block() {
  local output_file="$1"
  local rows_file i repo pr session key label pr_url
  local date_value trigger_value ci_value state_raw previous_state state_value

  rows_file="$(mktemp)"
  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    repo="${REPOS[$i]}"
    pr="${PRS[$i]}"
    session="${SESSIONS[$i]}"
    key="$(state_key_for "$repo" "$pr")"
    ensure_status_defaults "$key"

    label="$repo#$pr"
    pr_url="https://github.com/$repo/pull/$pr"
    state_raw="$(tmux_state_for_session "$session")"
    previous_state="$(read_status_field "$key" "state" "")"
    if [[ "$state_raw" != "$previous_state" ]]; then
      write_status_field "$key" "state" "$state_raw"
      write_status_field "$key" "date" "$(short_status_date)"
    fi

    date_value="$(markdown_cell "$(read_status_field "$key" "date" "$(short_status_date)")")"
    trigger_value="$(markdown_cell "$(read_status_field "$key" "trigger" "none")")"
    ci_value="$(markdown_cell "$(read_status_field "$key" "ci" "unknown")")"
    state_value="$(markdown_cell "$state_raw")"

    printf '%s\t| [%s](%s) | %s | %s | %s | %s |\n' \
      "$label" "$label" "$pr_url" "$date_value" "$trigger_value" "$ci_value" "$state_value" \
      >>"$rows_file"
  done

  {
    printf '%s\n' "$STATUS_BLOCK_START"
    printf '# Agent Watcher Status\n\n'
    printf 'Last updated: %s\n\n' "$(date '+%m-%d %H:%M %Z')"
    printf '| PR | Date | Trigger | CI | State |\n'
    printf '|---|---|---|---|---|\n'
    sort "$rows_file" | cut -f2-
    printf '\n%s\n' "$STATUS_BLOCK_END"
  } >"$output_file"

  rm -f "$rows_file"
}

replace_status_block() {
  local current_file="$1"
  local block_file="$2"
  local output_file="$3"

  if grep -Fxq "$STATUS_BLOCK_START" "$current_file"; then
    awk -v start="$STATUS_BLOCK_START" -v end="$STATUS_BLOCK_END" -v block_file="$block_file" '
      BEGIN {
        while ((getline line < block_file) > 0) {
          block = block line ORS
        }
        skip = 0
      }
      $0 == start {
        printf "%s", block
        skip = 1
        next
      }
      skip && $0 == end {
        skip = 0
        next
      }
      !skip {
        print
      }
    ' "$current_file" >"$output_file"
  else
    {
      if [[ -s "$current_file" ]]; then
        cat "$current_file"
        printf '\n\n'
      fi
      cat "$block_file"
    } >"$output_file"
  fi
}

maybe_update_status_issue() {
  local now_epoch interval current_file block_file new_body_file

  [[ "$STATUS_ENABLED" == "true" ]] || return 0
  [[ -n "$STATUS_ISSUE_REPO" && -n "$STATUS_ISSUE_NUMBER" ]] || return 0

  interval="$STATUS_UPDATE_SECONDS"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  now_epoch="$(date +%s)"
  if ! "$ONCE" && [[ "$LAST_STATUS_UPDATE_EPOCH" -gt 0 ]] &&
    ((now_epoch - LAST_STATUS_UPDATE_EPOCH < interval)); then
    return 0
  fi
  LAST_STATUS_UPDATE_EPOCH="$now_epoch"

  current_file="$(mktemp)"
  block_file="$(mktemp)"
  new_body_file="$(mktemp)"

  render_status_dashboard_block "$block_file"
  if ! "$GH_COMMAND" issue view "$STATUS_ISSUE_NUMBER" --repo "$STATUS_ISSUE_REPO" --json body -q .body >"$current_file"; then
    log "failed to read status issue $STATUS_ISSUE_REPO#$STATUS_ISSUE_NUMBER"
    rm -f "$current_file" "$block_file" "$new_body_file"
    return 0
  fi

  replace_status_block "$current_file" "$block_file" "$new_body_file"
  if cmp -s "$current_file" "$new_body_file"; then
    rm -f "$current_file" "$block_file" "$new_body_file"
    return 0
  fi

  if "$GH_COMMAND" issue edit "$STATUS_ISSUE_NUMBER" --repo "$STATUS_ISSUE_REPO" --body-file "$new_body_file" >/dev/null; then
    record_status_issue_update
  else
    log "failed to update status issue $STATUS_ISSUE_REPO#$STATUS_ISSUE_NUMBER"
  fi

  rm -f "$current_file" "$block_file" "$new_body_file"
}

send_prompt_to_target() {
  local target="$1"
  local prompt="$2"
  local safe_target buffer_name tmp text attempt
  safe_target="$(sanitize_name "$target")"
  buffer_name="pr_watch_msg_$safe_target"
  tmp="$(mktemp "/tmp/pr-watch-prompt.$safe_target.XXXXXX")"

  save_last_prompt_for_target "$target" "$prompt"
  printf '%s' "$prompt" >"$tmp"

  for ((attempt = 1; attempt <= PROMPT_SEND_ATTEMPTS; attempt++)); do
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"
    if codex_prompt_has_pending_input "$text" && ! prompt_visible_in_current_input "$text" "$prompt"; then
      clear_pending_codex_input "$target"
    fi

    if ! paste_prompt_once "$target" "$buffer_name" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi

    sleep "$SEND_VERIFY_WAIT_SECONDS"
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"

    if prompt_visible_in_current_input "$text" "$prompt"; then
      if submit_pending_prompt "$target" "$prompt"; then
        rm -f "$tmp"
        return 0
      fi
      log "prompt still pending in $target after Enter; retrying"
    else
      log "prompt paste incomplete in $target; retrying"
    fi

    clear_pending_codex_input "$target"
  done

  rm -f "$tmp"
  return 1
}

comment_summary() {
  local events_file="$1"
  jq -r '
    def preview:
      (.body // "" | gsub("\r"; "") | split("\n")[0] | .[0:220]);
    "- [" + .kind + "] @" + .author + " " + (.createdAt // "") + ": " + .url
    + (if (preview | length) > 0 then "\n  " + preview else "" end)
  ' "$events_file"
}

ci_attention_summary() {
  local checks_file="$1"
  jq -r '
    "- [" + .bucket + "] " + .workflow + " / " + .name
    + " (" + .state
    + (if ((.completedAt // "") | length) > 0 then ", completed " + .completedAt else "" end)
    + ")"
    + (if ((.link // "") | length) > 0 then "\n  " + .link else "" end)
    + (if ((.description // "") | length) > 0 then "\n  " + .description else "" end)
  ' "$checks_file"
}

build_prompt() {
  local repo="$1"
  local pr="$2"
  local skill="$3"

  skill_invocation_for "$repo" "$pr" "$skill"
}

dispatch_watch_prompt() {
  local repo="$1"
  local pr="$2"
  local worktree="$3"
  local session="$4"
  local skill="$5"
  local comment_count="$6"
  local ci_failure_count="$7"
  local target prompt

  log "dispatching prompt for $repo#$pr to tmux session $session (comments=$comment_count, ci_failures=$ci_failure_count)"
  target="$(ensure_codex_target "$session" "$worktree")" || return 1
  prompt="$(build_prompt "$repo" "$pr" "$skill")"
  send_prompt_to_target "$target" "$prompt" || return 1
  log "sent prompt for $repo#$pr to $target"
}

process_watch_item() {
  local repo="$1"
  local pr="$2"
  local worktree="$3"
  local session="$4"
  local skill="$5"
  local key comment_state_file events_file new_file new_comment_count
  local ci_state_file checks_file ci_failure_count ci_pending_count previous_signature current_signature
  local comment_needs_dispatch=false ci_needs_dispatch=false ci_cleared=false ci_primed=false
  local ci_pending_changed=false
  local trigger_label

  key="$(state_key_for "$repo" "$pr")"
  ensure_status_defaults "$key"
  comment_state_file="$STATE_DIR/$key.seen"
  ci_state_file="$STATE_DIR/$key.ci-failures"
  events_file="$(mktemp)"
  new_file="$(mktemp)"
  checks_file="$(mktemp)"
  new_comment_count=0
  ci_failure_count=0
  ci_pending_count=0
  current_signature=""

  if fetch_events "$repo" "$pr" >"$events_file"; then
    if [[ ! -f "$comment_state_file" ]]; then
      : >"$comment_state_file"
      if [[ "$BOOTSTRAP_MODE" != "trigger" ]]; then
        append_seen_ids "$comment_state_file" "$events_file"
        log "primed $repo#$pr with $(line_count "$events_file") existing comment event(s)"
      else
        collect_new_events "$comment_state_file" "$events_file" "$new_file"
      fi
    else
      collect_new_events "$comment_state_file" "$events_file" "$new_file"
    fi

    new_comment_count="$(line_count "$new_file")"
    if [[ "$new_comment_count" -gt 0 ]]; then
      comment_needs_dispatch=true
    fi
  else
    log "failed to fetch comments for $repo#$pr"
  fi

  if [[ "$WATCH_CI" == "true" ]]; then
    if fetch_ci_attention_checks "$repo" "$pr" >"$checks_file"; then
      ci_failure_count="$(jq -rs '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' "$checks_file")"
      ci_pending_count="$(jq -rs '[.[] | select(.bucket == "pending")] | length' "$checks_file")"
      current_signature="$(ci_attention_signature "$checks_file")"
      write_status_field "$key" "ci" "$(ci_status_for_counts "$ci_failure_count" "$ci_pending_count")"

      if [[ ! -f "$ci_state_file" ]]; then
        if [[ "$CI_BOOTSTRAP_MODE" != "trigger" ]]; then
          printf '%s\n' "$current_signature" >"$ci_state_file"
          log "primed $repo#$pr CI with $ci_failure_count current failure(s), $ci_pending_count pending check(s)"
          ci_primed=true
        else
          previous_signature=""
          if [[ "$ci_failure_count" -eq 0 ]]; then
            printf '%s\n' "$current_signature" >"$ci_state_file"
            previous_signature="$current_signature"
          fi
        fi
      else
        previous_signature="$(cat "$ci_state_file" 2>/dev/null || true)"
      fi

      if ! "$ci_primed"; then
        if [[ "$current_signature" != "${previous_signature-}" ]]; then
          if [[ "$ci_failure_count" -gt 0 ]]; then
            ci_needs_dispatch=true
          elif [[ "$ci_pending_count" -gt 0 ]]; then
            ci_pending_changed=true
          else
            ci_cleared=true
          fi
        fi
      fi
    else
      write_status_field "$key" "ci" "unknown"
      log "failed to fetch CI checks for $repo#$pr"
    fi
  else
    write_status_field "$key" "ci" "not watched"
  fi

  if "$ci_cleared"; then
    printf '%s\n' "$current_signature" >"$ci_state_file"
    record_status_event "$key" "CI cleared"
    log "CI failures cleared for $repo#$pr"
  fi

  if "$ci_pending_changed"; then
    printf '%s\n' "$current_signature" >"$ci_state_file"
    record_status_event "$key" "CI pending"
    log "CI pending for $repo#$pr"
  fi

  if "$comment_needs_dispatch" || "$ci_needs_dispatch"; then
    trigger_label=""
    if "$comment_needs_dispatch"; then
      trigger_label="comment"
    fi
    if "$ci_needs_dispatch"; then
      if [[ -n "$trigger_label" ]]; then
        trigger_label="$trigger_label + CI"
      else
        trigger_label="CI"
      fi
    fi

    if dispatch_watch_prompt "$repo" "$pr" "$worktree" "$session" "$skill" "$new_comment_count" "$ci_failure_count"; then
      record_status_event "$key" "$trigger_label"
      if "$comment_needs_dispatch"; then
        append_seen_ids "$comment_state_file" "$new_file"
      fi
      if "$ci_needs_dispatch"; then
        printf '%s\n' "$current_signature" >"$ci_state_file"
      fi
    else
      record_status_event "$key" "dispatch failed"
      log "dispatch failed for $repo#$pr; will retry pending comment/CI changes on next poll"
    fi
  fi

  rm -f "$events_file" "$new_file" "$checks_file"
}

recover_pending_watcher_prompt() {
  local target="$1"
  local text="$2"
  local last_prompt skill_token input_line

  codex_prompt_has_pending_input "$text" || return 0

  last_prompt="$(load_last_prompt_for_target "$target")"
  [[ -n "$last_prompt" ]] || return 0

  if prompt_visible_in_current_input "$text" "$last_prompt"; then
    if submit_pending_prompt "$target" "$last_prompt"; then
      log "submitted pending watcher prompt in $target"
    else
      log "pending watcher prompt in $target did not submit after Enter"
    fi
    return 0
  fi

  skill_token="${last_prompt%% *}"
  input_line="$(codex_pending_input_line "$text" 2>/dev/null || true)"
  if [[ "$input_line" == *"$skill_token"* ]]; then
    log "clearing incomplete watcher prompt in $target and resending"
    clear_pending_codex_input "$target"
    send_prompt_to_target "$target" "$last_prompt" || log "failed to resend watcher prompt to $target"
  fi
}

monitor_configured_sessions() {
  local i session target text

  for ((i = 0; i < ${#SESSIONS[@]}; i++)); do
    session="${SESSIONS[$i]}"
    tmux_session_exists "$session" || continue
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      text="$(pane_tail "$target" || true)"
      [[ -n "$text" ]] || continue
      maybe_approve_prompt "$target" "$text"
      recover_pending_watcher_prompt "$target" "$text"
    done < <(session_pane_targets "$session")
  done
}

main() {
  local i

  print_startup_warning
  parse_args "$@"
  need_command "$GH_COMMAND"
  need_command jq
  need_command tmux
  need_command grep
  need_command cksum
  need_command awk
  need_command tail
  need_command cmp
  need_command sort
  need_command cut
  need_command "$CODEX_COMMAND"

  mkdir -p "$STATE_DIR"
  "$GH_COMMAND" auth status >/dev/null || die "$GH_COMMAND is not authenticated"
  trap finish_status_line EXIT

  while true; do
    read_config
    for ((i = 0; i < ${#REPOS[@]}; i++)); do
      process_watch_item "${REPOS[$i]}" "${PRS[$i]}" "${WORKTREES[$i]}" "${SESSIONS[$i]}" "${SKILLS[$i]}"
    done
    monitor_configured_sessions
    maybe_update_status_issue

    print_status_line "${#REPOS[@]}" "$POLL_SECONDS"
    "$ONCE" && break
    sleep "$POLL_SECONDS"
  done
}

main "$@"
