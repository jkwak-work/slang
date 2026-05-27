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
AGENT_APPROVAL_PATTERN="${AGENT_APPROVAL_PATTERN:-}"
AGENT_SHELL_COMMAND_PATTERN="${AGENT_SHELL_COMMAND_PATTERN:-}"
AGENT_WINDOW_NAME="${AGENT_WINDOW_NAME:-}"
AGENT_SESSION_PREFIX="${AGENT_SESSION_PREFIX:-}"
AGENT_SKILL_PREFIX="${AGENT_SKILL_PREFIX:-}"
AGENT_START_WAIT_SECONDS="${AGENT_START_WAIT_SECONDS:-10}"
AGENT_START_ATTEMPTS="${AGENT_START_ATTEMPTS:-5}"
PROMPT_ENTER_DELAY_SECONDS="${PROMPT_ENTER_DELAY_SECONDS:-3}"
PROMPT_SEND_ATTEMPTS="${PROMPT_SEND_ATTEMPTS:-3}"
STATUS_ENABLED=false
STATUS_ISSUE_REPO=""
STATUS_ISSUE_NUMBER=""
STATUS_BLOCK_START="<!-- pr-watch-status:start -->"
STATUS_BLOCK_END="<!-- pr-watch-status:end -->"
RESOLVE_SKILL="slang-pr-resolve-comments"
PR_CREATE_SKILL="slang-pr-create"
WATCH_TEMP_DIR=""
ONCE=false
HELP_REQUESTED=false

declare -a REPOS=()
declare -a PRS=()
declare -a ISSUES=()
declare -a WORKTREES=()
declare -a SESSIONS=()
declare -A APPROVED_SIGNATURES=()
declare -A IDLE_SCREEN_TEXTS=()
declare -A IDLE_SCREEN_SIGNATURES=()
declare -A IDLE_SCREEN_RESULTS=()
LAST_STATUS_ISSUE_MESSAGE=""
STATUS_LINE_ACTIVE=false

finalize_agent_config() {
  local default_ready_pattern default_approval_pattern

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

  default_ready_pattern="$AGENT_COMMAND_NAME"
  case "$AGENT_COMMAND_NAME" in
    codex)
      default_ready_pattern=$'Codex|gpt-[0-9]|(^|[[:space:]])\342\200\272[[:space:]]*$'
      ;;
    claude|claude-code)
      default_ready_pattern='Claude|(^|[[:space:]])>[[:space:]]*$'
      ;;
  esac

  AGENT_READY_PATTERN="${AGENT_READY_PATTERN:-$default_ready_pattern}"
  default_approval_pattern=$'Do you trust the contents of this directory|Do you want to proceed|(^|[[:space:]])\342\235\257[[:space:]]+1[.] '
  AGENT_APPROVAL_PATTERN="${AGENT_APPROVAL_PATTERN:-$default_approval_pattern}"
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

watch_temp_file() {
  local prefix="${1:-watch-github}"

  if [[ -n "$WATCH_TEMP_DIR" ]]; then
    mktemp "$WATCH_TEMP_DIR/$prefix.XXXXXX"
  else
    mktemp
  fi
}

cleanup_watch_temp_dir() {
  local temp_dir="$WATCH_TEMP_DIR"

  WATCH_TEMP_DIR=""
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
  finish_status_line
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
    if ! command -v wslpath >/dev/null 2>&1; then
      log "missing required command for Windows path conversion: wslpath"
      return 1
    fi
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

  log "failed to determine default branch; set DEFAULT_BRANCH explicitly"
  return 1
}

require_default_branch() {
  local current_branch default_branch

  current_branch="$("$GIT_COMMAND" branch --show-current)" ||
    die "failed to determine current branch"
  [[ -n "$current_branch" ]] || die "must be run from the default branch; HEAD is detached"

  default_branch="$(resolve_default_branch)" ||
    die "failed to determine default branch; set DEFAULT_BRANCH explicitly"
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

  if ! origin_url="$("$GIT_COMMAND" remote get-url origin 2>/dev/null)"; then
    log "failed to read origin remote URL"
    return 1
  fi
  if ! origin_repo="$(repo_from_github_url "$origin_url")"; then
    log "origin remote is not a GitHub repository URL; set PR_BASE_REPO explicitly"
    return 1
  fi
  printf '%s\n' "$origin_repo"
}

resolve_issue_repo() {
  local repo

  if [[ -n "$WATCH_ISSUE_REPO" ]]; then
    printf '%s\n' "$WATCH_ISSUE_REPO"
    return 0
  fi

  if ! repo="$("$GH_COMMAND" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
    log "failed to determine GitHub issue repo; set WATCH_ISSUE_REPO explicitly"
    return 1
  fi
  if [[ -z "$repo" ]]; then
    log "failed to determine GitHub issue repo; set WATCH_ISSUE_REPO explicitly"
    return 1
  fi
  printf '%s\n' "$repo"
}

current_github_login() {
  local login

  login="$("$GH_COMMAND" api user --jq .login </dev/null 2>/dev/null | tr -d '\r')" ||
    return 1
  [[ -n "$login" ]] || return 1
  printf '%s\n' "$login"
}

resolve_repo_default_branch() {
  local repo="$1"
  local branch

  branch="$("$GH_COMMAND" repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [[ -n "$branch" ]] || branch="$(resolve_default_branch)" || return 1
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
  write_status_field_if_absent "$key" "ci" "unknown"
}

