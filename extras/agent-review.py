#!/usr/bin/env python3
"""
Discover assigned CoPilot PRs, create review worktrees, and drive tmux agents.

The persistent public state is:

    path tmux-session-name url [url ...]

in ~/.cache/agent-review/agent-review.conf. Per-URL derived state, such as
seen comments and CI signatures, lives beside that file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULT_LABEL = "CoPilot"
DEFAULT_UPSTREAM_REPO = "shader-slang/slang"
PR_CREATE_SKILL = "slang-pr-create"
RESOLVE_COMMENTS_SKILL = "slang-pr-resolve-comments"


class AgentReviewError(Exception):
    pass


@dataclass
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


@dataclass
class PullRequest:
    repo: str
    number: str
    url: str
    title: str
    state: str
    labels: list[str]
    assignees: list[str]
    head_owner: str
    head_repo: str
    head_branch: str
    head_sha: str


@dataclass
class StateRow:
    path: str
    session: str
    urls: list[str] = field(default_factory=list)


@dataclass
class PullRequestStatus:
    state: str
    labels: list[str]
    assignees: list[str]
    is_draft: bool
    head_owner: str
    head_repo: str
    head_branch: str


@dataclass
class IssueItem:
    repo: str
    number: str
    url: str
    title: str


@dataclass
class PullRequestAssignmentInfo:
    repo: str
    number: str
    url: str
    title: str
    state: str
    author: str
    assignees: list[str]


def strip_cr(text: str) -> str:
    return text.replace("\r", "")


def is_wsl_environment() -> bool:
    try:
        return bool(re.search(r"microsoft|wsl", Path("/proc/version").read_text(), re.I))
    except OSError:
        return False


def default_host_command(command: str) -> str:
    return f"{command}.exe" if is_wsl_environment() else command


def safe_name(value: str, *, lower: bool = False, fallback: str = "item") -> str:
    value = value.replace("\\", "-").replace("/", "-")
    value = re.sub(r"[^0-9A-Za-z_.-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip(".-")
    if lower:
        value = value.lower()
    if not value:
        value = fallback
    return value[:120].rstrip(".-") or fallback


def state_hash(value: str) -> str:
    return hashlib.sha1(value.encode("utf-8")).hexdigest()[:16]


def parse_pr_url(url: str) -> tuple[str, str] | None:
    match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/pull/([0-9]+)/*", url)
    if not match:
        return None
    return match.group(1), match.group(2)


def unique_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            output.append(value)
    return output


class AgentReview:
    def __init__(self) -> None:
        cache_home = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
        self.script_name = Path(sys.argv[0]).name
        self.state_dir = Path(os.environ.get("STATE_DIR", str(cache_home / "agent-review")))
        self.config_file = self.state_dir / "agent-review.conf"

        self.gh_command = os.environ.get("GH_COMMAND", default_host_command("gh"))
        self.git_command = os.environ.get("GIT_COMMAND", default_host_command("git"))
        self.agent_command = os.environ.get("AGENT_COMMAND", "codex")
        self.agent_flags = os.environ.get("AGENT_FLAGS", "")
        self.agent_yolo = os.environ.get("AGENT_YOLO", "false").lower() in {"1", "true", "yes", "on"}
        self.agent_skill_prefix = os.environ.get("AGENT_SKILL_PREFIX", "")
        self.agent_window_name = os.environ.get("AGENT_WINDOW_NAME", "agent")

        self.poll_seconds = int(os.environ.get("POLL_SECONDS", "60"))
        self.poll_active_seconds = int(os.environ.get("POLL_ACTIVE_SECONDS", "10"))
        self.poll_action_seconds = int(os.environ.get("POLL_ACTION_SECONDS", "5"))
        self.prompt_enter_delay_seconds = int(os.environ.get("PROMPT_ENTER_DELAY_SECONDS", "2"))
        self.prompt_send_attempts = int(os.environ.get("PROMPT_SEND_ATTEMPTS", "3"))
        self.capture_lines = int(os.environ.get("CAPTURE_LINES", "250"))
        self.match_tail_lines = int(os.environ.get("MATCH_TAIL_LINES", "60"))
        self.agent_start_wait_seconds = int(os.environ.get("AGENT_START_WAIT_SECONDS", "5"))
        self.agent_start_attempts = int(os.environ.get("AGENT_START_ATTEMPTS", "12"))
        self.comment_page_size = int(os.environ.get("COMMENT_PAGE_SIZE", "100"))

        self.bootstrap_mode = os.environ.get("BOOTSTRAP_MODE", "prime")
        self.ci_bootstrap_mode = os.environ.get("CI_BOOTSTRAP_MODE", self.bootstrap_mode)
        self.watch_ci = os.environ.get("WATCH_CI", "true").lower() != "false"
        self.init_submodules = os.environ.get("INIT_SUBMODULES", "true").lower() != "false"
        self.copilot_label = os.environ.get("COPILOT_LABEL", DEFAULT_LABEL)
        self.discovery_limit = int(os.environ.get("DISCOVERY_LIMIT", "100"))
        self.issue_limit = int(os.environ.get("ISSUE_LIMIT", os.environ.get("DISCOVERY_LIMIT", "100")))
        self.bot_login = os.environ.get("BOT_PR_AUTHOR", "nv-slang-bot")

        self.viewer_login = ""
        self.repo_root = Path.cwd()
        self.monitored_repos: list[str] = []
        self.rows: list[StateRow] = []
        self.dry_run = False
        self.once = False
        self.assign_bot_prs_enabled = (
            os.environ.get("ASSIGN_BOT_PRS", "true").lower() in {"1", "true", "yes", "on"}
        )
        self.next_poll_seconds = self.poll_seconds
        self.state_changed = False
        self.status_line_active = False

        self.agent_ready_pattern = self.translate_posix_regex(
            os.environ.get("AGENT_READY_PATTERN", self.default_agent_ready_pattern())
        )
        self.agent_approval_pattern = self.translate_posix_regex(
            os.environ.get("AGENT_APPROVAL_PATTERN", self.default_agent_approval_pattern())
        )
        self.agent_shell_command_pattern = self.translate_posix_regex(
            os.environ.get("AGENT_SHELL_COMMAND_PATTERN", self.default_agent_shell_pattern())
        )

        self.approved_signatures: dict[str, str] = {}
        self.idle_screen_texts: dict[str, str] = {}
        self.idle_screen_signatures: dict[str, str] = {}
        self.idle_screen_results: dict[str, bool] = {}

    def log(self, message: str) -> None:
        self.finish_status_line()
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", file=sys.stderr)

    def die(self, message: str) -> None:
        raise AgentReviewError(f"{self.script_name}: {message}")

    def finish_status_line(self) -> None:
        if self.status_line_active and sys.stderr.isatty():
            print(file=sys.stderr)
        self.status_line_active = False

    def print_status_line(self) -> None:
        if not sys.stderr.isatty():
            return
        status = (
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] last poll completed; "
            f"tracking {sum(len(row.urls) for row in self.rows)} URL(s) in {len(self.rows)} session(s); "
            f"next poll in {self.next_poll_seconds}s"
        )
        cols = shutil.get_terminal_size((80, 24)).columns
        if len(status) >= cols and cols > 1:
            status = status[: cols - 1]
        print("\r\033[K" + status + (" " * max(cols - len(status), 0)) + "\r", end="", file=sys.stderr)
        self.status_line_active = True

    @staticmethod
    def translate_posix_regex(pattern: str) -> str:
        return (
            pattern.replace("[[:space:]]", r"\s")
            .replace("[[:digit:]]", r"\d")
            .replace("[[:alnum:]]", r"[0-9A-Za-z]")
        )

    @staticmethod
    def default_agent_shell_pattern() -> str:
        return r"^(bash|dash|sh|zsh|fish|cmd|cmd[.]exe|powershell|powershell[.]exe|pwsh|pwsh[.]exe)$"

    def default_agent_ready_pattern(self) -> str:
        kind = self.normalized_agent_kind(self.agent_command.split()[0] if self.agent_command.split() else "")
        if kind == "claude":
            return r"Claude Code|(^|\s)[>\u276f]\s*(?:Try|$)"
        return r"Codex|gpt-[0-9]|(^|\s)[\u203a\u276f]\s*$"

    @staticmethod
    def default_agent_approval_pattern() -> str:
        return r"Do you trust the contents of this directory|Do you want to proceed|(^|\s)[>\u276f\u203a]\s+1[.] "

    @staticmethod
    def normalized_command_name(command_name: str) -> str:
        return Path(command_name).name.lower().removesuffix(".exe")

    @staticmethod
    def normalized_agent_kind(agent_name: str) -> str:
        name = AgentReview.normalized_command_name(agent_name)
        if name in {"claude", "claude-code"}:
            return "claude"
        if name == "codex":
            return "codex"
        return name

    def selected_agent_kind(self) -> str:
        words = self.agent_command.split()
        return self.normalized_agent_kind(words[0] if words else self.agent_command)

    def skill_prefix_for_agent_kind(self, agent_kind: str) -> str:
        if self.agent_skill_prefix:
            return self.agent_skill_prefix
        return "/" if self.normalized_agent_kind(agent_kind) == "claude" else "$"

    def skill_prefix_for_target(self, target: str, text: str | None = None) -> str:
        text = self.pane_tail(target) if text is None else text
        kind = self.agent_kind_for_target(target, text) or self.selected_agent_kind()
        return self.skill_prefix_for_agent_kind(kind)

    def run_cmd(
        self,
        args: list[str],
        *,
        cwd: str | Path | None = None,
        input_text: str | None = None,
        allow: set[int] | None = None,
        check: bool = False,
        env: dict[str, str] | None = None,
    ) -> CommandResult:
        allow = {0} if allow is None else allow
        try:
            proc = subprocess.run(
                args,
                cwd=str(cwd) if cwd is not None else None,
                input=input_text,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
        except OSError as exc:
            result = CommandResult(127, "", str(exc))
            if check:
                raise AgentReviewError(f"failed to start command: {shlex.join(args)}\n{exc}") from exc
            return result
        result = CommandResult(proc.returncode, strip_cr(proc.stdout or ""), strip_cr(proc.stderr or ""))
        if check and result.returncode not in allow:
            raise AgentReviewError(
                f"command failed ({result.returncode}): {shlex.join(args)}\n{result.stderr}"
            )
        return result

    def run_logged_cmd(self, log_file: Any, args: list[str], *, env: dict[str, str] | None = None) -> CommandResult:
        log_file.write(f"[{time.strftime('%H:%M:%S')}] $ {shlex.join(args)}\n")
        result = self.run_cmd(args, env=env)
        if result.stdout:
            log_file.write(result.stdout)
            if not result.stdout.endswith("\n"):
                log_file.write("\n")
        if result.stderr:
            log_file.write(result.stderr)
            if not result.stderr.endswith("\n"):
                log_file.write("\n")
        log_file.flush()
        return result

    def need_command(self, command: str) -> None:
        if not shutil.which(command):
            self.die(f"missing required command: {command}")

    def command_uses_windows_paths(self, command: str) -> bool:
        if not is_wsl_environment():
            return False
        resolved = shutil.which(command) or command
        return resolved.lower().endswith(".exe")

    def path_for_host_command(self, command: str, path: str | Path) -> str:
        path_str = str(path)
        if self.command_uses_windows_paths(command):
            self.need_command("wslpath")
            result = self.run_cmd(["wslpath", "-w", path_str], check=True)
            return result.stdout.strip()
        return path_str

    def path_for_git_arg(self, path: str | Path) -> str:
        return self.path_for_host_command(self.git_command, path)

    def git_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env

    def git(self, args: list[str], *, allow: set[int] | None = None, env: dict[str, str] | None = None) -> CommandResult:
        return self.run_cmd([self.git_command, *args], allow=allow or {0}, env=env)

    def git_in_worktree(
        self,
        path: str | Path,
        args: list[str],
        *,
        allow: set[int] | None = None,
        env: dict[str, str] | None = None,
    ) -> CommandResult:
        git_path = self.path_for_git_arg(path)
        return self.run_cmd([self.git_command, "-C", git_path, *args], allow=allow or {0}, env=env)

    def write_text_atomic(self, path: Path, text: str) -> None:
        if self.dry_run:
            self.log(f"dry-run: would write {path}")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        tmp = Path(name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write(text)
            os.replace(tmp, path)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise

    def parse_args(self, argv: list[str]) -> None:
        parser = argparse.ArgumentParser(
            prog=self.script_name,
            description="Monitor assigned CoPilot PRs and dispatch tmux agents.",
        )
        parser.add_argument("--agent", choices=["codex", "claude"], default=None)
        parser.add_argument("--agent-flags", default=None)
        parser.add_argument(
            "--yolo",
            action="store_true",
            help="launch agents with the selected CLI's permission-bypass flag",
        )
        parser.add_argument("--repo", action="append", default=None, metavar="OWNER/REPO")
        parser.add_argument("--label", default=None)
        parser.add_argument("--limit", type=int, default=None, metavar="N")
        parser.add_argument("--poll-seconds", type=int, default=None, metavar="N")
        parser.add_argument("--state-dir", default=None, metavar="PATH")
        parser.add_argument("--once", action="store_true")
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--no-submodules", action="store_true")
        parser.add_argument(
            "--assign-bot-prs",
            dest="assign_bot_prs_enabled",
            action="store_true",
            default=None,
            help="assign open bot-authored PRs linked from open issues assigned to @me (default)",
        )
        parser.add_argument(
            "--no-assign-bot-prs",
            dest="assign_bot_prs_enabled",
            action="store_false",
            help="disable assigning bot-authored PRs linked from issues assigned to @me",
        )
        parser.add_argument("--bot-login", default=None, metavar="LOGIN")
        parser.add_argument("--issue-limit", type=int, default=None, metavar="N")
        args = parser.parse_args(argv)

        if args.agent:
            self.agent_command = args.agent
            self.agent_ready_pattern = self.translate_posix_regex(self.default_agent_ready_pattern())
        if args.agent_flags is not None:
            self.agent_flags = args.agent_flags
        if args.yolo:
            self.agent_yolo = True
        if args.label:
            self.copilot_label = args.label
        if args.limit is not None:
            self.discovery_limit = args.limit
        if args.poll_seconds is not None:
            self.poll_seconds = args.poll_seconds
            self.next_poll_seconds = args.poll_seconds
        if args.state_dir:
            self.state_dir = Path(args.state_dir).expanduser()
            self.config_file = self.state_dir / "agent-review.conf"
        if args.no_submodules:
            self.init_submodules = False
        if args.bot_login:
            self.bot_login = args.bot_login
        if args.issue_limit is not None:
            self.issue_limit = args.issue_limit
        if args.assign_bot_prs_enabled is not None:
            self.assign_bot_prs_enabled = args.assign_bot_prs_enabled
        self.once = args.once
        self.dry_run = args.dry_run
        self.monitored_repos = args.repo or []

    def print_startup_warning(self) -> None:
        print(
            f"WARNING: {self.script_name} dispatches local agents from GitHub PR comments and CI state.\n"
            "Run it only for trusted repositories and trusted PR sources; PR comments can contain "
            "prompt-injection attempts.",
            file=sys.stderr,
        )
        if self.assign_bot_prs_enabled:
            print(
                f"WARNING: {self.script_name} also edits PR assignees for bot-authored PRs "
                "linked from issues assigned to the authenticated GitHub user.",
                file=sys.stderr,
            )

    def resolve_repo_root(self) -> None:
        result = self.git(["rev-parse", "--show-toplevel"])
        if result.returncode != 0 or not result.stdout.strip():
            self.die("must be run from inside a git worktree")
        self.repo_root = Path(result.stdout.strip()).resolve()
        if self.git(["worktree", "list"]).returncode != 0:
            self.die("failed to list git worktrees")

    def resolve_viewer_login(self) -> str:
        result = self.run_cmd([self.gh_command, "api", "user", "--jq", ".login"])
        login = result.stdout.strip()
        if result.returncode != 0 or not login:
            self.die(f"failed to resolve GitHub @me login with {self.gh_command}")
        return login

    def finalize_monitored_repos(self) -> None:
        if not self.monitored_repos:
            self.monitored_repos = [DEFAULT_UPSTREAM_REPO, f"{self.viewer_login}/slang"]
        self.monitored_repos = unique_preserve_order(self.monitored_repos)

    def log_startup(self) -> None:
        self.log(f"using GitHub CLI: {shutil.which(self.gh_command) or 'not found'}")
        self.log(f"using Git: {shutil.which(self.git_command) or 'not found'}")
        self.log(f"using tmux: {shutil.which('tmux') or 'not found'}")
        self.log(f"using agent: {shutil.which(self.agent_command.split()[0]) or 'not found'}")
        self.log(f"viewer login: {self.viewer_login}")
        self.log(f"monitored repositories: {', '.join(self.monitored_repos)}")
        if self.assign_bot_prs_enabled:
            self.log(f"bot PR author: {self.bot_login}; issue limit: {self.issue_limit}")
        else:
            self.log("bot PR assignment disabled")
        self.log(f"state file: {self.config_file}")

    def read_state(self) -> None:
        self.rows = []
        if not self.config_file.exists():
            if self.dry_run:
                return
            self.config_file.parent.mkdir(parents=True, exist_ok=True)
            self.config_file.write_text("")
            return
        for line_number, line in enumerate(self.config_file.read_text().splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            try:
                fields = shlex.split(stripped)
            except ValueError as exc:
                self.log(f"bad state line {line_number}: {exc}")
                continue
            if len(fields) < 3:
                self.log(f"bad state line {line_number}: expected path session url...")
                continue
            path, session, *urls = fields
            valid_urls = []
            for url in urls:
                if parse_pr_url(url):
                    valid_urls.append(url)
                else:
                    self.log(f"bad PR URL in state line {line_number}: {url}")
            if valid_urls:
                self.rows.append(StateRow(path, safe_name(session), unique_preserve_order(valid_urls)))

    def save_state(self) -> None:
        rows = []
        for row in self.rows:
            row.urls = unique_preserve_order(row.urls)
            if row.urls:
                rows.append(row)
        rows.sort(key=lambda row: (row.session.lower(), row.path.lower()))
        lines = [shlex.join([row.path, row.session, *row.urls]) + "\n" for row in rows]
        if self.dry_run:
            self.log("dry-run: would write agent-review.conf:")
            for line in lines:
                self.log(f"dry-run:   {line.rstrip()}")
            self.rows = rows
            self.state_changed = False
            return
        self.write_text_atomic(self.config_file, "".join(lines))
        self.rows = rows
        self.state_changed = False

    def row_for_url(self, url: str) -> StateRow | None:
        for row in self.rows:
            if url in row.urls:
                return row
        return None

    def row_for_path(self, path: str) -> StateRow | None:
        path_obj = Path(path)
        for row in self.rows:
            if Path(row.path) == path_obj:
                return row
        return None

    def add_url_to_row(self, row: StateRow, url: str) -> bool:
        if url in row.urls:
            return False
        row.urls.append(url)
        row.urls = unique_preserve_order(row.urls)
        self.state_changed = True
        return True

    def remove_url_from_rows(self, url: str) -> None:
        changed = False
        for row in self.rows:
            if url in row.urls:
                row.urls = [candidate for candidate in row.urls if candidate != url]
                changed = True
        if changed:
            self.rows = [row for row in self.rows if row.urls]
            self.state_changed = True
            self.log(f"removed {url} from state")

    @staticmethod
    def labels_from_json(value: Any) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(item.get("name", "")) for item in value if isinstance(item, dict) and item.get("name")]

    @staticmethod
    def logins_from_json(value: Any) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(item.get("login", "")) for item in value if isinstance(item, dict) and item.get("login")]

    @staticmethod
    def normalize_bot_author_login(value: str) -> str:
        value = value.strip().lower()
        if value.startswith("app/"):
            value = value[4:]
        if value.endswith("[bot]"):
            value = value[:-5]
        return value

    @staticmethod
    def repo_name_from_json(value: Any) -> str:
        if isinstance(value, dict):
            return str(value.get("nameWithOwner") or "")
        return ""

    @staticmethod
    def owner_login_from_json(value: Any) -> str:
        if isinstance(value, dict):
            return str(value.get("login") or "")
        return ""

    def pr_from_json(self, repo: str, item: dict[str, Any]) -> PullRequest | None:
        url = str(item.get("url") or "")
        parsed = parse_pr_url(url)
        if not parsed:
            return None
        labels = self.labels_from_json(item.get("labels"))
        assignees = self.logins_from_json(item.get("assignees"))
        head_owner = self.owner_login_from_json(item.get("headRepositoryOwner"))
        head_repo = self.repo_name_from_json(item.get("headRepository"))
        return PullRequest(
            repo=repo,
            number=str(item.get("number") or parsed[1]),
            url=url,
            title=str(item.get("title") or ""),
            state=str(item.get("state") or "").upper(),
            labels=labels,
            assignees=assignees,
            head_owner=head_owner,
            head_repo=head_repo,
            head_branch=str(item.get("headRefName") or ""),
            head_sha=str(item.get("headRefOid") or ""),
        )

    def pr_matches_policy(self, pr: PullRequest | PullRequestStatus) -> bool:
        has_label = any(label.lower() == self.copilot_label.lower() for label in pr.labels)
        assigned_to_me = any(login.lower() == self.viewer_login.lower() for login in pr.assignees)
        return has_label and assigned_to_me

    def pr_is_from_viewer(self, pr: PullRequest | PullRequestStatus) -> bool:
        return pr.head_owner.lower() == self.viewer_login.lower()

    def pr_is_from_bot_author(self, pr_author: str) -> bool:
        return self.normalize_bot_author_login(pr_author) == self.normalize_bot_author_login(
            self.bot_login
        )

    def row_has_fork_pr_url(self, row: StateRow) -> bool:
        prefix = f"https://github.com/{self.viewer_login.lower()}/"
        return any(url.lower().startswith(prefix) for url in row.urls)

    def discover_repo_prs(self, repo: str) -> list[PullRequest]:
        fields = ",".join(
            [
                "assignees",
                "headRefName",
                "headRefOid",
                "headRepository",
                "headRepositoryOwner",
                "labels",
                "number",
                "state",
                "title",
                "url",
            ]
        )
        result = self.run_cmd(
            [
                self.gh_command,
                "pr",
                "list",
                "--repo",
                repo,
                "--assignee",
                "@me",
                "--label",
                self.copilot_label,
                "--state",
                "open",
                "--limit",
                str(self.discovery_limit),
                "--json",
                fields,
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to discover PRs in {repo}: {result.stderr.strip()}")
            return []
        try:
            raw_items = json.loads(result.stdout or "[]")
        except json.JSONDecodeError as exc:
            self.log(f"failed to parse PR discovery output for {repo}: {exc}")
            return []
        prs: list[PullRequest] = []
        for raw_item in raw_items:
            if not isinstance(raw_item, dict):
                continue
            pr = self.pr_from_json(repo, raw_item)
            if not pr:
                continue
            if pr.state != "OPEN" or not self.pr_matches_policy(pr):
                continue
            if not pr.head_branch:
                self.log(f"skipping {pr.url}: missing head branch")
                continue
            prs.append(pr)
        return prs

    def discover_prs(self) -> list[PullRequest]:
        discovered: dict[str, PullRequest] = {}
        for repo in self.monitored_repos:
            for pr in self.discover_repo_prs(repo):
                discovered[pr.url] = pr
        return sorted(discovered.values(), key=lambda pr: (pr.repo.lower(), int(pr.number)))

    def worktree_name_for_pr(self, pr: PullRequest) -> str:
        branch_name = safe_name(pr.head_branch, fallback=f"pr-{pr.number}")
        if pr.head_owner.lower() == self.viewer_login.lower():
            return branch_name
        owner = safe_name(pr.head_owner, lower=True, fallback="owner")
        viewer = safe_name(self.viewer_login, lower=True, fallback="viewer")
        suffix = safe_name(f"{owner}-pr{pr.number}-{viewer}", lower=True, fallback=f"pr{pr.number}-{viewer}")
        max_branch_len = max(1, 120 - len(suffix) - 1)
        branch_prefix = branch_name[:max_branch_len].rstrip(".-") or f"pr-{pr.number}"
        return safe_name(f"{branch_prefix}-{suffix}", fallback=f"pr-{pr.number}-{viewer}")

    def worktree_path_for_pr(self, pr: PullRequest) -> Path:
        return self.repo_root.parent / self.worktree_name_for_pr(pr)

    def local_branch_for_pr(self, pr: PullRequest) -> str:
        if pr.head_owner.lower() == self.viewer_login.lower():
            return pr.head_branch
        return self.worktree_name_for_pr(pr)

    def base_repo_fetch_url(self, repo: str) -> str:
        return f"https://github.com/{repo}.git"

    def fetch_ref_for_pr(self, pr: PullRequest) -> str:
        repo_component = safe_name(pr.repo, lower=True, fallback="repo")
        return f"refs/remotes/agent-review/{repo_component}/pr-{pr.number}"

    def branch_exists(self, branch: str, env: dict[str, str]) -> bool:
        return (
            self.run_cmd(
                [self.git_command, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
                env=env,
            ).returncode
            == 0
        )

    def branch_checked_out_elsewhere(self, branch: str, expected_path: Path) -> str:
        result = self.git(["worktree", "list", "--porcelain"])
        if result.returncode != 0:
            return ""
        current_path = ""
        branch_ref = f"refs/heads/{branch}"
        for line in result.stdout.splitlines():
            if line.startswith("worktree "):
                current_path = line[len("worktree ") :].strip()
            elif line == f"branch {branch_ref}" and current_path:
                path = Path(current_path).resolve()
                if path != expected_path.resolve():
                    return str(path)
        return ""

    def check_branch_name(self, branch: str, log_file: Any, env: dict[str, str]) -> bool:
        result = self.run_logged_cmd(log_file, [self.git_command, "check-ref-format", "--branch", branch], env=env)
        if result.returncode != 0:
            log_file.write(f"Invalid branch name: {branch}\n")
            return False
        return True

    def update_own_branch_fast_forward(self, branch: str, fetch_ref: str, log_file: Any, env: dict[str, str]) -> bool:
        if not self.branch_exists(branch, env):
            return True
        branch_result = self.run_logged_cmd(
            log_file,
            [self.git_command, "rev-parse", "--verify", f"{branch}^{{commit}}"],
            env=env,
        )
        fetch_result = self.run_logged_cmd(
            log_file,
            [self.git_command, "rev-parse", "--verify", f"{fetch_ref}^{{commit}}"],
            env=env,
        )
        if branch_result.returncode != 0 or fetch_result.returncode != 0:
            return False
        branch_sha = branch_result.stdout.strip()
        fetch_sha = fetch_result.stdout.strip()
        if branch_sha == fetch_sha:
            return True
        ancestor = self.run_logged_cmd(
            log_file,
            [self.git_command, "merge-base", "--is-ancestor", branch, fetch_ref],
            env=env,
        )
        if ancestor.returncode == 0:
            result = self.run_logged_cmd(log_file, [self.git_command, "branch", "-f", branch, fetch_ref], env=env)
            return result.returncode == 0
        contains = self.run_logged_cmd(
            log_file,
            [self.git_command, "merge-base", "--is-ancestor", fetch_ref, branch],
            env=env,
        )
        if contains.returncode == 0:
            log_file.write(
                f"Local branch {branch} already contains the PR head; keeping the local branch tip.\n"
            )
            return True
        log_file.write(
            f"Local branch {branch} diverges from PR head {fetch_ref}; refusing to move it automatically.\n"
        )
        return False

    def init_worktree_submodules(self, worktree: Path, log_file: Any, env: dict[str, str]) -> None:
        if not self.init_submodules:
            log_file.write("Skipping submodule initialization because --no-submodules/INIT_SUBMODULES=false is set.\n")
            return
        if not (worktree / ".gitmodules").exists():
            log_file.write("Skipping submodule initialization because .gitmodules is absent.\n")
            return
        jobs = str(max(1, min(os.cpu_count() or 1, 16)))
        result = self.run_logged_cmd(
            log_file,
            [
                self.git_command,
                "-C",
                self.path_for_git_arg(worktree),
                "submodule",
                "update",
                "--init",
                "--recursive",
                "--jobs",
                jobs,
            ],
            env=env,
        )
        if result.returncode != 0:
            log_file.write("Submodule initialization failed; leaving worktree for manual recovery.\n")

    def create_worktree_for_pr(self, pr: PullRequest, worktree: Path) -> bool:
        branch = self.local_branch_for_pr(pr)
        fetch_ref = self.fetch_ref_for_pr(pr)
        log_path = self.state_dir / f"{state_hash(pr.url)}.worktree.log"
        env = self.git_env()
        if self.dry_run:
            self.log(f"dry-run: would create worktree {worktree} branch={branch} for {pr.url}")
            return True
        self.state_dir.mkdir(parents=True, exist_ok=True)
        with log_path.open("w", encoding="utf-8") as log_file:
            log_file.write(f"PR: {pr.url}\n")
            log_file.write(f"Worktree: {worktree}\n")
            log_file.write(f"Branch: {branch}\n")
            log_file.write(f"Head owner: {pr.head_owner}\n")
            log_file.write(f"Head branch: {pr.head_branch}\n")
            log_file.write(f"Head SHA: {pr.head_sha}\n")
            log_file.flush()

            if not self.check_branch_name(branch, log_file, env):
                self.log(f"invalid branch name for {pr.url}; see {log_path}")
                return False
            if not worktree.parent.is_dir():
                log_file.write(f"Destination parent does not exist: {worktree.parent}\n")
                self.log(f"cannot create {worktree}: parent directory does not exist")
                return False
            checked_out = self.branch_checked_out_elsewhere(branch, worktree)
            if checked_out:
                log_file.write(f"Branch {branch} is already checked out at {checked_out}\n")
                self.log(f"cannot create {worktree}: branch {branch} is already checked out at {checked_out}")
                return False

            self.run_logged_cmd(log_file, [self.git_command, "worktree", "prune"], env=env)
            fetch = self.run_logged_cmd(
                log_file,
                [
                    self.git_command,
                    "fetch",
                    "--no-tags",
                    self.base_repo_fetch_url(pr.repo),
                    f"+refs/pull/{pr.number}/head:{fetch_ref}",
                ],
                env=env,
            )
            if fetch.returncode != 0:
                self.log(f"failed to fetch {pr.url}; see {log_path}")
                return False

            own_pr = pr.head_owner.lower() == self.viewer_login.lower()
            if own_pr and not self.update_own_branch_fast_forward(branch, fetch_ref, log_file, env):
                self.log(f"failed to prepare local branch {branch} for {pr.url}; see {log_path}")
                return False

            git_worktree = self.path_for_git_arg(worktree)
            if own_pr and self.branch_exists(branch, env):
                add_args = [self.git_command, "worktree", "add", git_worktree, branch]
            elif own_pr:
                add_args = [self.git_command, "worktree", "add", "-b", branch, git_worktree, fetch_ref]
            else:
                add_args = [self.git_command, "worktree", "add", "-B", branch, git_worktree, fetch_ref]
            add = self.run_logged_cmd(log_file, add_args, env=env)
            if add.returncode != 0:
                self.log(f"failed to create worktree for {pr.url}; see {log_path}")
                return False

            if pr.head_sha:
                head = self.run_logged_cmd(
                    log_file,
                    [self.git_command, "-C", git_worktree, "rev-parse", "HEAD"],
                    env=env,
                )
                if head.returncode == 0 and head.stdout.strip() != pr.head_sha:
                    log_file.write(
                        f"WARNING: worktree HEAD {head.stdout.strip()} does not match PR head {pr.head_sha}\n"
                    )

            self.init_worktree_submodules(worktree, log_file, env)
        self.log(f"created worktree {worktree} for {pr.url}")
        return True

    def path_is_git_worktree(self, path: Path) -> bool:
        return path.is_dir() and self.git_in_worktree(path, ["rev-parse", "--git-dir"]).returncode == 0

    def ensure_worktree_for_pr(self, pr: PullRequest) -> Path | None:
        worktree = self.worktree_path_for_pr(pr)
        if worktree.exists():
            if not self.path_is_git_worktree(worktree):
                self.log(f"skipping {pr.url}: {worktree} exists but is not a git worktree")
                return None
            return worktree
        if self.create_worktree_for_pr(pr, worktree):
            return worktree
        return None

    def clone_prompt_sent_file(self, url: str) -> Path:
        return self.state_dir / f"{state_hash(url)}.clone-prompt-sent"

    def clone_prompt_was_sent(self, url: str) -> bool:
        return self.clone_prompt_sent_file(url).exists()

    def mark_clone_prompt_sent(self, url: str) -> None:
        if self.dry_run:
            return
        self.clone_prompt_sent_file(url).write_text(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {url}\n")

    def handle_external_pr_clone(self, pr: PullRequest, worktree: Path, session: str) -> None:
        row = self.row_for_path(str(worktree))
        if row and self.row_has_fork_pr_url(row):
            self.log(f"clone PR for {pr.url} is already tracked through {worktree}")
            return
        if self.clone_prompt_was_sent(pr.url):
            self.log(f"clone prompt already sent for {pr.url}; waiting for {self.viewer_login}/slang PR discovery")
            return

        target, started = self.ensure_agent_target(session, str(worktree))
        if not target:
            return
        text = self.pane_tail(target)
        if self.maybe_approve_prompt(target, text):
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            return
        if not started and not self.target_screen_is_idle(target, text):
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_active_seconds)
            return

        repo = f"{self.viewer_login}/slang"
        if self.send_prompt_to_target(target, self.pr_create_prompt(target, text, repo)):
            self.mark_clone_prompt_sent(pr.url)
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            self.log(
                f"sent clone {PR_CREATE_SKILL} prompt for external PR {pr.url} "
                f"using branch {self.local_branch_for_pr(pr)}"
            )
        else:
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            self.log(f"failed to send clone {PR_CREATE_SKILL} prompt for external PR {pr.url}")

    def upsert_discovered_pr(self, pr: PullRequest) -> None:
        worktree = self.ensure_worktree_for_pr(pr)
        if not worktree:
            return
        session = worktree.name
        if not self.pr_is_from_viewer(pr):
            self.handle_external_pr_clone(pr, worktree, safe_name(session))
            return

        existing = self.row_for_url(pr.url)
        if existing:
            return
        row = self.row_for_path(str(worktree))
        is_new_url = False
        if row:
            is_new_url = self.add_url_to_row(row, pr.url)
            if row.session != session:
                self.log(f"keeping existing session {row.session} for {worktree}; expected {session}")
        else:
            row = StateRow(str(worktree), safe_name(session), [pr.url])
            self.rows.append(row)
            self.state_changed = True
            is_new_url = True
            self.log(f"tracking {pr.url} in {worktree} session={row.session}")
        self.ensure_agent_target(row.session, row.path)

    def tmux_session_exists(self, session: str) -> bool:
        return self.run_cmd(["tmux", "has-session", "-t", f"={session}"]).returncode == 0

    def first_window_index(self, session: str) -> str:
        result = self.run_cmd(["tmux", "list-windows", "-t", session, "-F", "#{window_index}"])
        indices = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if not indices:
            return "0"
        return sorted(indices, key=lambda value: int(value) if value.isdigit() else 0)[0]

    def first_target_for_session(self, session: str) -> str:
        return f"{session}:{self.first_window_index(session)}.0"

    def current_command_for_target(self, target: str) -> str:
        result = self.run_cmd(["tmux", "display-message", "-p", "-t", target, "#{pane_current_command}"])
        return result.stdout.strip()

    def pane_tail(self, target: str) -> str:
        result = self.run_cmd(["tmux", "capture-pane", "-p", "-J", "-S", f"-{self.capture_lines}", "-t", target])
        return result.stdout if result.returncode == 0 else ""

    @staticmethod
    def tail_text(text: str, line_count: int) -> str:
        return "\n".join(text.splitlines()[-line_count:])

    def agent_kind_for_target(self, target: str, text: str) -> str:
        command_kind = self.normalized_agent_kind(self.current_command_for_target(target))
        if command_kind in {"codex", "claude"}:
            return command_kind
        tail = self.tail_text(text, self.match_tail_lines)
        if re.search(r"(^|\n)\s*\u203a", tail) or re.search(r"Codex|gpt-[0-9]", tail, re.I):
            return "codex"
        if re.search(r"(^|\n)\s*\u276f", tail) or re.search(r"Claude Code|Esc to cancel", tail):
            return "claude"
        if re.search(self.agent_ready_pattern, tail, re.MULTILINE):
            return self.selected_agent_kind()
        return ""

    def target_has_non_shell_process(self, target: str) -> bool:
        command = self.current_command_for_target(target)
        return bool(command) and not re.search(self.agent_shell_command_pattern, command)

    def target_looks_like_live_agent(self, target: str, text: str) -> bool:
        return bool(self.agent_kind_for_target(target, text)) or (
            self.target_has_non_shell_process(target) and self.approval_prompt_present(text)
        )

    def approval_prompt_present(self, text: str) -> bool:
        if not self.agent_approval_pattern:
            return False
        tail = self.tail_text(text, self.match_tail_lines)
        return bool(re.search(self.agent_approval_pattern, tail, re.MULTILINE))

    def maybe_approve_prompt(self, target: str, text: str) -> bool:
        if not self.approval_prompt_present(text):
            return False
        signature = state_hash(self.tail_text(text, self.match_tail_lines))
        if self.approved_signatures.get(target) != signature:
            if not self.dry_run:
                self.run_cmd(["tmux", "send-keys", "-t", target, "Enter"])
            self.approved_signatures[target] = signature
            self.log(f"approved agent prompt in {target}")
        return True

    def idle_screen_signature_file_for_target(self, target: str) -> Path:
        return self.state_dir / f"{safe_name(target, lower=True)}.idle-signature"

    def target_screen_is_idle(self, target: str, text: str) -> bool:
        if target in self.idle_screen_results:
            return self.idle_screen_results[target]
        signature = state_hash(text + "\n")
        path = self.idle_screen_signature_file_for_target(target)
        previous = path.read_text().strip() if path.exists() else ""
        idle = bool(previous and previous == signature)
        self.idle_screen_results[target] = idle
        self.idle_screen_texts[target] = text
        self.idle_screen_signatures[target] = signature
        return idle

    def persist_idle_screen_observations(self) -> None:
        for target, signature in self.idle_screen_signatures.items():
            path = self.idle_screen_signature_file_for_target(target)
            path.write_text(signature + "\n")
        self.idle_screen_texts = {}
        self.idle_screen_signatures = {}
        self.idle_screen_results = {}

    def agent_launch_command(self) -> str:
        parts = [self.agent_command]
        flags = self.agent_flags.strip()
        if flags:
            parts.append(flags)
        launch = " ".join(parts).strip()
        launch = self.ensure_default_flags_for_selected_agent(launch)
        yolo_flag = self.yolo_flag_for_selected_agent()
        if self.agent_yolo and yolo_flag and yolo_flag not in shlex.split(launch):
            launch = f"{launch} {yolo_flag}".strip()
        return launch

    def ensure_default_flags_for_selected_agent(self, launch: str) -> str:
        if self.selected_agent_kind() != "codex":
            return launch
        return self.ensure_codex_sandbox_flag(launch)

    @staticmethod
    def ensure_codex_sandbox_flag(launch: str) -> str:
        args = shlex.split(launch)
        filtered: list[str] = []
        skip_next = False
        for arg in args:
            if skip_next:
                skip_next = False
                continue
            if arg in {"--sandbox", "-s"}:
                skip_next = True
                continue
            if arg.startswith("--sandbox=") or arg.startswith("-s="):
                continue
            filtered.append(arg)
        filtered.extend(["--sandbox", "danger-full-access"])
        return shlex.join(filtered)

    def yolo_flag_for_selected_agent(self) -> str:
        kind = self.selected_agent_kind()
        if kind == "codex":
            return "--dangerously-bypass-approvals-and-sandbox"
        if kind == "claude":
            return "--dangerously-skip-permissions"
        return ""

    def shell_command_for_worktree(self, worktree: str) -> str:
        shell = os.environ.get("SHELL", "/bin/bash")
        return f"cd {shlex.quote(worktree)} && exec {shlex.quote(shell)} -l"

    def configure_tmux_session_defaults(self, session: str, worktree: str) -> None:
        if self.dry_run:
            return
        self.run_cmd(
            [
                "tmux",
                "set-option",
                "-t",
                session,
                "default-command",
                self.shell_command_for_worktree(worktree),
            ]
        )

    def wait_for_agent_ready(self, target: str) -> bool:
        for _ in range(self.agent_start_attempts):
            time.sleep(self.agent_start_wait_seconds)
            text = self.pane_tail(target)
            self.maybe_approve_prompt(target, text)
            if self.target_looks_like_live_agent(target, text):
                return True
        return False

    def start_agent_in_target(self, target: str, worktree: str) -> bool:
        if self.dry_run:
            self.log(f"dry-run: would start agent in {target} from {worktree}: {self.agent_launch_command()}")
            return True
        command = f"cd {shlex.quote(worktree)} && {self.agent_launch_command()}"
        self.run_cmd(["tmux", "send-keys", "-t", target, command, "Enter"])
        return self.wait_for_agent_ready(target)

    def ensure_agent_target(self, session: str, worktree: str) -> tuple[str | None, bool]:
        if self.dry_run:
            if not self.tmux_session_exists(session):
                self.log(f"dry-run: would create tmux session {session} in {worktree}")
                return f"{session}:0.0", True
            return self.first_target_for_session(session), False
        if not Path(worktree).is_dir():
            self.log(f"worktree does not exist for session {session}: {worktree}")
            return None, False
        created_or_started = False
        if not self.tmux_session_exists(session):
            self.log(f"creating tmux session {session} in {worktree}")
            result = self.run_cmd(
                [
                    "tmux",
                    "new-session",
                    "-d",
                    "-s",
                    session,
                    "-n",
                    self.agent_window_name,
                    "-c",
                    worktree,
                    "bash",
                    "-lc",
                    self.agent_launch_command(),
                ]
            )
            if result.returncode != 0:
                self.log(f"failed to create tmux session {session}: {result.stderr.strip()}")
                return None, False
            self.configure_tmux_session_defaults(session, worktree)
            target = self.first_target_for_session(session)
            if not self.wait_for_agent_ready(target):
                self.log(f"agent did not become ready in {target}")
                return None, False
            return target, True

        self.configure_tmux_session_defaults(session, worktree)
        target = self.first_target_for_session(session)
        text = self.pane_tail(target)
        if self.target_looks_like_live_agent(target, text):
            return target, False
        command = self.current_command_for_target(target)
        if not command or re.search(self.agent_shell_command_pattern, command):
            self.log(f"starting agent in existing tmux target {target}")
            created_or_started = self.start_agent_in_target(target, worktree)
            if not created_or_started:
                self.log(f"agent did not become ready in {target}")
                return None, False
            return target, True
        self.log(f"tmux target {target} is running non-agent command {command}; not interrupting it")
        return None, False

    def paste_prompt_once(self, target: str, buffer_name: str, prompt: str) -> bool:
        if self.dry_run:
            self.log(f"dry-run: would send prompt to {target}: {prompt.strip()}")
            return True
        if self.run_cmd(["tmux", "load-buffer", "-b", buffer_name, "-"], input_text=prompt).returncode != 0:
            return False
        if self.run_cmd(["tmux", "paste-buffer", "-b", buffer_name, "-t", target]).returncode != 0:
            self.run_cmd(["tmux", "delete-buffer", "-b", buffer_name])
            return False
        self.run_cmd(["tmux", "delete-buffer", "-b", buffer_name])
        return True

    def send_prompt_to_target(self, target: str, prompt: str) -> bool:
        buffer_name = f"agent_review_{safe_name(target, lower=True)}"
        for _ in range(self.prompt_send_attempts):
            if not self.paste_prompt_once(target, buffer_name, prompt):
                continue
            if self.dry_run:
                return True
            time.sleep(self.prompt_enter_delay_seconds)
            if self.run_cmd(["tmux", "send-keys", "-t", target, "Enter"]).returncode == 0:
                return True
        return False

    def pr_create_prompt(self, target: str, text: str, repo: str) -> str:
        prefix = self.skill_prefix_for_target(target, text)
        return f"{prefix}{PR_CREATE_SKILL} {repo}\n"

    def resolve_comments_prompt(self, target: str, text: str, urls: list[str]) -> str:
        prefix = self.skill_prefix_for_target(target, text)
        return f"{prefix}{RESOLVE_COMMENTS_SKILL} --single-pass {' '.join(urls)}\n"

    def pr_status_for_url(self, url: str) -> PullRequestStatus | None:
        parsed = parse_pr_url(url)
        if not parsed:
            return None
        repo, number = parsed
        result = self.run_cmd(
            [
                self.gh_command,
                "pr",
                "view",
                number,
                "--repo",
                repo,
                "--json",
                "assignees,headRefName,headRepository,headRepositoryOwner,isDraft,labels,state",
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to fetch PR status for {url}: {result.stderr.strip()}")
            return None
        try:
            item = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.log(f"failed to parse PR status for {url}: {exc}")
            return None
        return PullRequestStatus(
            state=str(item.get("state") or "").upper(),
            labels=self.labels_from_json(item.get("labels")),
            assignees=self.logins_from_json(item.get("assignees")),
            is_draft=bool(item.get("isDraft")),
            head_owner=self.owner_login_from_json(item.get("headRepositoryOwner")),
            head_repo=self.repo_name_from_json(item.get("headRepository")),
            head_branch=str(item.get("headRefName") or ""),
        )

    def fetch_json_stream(self, endpoint: str) -> list[Any] | None:
        result = self.run_cmd([self.gh_command, "api", "--paginate", endpoint])
        if result.returncode != 0:
            return None
        decoder = json.JSONDecoder()
        values: list[Any] = []
        idx = 0
        text = result.stdout
        try:
            while idx < len(text):
                while idx < len(text) and text[idx].isspace():
                    idx += 1
                if idx >= len(text):
                    break
                value, idx = decoder.raw_decode(text, idx)
                if isinstance(value, list):
                    values.extend(value)
                else:
                    values.append(value)
        except json.JSONDecodeError:
            return None
        return values

    def fetch_events(self, url: str) -> list[dict[str, str]] | None:
        parsed = parse_pr_url(url)
        if not parsed:
            return None
        repo, number = parsed
        endpoints = [
            (f"repos/{repo}/issues/{number}/comments?per_page={self.comment_page_size}", "issue-comment", "issue"),
            (f"repos/{repo}/pulls/{number}/comments?per_page={self.comment_page_size}", "review-comment", "review-comment"),
            (f"repos/{repo}/pulls/{number}/reviews?per_page={self.comment_page_size}", "review", "review"),
        ]
        events: list[dict[str, str]] = []
        agent_re = re.compile(r"^\s*\[Agent\]")
        for endpoint, kind, prefix in endpoints:
            values = self.fetch_json_stream(endpoint)
            if values is None:
                return None
            for item in values:
                if not isinstance(item, dict):
                    continue
                body = str(item.get("body") or "")
                if kind == "review" and not body:
                    continue
                if agent_re.search(body):
                    continue
                created = (
                    str(item.get("submitted_at") or "")
                    if kind == "review"
                    else str(item.get("created_at") or "")
                )
                updated = (
                    str(item.get("submitted_at") or "")
                    if kind == "review"
                    else str(item.get("updated_at") or "")
                )
                events.append(
                    {
                        "id": f"{prefix}:{item.get('id')}",
                        "created": created,
                        "updated": updated,
                    }
                )
        return sorted(events, key=lambda event: event.get("created") or event.get("updated") or "")

    def seen_file_for_url(self, url: str) -> Path:
        return self.state_dir / f"{state_hash(url)}.seen"

    def new_events_for_url(self, url: str) -> tuple[list[dict[str, str]], list[dict[str, str]] | None]:
        events = self.fetch_events(url)
        if events is None:
            self.log(f"failed to fetch comments for {url}")
            return [], None
        seen_file = self.seen_file_for_url(url)
        if not seen_file.exists():
            if self.dry_run:
                return (events if self.bootstrap_mode == "trigger" else []), events
            seen_file.write_text("")
            if self.bootstrap_mode != "trigger":
                self.mark_events_seen(url, events)
                self.log(f"primed {url} with {len(events)} existing comment event(s)")
                return [], events
        seen = set(seen_file.read_text().splitlines())
        return [event for event in events if event.get("id") not in seen], events

    def mark_events_seen(self, url: str, events: list[dict[str, str]]) -> None:
        seen_file = self.seen_file_for_url(url)
        seen = set(seen_file.read_text().splitlines()) if seen_file.exists() else set()
        seen.update(event["id"] for event in events if event.get("id"))
        self.write_text_atomic(seen_file, "".join(f"{item}\n" for item in sorted(seen)))

    def ci_signature_file_for_url(self, url: str) -> Path:
        return self.state_dir / f"{state_hash(url)}.ci"

    def fetch_ci_attention_checks(self, url: str) -> list[dict[str, str]] | None:
        parsed = parse_pr_url(url)
        if not parsed:
            return None
        repo, number = parsed
        result = self.run_cmd(
            [
                self.gh_command,
                "pr",
                "checks",
                number,
                "--repo",
                repo,
                "--json",
                "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
            ],
            allow={0, 8},
        )
        if result.returncode not in {0, 8}:
            return None
        try:
            raw_checks = json.loads(result.stdout or "[]")
        except json.JSONDecodeError:
            return None
        checks: list[dict[str, str]] = []
        for check in raw_checks:
            if check.get("bucket") not in {"fail", "cancel", "pending"}:
                continue
            checks.append(
                {
                    "bucket": str(check.get("bucket") or ""),
                    "workflow": str(check.get("workflow") or ""),
                    "name": str(check.get("name") or ""),
                    "state": str(check.get("state") or ""),
                    "completedAt": str(check.get("completedAt") or ""),
                    "startedAt": str(check.get("startedAt") or ""),
                    "link": str(check.get("link") or ""),
                    "description": str(check.get("description") or ""),
                    "event": str(check.get("event") or ""),
                }
            )
        return checks

    @staticmethod
    def ci_signature(checks: list[dict[str, str]]) -> str:
        lines = []
        for check in sorted(
            checks,
            key=lambda item: (
                item["bucket"],
                item["workflow"],
                item["name"],
                item["state"],
                item["completedAt"],
                item["startedAt"],
                item["link"],
            ),
        ):
            lines.append(
                "\t".join(
                    [
                        check["bucket"],
                        check["workflow"],
                        check["name"],
                        check["state"],
                        check["completedAt"],
                        check["startedAt"],
                        check["link"],
                    ]
                )
            )
        return state_hash("\n".join(lines) + ("\n" if lines else ""))

    def ci_change_for_url(self, url: str) -> tuple[bool, str]:
        if not self.watch_ci:
            return False, ""
        checks = self.fetch_ci_attention_checks(url)
        if checks is None:
            self.log(f"failed to fetch CI checks for {url}")
            return False, ""
        signature = self.ci_signature(checks)
        state_file = self.ci_signature_file_for_url(url)
        failure_count = sum(1 for check in checks if check["bucket"] in {"fail", "cancel"})
        pending_count = sum(1 for check in checks if check["bucket"] == "pending")
        if not state_file.exists():
            if self.dry_run:
                if self.ci_bootstrap_mode == "trigger" and failure_count > 0:
                    return True, signature
                return False, ""
            state_file.write_text(signature + "\n")
            if self.ci_bootstrap_mode == "trigger" and failure_count > 0:
                return True, signature
            self.log(f"primed {url} CI with {failure_count} failure/cancel and {pending_count} pending check(s)")
            return False, ""
        previous = state_file.read_text().strip()
        if previous == signature:
            return False, ""
        if failure_count > 0:
            return True, signature
        if not self.dry_run:
            state_file.write_text(signature + "\n")
        if pending_count > 0:
            self.log(f"noted pending CI change for {url}")
        else:
            self.log(f"noted passing CI change for {url}")
        return False, ""

    def row_ready_for_events(self, row: StateRow) -> tuple[str | None, str | None]:
        target, started = self.ensure_agent_target(row.session, row.path)
        if not target:
            return None, None
        text = self.pane_tail(target)
        if self.maybe_approve_prompt(target, text):
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            return None, None
        if not self.target_screen_is_idle(target, text):
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_active_seconds)
            return None, None
        return target, text

    def process_row(self, row: StateRow) -> None:
        target, text = self.row_ready_for_events(row)
        if not target or text is None:
            return

        urls_for_prompt = list(row.urls)
        comments_to_mark: dict[str, list[dict[str, str]]] = {}
        ci_signatures_to_mark: dict[str, str] = {}
        dispatch_needed = False

        for url in list(row.urls):
            status = self.pr_status_for_url(url)
            if status is None:
                continue
            if status.state != "OPEN":
                self.remove_url_from_rows(url)
                continue
            if not self.pr_is_from_viewer(status):
                self.log(f"stopped tracking {url}: PR head is not owned by {self.viewer_login}")
                self.remove_url_from_rows(url)
                continue
            if not self.pr_matches_policy(status):
                self.log(f"stopped tracking {url}: it is no longer assigned to {self.viewer_login} with label {self.copilot_label}")
                self.remove_url_from_rows(url)
                continue

            new_events, all_events = self.new_events_for_url(url)
            if new_events and all_events is not None:
                comments_to_mark[url] = new_events
                dispatch_needed = True
                self.log(f"detected {len(new_events)} new comment/review event(s) on {url}")

            ci_changed, ci_signature = self.ci_change_for_url(url)
            if ci_changed:
                ci_signatures_to_mark[url] = ci_signature
                dispatch_needed = True
                self.log(f"detected failing CI change on {url}")

        if self.state_changed:
            self.save_state()
        if not dispatch_needed:
            return

        urls_for_prompt = [url for url in urls_for_prompt if self.row_for_url(url)]
        if not urls_for_prompt:
            return
        if self.send_prompt_to_target(target, self.resolve_comments_prompt(target, text, urls_for_prompt)):
            for url, events in comments_to_mark.items():
                self.mark_events_seen(url, events)
            for url, signature in ci_signatures_to_mark.items():
                self.ci_signature_file_for_url(url).write_text(signature + "\n")
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            self.log(f"sent {RESOLVE_COMMENTS_SKILL} prompt for {', '.join(urls_for_prompt)} to {target}")
        else:
            self.next_poll_seconds = min(self.next_poll_seconds, self.poll_action_seconds)
            self.log(f"failed to send {RESOLVE_COMMENTS_SKILL} prompt for {', '.join(urls_for_prompt)}")

    def fetch_assigned_open_issues(self, repo: str) -> list[IssueItem] | None:
        result = self.run_cmd(
            [
                self.gh_command,
                "issue",
                "list",
                "--repo",
                repo,
                "--assignee",
                "@me",
                "--state",
                "open",
                "--limit",
                str(self.issue_limit),
                "--json",
                "number,title,url",
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to fetch assigned open issues for {repo}: {result.stderr.strip()}")
            return None
        try:
            raw_issues = json.loads(result.stdout or "[]")
        except json.JSONDecodeError as exc:
            self.log(f"failed to parse assigned open issues for {repo}: {exc}")
            return None
        issues: list[IssueItem] = []
        for item in raw_issues:
            if not isinstance(item, dict):
                continue
            number = str(item.get("number") or "")
            if not number:
                continue
            issues.append(
                IssueItem(
                    repo=repo,
                    number=number,
                    url=str(item.get("url") or f"https://github.com/{repo}/issues/{number}"),
                    title=str(item.get("title") or ""),
                )
            )
        return issues

    @staticmethod
    def normalize_pr_url(value: str) -> str:
        value = value.strip()
        if not value:
            return ""
        parsed = parse_pr_url(value)
        if parsed:
            return f"https://github.com/{parsed[0]}/pull/{parsed[1]}"
        match = re.fullmatch(r"https://api\.github\.com/repos/([^/\s]+/[^/\s]+)/pulls/([0-9]+)", value)
        if match:
            return f"https://github.com/{match.group(1)}/pull/{match.group(2)}"
        return ""

    def pr_url_from_issue_object(self, item: Any) -> str:
        if not isinstance(item, dict) or item.get("pull_request") is None:
            return ""
        for candidate in (
            item.get("html_url"),
            item.get("url"),
            item.get("pull_request", {}).get("html_url") if isinstance(item.get("pull_request"), dict) else "",
            item.get("pull_request", {}).get("url") if isinstance(item.get("pull_request"), dict) else "",
        ):
            if not candidate:
                continue
            url = self.normalize_pr_url(str(candidate))
            if url:
                return url
        return ""

    def related_pr_urls_for_issue(self, issue: IssueItem) -> list[str] | None:
        urls: list[str] = []
        result = self.run_cmd(
            [
                self.gh_command,
                "issue",
                "view",
                issue.number,
                "--repo",
                issue.repo,
                "--json",
                "closedByPullRequestsReferences",
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to fetch linked PR references for {issue.url}: {result.stderr.strip()}")
            return None
        try:
            issue_data = json.loads(result.stdout or "{}")
        except json.JSONDecodeError as exc:
            self.log(f"failed to parse linked PR references for {issue.url}: {exc}")
            return None
        for ref in issue_data.get("closedByPullRequestsReferences", []):
            if not isinstance(ref, dict):
                continue
            url = self.normalize_pr_url(str(ref.get("url") or ""))
            if url:
                urls.append(url)

        timeline = self.fetch_json_stream(
            f"repos/{issue.repo}/issues/{issue.number}/timeline?per_page={self.comment_page_size}"
        )
        if timeline is None:
            self.log(f"failed to fetch issue timeline for {issue.url}; using closing PR references only")
        else:
            for event in timeline:
                if not isinstance(event, dict):
                    continue
                for candidate in (
                    event.get("source", {}).get("issue") if isinstance(event.get("source"), dict) else None,
                    event.get("subject"),
                ):
                    url = self.pr_url_from_issue_object(candidate)
                    if url:
                        urls.append(url)
        return unique_preserve_order(urls)

    def pr_assignment_info_for_url(self, url: str) -> PullRequestAssignmentInfo | None:
        parsed = parse_pr_url(url)
        if not parsed:
            return None
        repo, number = parsed
        result = self.run_cmd(
            [
                self.gh_command,
                "pr",
                "view",
                number,
                "--repo",
                repo,
                "--json",
                "assignees,author,number,state,title,url",
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to fetch PR metadata for {url}: {result.stderr.strip()}")
            return None
        try:
            item = json.loads(result.stdout or "{}")
        except json.JSONDecodeError as exc:
            self.log(f"failed to parse PR metadata for {url}: {exc}")
            return None
        author = item.get("author", {}).get("login", "") if isinstance(item.get("author"), dict) else ""
        return PullRequestAssignmentInfo(
            repo=repo,
            number=str(item.get("number") or number),
            url=str(item.get("url") or url),
            title=str(item.get("title") or ""),
            state=str(item.get("state") or "").upper(),
            author=str(author),
            assignees=self.logins_from_json(item.get("assignees")),
        )

    def assign_bot_pr_to_me_if_needed(self, issue: IssueItem, pr_url: str) -> None:
        info = self.pr_assignment_info_for_url(pr_url)
        if not info:
            return
        if info.state != "OPEN":
            return
        if not self.pr_is_from_bot_author(info.author):
            return
        if any(assignee.lower() == self.viewer_login.lower() for assignee in info.assignees):
            return
        if self.dry_run:
            self.log(f"dry-run: would assign {info.url} to {self.viewer_login} for issue {issue.url}")
            return
        result = self.run_cmd([self.gh_command, "pr", "edit", info.url, "--add-assignee", "@me"])
        if result.returncode == 0:
            self.log(f"assigned bot PR {info.url} to {self.viewer_login} for issue {issue.url}")
        else:
            self.log(f"failed to assign bot PR {info.url}: {result.stderr.strip()}")

    def assign_bot_prs_for_issue(self, issue: IssueItem) -> None:
        related_urls = self.related_pr_urls_for_issue(issue)
        if related_urls is None:
            return
        for pr_url in related_urls:
            self.assign_bot_pr_to_me_if_needed(issue, pr_url)

    def assign_bot_prs_once(self) -> None:
        for repo in self.monitored_repos:
            issues = self.fetch_assigned_open_issues(repo)
            if issues is None:
                continue
            for issue in issues:
                self.assign_bot_prs_for_issue(issue)

    def poll_once(self) -> None:
        if self.assign_bot_prs_enabled:
            self.assign_bot_prs_once()
        self.read_state()
        discovered = self.discover_prs()
        for pr in discovered:
            self.upsert_discovered_pr(pr)
        if self.state_changed:
            self.save_state()
        if self.dry_run:
            return
        for row in list(self.rows):
            self.process_row(row)
        if self.state_changed:
            self.save_state()

    def reset_next_poll_delay(self) -> None:
        self.next_poll_seconds = self.poll_seconds

    def run(self, argv: list[str]) -> int:
        self.parse_args(argv)
        self.print_startup_warning()
        required_commands = [self.gh_command, self.git_command, "tmux", "bash", self.agent_command.split()[0]]
        for command in required_commands:
            self.need_command(command)
        if self.command_uses_windows_paths(self.git_command):
            self.need_command("wslpath")
        if self.run_cmd([self.gh_command, "auth", "status"]).returncode != 0:
            self.die(f"{self.gh_command} is not authenticated")
        self.resolve_repo_root()
        if not self.dry_run:
            self.state_dir.mkdir(parents=True, exist_ok=True)
        self.viewer_login = self.resolve_viewer_login()
        self.finalize_monitored_repos()
        self.log_startup()

        while True:
            self.reset_next_poll_delay()
            self.poll_once()
            if not self.dry_run:
                self.persist_idle_screen_observations()
            self.print_status_line()
            if self.once:
                break
            time.sleep(self.next_poll_seconds)
        return 0

    def cleanup(self) -> None:
        self.finish_status_line()


def main(argv: list[str]) -> int:
    watcher = AgentReview()

    def handle_signal(signum: int, _frame: Any) -> None:
        watcher.cleanup()
        raise SystemExit(130 if signum == signal.SIGINT else 143)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    try:
        return watcher.run(argv)
    except AgentReviewError as exc:
        watcher.cleanup()
        print(exc, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        watcher.cleanup()
        return 130
    finally:
        watcher.cleanup()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
