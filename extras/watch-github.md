# watch-github.py

`watch-github.py` watches GitHub PR comments, reviews, and CI checks for PRs listed in its
internal state file. When a new comment or review appears, or CI starts failing, it starts or
reuses a tmux session rooted in the PR worktree and sends:

```text
<skill-prefix>slang-pr-resolve-comments --single-pass <PR_URL>
```

The watcher passes `--single-pass` to `slang-pr-resolve-comments`, so each dispatched agent pass
handles the current PR state and returns control to the watcher instead of scheduling its own
follow-up.

The watch list is internal state managed by the surrounding workflow. It is read from
`STATE_DIR/watch-github.conf`; this document intentionally does not define that file format as a
public interface. Recoverable errors during polling, such as malformed watch-state rows or
temporary GitHub/path lookup failures, are logged and skipped for that poll instead of terminating
the watcher.

The watcher also discovers open issues in the configured issue repository that are assigned to
`@me` and have the `Copilot` label. For each issue, it lists candidate PRs from GitHub issue
metadata, timeline references, and open PRs whose head branch contains `issue-N`, where `N` is the
issue number. A candidate only counts if it is open, was created by `@me`, and its head branch
contains that issue branch marker. If any matching PR exists, the watcher tracks that PR instead of
starting issue work.

If there is no open related PR and the issue is not already tracked, the watcher first checks for
an existing `issue-N` tmux session. If one exists, it treats that as failed setup recovery, kills
the session, then deletes any safe `issue-N` worktree path because it may be leftover or corrupted.
If no tmux session exists, the same worktree cleanup still runs. Before fresh setup, the watcher
also removes the reserved local `issue-N` branch so stale branch contents are not reused. Fresh
issue worktrees are created through `create_issue_worktree`, which validates the reserved branch,
adds the sibling Git worktree, and initializes submodules through the watcher's configured Git
command. The issue is added to watch state only after the new agent is live. The normal
tracked-issue path then sends the initial issue prompt once the agent's captured screen is stable.

For tracked issue rows, the watcher treats the agent as idle when the captured pane screen repeats
across polling checks. The first idle check for a tmux target during a poll computes and caches that
target's idle result; later checks in the same poll reuse the cached answer. The watcher persists
the latest observed screen once at the end of that poll, so two checks in the same poll cannot make
the current screen become the previous screen. Issue rows already present at the beginning of a poll
are processed after discovery even if the issue is absent from the latest discovery result; issue
rows appended during that discovery pass wait until the next poll. If the tracked tmux session no
longer has a live agent, the issue row is removed and rediscovered through the fresh setup path. The
same happens when the tracked worktree is missing or the tmux session is rooted somewhere else. When
the agent is idle and live, it checks whether the worktree HEAD is already contained in any known
ref for the target repository default branch. If so, it sends the issue prompt. If the worktree has
a new commit, it sends `slang-pr-create <origin-repo>`.

For tracked PR rows, the watcher checks the configured tmux session before fetching PR state from
GitHub. Missing sessions are logged and skipped until the next poll. Existing sessions are only
polled for GitHub events after their live agent pane has gone idle. If the idle screen is waiting
for a permission or trust prompt, the watcher sends Enter, sets the phase to
`Advancing agent`, and waits for the next poll. If the idle screen contains a recoverable agent
error, such as a Codex terminal retry-limit failure, the watcher sets the phase to
`Recovering agent`, sends the recovery prompt, and waits for the next poll. Otherwise it sets the
phase to `Waiting for next events` before fetching PR, comment, and CI state.

## Issue State Flow