set_status_phase() {
  local key="$1"
  local phase="$2"

  write_status_field "$key" "date" "$(short_status_date)"
  write_status_field "$key" "phase" "$phase"
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

resolve_prompt_for_pr_resolve() {
  local repo="$1"
  local pr="$2"
  local prefix

  prefix="$(skill_prefix_for_agent)"
  printf '%s%s https://github.com/%s/pull/%s\n' "$prefix" "$RESOLVE_SKILL" "$repo" "$pr"
}

resolve_prompt_for_issue() {
  local repo="$1"
  local issue="$2"

  printf 'Work on GitHub issue https://github.com/%s/issues/%s in this worktree. Read the issue and comments, implement the requested changes, and run appropriate focused validation. Commit when the implementation is ready for the review.\n' \
    "$repo" "$issue"
}

resolve_prompt_for_pr_create() {
  local pr_repo="$1"
  local prefix

  prefix="$(skill_prefix_for_agent)"
  printf '%s%s %s\n' "$prefix" "$PR_CREATE_SKILL" "$pr_repo"
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
  if [[ -n "${extra:-}" ]]; then
    log "too many fields in watch state line: $raw"
    return 1
  fi
  [[ -n "${first:-}" ]] || return 1
  value_pr=""
  value_issue=""

  if [[ "$first" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)/*$ ]]; then
    if [[ -n "${fourth:-}" ]]; then
      log "too many fields in watch state line: $raw"
      return 1
    fi
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^https://github\.com/([^[:space:]]+/[^[:space:]]+)/issues/([0-9]+)/*$ ]]; then
    if [[ -n "${fourth:-}" ]]; then
      log "too many fields in watch state line: $raw"
      return 1
    fi
    value_repo="${BASH_REMATCH[1]}"
    value_issue="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^#[:space:]]+)#([0-9]+)$ ]]; then
    if [[ -n "${fourth:-}" ]]; then
      log "too many fields in watch state line: $raw"
      return 1
    fi
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^[:space:]]+)/pull/([0-9]+)$ ]]; then
    if [[ -n "${fourth:-}" ]]; then
      log "too many fields in watch state line: $raw"
      return 1
    fi
    value_repo="${BASH_REMATCH[1]}"
    value_pr="${BASH_REMATCH[2]}"
    value_worktree="${second:-}"
    value_session="${third:-}"
  elif [[ "$first" =~ ^([^[:space:]]+/[^[:space:]]+)/issues/([0-9]+)$ ]]; then
    if [[ -n "${fourth:-}" ]]; then
      log "too many fields in watch state line: $raw"
      return 1
    fi
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

  if [[ -z "$value_repo" || -z "$value_worktree" ]]; then
    log "bad watch state line: $raw"
    return 1
  fi
  if [[ -n "$value_pr" ]]; then
    if [[ ! "$value_pr" =~ ^[0-9]+$ ]]; then
      log "bad PR number in watch state line: $raw"
      return 1
    fi
  elif [[ -n "$value_issue" ]]; then
    if [[ ! "$value_issue" =~ ^[0-9]+$ ]]; then
      log "bad issue number in watch state line: $raw"
      return 1
    fi
  else
    log "bad watch state line: $raw"
    return 1
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
  if [[ -z "$value_session" ]]; then
    log "empty tmux session name for watch state line: $raw"
    return 1
  fi

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
      log "watch state file not found: $WATCH_STATE_FILE"
      return 1
    fi
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_watch_state_line "$line"
  done <"$WATCH_STATE_FILE"

  if [[ "${#REPOS[@]}" -eq 0 && "$WATCH_COPILOT_ISSUES" != "true" ]]; then
    log "watch state contains no items: $WATCH_STATE_FILE"
    return 1
  fi
}

watch_state_has_item() {
  local repo="$1"
  local pr="$2"
  local issue="$3"
  local worktree session

  watch_state_find_item "$repo" "$pr" "$issue" worktree session
}

watch_state_find_item() {
  local repo="$1"
  local pr="$2"
  local issue="$3"
  local worktree_var="$4"
  local session_var="$5"
  local i

  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    [[ "${REPOS[$i]}" == "$repo" ]] || continue
    if [[ -n "$pr" && "${PRS[$i]}" == "$pr" ]]; then
      printf -v "$worktree_var" '%s' "${WORKTREES[$i]}"
      printf -v "$session_var" '%s' "${SESSIONS[$i]}"
      return 0
    fi
    if [[ -n "$issue" && "${ISSUES[$i]}" == "$issue" ]]; then
      printf -v "$worktree_var" '%s' "${WORKTREES[$i]}"
      printf -v "$session_var" '%s' "${SESSIONS[$i]}"
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

  tmp="$(watch_temp_file)"
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
  read_watch_state >/dev/null || true
}

remove_watch_state_item() {
  local old_repo="$1"
  local old_pr="$2"
  local old_issue="$3"
  local tmp line repo pr issue parsed_worktree parsed_session removed=false

  tmp="$(watch_temp_file)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if parse_watch_state_fields "$line" repo pr issue parsed_worktree parsed_session 2>/dev/null &&
      [[ "$repo" == "$old_repo" ]] &&
      { [[ -n "$old_pr" && "$pr" == "$old_pr" ]] ||
        [[ -n "$old_issue" && "$issue" == "$old_issue" ]]; }; then
      removed=true
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$WATCH_STATE_FILE"

  mv "$tmp" "$WATCH_STATE_FILE"
  if "$removed"; then
    log "removed watch-state item for $old_repo#${old_pr:-$old_issue}"
    read_watch_state >/dev/null || true
  fi
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

pr_state_for() {
  local repo="$1"
  local pr="$2"
  local state

  state="$("$GH_COMMAND" api "repos/$repo/pulls/$pr" \
    --jq 'if (.state // "") == "closed" and (.merged // false) then "merged" else (.state // "") end' \
    </dev/null 2>/dev/null | tr -d '\r')" ||
    return 1
  [[ -n "$state" ]] || return 1
  printf '%s\n' "${state,,}"
}

pr_has_copilot_label() {
  local repo="$1"
  local pr="$2"
  local labels_file rc

  labels_file="$(watch_temp_file)"
  if ! "$GH_COMMAND" api "repos/$repo/issues/$pr" \
    --jq '.labels[]?.name' >"$labels_file" </dev/null; then
    rm -f "$labels_file"
    return 2
  fi

  tr -d '\r' <"$labels_file" | grep -Fixq -- "$COPILOT_LABEL"
  rc=$?
  rm -f "$labels_file"
  return "$rc"
}

pr_head_ref_matches_issue() {
  local head_ref="$1"
  local issue="$2"

  [[ "$head_ref" == *"issue-$issue"* ]]
}

pr_url_is_open_for_issue_and_created_by() {
  local pr_url="$1"
  local author_login="$2"
  local issue="$3"
  local repo pr pr_info state login head_ref

  parse_github_pr_url "$pr_url" repo pr || return 2
  pr_info="$("$GH_COMMAND" api "repos/$repo/pulls/$pr" \
    --jq '
      [
        if (.state // "") == "closed" and (.merged // false)
        then "merged"
        else (.state // "")
        end,
        (.user.login // ""),
        (.head.ref // "")
      ] | @tsv
    ' \
    </dev/null 2>/dev/null | tr -d '\r')" ||
    return 2
  IFS=$'\t' read -r state login head_ref <<<"$pr_info"
  [[ -n "$state" && -n "$login" && -n "$head_ref" ]] || return 2
  [[ "${state,,}" == "open" && "$login" == "$author_login" ]] || return 1
  pr_head_ref_matches_issue "$head_ref" "$issue"
}

related_pr_urls_for_issue() {
  local repo="$1"
  local issue="$2"
  local refs_file timeline_file rc

  refs_file="$(watch_temp_file)"
  timeline_file="$(watch_temp_file)"

  if ! "$GH_COMMAND" issue view "$issue" \
    --repo "$repo" \
    --json closedByPullRequestsReferences \
    --jq '.closedByPullRequestsReferences[]?.url' >"$refs_file" </dev/null; then
    rm -f "$refs_file" "$timeline_file"
    return 1
  fi

  if ! "$GH_COMMAND" api --paginate \
    "repos/$repo/issues/$issue/timeline?per_page=$COMMENT_PAGE_SIZE" >"$timeline_file" </dev/null; then
    rm -f "$refs_file" "$timeline_file"
    return 1
  fi

  {
    cat "$refs_file"
    jq -r '
      .[] |
      [(.source.issue? // empty), (.subject? // empty)][] |
      select(.pull_request? != null) |
      (.html_url // .pull_request.html_url // empty)
    ' "$timeline_file"
  } | awk 'NF' | sort -u
  rc=$?

  rm -f "$refs_file" "$timeline_file"
  return "$rc"
}

open_issue_branch_pr_urls_for_issue() {
  local repo="$1"
  local issue="$2"
  local author_login="$3"
  local raw branch_marker rc

  raw="$(watch_temp_file)"
  branch_marker="issue-$issue"
  if ! "$GH_COMMAND" api --paginate \
    "repos/$repo/pulls?state=open&per_page=$COMMENT_PAGE_SIZE" >"$raw" </dev/null; then
    rm -f "$raw"
    return 1
  fi

  jq -r --arg author_login "$author_login" --arg branch_marker "$branch_marker" '
    .[] |
    select((.user.login // "") == $author_login) |
    select((.head.ref // "") | contains($branch_marker)) |
    .html_url // empty
  ' "$raw"
  rc=$?

  rm -f "$raw"
  return "$rc"
}

open_related_prs_for_issue() {
  local repo="$1"
  local issue="$2"
  local related_file candidate_file pr_url rc
  local viewer_login has_open=false inspect_failed=false

  viewer_login="$(current_github_login)" || return 2
  related_file="$(watch_temp_file)"
  candidate_file="$(watch_temp_file)"
  if ! related_pr_urls_for_issue "$repo" "$issue" >"$related_file"; then
    rm -f "$related_file" "$candidate_file"
    return 2
  fi

  cat "$related_file" >"$candidate_file"
  if ! open_issue_branch_pr_urls_for_issue \
    "$repo" "$issue" "$viewer_login" >>"$candidate_file"; then
    inspect_failed=true
  fi
  awk 'NF && !seen[$0]++' "$candidate_file" >"$related_file"

  while IFS= read -r pr_url; do
    [[ -n "$pr_url" ]] || continue
    pr_url_is_open_for_issue_and_created_by "$pr_url" "$viewer_login" "$issue"
    rc=$?
    case "$rc" in
      0)
        printf '%s\n' "$pr_url"
        has_open=true
        ;;
      1)
        ;;
      *)
        inspect_failed=true
        ;;
    esac
  done <"$related_file"

  rm -f "$related_file" "$candidate_file"
  if "$inspect_failed"; then
    return 2
  fi
  "$has_open"
}

first_open_related_pr_for_issue() {
  local repo="$1"
  local issue="$2"
  local open_prs_file first_pr rc

  open_prs_file="$(watch_temp_file)"
  open_related_prs_for_issue "$repo" "$issue" >"$open_prs_file"
  rc=$?
  case "$rc" in
    0)
      IFS= read -r first_pr <"$open_prs_file" || first_pr=""
      rm -f "$open_prs_file"
      [[ -n "$first_pr" ]] || return 1
      printf '%s\n' "$first_pr"
      return 0
      ;;
    1)
      rm -f "$open_prs_file"
      return 1
      ;;
    *)
      rm -f "$open_prs_file"
      return 2
      ;;
  esac
}

git_in_worktree() {
  local worktree="$1"
  local git_worktree
  shift
  git_worktree="$(path_for_git_path_arg "$worktree")" || return 1
  "$GIT_COMMAND" -C "$git_worktree" "$@" | tr -d '\r'
}

git_commit_for_ref() {
  local worktree="$1"
  local ref="$2"
  git_in_worktree "$worktree" rev-parse --verify "$ref^{commit}" 2>/dev/null
}

worktree_ref_contains_head() {
  local worktree="$1"
  local ref="$2"
  local rc

  git_commit_for_ref "$worktree" "$ref" >/dev/null || return 2
  git_in_worktree "$worktree" merge-base --is-ancestor HEAD "$ref" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0 | 1)
      return "$rc"
      ;;
    *)
      return 2
      ;;
  esac
}

worktree_head_is_in_default_branch() {
  local worktree="$1"
  local pr_repo="$2"
  local base_branch refs_file unique_refs_file ref rc

  git_commit_for_ref "$worktree" HEAD >/dev/null || return 2

  base_branch="$(resolve_repo_default_branch "$pr_repo")" || return 2
  refs_file="$(watch_temp_file)"
  unique_refs_file="$(watch_temp_file)"
  printf '%s\n' \
    "refs/remotes/origin/$base_branch" \
    "origin/$base_branch" \
    "$base_branch" >"$refs_file"
  git_in_worktree "$worktree" for-each-ref \
    --format='%(refname:short)' "refs/remotes/*/$base_branch" >>"$refs_file" 2>/dev/null || true
  awk 'NF && !seen[$0]++' "$refs_file" >"$unique_refs_file"

  rc=2
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    worktree_ref_contains_head "$worktree" "$ref"
    case "$?" in
      0)
        rc=0
        break
        ;;
      1)
        rc=1
        ;;
    esac
  done <"$unique_refs_file"

  rm -f "$refs_file" "$unique_refs_file"
  return "$rc"
}

