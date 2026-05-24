#!/usr/bin/env bash
set -u -o pipefail

# Watches configured GitHub PRs for new comments, and starts new issue worktrees
# for Copilot-labeled issues assigned to @me. PR rows dispatch
# slang-pr-resolve-comments; issue rows progress from implementation to PR
# creation and are replaced by the created PR URL when it is found.

default_host_command() {
  local command_name="$1"

  if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version &&
    command -v "$command_name.exe" >/dev/null 2>&1; then
    printf '%s.exe\n' "$command_name"
    return 0
  fi

  printf '%s\n' "$command_name"
}

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="${STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/watch-github}"
WATCH_STATE_FILE="$STATE_DIR/watch-github.conf"
POLL_SECONDS="${POLL_SECONDS:-60}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-prime}" # prime or trigger
CI_BOOTSTRAP_MODE="${CI_BOOTSTRAP_MODE:-$BOOTSTRAP_MODE}" # prime or trigger
WATCH_CI="${WATCH_CI:-true}"
WATCH_COPILOT_ISSUES="${WATCH_COPILOT_ISSUES:-true}"
COPILOT_LABEL="${COPILOT_LABEL:-Copilot}"
ISSUE_LIST_LIMIT="${ISSUE_LIST_LIMIT:-100}"
WATCH_ISSUE_REPO="${WATCH_ISSUE_REPO:-shader-slang/slang}"
PR_BASE_REPO="${PR_BASE_REPO:-}"
COMMENT_PAGE_SIZE="${COMMENT_PAGE_SIZE:-100}"
CAPTURE_LINES="${CAPTURE_LINES:-250}"
MATCH_TAIL_LINES="${MATCH_TAIL_LINES:-50}"
GH_COMMAND="${GH_COMMAND:-$(default_host_command gh)}"
GIT_COMMAND="${GIT_COMMAND:-$(default_host_command git)}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
AGENT_COMMAND="${AGENT_COMMAND:-codex}"
AGENT_FLAGS="${AGENT_FLAGS:-}"
AGENT_COMMAND_NAME=""
AGENT_READY_PATTERN="${AGENT_READY_PATTERN:-}"
AGENT_PROMPT_LINE_PATTERN="${AGENT_PROMPT_LINE_PATTERN:-}"
AGENT_PENDING_INPUT_PATTERN="${AGENT_PENDING_INPUT_PATTERN:-}"
AGENT_WORKING_PATTERN="${AGENT_WORKING_PATTERN:-}"
AGENT_APPROVAL_PATTERN="${AGENT_APPROVAL_PATTERN:-}"
AGENT_TRUST_PROMPT_PATTERN="${AGENT_TRUST_PROMPT_PATTERN:-}"
AGENT_SHELL_COMMAND_PATTERN="${AGENT_SHELL_COMMAND_PATTERN:-}"
AGENT_WINDOW_NAME="${AGENT_WINDOW_NAME:-}"
AGENT_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-}"
AGENT_SKILL_PREFIX="${AGENT_SKILL_PREFIX:-}"
AGENT_START_WAIT_SECONDS="${AGENT_START_WAIT_SECONDS:-10}"
AGENT_START_ATTEMPTS="${AGENT_START_ATTEMPTS:-5}"
SEND_VERIFY_WAIT_SECONDS="${SEND_VERIFY_WAIT_SECONDS:-2}"
PROMPT_ENTER_DELAY_SECONDS="${PROMPT_ENTER_DELAY_SECONDS:-3}"
PROMPT_SEND_ATTEMPTS="${PROMPT_SEND_ATTEMPTS:-3}"
PROMPT_ENTER_ATTEMPTS="${PROMPT_ENTER_ATTEMPTS:-3}"
STATUS_ENABLED=false
STATUS_ISSUE_REPO=""
STATUS_ISSUE_NUMBER=""
STATUS_BLOCK_START="<!-- pr-watch-status:start -->"
STATUS_BLOCK_END="<!-- pr-watch-status:end -->"
RESOLVE_SKILL="slang-pr-resolve-comments"
PR_CREATE_SKILL="slang-pr-create"
ONCE=false
HELP_REQUESTED=false

declare -a REPOS=()
declare -a PRS=()
declare -a ISSUES=()
declare -a WORKTREES=()
declare -a SESSIONS=()
declare -A APPROVED_SIGNATURES=()
LAST_STATUS_ISSUE_MESSAGE=""
STATUS_LINE_ACTIVE=false