```mermaid
flowchart TD
    A["Discover assigned open issue with `Copilot` label"] --> B{"Find matching open PR?"}
    B -- lookup failed --> Z["Log and skip this issue until the next poll"]
    B -- found --> C{"PR row already tracked?"}
    B -- none --> L{"Issue row already tracked?"}

    C -- yes --> D{"Issue row also tracked?"}
    D -- yes --> E["Remove issue row"]
    D -- no --> P0
    E --> P0
    C -- no --> F{"Issue row tracked?"}
    F -- yes --> G["Replace issue row with PR row"]
    F -- no --> H["Append PR row using issue worktree/session"]
    G --> I["Set phase `PR discovered`"]
    H --> I
    I --> P0["Process PR rows in PR pass"]

    L -- yes --> T0
    L -- no --> N{"Does `issue-N` tmux session exist?"}
    N -- yes --> O{"Kill existing tmux session and verify gone?"}
    O -- failed --> Z
    O -- succeeded --> V
    N -- no --> V{"Delete safe issue worktree path if present?"}
    V -- failed --> Z
    V -- succeeded --> W{"`create_issue_worktree` creates branch, worktree, and submodules?"}
    W -- failed --> Z
    W -- succeeded --> X["Clear cached idle state for `issue-N` agent"]
    X --> Y{"Ensure/start agent and verify live?"}
    Y -- failed --> Z
    Y -- live --> AA["Append issue row; phase `Initalizing agent`; CI `N/A`"]
    AA --> Z

    T0["Issue row present at start of poll"] --> T1{"Worktree exists?"}
    T1 -- no --> R
    T1 -- yes --> T2{"tmux state is `no session` or `unknown`?"}
    T2 -- yes --> R
    T2 -- no --> T3{"Session cwd matches row worktree?"}
    T3 -- no --> R["Remove issue row"]
    R --> N
    T3 -- yes --> T4{"tmux state is `idle`?"}
    T4 -- no --> Z
    T4 -- yes --> T5{"Target still looks like live agent?"}
    T5 -- no --> R
    T5 -- yes --> T6{"Resolve PR base repo?"}
    T6 -- no --> T7["Set phase `repo check failed`"]
    T7 --> Z
    T6 -- yes --> T8{"HEAD is in default branch history?"}
    T8 -- yes --> T9["Send issue work prompt"]
    T9 --> T10{"Prompt sent?"}
    T10 -- yes --> T11["Set phase `issue prompt`"]
    T10 -- no --> T12["Set phase `dispatch failed`"]
    T8 -- compare failed --> T13["Set phase `head check failed`"]
    T8 -- no --> T14["Send `slang-pr-create` prompt"]
    T14 --> T15{"Prompt sent?"}
    T15 -- yes --> T16["Set phase `create PR`"]
    T15 -- no --> T12
    T11 --> Z
    T12 --> Z
    T13 --> Z
    T16 --> Z
```

## PR State Flow