fetch_copilot_issues() {
  local repo="$1"
  local issues_file

  issues_file="$(watch_temp_file)"
  if ! "$GH_COMMAND" issue list \
    --repo "$repo" \
    --assignee "@me" \
    --label "$COPILOT_LABEL" \
    --state open \
    --limit "$ISSUE_LIST_LIMIT" \
    --json number \
    --jq '.[].number' >"$issues_file"; then
    rm -f "$issues_file"
    return 1
  fi

  cat "$issues_file"
  rm -f "$issues_file"
}

issue_worktree_name() {
  local issue="$1"
  printf 'issue-%s\n' "$issue"
}

issue_worktree_path() {
  local issue="$1"
  printf '%s/%s\n' "$(dirname "$(pwd -P)")" "$(issue_worktree_name "$issue")"
}

issue_worktree_path_is_safe_to_delete() {
  local issue="$1"
  local worktree="$2"
  local expected

  expected="$(issue_worktree_path "$issue")"
  [[ "$worktree" == "$expected" && "$(basename "$worktree")" == "$(issue_worktree_name "$issue")" ]]
}

delete_issue_worktree() {
  local issue="$1"
  local worktree="$2"
  local git_worktree

  [[ -e "$worktree" ]] || return 0
  if ! issue_worktree_path_is_safe_to_delete "$issue" "$worktree"; then
    log "refusing to delete unexpected issue worktree path: $worktree"
    return 1
  fi

  log "deleting existing issue worktree $(basename "$worktree") before rediscovery"
  git_worktree="$(path_for_git_path_arg "$worktree")" || return 1
  if ! "$GIT_COMMAND" worktree remove --force --force "$git_worktree" >/dev/null 2>&1; then
    log "git worktree remove failed for $worktree; removing directory directly"
  fi
  "$GIT_COMMAND" worktree prune >/dev/null 2>&1 || true
  if [[ -e "$worktree" ]]; then
    rm -rf -- "$worktree" || {
      log "failed to delete issue worktree directory: $worktree"
      return 1
    }
    "$GIT_COMMAND" worktree prune >/dev/null 2>&1 || true
  fi
}

