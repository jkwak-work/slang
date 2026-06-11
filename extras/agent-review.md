# agent-review.py

`extras/agent-review.py` is a long-running local watcher for CoPilot-labeled pull requests
assigned to the authenticated GitHub user. It discovers matching PRs in `shader-slang/slang`
and `@me/slang`, creates or reuses sibling worktrees, starts one tmux session per worktree, and
sends review-maintenance prompts to the agent running in the first tmux window.

Keep the Mermaid flows in this document updated as the primary behavior contract whenever the
script behavior changes.

## Usage

```bash
extras/agent-review.py --agent codex
extras/agent-review.py --agent claude
extras/agent-review.py --once --dry-run --no-submodules
```

The script must be run from inside a Slang git worktree. It resolves the repository root and
creates new worktrees as siblings of that root.

The GitHub CLI must already be authenticated. On native Linux it uses `gh` and `git`. Under WSL it
defaults to `gh.exe` and `git.exe` and converts path arguments for Windows-hosted Git.

## State

The public tracking file is:

```text
~/.cache/agent-review/agent-review.conf
```

Each non-comment row has this format:

```text
path tmux-session-name url [url ...]
```

Example:

```text
/home/shadeform/git/issue-11500 issue-11500 https://github.com/jkwak-work/slang/pull/251 https://github.com/shader-slang/slang/pull/11546
```

URLs are last because one worktree/session can correspond to more than one PR URL, such as an
upstream PR and a fork PR for the same branch. The script keeps derived state beside the config
file using hashed filenames for seen comments, CI signatures, queued initial prompts, and tmux idle
signatures.

## Discovery Flow

```mermaid
flowchart TD
    A["Start poll"] --> B["Resolve @me with `gh api user`"]
    B --> C["List open PRs in `shader-slang/slang` and `@me/slang`"]
    C --> D{"PR is assigned to @me and has `CoPilot` label?"}
    D -- no --> Z["Ignore for this poll"]
    D -- yes --> E["Read PR head owner, head branch, and head SHA"]
    E --> F["Convert head branch to a safe directory name by replacing path separators with `-`"]
    F --> G{"Head owner is @me?"}
    G -- yes --> H["Worktree path: `../<branch-dir>`\nLocal branch: original PR head branch"]
    G -- no --> I["Worktree path: `../<branch-dir>-<me>`\nLocal branch: same as directory name"]
    H --> J{"Worktree directory exists?"}
    I --> J
    J -- yes --> K{"Directory is a git worktree?"}
    K -- no --> Z
    K -- yes --> O["Reuse existing worktree"]
    J -- no --> L["Fetch `refs/pull/N/head` from the PR base repo"]
    L --> M{"Head owner is @me?"}
    M -- yes --> N["Create worktree on the PR branch\nFast-forward existing local branch only when safe"]
    M -- no --> P["Create worktree with `git worktree add -B <dir-name>`\nReset branch to the PR head ref"]
    N --> Q["Optionally initialize submodules"]
    P --> Q
    O --> R["Upsert `path session url...` row in `agent-review.conf`"]
    Q --> R
    R --> S["Ensure tmux session named after the directory"]
    S --> T["First tmux window runs selected agent in the worktree"]
    T --> U["Configure tmux default command so new windows start in the worktree"]
    U --> V{"Newly discovered PR is not from @me?"}
    V -- yes --> W["Queue/send `<prefix>slang-pr-create @me/slang`"]
    V -- no --> X["Discovery complete for this PR"]
    W --> X
```

`<prefix>` defaults to `$` for Codex and `/` for Claude. Override it with
`AGENT_SKILL_PREFIX` if the agent CLI changes.

## Monitor Flow