finalize_agent_config() {
  local default_ready_pattern default_pending_input_pattern default_approval_pattern
  local default_prompt_line_pattern
  local codex_prompt_marker claude_prompt_marker prompt_gap

  AGENT_COMMAND_NAME="$(basename "${AGENT_COMMAND%% *}")"
  if [[ -z "$AGENT_COMMAND_NAME" ]]; then
    AGENT_COMMAND_NAME="agent"
  fi

  if [[ -z "$AGENT_FLAGS" ]]; then
    case "$AGENT_COMMAND_NAME" in
      codex)
        AGENT_FLAGS="--dangerously-bypass-approvals-and-sandbox"
        ;;
      claude|claude-code)
        # This option may put Claude into Sandbox mode which may cause other problems.
        #AGENT_FLAGS="--dangerously-skip-permissions"
        ;;
    esac
  fi

  codex_prompt_marker=$'\342\200\272'
  claude_prompt_marker=$'\342\235\257'
  prompt_gap=$'([[:space:]]|\302\240)*'

  default_ready_pattern="$AGENT_COMMAND_NAME"
  default_prompt_line_pattern="(^|[[:space:]])${codex_prompt_marker}|(^|[[:space:]])${claude_prompt_marker}"
  default_pending_input_pattern="(^|[[:space:]])${codex_prompt_marker}${prompt_gap}\\\$(${RESOLVE_SKILL}|${PR_CREATE_SKILL})|(^|[[:space:]])${claude_prompt_marker}${prompt_gap}/(${RESOLVE_SKILL}|${PR_CREATE_SKILL})"
  case "$AGENT_COMMAND_NAME" in
    codex)
      default_ready_pattern=$'Codex|gpt-[0-9]|(^|[[:space:]])\342\200\272[[:space:]]*$'
      default_prompt_line_pattern="(^|[[:space:]])${codex_prompt_marker}"
      default_pending_input_pattern="(^|[[:space:]])${codex_prompt_marker}${prompt_gap}\\\$(${RESOLVE_SKILL}|${PR_CREATE_SKILL})"
      ;;
    claude|claude-code)
      default_ready_pattern='Claude|(^|[[:space:]])>[[:space:]]*$'
      default_prompt_line_pattern="(^|[[:space:]])${claude_prompt_marker}"
      default_pending_input_pattern="(^|[[:space:]])${claude_prompt_marker}${prompt_gap}/(${RESOLVE_SKILL}|${PR_CREATE_SKILL})"
      ;;
  esac

  AGENT_READY_PATTERN="${AGENT_READY_PATTERN:-$default_ready_pattern}"
  AGENT_PROMPT_LINE_PATTERN="${AGENT_PROMPT_LINE_PATTERN:-$default_prompt_line_pattern}"
  AGENT_PENDING_INPUT_PATTERN="${AGENT_PENDING_INPUT_PATTERN:-$default_pending_input_pattern}"
  AGENT_WORKING_PATTERN="${AGENT_WORKING_PATTERN:-Working \(|esc to interrupt|background terminal running|^• (Ran|Explored|Edited|Read|Searched|Thinking|Working)}"
  default_approval_pattern=$'(^|[[:space:]])\342\235\257[[:space:]]+1[.] Yes'
  AGENT_APPROVAL_PATTERN="${AGENT_APPROVAL_PATTERN:-$default_approval_pattern}"
  AGENT_TRUST_PROMPT_PATTERN="${AGENT_TRUST_PROMPT_PATTERN:-Do you trust the contents of this directory[?]|1[.] Yes, continue|Press enter to continue}"
  AGENT_SHELL_COMMAND_PATTERN="${AGENT_SHELL_COMMAND_PATTERN:-^(bash|dash|sh|zsh|fish|cmd|cmd[.]exe|powershell|powershell[.]exe|pwsh|pwsh[.]exe)$}"
  AGENT_WINDOW_NAME="${AGENT_WINDOW_NAME:-$AGENT_COMMAND_NAME}"
  AGENT_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-$AGENT_WINDOW_NAME}"
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--agent [claude|codex]] [--once] [--status-issue URL]

Purpose:
  Watch GitHub PR comments, reviews, and CI checks, then dispatch
  $(skill_prefix_for_agent)$RESOLVE_SKILL <PR_NUMBER> to a tmux-hosted agent.
  Also create issue worktrees for Copilot-labeled issues assigned to @me.

Options:
  --agent [claude|codex]
                      Agent to run in tmux. Defaults to codex.
  --once              Run one polling pass and exit.
  --status-issue URL  Update this GitHub issue once per polling pass.

Details:
  See extras/watch-github.md.
EOF
}