delete_issue_branch() {
  local branch="$1"
  local worktree_log="$2"

  "$GIT_COMMAND" show-ref --verify --quiet "refs/heads/$branch" || return 0

  log "deleting existing issue branch $branch before rediscovery"
  printf '[%s] Deleting existing issue branch before rediscovery: %s\n' \
    "$(date '+%H:%M:%S')" "$branch" >>"$worktree_log"
  "$GIT_COMMAND" worktree prune >>"$worktree_log" 2>&1 || true
  if ! "$GIT_COMMAND" branch -D "$branch" >>"$worktree_log" 2>&1; then
    log "failed to delete existing issue branch $branch; see $worktree_log"
    return 1
  fi
}

clear_issue_agent_state() {
  local session="$1"
  local target safe_target

  for target in "$session:$AGENT_WINDOW_NAME.0" "$session:0.0"; do
    safe_target="$(sanitize_name "$target")"
    rm -f \
      "$STATE_DIR/$safe_target.idle-screen" \
      "$STATE_DIR/$safe_target.idle-screen-signature"
  done
}

create_issue_worktree() {
  local repo="$1"
  local issue="$2"
  local worktree_name worktree worktree_log

  worktree_name="$(issue_worktree_name "$issue")"
  worktree="$(issue_worktree_path "$issue")"

  worktree_log="$STATE_DIR/$(state_key_for_issue "$repo" "$issue").worktree-add.log"

  if [[ -e "$worktree" ]]; then
    log "issue worktree still exists before creation: $worktree"
    return 1
  fi

  : >"$worktree_log"
  delete_issue_branch "$worktree_name" "$worktree_log" || return 1

  log "creating issue worktree $worktree_name for $repo#$issue"
  if ! GIT_EXE="$GIT_COMMAND" extras/git-worktree-add.sh "$worktree_name" \
    >>"$worktree_log" 2>&1; then
    log "git-worktree-add failed for $repo#$issue; see $worktree_log"
    return 1
  fi

  printf '%s\n' "$worktree"
}