```mermaid
flowchart TD
    A["Poll a watch-state PR row"] --> B["Ensure status defaults"]
    B --> B0{"tmux session exists?"}
    B0 -- no --> B1["Log missing session"]
    B1 --> BZ["Skip until next poll"]
    B0 -- yes --> B2{"Live agent pane is idle?"}
    B2 -- no --> BZ
    B2 -- yes --> B3{"Idle screen is waiting for input?"}
    B3 -- yes --> B4["Send Enter; set phase `Advancing agent`"]
    B4 --> BZ
    B3 -- no --> B6{"Idle screen has recoverable agent error?"}
    B6 -- yes --> B7["Set phase `Recovering agent`; send recovery prompt"]
    B7 --> BZ
    B6 -- no --> B5["Set phase `Waiting for next events`"]
    B5 --> BA{"Fetch PR state?"}
    BA -- no --> BB["Set phase `PR state unknown`"]
    BB --> BZ
    BA -- yes --> BC{"PR state is `open`?"}
    BC -- no --> BD["Remove PR row from watch state"]
    BC -- yes --> CA{"PR has configured Copilot label?"}
    CA -- yes --> C{"Fetch comments, review comments, and reviews?"}
    CA -- no --> CB["Mark prompts paused"]
    CB --> C
    C -- no --> D["Log comment fetch failure"]
    C -- yes --> E{"Seen-id file exists?"}
    E -- no --> F["Create empty seen-id file"]
    F --> G{"`BOOTSTRAP_MODE` is `trigger`?"}
    G -- no --> H["Prime seen IDs from existing events"]
    G -- yes --> I["Collect fetched events as new"]
    E -- yes --> J["Collect events not in seen-id file"]
    I --> K{"Any new events?"}
    J --> K
    H --> L["No comment dispatch"]
    D --> L
    K -- no --> L
    K -- yes --> M["Mark comment dispatch pending"]

    L --> N{"`WATCH_CI` is `true`?"}
    M --> N
    N -- no --> O["Set CI to `not watched`"]
    N -- yes --> P{"Fetch fail/cancel/pending checks?"}
    P -- no --> Q["Set CI to `unknown` and log"]
    P -- yes --> R["Count checks, compute CI signature, write CI status"]
    R --> U{"No CI state file and `CI_BOOTSTRAP_MODE` is not `trigger`?"}
    U -- yes --> V["Store signature; mark CI just primed; suppress CI change"]
    U -- no --> S{"Signature differs from stored CI signature?"}
    S -- no --> T["No CI change"]
    S -- yes --> W{"Any fail or cancel checks?"}
    W -- yes --> X["Mark failing-CI dispatch pending"]
    W -- no --> Y{"Any pending checks?"}
    Y -- yes --> ZA["Mark CI pending change"]
    Y -- no --> ZB["Mark CI passing change"]

    O --> ZC{"Comment or failing-CI dispatch pending?"}
    Q --> ZC
    T --> ZC
    V --> ZC
    X --> ZC
    ZA --> ZC
    ZB --> ZC

    ZC -- yes --> ZCA{"Prompts paused?"}
    ZCA -- yes --> ZCB["Log skipped prompt; leave pending state for retry"]
    ZCA -- no --> ZD["Ensure/start agent and send `slang-pr-resolve-comments --single-pass`"]
    ZCB --> ZP
    ZD --> ZE{"Prompt sent?"}
    ZE -- yes --> ZFA{Is there comment pending}
    ZFA -- yes --> ZFB["Set phase `Addressing comments`"]
    ZFA -- no --> ZFC["Set phase `All comments resolved`"]
    ZFB --> ZF["Store seen IDs and failing-CI signature when applicable"]
    ZFC --> ZF
    ZE -- no --> ZG["Set phase `dispatch failed`; leave pending state for retry"]
    ZC -- no --> ZH{"CI pending change?"}
    ZH -- yes --> ZI["Store signature; set phase `CI pending`"]
    ZH -- no --> ZJ{"CI passing change?"}
    ZJ -- yes --> ZK["Store signature; set phase `CI passing`"]
    ZJ -- no --> ZL{"CI just primed?"}
    ZL -- yes --> ZM["Set phase from current CI state"]
    ZL -- no --> ZP{"Prompts paused?"}
    ZF --> ZP
    ZG --> ZP
    ZI --> ZP
    ZK --> ZP
    ZM --> ZP
    ZP -- yes --> ZQ["Set phase `paused`"]
    ZP -- no --> ZN["Remove temporary files"]
    ZQ --> ZN
```

## Usage

```bash
extras/watch-github.py [--agent [claude|codex]] [--once] [--status-issue URL]
```

Options:

- `--agent [claude|codex]`: select the agent to run in tmux. Defaults to `codex`.
- `--once`: run one polling pass and exit.
- `--status-issue URL`: update a GitHub issue with watcher status once per polling pass. The URL
  must look like `https://github.com/OWNER/REPO/issues/NUMBER`.
  The managed status block shows `Item`, `Phase`, and `CI`. If watched tmux agent panes exist, the
  block also appends their captured screens at the bottom as folded `details` sections. Each pane
  shows the last 10 captured lines after the folded section; the expanded body contains earlier
  captured lines so the visible tail is not duplicated. The combined capture is limited by
  `CAPTURE_LINES`. The `Phase` and `CI` cells include scan-friendly status icons: 🟢 ready or
  passing, 🔵 active work, 🟡 pending, 🔴 failure or unknown, ⏸️ paused or not watched, and ⚪
  not applicable.

## Agent Configuration

The watcher runs an interactive agent CLI inside tmux. The `--agent` command-line option selects
the agent for a run. Supported values are `codex` and `claude`; `AGENT_COMMAND` provides the same
value through the environment. New tmux sessions and agent windows start with the agent launch
command as the tmux command itself, so a successful setup must leave a live agent process in the
pane. The watcher sends the issue prompt after readiness detection instead of passing it on the
agent command line; tracked issue processing sends it after the once-per-poll idle check passes.

- `AGENT_COMMAND`: agent command to start. Defaults to `codex`. Use `AGENT_COMMAND=claude` for
  Claude Code.
- `AGENT_FLAGS`: flags appended when starting the agent. Defaults to empty. Codex permission and
  trust prompts are handled through `AGENT_APPROVAL_PATTERN`.
- `AGENT_SKILL_PREFIX`: prefix before agent skills such as `slang-pr-resolve-comments` and
  `slang-pr-create`. Defaults to `$` for Codex and `/` for Claude.