print_startup_warning() {
  cat >&2 <<EOF
WARNING: $SCRIPT_NAME dispatches local agent sessions from GitHub PR comments, CI changes, and assigned Copilot issues.
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

  status="$(printf '[%s] last poll completed; watching %s item(s); next poll in %ss' \
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

is_wsl_environment() {
  [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version
}

command_uses_windows_paths() {
  local command_name="$1"
  local resolved

  is_wsl_environment || return 1
  [[ "$command_name" == *.exe ]] && return 0

  resolved="$(command -v "$command_name" 2>/dev/null || true)"
  [[ "$resolved" == *.exe ]]
}

path_for_host_command() {
  local command_name="$1"
  local path="$2"

  if command_uses_windows_paths "$command_name"; then
    command -v wslpath >/dev/null 2>&1 ||
      die "missing required command for Windows path conversion: wslpath"
    wslpath -w "$path"
  else
    printf '%s\n' "$path"
  fi
}

path_for_gh_file_arg() {
  path_for_host_command "$GH_COMMAND" "$1"
}

path_for_git_path_arg() {
  path_for_host_command "$GIT_COMMAND" "$1"
}

command_path_for_log() {
  command -v "$1" 2>/dev/null || printf 'not found'
}

log_startup_tools() {
  log "using GitHub CLI: $(command_path_for_log "$GH_COMMAND")"
  log "using Git: $(command_path_for_log "$GIT_COMMAND")"
  log "using agent: $(command_path_for_log "${AGENT_COMMAND%% *}")"
  log "using tmux: $(command_path_for_log tmux)"
  log "using jq: $(command_path_for_log jq)"
  log "using PR create skill: $(skill_prefix_for_agent)$PR_CREATE_SKILL"
  log "watch state file: $WATCH_STATE_FILE"
  log "watch issue repo: $WATCH_ISSUE_REPO; Copilot issue discovery=$WATCH_COPILOT_ISSUES; CI watch=$WATCH_CI"
}

require_repo_root() {
  local cdup is_bare

  if ! "$GIT_COMMAND" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "must be run from the root of a git worktree"
  fi

  cdup="$("$GIT_COMMAND" rev-parse --show-cdup)" ||
    die "failed to determine git repository root"
  [[ -z "$cdup" ]] || die "must be run from the root of a git worktree"

  is_bare="$("$GIT_COMMAND" rev-parse --is-bare-repository)" ||
    die "failed to determine whether the repository is bare"
  [[ "$is_bare" == "false" ]] || die "must be run from a non-bare git worktree"

  "$GIT_COMMAND" worktree list >/dev/null ||
    die "must be run from a repository that supports git worktree"
}

resolve_default_branch() {
  local remote_head

  if [[ -n "$DEFAULT_BRANCH" ]]; then
    printf '%s\n' "$DEFAULT_BRANCH"
    return 0
  fi

  remote_head="$("$GIT_COMMAND" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ "$remote_head" == origin/* ]]; then
    printf '%s\n' "${remote_head#origin/}"
    return 0
  fi
  if [[ -n "$remote_head" ]]; then
    printf '%s\n' "$remote_head"
    return 0
  fi

  die "failed to determine default branch; set DEFAULT_BRANCH explicitly"
}

require_default_branch() {
  local current_branch default_branch

  current_branch="$("$GIT_COMMAND" branch --show-current)" ||
    die "failed to determine current branch"
  [[ -n "$current_branch" ]] || die "must be run from the default branch; HEAD is detached"

  default_branch="$(resolve_default_branch)"
  [[ "$current_branch" == "$default_branch" ]] ||
    die "must be run from the default branch ($default_branch); current branch is $current_branch"
}

repo_from_github_url() {
  local url="$1"
  local owner name

  if [[ "$url" =~ ^https://github\.com/([^/[:space:]]+)/([^/[:space:]]+)(\.git)?/?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]%.git}"
    printf '%s/%s\n' "$owner" "$name"
    return 0
  fi

  if [[ "$url" =~ ^git@github\.com:([^/[:space:]]+)/([^/[:space:]]+)(\.git)?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]%.git}"
    printf '%s/%s\n' "$owner" "$name"
    return 0
  fi

  if [[ "$url" =~ ^ssh://git@github\.com/([^/[:space:]]+)/([^/[:space:]]+)(\.git)?/?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]%.git}"
    printf '%s/%s\n' "$owner" "$name"
    return 0
  fi

  return 1
}

resolve_origin_repo() {
  local origin_url origin_repo

  if [[ -n "$PR_BASE_REPO" ]]; then
    printf '%s\n' "$PR_BASE_REPO"
    return 0
  fi

  origin_url="$("$GIT_COMMAND" remote get-url origin 2>/dev/null)" ||
    die "failed to read origin remote URL"
  origin_repo="$(repo_from_github_url "$origin_url")" ||
    die "origin remote is not a GitHub repository URL; set PR_BASE_REPO explicitly"
  printf '%s\n' "$origin_repo"
}

resolve_issue_repo() {
  local repo

  if [[ -n "$WATCH_ISSUE_REPO" ]]; then
    printf '%s\n' "$WATCH_ISSUE_REPO"
    return 0
  fi

  repo="$("$GH_COMMAND" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" ||
    die "failed to determine GitHub issue repo; set WATCH_ISSUE_REPO explicitly"
  [[ -n "$repo" ]] || die "failed to determine GitHub issue repo; set WATCH_ISSUE_REPO explicitly"
  printf '%s\n' "$repo"
}

resolve_repo_default_branch() {
  local repo="$1"
  local branch

  branch="$("$GH_COMMAND" repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [[ -n "$branch" ]] || branch="$(resolve_default_branch)"
  printf '%s\n' "$branch"
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

state_key_for_issue() {
  sanitize_name "$1-issue-$2"
}

state_key_for_item() {
  local repo="$1"
  local pr="$2"
  local issue="$3"

  if [[ -n "$pr" ]]; then
    state_key_for "$repo" "$pr"
  else
    state_key_for_issue "$repo" "$issue"
  fi
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

skill_prefix_for_agent() {
  if [[ -n "$AGENT_SKILL_PREFIX" ]]; then
    printf '%s\n' "$AGENT_SKILL_PREFIX"
    return 0
  fi

  case "$AGENT_COMMAND_NAME" in
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

resolve_prompt_for_pr() {
  local pr="$1"
  local prefix

  prefix="$(skill_prefix_for_agent)"
  printf '%s%s %s\n' "$prefix" "$RESOLVE_SKILL" "$pr"
}

resolve_prompt_for_pr_url() {
  local pr_url="$1"
  local prefix

  prefix="$(skill_prefix_for_agent)"
  printf '%s%s %s\n' "$prefix" "$RESOLVE_SKILL" "$pr_url"
}

resolve_prompt_for_issue() {
  local repo="$1"
  local issue="$2"

  printf 'Work on GitHub issue https://github.com/%s/issues/%s in this worktree. Read the issue and comments, implement the requested changes, and run appropriate focused validation. Commit when the implementation is ready for the review.\n' \
    "$repo" "$issue"
}

resolve_internal_review_prompt() {
  local pr_repo="$1"
  local prefix

  prefix="$(skill_prefix_for_agent)"
  printf '%s%s --repo %s\n' "$prefix" "$PR_CREATE_SKILL" "$pr_repo"
}

parse_status_issue_url() {
  local url="$1"

  if [[ "$url" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/issues/([0-9]+)/*$ ]]; then
    STATUS_ISSUE_REPO="${BASH_REMATCH[1]}"
    STATUS_ISSUE_NUMBER="${BASH_REMATCH[2]}"
    STATUS_ENABLED=true
    return 0
  fi

  die "bad status issue URL: $url"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -ge 2 ]] || die "--agent requires an agent command"
        case "$2" in
          codex|claude)
            ;;
          *)
            die "bad --agent value: $2; expected codex or claude"
            ;;
        esac
        AGENT_COMMAND="$2"
        shift 2
        ;;
      --once)
        ONCE=true
        shift
        ;;
      --status-issue)
        [[ $# -ge 2 ]] || die "--status-issue requires a GitHub issue URL"
        parse_status_issue_url "$2"
        shift 2
        ;;
      --help|-h)
        HELP_REQUESTED=true
        shift
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

parse_watch_state_fields() {
  local raw="$1"
  local repo_var="$2"
  local pr_var="$3"
  local issue_var="$4"
  local worktree_var="$5"
  local session_var="$6"
  local line first second third fourth extra
  local value_repo value_pr value_issue value_worktree value_session

  line="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -n "$line" ]] || return 1
  [[ "$line" =~ ^# ]] && return 1

  read -r first second third fourth extra <<<"$line"
  [[ -z "${extra:-}" ]] || die "too many fields in watch state line: $raw"
  [[ -n "${first:-}" ]] || return 1
  value_pr=""
  value_issue=""

  if [[ "$first" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)/*$ ]]; then
    [[ -z "${fourth:-}" ]] || die "too many fields in watch state line: $raw"
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/issues/([0-9]+)/*$ ]]; then
    [[ -z "${fourth:-}" ]] || die "too many fields in watch state line: $raw"
    value_repo="${BASH_REMATCH[1]}"
    value_issue="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^#[:space:]]+)#([0-9]+)$ ]]; then
    [[ -z "${fourth:-}" ]] || die "too many fields in watch state line: $raw"
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)$ ]]; then
    [[ -z "${fourth:-}" ]] || die "too many fields in watch state line: $raw"
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^[:space:]]+)/issues/([0-9]+)$ ]]; then
    [[ -z "${fourth:-}" ]] || die "too many fields in watch state line: $raw"
    value_repo="${BASH_REMATCH[1]}"
    value_issue="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  else
    value_repo="${first:-}"
    value_pr="${second:-}"
    value_worktree="${third:-}"
    value_session="${fourth:-}"
  fi

  [[ -n "$value_repo" && -n "$value_worktree" ]] || die "bad watch state line: $raw"
  if [[ -n "$value_pr" ]]; then
    [[ "$value_pr" =~ ^[0-9]+$ ]] || die "bad PR number in watch state line: $raw"
  elif [[ -n "$value_issue" ]]; then
    [[ "$value_issue" =~ ^[0-9]+$ ]] || die "bad issue number in watch state line: $raw"
  else
    die "bad watch state line: $raw"
  fi

  if [[ -z "$value_session" ]]; then
    if [[ -n "$value_pr" ]]; then
      value_session="$(sanitize_name "$AGENT_SESSION_PREFIX-${value_repo}-pr-${value_pr}")"
    else
      value_session="$(sanitize_name "issue-${value_issue}")"
    fi
  else
    value_session="$(sanitize_name "$value_session")"
  fi
  [[ -n "$value_session" ]] || die "empty tmux session name for watch state line: $raw"

  printf -v "$repo_var" '%s' "$value_repo"
  printf -v "$pr_var" '%s' "$value_pr"
  printf -v "$issue_var" '%s' "$value_issue"
  printf -v "$worktree_var" '%s' "$value_worktree"
  printf -v "$session_var" '%s' "$value_session"
  return 0
}

parse_watch_state_line() {
  local raw="$1"
  local repo pr issue worktree session

  parse_watch_state_fields "$raw" repo pr issue worktree session || return 0

  REPOS+=("$repo")
  PRS+=("$pr")
  ISSUES+=("$issue")
  WORKTREES+=("$worktree")
  SESSIONS+=("$session")
}

read_watch_state() {
  local line
  REPOS=()
  PRS=()
  ISSUES=()
  WORKTREES=()
  SESSIONS=()

  if [[ ! -f "$WATCH_STATE_FILE" ]]; then
    if [[ "$WATCH_COPILOT_ISSUES" == "true" ]]; then
      : >"$WATCH_STATE_FILE"
    else
      die "watch state file not found: $WATCH_STATE_FILE"
    fi
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_watch_state_line "$line"
  done <"$WATCH_STATE_FILE"

  [[ "${#REPOS[@]}" -gt 0 || "$WATCH_COPILOT_ISSUES" == "true" ]] ||
    die "watch state contains no items: $WATCH_STATE_FILE"
}

watch_state_has_item() {
  local repo="$1"
  local pr="$2"
  local issue="$3"
  local i

  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    [[ "${REPOS[$i]}" == "$repo" ]] || continue
    if [[ -n "$pr" && "${PRS[$i]}" == "$pr" ]]; then
      return 0
    fi
    if [[ -n "$issue" && "${ISSUES[$i]}" == "$issue" ]]; then
      return 0
    fi
  done

  return 1
}

append_watch_state_item() {
  local repo="$1"
  local pr="$2"
  local issue="$3"
  local worktree="$4"
  local session="$5"
  local item_url

  if [[ -n "$pr" ]]; then
    item_url="https://github.com/$repo/pull/$pr"
  else
    item_url="https://github.com/$repo/issues/$issue"
  fi

  printf '%s %s %s\n' "$item_url" "$worktree" "$session" >>"$WATCH_STATE_FILE"
  log "appended watch-state item: $item_url worktree=$worktree session=$session"
  REPOS+=("$repo")
  PRS+=("$pr")
  ISSUES+=("$issue")
  WORKTREES+=("$worktree")
  SESSIONS+=("$session")
}

replace_watch_state_item() {
  local old_repo="$1"
  local old_pr="$2"
  local old_issue="$3"
  local new_repo="$4"
  local new_pr="$5"
  local worktree="$6"
  local session="$7"
  local tmp line repo pr issue parsed_worktree parsed_session replaced=false

  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ! "$replaced" &&
      parse_watch_state_fields "$line" repo pr issue parsed_worktree parsed_session 2>/dev/null &&
      [[ "$repo" == "$old_repo" ]] &&
      { [[ -n "$old_pr" && "$pr" == "$old_pr" ]] ||
        [[ -n "$old_issue" && "$issue" == "$old_issue" ]]; }; then
      : "$parsed_worktree" "$parsed_session"
      printf 'https://github.com/%s/pull/%s %s %s\n' "$new_repo" "$new_pr" "$worktree" "$session" >>"$tmp"
      replaced=true
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$WATCH_STATE_FILE"

  if ! "$replaced"; then
    printf 'https://github.com/%s/pull/%s %s %s\n' "$new_repo" "$new_pr" "$worktree" "$session" >>"$tmp"
  fi

  mv "$tmp" "$WATCH_STATE_FILE"
  log "updated watch-state item to https://github.com/$new_repo/pull/$new_pr worktree=$worktree session=$session"
}

parse_github_pr_url() {
  local url="$1"
  local repo_var="$2"
  local pr_var="$3"

  [[ "$url" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)/*$ ]] ||
    return 1
  printf -v "$repo_var" '%s' "${BASH_REMATCH[1]}"
  printf -v "$pr_var" '%s' "${BASH_REMATCH[2]}"
}

branch_for_worktree() {
  local worktree="$1"
  git_in_worktree "$worktree" branch --show-current 2>/dev/null
}

git_in_worktree() {
  local worktree="$1"
  local git_worktree
  shift
  git_worktree="$(path_for_git_path_arg "$worktree")"
  "$GIT_COMMAND" -C "$git_worktree" "$@" | tr -d '\r'
}

git_commit_for_ref() {
  local worktree="$1"
  local ref="$2"
  git_in_worktree "$worktree" rev-parse --verify "$ref^{commit}" 2>/dev/null
}

worktree_head_matches_base() {
  local worktree="$1"
  local pr_repo="$2"
  local base_branch head_sha base_sha

  base_branch="$(resolve_repo_default_branch "$pr_repo")"
  head_sha="$(git_commit_for_ref "$worktree" HEAD || true)"
  base_sha="$(git_commit_for_ref "$worktree" "refs/remotes/origin/$base_branch" || true)"
  [[ -n "$base_sha" ]] || base_sha="$(git_commit_for_ref "$worktree" "origin/$base_branch" || true)"
  [[ -n "$base_sha" ]] || base_sha="$(git_commit_for_ref "$worktree" "$base_branch" || true)"

  if [[ -z "$head_sha" || -z "$base_sha" ]]; then
    return 2
  fi

  [[ "$head_sha" == "$base_sha" ]]
}

fetch_copilot_issues() {
  local repo="$1"

  "$GH_COMMAND" issue list \
    --repo "$repo" \
    --assignee "@me" \
    --label "$COPILOT_LABEL" \
    --search "-linked:pr" \
    --state open \
    --limit "$ISSUE_LIST_LIMIT" \
    --json number,closedByPullRequestsReferences,url \
    --jq '.[] | select((.closedByPullRequestsReferences // []) | length == 0) | .number'
}

create_issue_worktree() {
  local repo="$1"
  local issue="$2"
  local worktree_name="issue-$issue"
  local worktree worktree_log

  if [[ -n "$(read_status_field "$(state_key_for_issue "$repo" "$issue")" "completed-pr" "")" ]]; then
    return 1
  fi

  worktree="$(dirname "$(pwd -P)")/$worktree_name"
  worktree_log="$STATE_DIR/$(state_key_for_issue "$repo" "$issue").worktree-add.log"
  if [[ ! -d "$worktree" ]]; then
    log "creating issue worktree $worktree_name for $repo#$issue"
    if ! GH_REPO="$repo" GIT_EXE="$GIT_COMMAND" GH_EXE="$GH_COMMAND" \
      extras/git-worktree-add.sh --issue "$issue" "$worktree_name" >"$worktree_log" 2>&1; then
      log "git-worktree-add failed for $repo#$issue; see $worktree_log"
      return 1
    fi
  else
    log "resuming existing issue worktree $worktree_name for $repo#$issue"
  fi

  printf '%s\n' "$worktree"
}

worktree_for_existing_issue_session() {
  local session="$1"
  local expected_worktree="$2"
  local session_path

  if session_path="$(current_path_for_session "$session")"; then
    printf '%s\n' "$session_path"
    return 0
  fi

  [[ -d "$expected_worktree" ]] || return 1
  printf '%s\n' "$expected_worktree"
}

start_discovered_issue() {
  local repo="$1"
  local issue="$2"
  local key worktree_name expected_worktree worktree target state

  key="$(state_key_for_issue "$repo" "$issue")"
  worktree_name="issue-$issue"
  expected_worktree="$(dirname "$(pwd -P)")/$worktree_name"

  if tmux_session_exists "$worktree_name"; then
    log "resuming existing tmux session $worktree_name for $repo#$issue"
    if ! worktree="$(worktree_for_existing_issue_session "$worktree_name" "$expected_worktree")"; then
      log "existing tmux session $worktree_name has no usable worktree; will retry from issue discovery"
      return 1
    fi
  else
    worktree="$(create_issue_worktree "$repo" "$issue")" || return 1
  fi

  if ! target="$(ensure_agent_target "$worktree_name" "$worktree")"; then
    log "failed to start agent for $repo#$issue; will retry from issue discovery"
    return 1
  fi
  state="$(tmux_state_for_session "$worktree_name")"
  if [[ "$state" == "no session" || "$state" == "unknown" ]]; then
    log "agent is not live in $worktree_name after startup (state=$state); will retry from issue discovery"
    return 1
  fi

  append_watch_state_item "$repo" "" "$issue" "$worktree" "$worktree_name"
  record_status_event "$key" "issue started"
  write_status_field "$key" "phase" "progress"
  write_status_field "$key" "ci" "not watched"
  log "watching issue $repo#$issue in $worktree_name after starting agent at $target"
}

discover_copilot_issues() {
  local repo issue

  [[ "$WATCH_COPILOT_ISSUES" == "true" ]] || return 0
  repo="$(resolve_issue_repo)"

  while IFS= read -r issue; do
    [[ -n "$issue" ]] || continue
    watch_state_has_item "$repo" "" "$issue" && continue
    [[ -n "$(read_status_field "$(state_key_for_issue "$repo" "$issue")" "completed-pr" "")" ]] && continue
    start_discovered_issue "$repo" "$issue" || true
  done < <({ fetch_copilot_issues "$repo" || log "failed to fetch Copilot issues for $repo"; })
}

find_open_pr_for_branch() {
  local repo="$1"
  local head_owner="$2"
  local branch="$3"

  "$GH_COMMAND" api "repos/$repo/pulls?head=$head_owner:$branch&state=open" \
    --jq '.[0].html_url // ""' 2>/dev/null
}

find_pr_for_issue_worktree() {
  local worktree="$1"
  local pr_repo branch head_owner

  pr_repo="$(resolve_origin_repo)"
  branch="$(branch_for_worktree "$worktree")"
  [[ -n "$branch" ]] || return 1
  head_owner="${pr_repo%%/*}"
  find_open_pr_for_branch "$pr_repo" "$head_owner" "$branch"
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
  if tmux_window_exists "$session" "$AGENT_WINDOW_NAME"; then
    printf '%s\n' "$session:$AGENT_WINDOW_NAME.0"
  else
    printf '%s\n' "$session:0.0"
  fi
}

current_path_for_session() {
  local session="$1"
  local target path

  tmux_session_exists "$session" || return 1
  target="$(target_for_session "$session")"
  path="$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)"
  [[ -n "$path" && -d "$path" ]] || return 1
  printf '%s\n' "$path"
}

current_command_for_target() {
  local target="$1"
  tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null
}

target_has_non_shell_process() {
  local target="$1"
  local command_name

  command_name="$(current_command_for_target "$target" || true)"
  [[ -n "$command_name" ]] || return 1
  [[ "$command_name" =~ $AGENT_SHELL_COMMAND_PATTERN ]] && return 1
  return 0
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

idle_screen_file_for_target() {
  local target="$1"
  local safe_target
  safe_target="$(sanitize_name "$target")"
  printf '%s/%s.idle-screen\n' "$STATE_DIR" "$safe_target"
}

idle_screen_signature_file_for_target() {
  local target="$1"
  local safe_target
  safe_target="$(sanitize_name "$target")"
  printf '%s/%s.idle-screen-signature\n' "$STATE_DIR" "$safe_target"
}

target_screen_is_idle() {
  local target="$1"
  local text="$2"
  local idle_screen_file signature_file signature previous_signature

  idle_screen_file="$(idle_screen_file_for_target "$target")"
  signature_file="$(idle_screen_signature_file_for_target "$target")"
  signature="$(printf '%s\n' "$text" | signature_for)"
  previous_signature="$(cat "$signature_file" 2>/dev/null || true)"

  printf '%s\n' "$text" >"$idle_screen_file"
  printf '%s\n' "$signature" >"$signature_file"

  [[ -n "$previous_signature" && "$previous_signature" == "$signature" ]]
}

pane_looks_like_agent() {
  local text="$1"
  printf '%s\n' "$text" | grep -Eq "$AGENT_READY_PATTERN"
}

target_looks_like_live_agent() {
  local target="$1"
  local text="$2"

  target_has_non_shell_process "$target" || return 1
  pane_looks_like_agent "$text" || pane_looks_working "$text" || return 1
}

agent_prompt_has_pending_input() {
  local text="$1"
  agent_pending_input_line "$text" >/dev/null
}

agent_current_prompt_line() {
  local text="$1"
  local line last_prompt_line

  last_prompt_line=""
  while IFS= read -r line; do
    if [[ "$line" =~ $AGENT_PROMPT_LINE_PATTERN ]]; then
      last_prompt_line="$line"
    fi
  done < <(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")

  [[ -n "$last_prompt_line" ]] || return 1
  printf '%s\n' "$last_prompt_line"
}

agent_pending_input_line() {
  local text="$1"
  local last_prompt_line

  last_prompt_line="$(agent_current_prompt_line "$text")" || return 1
  [[ "$last_prompt_line" =~ $AGENT_PENDING_INPUT_PATTERN ]] || return 1
  printf '%s\n' "$last_prompt_line"
}

prompt_visible_in_current_input() {
  local text="$1"
  local prompt="$2"
  local input_line token

  input_line="$(agent_current_prompt_line "$text")" || return 1
  [[ "$input_line" == *"$prompt"* ]] && return 0

  token="${prompt%%$'\n'*}"
  token="${token:0:80}"
  [[ -n "$token" ]] || return 1
  [[ "$input_line" == *"$token"* ]]
}

prompt_seen_in_text() {
  local text="$1"
  local prompt="$2"
  local token

  [[ "$text" == *"$prompt"* ]] && return 0

  token="${prompt%%$'\n'*}"
  token="${token:0:80}"
  [[ -n "$token" ]] || return 1
  [[ "$text" == *"$token"* ]]
}

pane_looks_working() {
  local text="$1"
  printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES" \
    | grep -Eq "$AGENT_WORKING_PATTERN"
}

pane_has_active_work_indicator() {
  local text="$1"
  printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES" \
    | grep -Eq 'Working \(|esc to interrupt|background terminal running'
}

maybe_send_initial_prompt() {
  local target="$1"
  local prompt="${2:-}"
  local attempt text

  [[ -n "$prompt" ]] || return 0

  for ((attempt = 1; attempt <= AGENT_START_ATTEMPTS; attempt++)); do
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"

    if prompt_visible_in_current_input "$text" "$prompt"; then
      submit_pending_prompt "$target" "$prompt"
      return $?
    fi

    prompt_seen_in_text "$text" "$prompt" && return 0
    pane_has_active_work_indicator "$text" && return 0

    if agent_current_prompt_line "$text" >/dev/null; then
      log "agent in $target reached idle prompt; sending initial prompt"
      send_prompt_to_target "$target" "$prompt"
      return $?
    fi

    sleep "$SEND_VERIFY_WAIT_SECONDS"
  done

  return 1
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

clear_pending_agent_input() {
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

    if ! prompt_visible_in_current_input "$text" "$prompt"; then
      return 0
    fi
    if pane_looks_working "$text"; then
      continue
    fi
  done

  return 1
}

wait_for_agent_ready() {
  local target="$1"
  local attempt text
  for ((attempt = 1; attempt <= AGENT_START_ATTEMPTS; attempt++)); do
    sleep "$AGENT_START_WAIT_SECONDS"
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"
    if target_looks_like_live_agent "$target" "$text"; then
      return 0
    fi
  done
  return 1
}

agent_launch_command() {
  local command

  command="$AGENT_COMMAND"
  [[ -n "$AGENT_FLAGS" ]] && command="$command $AGENT_FLAGS"
  printf '%s\n' "$command"
}

start_agent_in_pane() {
  local target="$1"
  local worktree="$2"
  local initial_prompt="${3:-}"
  local command

  command="$(agent_launch_command)"
  tmux send-keys -t "$target" "$command" Enter
  wait_for_agent_ready "$target" || return 1
  maybe_send_initial_prompt "$target" "$initial_prompt"
}

ensure_agent_target() {
  local session="$1"
  local worktree="$2"
  local initial_prompt="${3:-}"
  local target text command

  [[ -d "$worktree" ]] || {
    log "worktree does not exist: $worktree"
    return 1
  }

  if ! tmux_session_exists "$session"; then
    log "creating tmux session $session in $worktree"
    command="$(agent_launch_command)"
    tmux new-session -d -s "$session" -n "$AGENT_WINDOW_NAME" -c "$worktree" \
      bash -lc "$command" || return 1
    target="$session:$AGENT_WINDOW_NAME.0"
    if ! wait_for_agent_ready "$target"; then
      log "agent did not become ready in $target"
      pane_tail "$target" >&2 || true
      return 1
    fi
    if ! maybe_send_initial_prompt "$target" "$initial_prompt"; then
      log "failed to send initial prompt in $target"
      return 1
    fi
    printf '%s\n' "$target"
    return 0
  fi

  if ! tmux_window_exists "$session" "$AGENT_WINDOW_NAME"; then
    target="$(target_for_session "$session")"
    text="$(pane_tail "$target" || true)"
    if ! target_looks_like_live_agent "$target" "$text"; then
      log "session $session exists; creating $AGENT_WINDOW_NAME window in $worktree"
      command="$(agent_launch_command)"
      tmux new-window -d -t "$session:" -n "$AGENT_WINDOW_NAME" -c "$worktree" \
        bash -lc "$command" || return 1
      target="$session:$AGENT_WINDOW_NAME.0"
      if ! wait_for_agent_ready "$target"; then
        log "agent did not become ready in $target"
        pane_tail "$target" >&2 || true
        return 1
      fi
      if ! maybe_send_initial_prompt "$target" "$initial_prompt"; then
        log "failed to send initial prompt in $target"
        return 1
      fi
    fi
  fi

  target="$(target_for_session "$session")"
  text="$(pane_tail "$target" || true)"
  if ! target_looks_like_live_agent "$target" "$text"; then
    if ! start_agent_in_pane "$target" "$worktree" "$initial_prompt"; then
      log "agent did not become ready in existing target $target"
      pane_tail "$target" >&2 || true
      return 1
    fi
  fi

  printf '%s\n' "$target"
}

approval_prompt_present() {
  local text="$1"
  local tail_text
  [[ -n "$AGENT_APPROVAL_PATTERN" ]] || return 1
  tail_text="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"

  printf '%s\n' "$tail_text" | grep -Eq "$AGENT_APPROVAL_PATTERN" || return 1

  return 0
}

trust_prompt_present() {
  local text="$1"
  local tail_text
  [[ -n "$AGENT_TRUST_PROMPT_PATTERN" ]] || return 1
  tail_text="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"

  printf '%s\n' "$tail_text" | grep -Eq "$AGENT_TRUST_PROMPT_PATTERN" || return 1

  return 0
}

signature_for() {
  cksum | awk '{ print $1 ":" $2 }'
}

maybe_approve_prompt() {
  local target="$1"
  local text="$2"
  local prompt_tail signature

  if trust_prompt_present "$text"; then
    prompt_tail="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"
    signature="$(printf '%s\n' "$prompt_tail" | signature_for)"
    if [[ "${APPROVED_SIGNATURES[$target]:-}" != "$signature" ]]; then
      tmux send-keys -t "$target" 1 Enter
      APPROVED_SIGNATURES["$target"]="$signature"
      log "approved agent trust prompt in $target"
    fi
    return 0
  fi

  target_looks_like_live_agent "$target" "$text" || return 0
  if approval_prompt_present "$text"; then
    prompt_tail="$(printf '%s\n' "$text" | tail -n "$MATCH_TAIL_LINES")"
    signature="$(printf '%s\n' "$prompt_tail" | signature_for)"
    if [[ "${APPROVED_SIGNATURES[$target]:-}" != "$signature" ]]; then
      tmux send-keys -t "$target" Enter
      APPROVED_SIGNATURES["$target"]="$signature"
      log "approved agent prompt in $target"
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

    if ! target_looks_like_live_agent "$target" "$text"; then
      continue
    fi

    if approval_prompt_present "$text"; then
      printf 'needs approval\n'
      return 0
    fi

    if agent_prompt_has_pending_input "$text"; then
      state="pending input"
      continue
    fi

    if [[ "$state" != "pending input" ]]; then
      if pane_has_active_work_indicator "$text"; then
        state="working"
      elif agent_current_prompt_line "$text" >/dev/null; then
        if target_screen_is_idle "$target" "$text"; then
          [[ "$state" == "unknown" ]] && state="idle"
        elif [[ "$state" == "unknown" ]]; then
          state="working"
        fi
      elif pane_looks_working "$text"; then
        state="working"
      elif [[ "$state" == "unknown" ]]; then
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
  local rows_file i repo pr issue session key label item_url phase
  local date_value trigger_value ci_value state_raw previous_state state_value display_state

  rows_file="$(mktemp)"
  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    repo="${REPOS[$i]}"
    pr="${PRS[$i]}"
    issue="${ISSUES[$i]}"
    session="${SESSIONS[$i]}"
    key="$(state_key_for_item "$repo" "$pr" "$issue")"
    ensure_status_defaults "$key"

    if [[ -n "$pr" ]]; then
      label="$repo#$pr"
      item_url="https://github.com/$repo/pull/$pr"
    else
      label="$repo#$issue"
      item_url="https://github.com/$repo/issues/$issue"
      write_status_field_if_absent "$key" "phase" "progress"
      write_status_field "$key" "ci" "not watched"
    fi

    state_raw="$(tmux_state_for_session "$session")"
    previous_state="$(read_status_field "$key" "state" "")"
    if [[ "$state_raw" != "$previous_state" ]]; then
      write_status_field "$key" "state" "$state_raw"
      write_status_field "$key" "date" "$(short_status_date)"
    fi

    date_value="$(markdown_cell "$(read_status_field "$key" "date" "$(short_status_date)")")"
    trigger_value="$(markdown_cell "$(read_status_field "$key" "trigger" "none")")"
    ci_value="$(markdown_cell "$(read_status_field "$key" "ci" "unknown")")"
    display_state="$state_raw"
    if [[ -z "$pr" ]]; then
      phase="$(read_status_field "$key" "phase" "progress")"
      display_state="$phase ($state_raw)"
    fi
    state_value="$(markdown_cell "$display_state")"

    printf '%s\t| [%s](%s) | %s | %s | %s | %s |\n' \
      "$label" "$label" "$item_url" "$date_value" "$trigger_value" "$ci_value" "$state_value" \
      >>"$rows_file"
  done

  {
    printf '%s\n' "$STATUS_BLOCK_START"
    printf '# Agent Watcher Status\n\n'
    printf 'Last updated: %s\n\n' "$(date '+%m-%d %H:%M %Z')"
    printf '| Item | Date | Trigger | CI | State |\n'
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
  local current_file block_file new_body_file gh_body_file

  [[ "$STATUS_ENABLED" == "true" ]] || return 0
  [[ -n "$STATUS_ISSUE_REPO" && -n "$STATUS_ISSUE_NUMBER" ]] || return 0

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

  gh_body_file="$(path_for_gh_file_arg "$new_body_file")"
  if "$GH_COMMAND" issue edit "$STATUS_ISSUE_NUMBER" --repo "$STATUS_ISSUE_REPO" --body-file "$gh_body_file" >/dev/null; then
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
    if agent_prompt_has_pending_input "$text" && ! prompt_visible_in_current_input "$text" "$prompt"; then
      clear_pending_agent_input "$target"
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

    clear_pending_agent_input "$target"
  done

  rm -f "$tmp"
  return 1
}

dispatch_watch_prompt() {
  local repo="$1"
  local pr="$2"
  local worktree="$3"
  local session="$4"
  local comment_count="$5"
  local ci_failure_count="$6"
  local target prompt

  log "dispatching prompt for $repo#$pr to tmux session $session (comments=$comment_count, ci_failures=$ci_failure_count)"
  target="$(ensure_agent_target "$session" "$worktree")" || return 1
  prompt="$(resolve_prompt_for_pr "$pr")"
  send_prompt_to_target "$target" "$prompt" || return 1
  log "sent prompt for $repo#$pr to $target"
}

process_issue_item() {
  local repo="$1"
  local issue="$2"
  local worktree="$3"
  local session="$4"
  local key state target prompt pr_url pr_repo pr_number pr_base_repo compare_status

  key="$(state_key_for_issue "$repo" "$issue")"
  ensure_status_defaults "$key"
  write_status_field "$key" "ci" "not watched"
  write_status_field_if_absent "$key" "phase" "progress"

  target="$(ensure_agent_target "$session" "$worktree")" || {
    record_status_event "$key" "dispatch failed"
    return 0
  }

  state="$(tmux_state_for_session "$session")"
  [[ "$state" == "idle" ]] || return 0

  pr_base_repo="$(resolve_origin_repo)"
  pr_url="$(find_pr_for_issue_worktree "$worktree" || true)"
  if [[ -n "$pr_url" ]] && parse_github_pr_url "$pr_url" pr_repo pr_number; then
    prompt="$(resolve_prompt_for_pr_url "$pr_url")"
    if send_prompt_to_target "$target" "$prompt"; then
      write_status_field "$key" "completed-pr" "$pr_url"
      replace_watch_state_item "$repo" "" "$issue" "$pr_repo" "$pr_number" "$worktree" "$session"
      record_status_event "$(state_key_for "$pr_repo" "$pr_number")" "PR resolve"
      log "issue $repo#$issue is now tracked as $pr_url"
    else
      record_status_event "$key" "dispatch failed"
      log "failed to send PR resolve prompt for issue $repo#$issue"
    fi
    return 0
  fi

  compare_status=0
  worktree_head_matches_base "$worktree" "$pr_base_repo" || compare_status=$?
  if [[ "$compare_status" -eq 0 ]]; then
    prompt="$(resolve_prompt_for_issue "$repo" "$issue")"
    if send_prompt_to_target "$target" "$prompt"; then
      write_status_field "$key" "phase" "progress"
      record_status_event "$key" "issue prompt"
      log "sent initial issue prompt for $repo#$issue to $target"
    else
      record_status_event "$key" "dispatch failed"
      log "failed to send initial issue prompt for $repo#$issue"
    fi
    return 0
  elif [[ "$compare_status" -eq 2 ]]; then
    record_status_event "$key" "head check failed"
    log "could not compare $worktree HEAD with $pr_base_repo default branch"
    return 0
  fi

  prompt="$(resolve_internal_review_prompt "$pr_base_repo")"
  if send_prompt_to_target "$target" "$prompt"; then
    write_status_field "$key" "phase" "create PR"
    record_status_event "$key" "create PR"
    log "sent PR create prompt for issue $repo#$issue to $target"
  else
    record_status_event "$key" "dispatch failed"
    log "failed to send PR create prompt for issue $repo#$issue"
  fi
}

process_watch_item() {
  local repo="$1"
  local pr="$2"
  local worktree="$3"
  local session="$4"
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

    if dispatch_watch_prompt "$repo" "$pr" "$worktree" "$session" "$new_comment_count" "$ci_failure_count"; then
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

  agent_prompt_has_pending_input "$text" || return 0

  skill_token="${last_prompt%% *}"
  input_line="$(agent_pending_input_line "$text" 2>/dev/null || true)"
  if [[ "$input_line" == *"$skill_token"* ]]; then
    log "clearing incomplete watcher prompt in $target and resending"
    clear_pending_agent_input "$target"
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

  parse_args "$@"
  finalize_agent_config
  if "$HELP_REQUESTED"; then
    usage
    exit 0
  fi
  print_startup_warning
  need_command "$GH_COMMAND"
  need_command "$GIT_COMMAND"
  need_command "${AGENT_COMMAND%% *}"
  need_command awk
  need_command cksum
  need_command cmp
  need_command cut
  need_command grep
  need_command jq
  need_command sort
  need_command tail
  need_command tmux

  log_startup_tools
  require_repo_root
  require_default_branch
  "$GH_COMMAND" auth status >/dev/null || die "$GH_COMMAND is not authenticated"

  mkdir -p "$STATE_DIR"
  trap finish_status_line EXIT

  while true; do
    read_watch_state
    discover_copilot_issues
    for ((i = 0; i < ${#REPOS[@]}; i++)); do
      if [[ -n "${PRS[$i]}" ]]; then
        process_watch_item "${REPOS[$i]}" "${PRS[$i]}" "${WORKTREES[$i]}" "${SESSIONS[$i]}"
      else
        process_issue_item "${REPOS[$i]}" "${ISSUES[$i]}" "${WORKTREES[$i]}" "${SESSIONS[$i]}"
      fi
    done
    monitor_configured_sessions
    maybe_update_status_issue

    print_status_line "${#REPOS[@]}" "$POLL_SECONDS"
    "$ONCE" && break
    sleep "$POLL_SECONDS"
  done
}

main "$@"