start_discovered_issue() {
  local repo="$1"
  local issue="$2"
  local key worktree_name worktree target state

  key="$(state_key_for_issue "$repo" "$issue")"
  worktree_name="$(issue_worktree_name "$issue")"
  worktree="$(issue_worktree_path "$issue")"

  if tmux_session_exists "$worktree_name"; then
    log "killing existing tmux session $worktree_name before starting issue agent"
    if ! tmux kill-session -t "=$worktree_name" 2>/dev/null; then
      log "failed to kill existing tmux session $worktree_name"
      return 1
    fi
    if tmux_session_exists "$worktree_name"; then
      log "tmux session $worktree_name still exists after kill"
      return 1
    fi
  fi

  if [[ -e "$worktree" ]]; then
    delete_issue_worktree "$issue" "$worktree" || return 1
  fi
  worktree="$(create_issue_worktree "$repo" "$issue")" || return 1
  clear_issue_agent_state "$worktree_name"

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
  set_status_phase "$key" "Initalizing agent"
  write_status_field "$key" "ci" "N/A"
  log "watching issue $repo#$issue in $worktree_name after starting agent at $target"
}

track_open_pr_for_issue() {
  local repo="$1"
  local issue="$2"
  local pr_url="$3"
  local pr_repo pr_number worktree session

  if ! parse_github_pr_url "$pr_url" pr_repo pr_number; then
    log "failed to parse related PR URL for $repo#$issue: $pr_url"
    return 2
  fi

  if watch_state_has_item "$pr_repo" "$pr_number" ""; then
    if watch_state_has_item "$repo" "" "$issue"; then
      remove_watch_state_item "$repo" "" "$issue"
    fi
    return 0
  fi

  if watch_state_find_item "$repo" "" "$issue" worktree session; then
    replace_watch_state_item "$repo" "" "$issue" "$pr_repo" "$pr_number" "$worktree" "$session"
    set_status_phase "$(state_key_for "$pr_repo" "$pr_number")" "PR discovered"
    return 0
  fi

  worktree="$(issue_worktree_path "$issue")"
  session="$(issue_worktree_name "$issue")"
  append_watch_state_item "$pr_repo" "$pr_number" "" "$worktree" "$session"
  set_status_phase "$(state_key_for "$pr_repo" "$pr_number")" "PR discovered"
  return 0
}

process_discovered_issue() {
  local repo="$1"
  local issue="$2"
  local pr_url rc

  pr_url="$(first_open_related_pr_for_issue "$repo" "$issue")"
  rc=$?
  case "$rc" in
    0)
      track_open_pr_for_issue "$repo" "$issue" "$pr_url" || true
      return 0
      ;;
    1)
      ;;
    *)
      log "failed to inspect related PRs for $repo#$issue"
      return 0
      ;;
  esac

  if watch_state_find_item "$repo" "" "$issue" worktree session; then
    return 0
  fi

  start_discovered_issue "$repo" "$issue" || true
}

discover_copilot_issues() {
  local repo issue

  [[ "$WATCH_COPILOT_ISSUES" == "true" ]] || return 0
  repo="$(resolve_issue_repo)" || return 0

  while IFS= read -r issue; do
    [[ -n "$issue" ]] || continue
    process_discovered_issue "$repo" "$issue"
  done < <({ fetch_copilot_issues "$repo" || log "failed to fetch Copilot issues for $repo"; })
}

