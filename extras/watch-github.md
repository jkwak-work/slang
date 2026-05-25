# watch-github.sh

`watch-github.sh` watches GitHub PR comments, reviews, and CI checks for PRs listed in its
internal state file. When a new comment or review appears, or CI starts failing, it starts or
reuses a tmux session rooted in the PR worktree and sends:

```text
<skill-prefix>slang-pr-resolve-comments <PR_URL>
```

The watch list is internal state managed by the surrounding workflow. It is read from
`STATE_DIR/watch-github.conf`; this document intentionally does not define that file format as a
public interface. Recoverable errors during polling, such as malformed watch-state rows or
temporary GitHub/path lookup failures, are logged and skipped for that poll instead of terminating
the watcher.

The watcher also discovers open issues in the configured issue repository that are assigned to
`@me` and have the `Copilot` label. For each issue, it lists related PRs from GitHub issue
metadata and timeline references. If any related PR is open, the watcher tracks that PR instead of
starting issue work.

If there is no open related PR and the issue is not already tracked, the watcher first checks for
an existing `issue-N` tmux session. If one exists, it treats that as failed setup recovery, kills
the session, then deletes any safe `issue-N` worktree path because it may be leftover or corrupted.
If no tmux session exists, the same worktree cleanup still runs. A fresh worktree is then created
with `extras/git-worktree-add.sh --issue N issue-N`. The issue is added to watch state only after
the new agent is live.

For tracked issue rows, the watcher treats the agent as idle when the captured pane screen repeats
across polling checks. If the tracked tmux session no longer has a live agent, the issue row is
removed and rediscovered through the fresh setup path. When the agent is idle and live, it compares
the worktree HEAD with the target repository default branch. If they match, it sends the issue
prompt. If the worktree has a new commit, it sends `slang-pr-create <origin-repo>`.

## Issue State Flow

```mermaid
flowchart TD
    A["Discover assigned open issue with `Copilot` label"] --> B["Find related PRs from issue refs and timeline"]
    B --> C{"Related PR lookup succeeded?"}
    C -- no --> Z["Log and skip this issue until the next poll"]
    C -- yes --> D{"Any related PR is open?"}

    D -- yes --> E{"Is that PR already tracked?"}
    E -- yes --> F{"Is the issue row tracked?"}
    F -- yes --> G["Remove the issue row"]
    F -- no --> P0
    G --> P0
    E -- no --> H{"Is the issue row tracked?"}
    H -- yes --> I["Replace the issue row with a PR row"]
    H -- no --> J["Append a PR row"]
    I --> K["Set phase `PR discovered`"]
    J --> K
    K --> P0["Continue with PR state flow"]

    D -- no --> L{"Is the issue row tracked?"}
    L -- yes --> M["Process tracked issue row"]
    BA --> N
    L -- no --> N{"Does `issue-N` tmux session exist?"}
    N -- yes --> O{"Kill existing tmux session"}
    O -- failed --> Z
    O -- succeed --> V
    N -- no --> V{"Does the issue worktree path exist?"}
    V -- yes --> W{"Delete the safe `issue-N` worktree path"}
    V -- no --> U["Create worktree for `issue-N`"]
    W -- failed --> Z
    W -- succeed --> U
    U --> X["Create a tmux session and start an agent in `issue-N`"]
    X --> AA["Append issue row; phase `progress`; CI `not watched`"]
    AA --> Z

    M --> AB{"tmux state is `idle`?"}
    AB -- no --> Z
    AB -- yes --> Y{"Agent live?"}
    Y -- no --> BA["Remove the issue row"]
    Y -- yes --> AC{"Resolve PR base repo?"}
    AC -- no --> AD["Set phase `repo check failed`"]
    AD --> Z
    AC -- yes --> AE{"HEAD matches base branch?"}
    AE -- yes --> AF["Send issue work prompt"]
    AF --> AG{"Prompt sent?"}
    AG -- yes --> AH["Set phase `issue prompt`"]
    AG -- no --> AI["Set phase `dispatch failed`"]
    AE -- compare failed --> AJ["Set phase `head check failed`"]
    AE -- no --> AK["Send `slang-pr-create` prompt"]
    AK --> AL{"Prompt sent?"}
    AL -- yes --> AM["Set phase `create PR`"]
    AL -- no --> AI
    AH --> Z
    AI --> Z
    AJ --> Z
    AM --> Z
```