```mermaid
flowchart TD
    A["Poll tracked state row"] --> B["Ensure first tmux window has a live agent"]
    B --> C{"Agent screen shows permission/trust prompt?"}
    C -- yes --> D["Send Enter through tmux"]
    D --> Z["Wait for next poll"]
    C -- no --> E{"Queued initial `slang-pr-create` prompt?"}
    E -- yes --> F{"Agent is newly started or idle?"}
    F -- no --> Z
    F -- yes --> G["Send `<prefix>slang-pr-create @me/slang`"]
    G --> Z
    E -- no --> H{"Captured screen is unchanged from last poll?"}
    H -- no --> Z
    H -- yes --> I["Fetch PR status for each URL in the row"]
    I --> J{"PR is still open, assigned to @me, and labeled `CoPilot`?"}
    J -- no --> K["Remove that URL from the row"]
    K --> L{"Any URLs remain?"}
    L -- no --> Z
    L -- yes --> M
    J -- yes --> M["Fetch issue comments, review comments, reviews, and CI checks"]
    M --> N{"New non-agent comment/review event?"}
    N -- yes --> P["Mark dispatch pending"]
    N -- no --> O{"Failing/canceled CI signature changed?"}
    O -- yes --> P
    O -- no --> Q["Record passing or pending CI signature changes without dispatch"]
    P --> R["Send `<prefix>slang-pr-resolve-comments --single-pass <url...>`"]
    R --> S{"Prompt sent?"}
    S -- yes --> T["Persist seen comment IDs and failing CI signature"]
    S -- no --> U["Leave state pending for retry on next idle poll"]
    Q --> Z
    T --> Z
    U --> Z
```

The idle check is intentionally conservative: a pane is idle only after the captured screen matches
the previous poll. This avoids sending a new task while the agent is still streaming or editing.

## Configuration

Command-line options:

```text
--agent {codex,claude}      Agent CLI to start in tmux. Defaults to codex.
--agent-flags TEXT          Extra flags appended to the agent launch command.
--repo OWNER/REPO           Repository to scan. Repeatable. Overrides the default repo pair.
--label LABEL               Label to require. Defaults to CoPilot.
--limit N                   PR discovery limit per repository. Defaults to 100.
--poll-seconds N            Quiet polling interval. Defaults to 60.
--state-dir PATH            State directory. Defaults to ~/.cache/agent-review.
--once                      Run one poll and exit.
--dry-run                   Discover and print planned state without writing files or starting tmux.
--no-submodules             Skip submodule initialization for new worktrees.
```

Environment overrides:

```text
GH_COMMAND                  GitHub CLI command.
GIT_COMMAND                 Git command.
AGENT_COMMAND               Agent command, normally codex or claude.
AGENT_FLAGS                 Extra flags for the agent command.
AGENT_SKILL_PREFIX          Prefix before skill names.
AGENT_READY_PATTERN         Regex for agent readiness detection.
AGENT_APPROVAL_PATTERN      Regex for permission/trust prompts.
AGENT_SHELL_COMMAND_PATTERN Regex for shell commands that may be replaced by an agent.
POLL_SECONDS                Quiet poll interval.
POLL_ACTIVE_SECONDS         Poll interval while an agent is active.
POLL_ACTION_SECONDS         Poll interval after sending input.
BOOTSTRAP_MODE              `prime` or `trigger` for existing comments. Defaults to prime.
CI_BOOTSTRAP_MODE           `prime` or `trigger` for existing CI failures. Defaults to BOOTSTRAP_MODE.
WATCH_CI                   Set to false to ignore CI checks.
INIT_SUBMODULES             Set to false to skip submodule initialization.
COPILOT_LABEL               Label to require. Defaults to CoPilot.
DISCOVERY_LIMIT             PR discovery limit per repository.
STATE_DIR                   State directory.
```

## Notes

For branch names containing `/`, the worktree directory replaces separators with `-`; the local
branch for PRs owned by `@me` remains the original PR branch name. For PRs not owned by `@me`, the
directory name gets the `-<me>` suffix and the local branch name is the same as the directory name.

The script never deletes worktrees or tmux sessions. Closed, unassigned, or unlabeled PR URLs are
removed from `agent-review.conf`, but the local checkout is left for manual inspection.