fetch_events() {
  local repo="$1"
  local pr="$2"
  local tmp raw
  tmp="$(watch_temp_file)"

  raw="$(watch_temp_file)"
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

  raw="$(watch_temp_file)"
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

  raw="$(watch_temp_file)"
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
  raw="$(watch_temp_file)"

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
  tmp="$(watch_temp_file)"
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

same_existing_dir() {
  local left="$1"
  local right="$2"
  local left_path right_path

  [[ -d "$left" && -d "$right" ]] || return 1
  left_path="$(cd "$left" && pwd -P)" || return 1
  right_path="$(cd "$right" && pwd -P)" || return 1
  [[ "$left_path" == "$right_path" ]]
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

agent_pane_targets_for_session() {
  local session="$1"

  tmux_session_exists "$session" || return 0
  if tmux_window_exists "$session" "$AGENT_WINDOW_NAME"; then
    tmux list-panes -t "$session:$AGENT_WINDOW_NAME" \
      -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
  else
    target_for_session "$session"
  fi
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
  local signature_file signature previous_signature

  if [[ -n "${IDLE_SCREEN_RESULTS[$target]+set}" ]]; then
    [[ "${IDLE_SCREEN_RESULTS[$target]}" == "idle" ]]
    return $?
  fi

  signature_file="$(idle_screen_signature_file_for_target "$target")"
  signature="$(printf '%s\n' "$text" | signature_for)"
  previous_signature="$(cat "$signature_file" 2>/dev/null || true)"

  IDLE_SCREEN_TEXTS["$target"]="$text"
  IDLE_SCREEN_SIGNATURES["$target"]="$signature"

  if [[ -n "$previous_signature" && "$previous_signature" == "$signature" ]]; then
    IDLE_SCREEN_RESULTS["$target"]="idle"
    return 0
  fi

  IDLE_SCREEN_RESULTS["$target"]="working"
  return 1
}

persist_idle_screen_observations() {
  local target idle_screen_file signature_file

  for target in "${!IDLE_SCREEN_SIGNATURES[@]}"; do
    idle_screen_file="$(idle_screen_file_for_target "$target")"
    signature_file="$(idle_screen_signature_file_for_target "$target")"
    printf '%s\n' "${IDLE_SCREEN_TEXTS[$target]}" >"$idle_screen_file"
    printf '%s\n' "${IDLE_SCREEN_SIGNATURES[$target]}" >"$signature_file"
  done

  IDLE_SCREEN_TEXTS=()
  IDLE_SCREEN_SIGNATURES=()
  IDLE_SCREEN_RESULTS=()
}

pane_looks_like_agent() {
  local text="$1"
  printf '%s\n' "$text" | grep -Eq "$AGENT_READY_PATTERN"
}

target_looks_like_live_agent() {
  local target="$1"
  local text="$2"

  target_has_non_shell_process "$target" || return 1
  pane_looks_like_agent "$text" || return 1
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

wait_for_agent_ready() {
  local target="$1"
  local attempt text
  for ((attempt = 1; attempt <= AGENT_START_ATTEMPTS; attempt++)); do
    sleep "$AGENT_START_WAIT_SECONDS"
    text="$(pane_tail "$target" || true)"
    maybe_approve_prompt "$target" "$text"
    if target_looks_like_live_agent "$target" "$text"; then
      sleep "$AGENT_START_WAIT_SECONDS"
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
  local command

  command="$(agent_launch_command)"
  tmux send-keys -t "$target" "$command" Enter
  wait_for_agent_ready "$target"
}

ensure_agent_target() {
  local session="$1"
  local worktree="$2"
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
    fi
  fi

  target="$(target_for_session "$session")"
  text="$(pane_tail "$target" || true)"
  if ! target_looks_like_live_agent "$target" "$text"; then
    if ! start_agent_in_pane "$target" "$worktree"; then
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

    if target_screen_is_idle "$target" "$text"; then
      [[ "$state" == "unknown" ]] && state="idle"
    elif [[ "$state" == "unknown" ]]; then
      state="working"
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

html_text() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

render_markdown_code_block() {
  local text="$1"
  local fence='```'

  while printf '%s\n' "$text" | grep -Fq "$fence"; do
    fence="${fence}\`"
  done

  printf '%stext\n' "$fence"
  if [[ -n "$text" ]]; then
    printf '%s\n' "$text" | sed -e 's/\r$//'
  else
    printf '[empty pane]\n'
  fi
  printf '%s\n' "$fence"
}

capture_tail_lines() {
  local text="$1"

  if [[ -z "$text" ]]; then
    printf '[empty pane]\n'
    return 0
  fi

  printf '%s\n' "$text" | sed -e 's/\r$//' | tail -n 10
}

capture_without_tail_lines() {
  local text="$1"

  if [[ -z "$text" ]]; then
    printf '[no earlier captured lines]\n'
    return 0
  fi

  printf '%s\n' "$text" | sed -e 's/\r$//' | awk '
    { lines[NR] = $0 }
    END {
      limit = NR - 10
      if (limit <= 0) {
        print "[no earlier captured lines]"
      } else {
        for (i = 1; i <= limit; i++) {
          print lines[i]
        }
      }
    }
  '
}

render_status_pane_captures() {
  local output_file="$1"
  local i repo pr issue session label item_url target text summary_label summary_target
  local captures_found=false
  declare -A captured_targets=()

  : >"$output_file"
  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    repo="${REPOS[$i]}"
    pr="${PRS[$i]}"
    issue="${ISSUES[$i]}"
    session="${SESSIONS[$i]}"
    if [[ -n "$pr" ]]; then
      label="$repo#$pr"
      item_url="https://github.com/$repo/pull/$pr"
    else
      label="$repo#$issue"
      item_url="https://github.com/$repo/issues/$issue"
    fi

    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      [[ -z "${captured_targets[$target]+set}" ]] || continue
      captured_targets["$target"]=1
      text="$(pane_tail "$target" || true)"

      if ! "$captures_found"; then
        printf '\n## Tmux Pane Captures\n\n' >>"$output_file"
        captures_found=true
      fi
      summary_label="$(html_text "$label")"
      summary_target="$(html_text "$target")"
      printf '<details>\n' >>"$output_file"
      printf '<summary>%s (%s)</summary>\n\n' "$summary_label" "$summary_target" \
        >>"$output_file"
      printf '[%s](%s)\n\n' "$label" "$item_url" >>"$output_file"
      printf 'Earlier captured lines:\n\n' >>"$output_file"
      render_markdown_code_block "$(capture_without_tail_lines "$text")" >>"$output_file"
      printf '\n</details>\n\n' >>"$output_file"
      printf 'Last 10 lines:\n\n' >>"$output_file"
      render_markdown_code_block "$(capture_tail_lines "$text")" >>"$output_file"
      printf '\n' >>"$output_file"
    done < <(agent_pane_targets_for_session "$session")
  done
}

render_status_dashboard_block() {
  local output_file="$1"
  local rows_file captures_file i repo pr issue key label item_url phase
  local phase_value ci_value

  rows_file="$(watch_temp_file)"
  captures_file="$(watch_temp_file)"
  for ((i = 0; i < ${#REPOS[@]}; i++)); do
    repo="${REPOS[$i]}"
    pr="${PRS[$i]}"
    issue="${ISSUES[$i]}"
    key="$(state_key_for_item "$repo" "$pr" "$issue")"
    ensure_status_defaults "$key"

    if [[ -n "$pr" ]]; then
      label="$repo#$pr"
      item_url="https://github.com/$repo/pull/$pr"
    else
      label="$repo#$issue"
      item_url="https://github.com/$repo/issues/$issue"
      write_status_field_if_absent "$key" "phase" "Initalizing agent"
      write_status_field "$key" "ci" "N/A"
    fi

    phase="$(read_status_field "$key" "phase" "none")"
    phase_value="$(markdown_cell "$phase")"
    ci_value="$(markdown_cell "$(read_status_field "$key" "ci" "unknown")")"

    printf '%s\t| [%s](%s) | %s | %s |\n' \
      "$label" "$label" "$item_url" "$phase_value" "$ci_value" \
      >>"$rows_file"
  done
  render_status_pane_captures "$captures_file"

  {
    printf '%s\n' "$STATUS_BLOCK_START"
    printf '# Agent Watcher Status\n\n'
    printf 'Last updated: %s\n\n' "$(date '+%m-%d %H:%M %Z')"
    printf '| Item | Phase | CI |\n'
    printf '|---|---|---|\n'
    sort "$rows_file" | cut -f2-
    cat "$captures_file"
    printf '\n%s\n' "$STATUS_BLOCK_END"
  } >"$output_file"

  rm -f "$rows_file" "$captures_file"
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

  current_file="$(watch_temp_file)"
  block_file="$(watch_temp_file)"
  new_body_file="$(watch_temp_file)"

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

  if ! gh_body_file="$(path_for_gh_file_arg "$new_body_file")"; then
    log "failed to convert status issue body path for $STATUS_ISSUE_REPO#$STATUS_ISSUE_NUMBER"
    rm -f "$current_file" "$block_file" "$new_body_file"
    return 0
  fi
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
  local safe_target buffer_name tmp attempt
  safe_target="$(sanitize_name "$target")"
  buffer_name="pr_watch_msg_$safe_target"
  tmp="$(watch_temp_file "pr-watch-prompt.$safe_target")"

  printf '%s' "$prompt" >"$tmp"

  for ((attempt = 1; attempt <= PROMPT_SEND_ATTEMPTS; attempt++)); do
    if ! paste_prompt_once "$target" "$buffer_name" "$tmp"; then
      continue
    fi

    sleep "$PROMPT_ENTER_DELAY_SECONDS"
    if ! tmux send-keys -t "$target" Enter; then
      continue
    fi
    rm -f "$tmp"
    return 0
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
  prompt="$(resolve_prompt_for_pr_resolve "$repo" "$pr")"
  send_prompt_to_target "$target" "$prompt" || return 1
  log "sent prompt for $repo#$pr to $target"
}

process_issue_item() {
  local repo="$1"
  local issue="$2"
  local worktree="$3"
  local session="$4"
  local key state target text prompt pr_base_repo compare_status pane_path

  key="$(state_key_for_issue "$repo" "$issue")"
  ensure_status_defaults "$key"
  write_status_field "$key" "ci" "N/A"
  write_status_field_if_absent "$key" "phase" "Initalizing agent"

  if [[ ! -d "$worktree" ]]; then
    log "removing stale issue row for $repo#$issue because worktree is missing: $worktree"
    remove_watch_state_item "$repo" "" "$issue"
    return 1
  fi

  state="$(tmux_state_for_session "$session")"
  if [[ "$state" == "no session" || "$state" == "unknown" ]]; then
    log "removing stale issue row for $repo#$issue because agent state is $state"
    remove_watch_state_item "$repo" "" "$issue"
    return 1
  fi

  if ! pane_path="$(current_path_for_session "$session")" ||
    ! same_existing_dir "$pane_path" "$worktree"; then
    log "removing stale issue row for $repo#$issue because session $session is not rooted in $worktree"
    remove_watch_state_item "$repo" "" "$issue"
    return 1
  fi

  [[ "$state" == "idle" ]] || return 0
  target="$(target_for_session "$session")"
  text="$(pane_tail "$target" || true)"
  if ! target_looks_like_live_agent "$target" "$text"; then
    log "removing stale issue row for $repo#$issue because agent is not live in $target"
    remove_watch_state_item "$repo" "" "$issue"
    return 1
  fi

  if ! pr_base_repo="$(resolve_origin_repo)"; then
    set_status_phase "$key" "repo check failed"
    return 0
  fi

  compare_status=0
  worktree_head_is_in_default_branch "$worktree" "$pr_base_repo" || compare_status=$?
  if [[ "$compare_status" -eq 0 ]]; then
    prompt="$(resolve_prompt_for_issue "$repo" "$issue")"
    if send_prompt_to_target "$target" "$prompt"; then
      set_status_phase "$key" "issue prompt"
      log "sent initial issue prompt for $repo#$issue to $target"
    else
      set_status_phase "$key" "dispatch failed"
      log "failed to send initial issue prompt for $repo#$issue"
    fi
    return 0
  elif [[ "$compare_status" -eq 2 ]]; then
    set_status_phase "$key" "head check failed"
    log "could not determine whether $worktree HEAD is already in the default branch history"
    return 0
  fi

  prompt="$(resolve_prompt_for_pr_create "$pr_base_repo")"
  if send_prompt_to_target "$target" "$prompt"; then
    set_status_phase "$key" "create PR"
    log "sent PR create prompt for issue $repo#$issue to $target"
  else
    set_status_phase "$key" "dispatch failed"
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
  local pr_state pr_label_status
  local comment_needs_dispatch=false ci_needs_dispatch=false
  local ci_pending_changed=false ci_passing_changed=false
  local ci_signature_changed=false ci_state_ready=false ci_was_primed=false

  key="$(state_key_for "$repo" "$pr")"
  ensure_status_defaults "$key"

  if ! pr_state="$(pr_state_for "$repo" "$pr")"; then
    log "failed to fetch PR state for $repo#$pr"
    set_status_phase "$key" "PR state unknown"
    return 0
  fi
  if [[ "$pr_state" != "open" ]]; then
    log "removing watch-state item for $repo#$pr because PR state is $pr_state"
    remove_watch_state_item "$repo" "$pr" ""
    return 0
  fi

  pr_label_status=0
  pr_has_copilot_label "$repo" "$pr" || pr_label_status=$?
  if [[ "$pr_label_status" -ne 0 ]]; then
    if [[ "$pr_label_status" -eq 2 ]]; then
      log "failed to fetch PR labels for $repo#$pr; pausing"
    else
      log "pausing $repo#$pr because it does not have label $COPILOT_LABEL"
    fi
    set_status_phase "$key" "paused"
    return 0
  fi

  comment_state_file="$STATE_DIR/$key.seen"
  ci_state_file="$STATE_DIR/$key.ci-failures"
  events_file="$(watch_temp_file)"
  new_file="$(watch_temp_file)"
  checks_file="$(watch_temp_file)"
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
        previous_signature=""
      else
        previous_signature="$(cat "$ci_state_file" 2>/dev/null || true)"
      fi

      if [[ "$current_signature" != "${previous_signature-}" ]]; then
        ci_signature_changed=true
      fi

      if [[ ! -f "$ci_state_file" && "$CI_BOOTSTRAP_MODE" != "trigger" ]]; then
        printf '%s\n' "$current_signature" >"$ci_state_file"
        log "primed $repo#$pr CI with $ci_failure_count current failure(s), $ci_pending_count pending check(s)"
        ci_signature_changed=false
        ci_was_primed=true
      fi

      if "$ci_signature_changed"; then
        if [[ "$ci_failure_count" -gt 0 ]]; then
          ci_needs_dispatch=true
        elif [[ "$ci_pending_count" -gt 0 ]]; then
          ci_pending_changed=true
        else
          ci_passing_changed=true
        fi
      fi

      ci_state_ready=true
    else
      write_status_field "$key" "ci" "unknown"
      log "failed to fetch CI checks for $repo#$pr"
    fi
  else
    write_status_field "$key" "ci" "not watched"
  fi

  if "$comment_needs_dispatch" || "$ci_needs_dispatch"; then
    if dispatch_watch_prompt "$repo" "$pr" "$worktree" "$session" "$new_comment_count" "$ci_failure_count"; then
      if "$comment_needs_dispatch"; then
        set_status_phase "$key" "Addressing comments"
      else
        set_status_phase "$key" "All comments resolved"
      fi
      if "$comment_needs_dispatch"; then
        append_seen_ids "$comment_state_file" "$new_file"
      fi
      if "$ci_needs_dispatch"; then
        printf '%s\n' "$current_signature" >"$ci_state_file"
      fi
    else
      set_status_phase "$key" "dispatch failed"
      log "dispatch failed for $repo#$pr; will retry pending comment/CI changes on next poll"
    fi
  elif "$ci_pending_changed"; then
    printf '%s\n' "$current_signature" >"$ci_state_file"
    set_status_phase "$key" "CI pending"
    log "CI pending for $repo#$pr"
  elif "$ci_passing_changed"; then
    printf '%s\n' "$current_signature" >"$ci_state_file"
    set_status_phase "$key" "CI passing"
    log "CI passing for $repo#$pr"
  elif "$ci_was_primed"; then
    if [[ "$ci_failure_count" -gt 0 ]]; then
      set_status_phase "$key" "CI failing"
    elif [[ "$ci_pending_count" -gt 0 ]]; then
      set_status_phase "$key" "CI pending"
    elif "$ci_state_ready"; then
      set_status_phase "$key" "CI passing"
    fi
  fi

  rm -f "$events_file" "$new_file" "$checks_file"
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
    done < <(session_pane_targets "$session")
  done
}

main() {
  local i initial_issue_rows_file repo issue current_worktree current_session

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
  need_command mktemp
  need_command sort
  need_command tail
  need_command tmux
  if command_uses_windows_paths "$GH_COMMAND" || command_uses_windows_paths "$GIT_COMMAND"; then
    need_command wslpath
  fi

  log_startup_tools
  require_repo_root
  require_default_branch
  "$GH_COMMAND" auth status >/dev/null || die "$GH_COMMAND is not authenticated"

  mkdir -p "$STATE_DIR"
  WATCH_TEMP_DIR="$(mktemp -d)" || die "failed to create temporary directory"
  trap cleanup_watch_temp_dir EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  while true; do
    if read_watch_state; then
      initial_issue_rows_file="$(watch_temp_file)"
      for ((i = 0; i < ${#REPOS[@]}; i++)); do
        [[ -n "${ISSUES[$i]}" ]] || continue
        printf '%s\t%s\n' "${REPOS[$i]}" "${ISSUES[$i]}" >>"$initial_issue_rows_file"
      done

      discover_copilot_issues

      while IFS=$'\t' read -r repo issue; do
        [[ -n "$repo" && -n "$issue" ]] || continue
        if watch_state_find_item "$repo" "" "$issue" current_worktree current_session; then
          if ! process_issue_item "$repo" "$issue" "$current_worktree" "$current_session"; then
            start_discovered_issue "$repo" "$issue" || true
          fi
        fi
      done <"$initial_issue_rows_file"
      rm -f "$initial_issue_rows_file"

      for ((i = 0; i < ${#REPOS[@]}; i++)); do
        [[ -n "${PRS[$i]}" ]] || continue
        process_watch_item "${REPOS[$i]}" "${PRS[$i]}" "${WORKTREES[$i]}" "${SESSIONS[$i]}"
      done
      monitor_configured_sessions
    fi

    maybe_update_status_issue
    persist_idle_screen_observations
    print_status_line "${#REPOS[@]}" "$POLL_SECONDS"
    "$ONCE" && break
    sleep "$POLL_SECONDS"
  done
}

main "$@"