## PR State Flow

```mermaid
flowchart TD
    A["Poll a watch-state PR row"] --> B["Ensure status defaults"]
    B --> C{"Fetch comments, review comments, and reviews?"}
    C -- no --> D["Log comment fetch failure"]
    C -- yes --> E{"Seen-id file exists?"}
    E -- no --> F{"`BOOTSTRAP_MODE` is `trigger`?"}
    F -- no --> G["Prime seen IDs from existing events"]
    F -- yes --> H["Collect fetched events as new"]
    E -- yes --> I["Collect events not in seen-id file"]
    H --> J{"Any new events?"}
    I --> J
    G --> K["No comment dispatch"]
    D --> K
    J -- no --> K
    J -- yes --> L["Mark comment dispatch pending"]

    K --> M{"`WATCH_CI` is `true`?"}
    L --> M
    M -- no --> N["Set CI to `not watched`"]
    M -- yes --> O{"Fetch fail/cancel/pending checks?"}
    O -- no --> P["Set CI to `unknown` and log"]
    O -- yes --> Q["Count checks, compute CI signature, write CI status"]
    Q --> R{"CI signature changed?"}
    R -- no --> S{"Was this CI state just primed?"}
    R -- yes --> T{"First sample and `CI_BOOTSTRAP_MODE` is not `trigger`?"}
    T -- yes --> U["Store signature and mark CI primed"]
    U --> S
    T -- no --> V{"Any fail or cancel checks?"}
    V -- yes --> W["Mark failing-CI dispatch pending"]
    V -- no --> X{"Any pending checks?"}
    X -- yes --> Y["Mark CI pending change"]
    X -- no --> ZA["Mark CI passing change"]
    S -- yes --> ZB["Set phase from current CI state"]
    S -- no --> ZC{"Comment or failing-CI dispatch pending?"}
    N --> ZC
    P --> ZC
    W --> ZC
    Y --> ZC
    ZA --> ZC
    ZB --> ZD["Remove temporary files"]

    ZC -- yes --> ZE["Ensure/start agent and send `slang-pr-resolve-comments`"]
    ZE --> ZF{"Prompt sent?"}
    ZF -- yes --> ZG["Set phase `addressing comments`; store seen IDs and failing-CI signature when applicable"]
    ZF -- no --> ZH["Set phase `dispatch failed`; leave pending state for retry"]
    ZC -- no --> ZI{"CI pending change?"}
    ZI -- yes --> ZJ["Store signature; set phase `CI pending`"]
    ZI -- no --> ZK{"CI passing change?"}
    ZK -- yes --> ZL["Store signature; set phase `CI passing`"]
    ZK -- no --> ZD
    ZG --> ZD
    ZH --> ZD
    ZJ --> ZD
    ZL --> ZD
```

## Usage

```bash
extras/watch-github.sh [--agent [claude|codex]] [--once] [--status-issue URL]
```

Options:

- `--agent [claude|codex]`: select the agent to run in tmux. Defaults to `codex`.
- `--once`: run one polling pass and exit.
- `--status-issue URL`: update a GitHub issue with watcher status once per polling pass. The URL
  must look like `https://github.com/OWNER/REPO/issues/NUMBER`.

## Agent Configuration

The watcher runs an interactive agent CLI inside tmux. The `--agent` command-line option selects
the agent for a run. Supported values are `codex` and `claude`; `AGENT_COMMAND` provides the same
value through the environment. New tmux sessions and agent windows start with the agent launch
command as the tmux command itself, so a successful setup must leave a live agent process in the
pane. The watcher sends the issue prompt after readiness detection instead of passing it on the
agent command line; it waits until the agent's idle input prompt is visible before sending.

- `AGENT_COMMAND`: agent command to start. Defaults to `codex`. Use `AGENT_COMMAND=claude` for
  Claude Code.