- `AGENT_WINDOW_NAME`: tmux window name for the agent. Defaults to the command name.
- `AGENT_SESSION_PREFIX`: prefix for generated PR tmux session names. Defaults to
  `AGENT_WINDOW_NAME`.
- `AGENT_READY_PATTERN`: extended regex used to detect that the agent has started. Readiness also
  requires the tmux pane's current command to be a non-shell process.
- `AGENT_APPROVAL_PATTERN`: extended regex used to detect approval and trust prompts. When this
  matches, the watcher sends Enter.
- `AGENT_RECOVERABLE_ERROR_PATTERN`: extended regex used to detect terminal agent errors that can
  be retried by sending `AGENT_RECOVERY_PROMPT`. Defaults to Codex retry-limit errors with HTTP
  `403 Forbidden` or `429 Too Many Requests` status. WebSocket fallback warnings alone are not
  treated as terminal errors.
- `AGENT_RECOVERY_PROMPT`: prompt sent after a recoverable terminal agent error. Defaults to
  `resume`.
- `AGENT_SHELL_COMMAND_PATTERN`: extended regex for shell process names that do not count as a
  live agent pane.
- `AGENT_START_WAIT_SECONDS`: seconds between readiness checks after starting the agent, and the
  extra settle wait after readiness is detected.
- `AGENT_START_ATTEMPTS`: number of readiness checks before startup is considered failed.

## Polling and State

- `STATE_DIR`: directory for internal watcher state, including the PR list and seen IDs. Defaults
  to `${XDG_CACHE_HOME:-$HOME/.cache}/watch-github`.
- `POLL_SECONDS`: seconds between quiet idle polling passes. Defaults to `60`.
- `POLL_ACTIVE_SECONDS`: seconds before the next poll when a tracked agent is still working.
  Defaults to `10`.
- `POLL_ACTION_SECONDS`: seconds before the next poll after the watcher sends input to an agent,
  such as Enter, a recovery prompt, or a task prompt. Defaults to `5`.
- `BOOTSTRAP_MODE`: `prime` records existing comments on first run without dispatching; `trigger`
  dispatches for already-present comments on first run. Defaults to `prime`.
- `CI_BOOTSTRAP_MODE`: same behavior as `BOOTSTRAP_MODE`, but for current CI failure state.
  Defaults to `BOOTSTRAP_MODE`.
- `WATCH_CI`: set to `false` to ignore CI check changes. Defaults to `true`.
- `WATCH_COPILOT_ISSUES`: set to `false` to disable assigned Copilot issue discovery. Defaults
  to `true`.
- `COPILOT_LABEL`: label used for issue discovery and PR-row processing. PR-row matching ignores
  case. PR rows without this label still update comment and CI state, but skip agent prompts and
  report phase `paused`. Defaults to `Copilot`.
- `ISSUE_LIST_LIMIT`: maximum number of assigned Copilot issues to list per poll. Defaults to
  `100`.
- `WATCH_ISSUE_REPO`: repository used for assigned issue discovery. Defaults to
  `shader-slang/slang`.
- `PR_BASE_REPO`: repository passed to `slang-pr-create` for issue PR creation. If unset, the
  watcher parses the GitHub `owner/repo` value from the `origin` remote URL.
- `COMMENT_PAGE_SIZE`: GitHub API page size for comment and review fetches. Defaults to `100`.
- `CAPTURE_LINES`: tmux pane capture depth used for state detection and status-issue screen
  captures. Defaults to `250`.
- `MATCH_TAIL_LINES`: number of captured tail lines scanned for approval and trust prompts.
  Defaults to `50`.

## Prompt Delivery

- `PROMPT_ENTER_DELAY_SECONDS`: wait after pasting a prompt before sending Enter.
- `PROMPT_SEND_ATTEMPTS`: tmux paste retry count.

## Tool Overrides

- `GH_COMMAND`: GitHub CLI command. Defaults to `gh.exe` under WSL when available, otherwise `gh`.
- `GIT_COMMAND`: Git command. Defaults to `git.exe` under WSL when available, otherwise `git`.
- `DEFAULT_BRANCH`: override when `origin/HEAD` is unavailable.

When `GIT_COMMAND` resolves to a Windows `.exe` under WSL, worktree paths passed to Git are
converted to Windows paths before invocation.

The script must be run from the repository default branch, and the GitHub CLI must already be
authenticated.