- `AGENT_FLAGS`: flags appended when starting the agent. Defaults depend on `AGENT_COMMAND`:
  Codex uses `--dangerously-bypass-approvals-and-sandbox`; Claude uses
  `--dangerously-skip-permissions`.
- `AGENT_SKILL_PREFIX`: prefix before agent skills such as `slang-pr-resolve-comments` and
  `slang-pr-create`. Defaults to `$` for Codex and `/` for Claude.
- `AGENT_WINDOW_NAME`: tmux window name for the agent. Defaults to the command name.
- `AGENT_READY_PATTERN`: extended regex used to detect that the agent has started. Readiness also
  requires the tmux pane's current command to be a non-shell process.
- `AGENT_PROMPT_LINE_PATTERN`: extended regex used to identify the agent's current prompt line.
- `AGENT_PENDING_INPUT_PATTERN`: extended regex used to detect watcher-owned pending input. The
  default matches the agent prompt marker plus watcher-owned skill prompts, so suggested prompt text
  is not treated as pending input.
- `AGENT_WORKING_PATTERN`: extended regex used to detect work in progress.
- `AGENT_APPROVAL_PATTERN`: extended regex used to detect approval prompts.
- `AGENT_TRUST_PROMPT_PATTERN`: extended regex used to detect startup trust prompts. When this
  matches, the watcher sends `1` and Enter before waiting for agent readiness.
- `AGENT_START_WAIT_SECONDS`: seconds between readiness checks after starting the agent.
- `AGENT_START_ATTEMPTS`: number of readiness checks before startup is considered failed.

## Polling and State

- `STATE_DIR`: directory for internal watcher state, including the PR list and seen IDs. Defaults
  to `${XDG_CACHE_HOME:-$HOME/.cache}/watch-github`.
- `POLL_SECONDS`: seconds between polling passes. Defaults to `60`.
- `BOOTSTRAP_MODE`: `prime` records existing comments on first run without dispatching; `trigger`
  dispatches for already-present comments on first run. Defaults to `prime`.
- `CI_BOOTSTRAP_MODE`: same behavior as `BOOTSTRAP_MODE`, but for current CI failure state.
  Defaults to `BOOTSTRAP_MODE`.
- `WATCH_CI`: set to `false` to ignore CI check changes. Defaults to `true`.
- `WATCH_COPILOT_ISSUES`: set to `false` to disable assigned Copilot issue discovery. Defaults
  to `true`.
- `COPILOT_LABEL`: label used for issue discovery. Defaults to `Copilot`.
- `ISSUE_LIST_LIMIT`: maximum number of assigned Copilot issues to list per poll. Defaults to
  `100`.
- `WATCH_ISSUE_REPO`: repository used for assigned issue discovery. Defaults to
  `shader-slang/slang`.
- `PR_BASE_REPO`: repository passed to `slang-pr-create` for issue PR creation. Defaults
  to `origin`; the skill resolves that repository's default branch.
- `COMMENT_PAGE_SIZE`: GitHub API page size for comment and review fetches.
- `CAPTURE_LINES`: tmux pane capture depth used for prompt detection.
- `MATCH_TAIL_LINES`: number of captured tail lines scanned for prompt/state matches.

## Prompt Delivery

- `SEND_VERIFY_WAIT_SECONDS`: wait after pasting or submitting before checking the pane.
- `PROMPT_ENTER_DELAY_SECONDS`: wait before sending Enter after a prompt paste.
- `PROMPT_SEND_ATTEMPTS`: paste retry count.
- `PROMPT_ENTER_ATTEMPTS`: submit retry count.

## Tool Overrides

- `GH_COMMAND`: GitHub CLI command. Defaults to `gh.exe` under WSL when available, otherwise `gh`.
- `GIT_COMMAND`: Git command. Defaults to `git.exe` under WSL when available, otherwise `git`.
- `DEFAULT_BRANCH`: override when `origin/HEAD` is unavailable.

When `GH_COMMAND` or `GIT_COMMAND` resolves to a Windows `.exe` under WSL, local temporary files
and worktree paths passed to those tools are converted to Windows paths before invocation.

The script must be run from the repository default branch, and the GitHub CLI must already be
authenticated.
