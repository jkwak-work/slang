#!/usr/bin/env python3
"""
Watch GitHub PR comments, reviews, CI checks, and Copilot-labeled assigned issues.

This watcher intentionally keeps the same command-line flags, environment variables,
watch-state file format, status field files, tmux session naming, and prompt text
used by the previous shell watcher so it can run without migrating state.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


STATUS_BLOCK_START = "<!-- pr-watch-status:start -->"
STATUS_BLOCK_END = "<!-- pr-watch-status:end -->"
RESOLVE_SKILL = "slang-pr-resolve-comments"
PR_CREATE_SKILL = "slang-pr-create"


class WatchError(Exception):
    pass


@dataclass
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


@dataclass
class WatchItem:
    repo: str
    pr: str
    issue: str
    worktree: str
    session: str

    @property
    def is_pr(self) -> bool:
        return bool(self.pr)

    @property
    def is_issue(self) -> bool:
        return bool(self.issue)


def strip_cr(text: str) -> str:
    return text.replace("\r", "")


def env_bool(name: str, default: str = "true") -> str:
    return os.environ.get(name, default)


def is_wsl_environment() -> bool:
    try:
        return bool(re.search(r"microsoft|wsl", Path("/proc/version").read_text(), re.I))
    except OSError:
        return False


def default_host_command(command_name: str) -> str:
    if is_wsl_environment() and shutil.which(f"{command_name}.exe"):
        return f"{command_name}.exe"
    return command_name


def sanitize_name(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9_.-]+", "-", value)
    value = value.strip("-")[:80]
    value = re.sub(r"-+$", "", value)
    return value


def parse_json_stream(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    values: list[Any] = []
    idx = 0
    while idx < len(text):
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            break
        value, idx = decoder.raw_decode(text, idx)
        values.append(value)
    return values


def flatten_json_stream(text: str) -> list[Any]:
    values = parse_json_stream(text)
    flattened: list[Any] = []
    for value in values:
        if isinstance(value, list):
            flattened.extend(value)
        else:
            flattened.append(value)
    return flattened


class WatchGithub:
    def __init__(self) -> None:
        cache_home = os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
        self.script_name = Path(sys.argv[0]).name
        self.state_dir = Path(os.environ.get("STATE_DIR", str(Path(cache_home) / "watch-github")))
        self.watch_state_file = self.state_dir / "watch-github.conf"
        self.poll_seconds = int(os.environ.get("POLL_SECONDS", "60"))
        self.bootstrap_mode = os.environ.get("BOOTSTRAP_MODE", "prime")
        self.ci_bootstrap_mode = os.environ.get("CI_BOOTSTRAP_MODE", self.bootstrap_mode)
        self.watch_ci = env_bool("WATCH_CI")
        self.watch_copilot_issues = env_bool("WATCH_COPILOT_ISSUES")
        self.copilot_label = os.environ.get("COPILOT_LABEL", "Copilot")
        self.issue_list_limit = os.environ.get("ISSUE_LIST_LIMIT", "100")
        self.watch_issue_repo = os.environ.get("WATCH_ISSUE_REPO", "shader-slang/slang")
        self.pr_base_repo = os.environ.get("PR_BASE_REPO", "")
        self.comment_page_size = os.environ.get("COMMENT_PAGE_SIZE", "100")
        self.capture_lines = int(os.environ.get("CAPTURE_LINES", "250"))
        self.match_tail_lines = int(os.environ.get("MATCH_TAIL_LINES", "50"))
        self.gh_command = os.environ.get("GH_COMMAND", default_host_command("gh"))
        self.git_command = os.environ.get("GIT_COMMAND", default_host_command("git"))
        self.default_branch = os.environ.get("DEFAULT_BRANCH", "")
        self.agent_command = os.environ.get("AGENT_COMMAND", "codex")
        self.agent_flags = os.environ.get("AGENT_FLAGS", "")
        self.agent_command_name = ""
        self.agent_ready_pattern = os.environ.get("AGENT_READY_PATTERN", "")
        self.agent_approval_pattern = os.environ.get("AGENT_APPROVAL_PATTERN", "")
        self.agent_shell_command_pattern = os.environ.get("AGENT_SHELL_COMMAND_PATTERN", "")
        self.agent_window_name = os.environ.get("AGENT_WINDOW_NAME", "")
        self.agent_session_prefix = os.environ.get("AGENT_SESSION_PREFIX", "")
        self.agent_skill_prefix = os.environ.get("AGENT_SKILL_PREFIX", "")
        self.agent_start_wait_seconds = int(os.environ.get("AGENT_START_WAIT_SECONDS", "10"))
        self.agent_start_attempts = int(os.environ.get("AGENT_START_ATTEMPTS", "5"))
        self.prompt_enter_delay_seconds = int(os.environ.get("PROMPT_ENTER_DELAY_SECONDS", "3"))
        self.prompt_send_attempts = int(os.environ.get("PROMPT_SEND_ATTEMPTS", "3"))

        self.status_enabled = False
        self.status_issue_repo = ""
        self.status_issue_number = ""
        self.once = False
        self.items: list[WatchItem] = []
        self.approved_signatures: dict[str, str] = {}
        self.idle_screen_texts: dict[str, str] = {}
        self.idle_screen_signatures: dict[str, str] = {}
        self.idle_screen_results: dict[str, str] = {}
        self.last_status_issue_message = ""
        self.status_line_active = False

    def run_cmd(
        self,
        args: list[str],
        *,
        cwd: str | Path | None = None,
        input_text: str | None = None,
        check: bool = False,
        allow: set[int] | None = None,
        stdout: int = subprocess.PIPE,
        stderr: int = subprocess.PIPE,
        env: dict[str, str] | None = None,
    ) -> CommandResult:
        allow = {0} if allow is None else allow
        proc = subprocess.run(
            args,
            cwd=str(cwd) if cwd is not None else None,
            input=input_text,
            text=True,
            stdout=stdout,
            stderr=stderr,
            env=env,
        )
        out = strip_cr(proc.stdout or "")
        err = strip_cr(proc.stderr or "")
        if check and proc.returncode not in allow:
            raise WatchError(f"command failed ({proc.returncode}): {' '.join(args)}\n{err}")
        return CommandResult(proc.returncode, out, err)

    def log(self, message: str) -> None:
        self.finish_status_line()
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", file=sys.stderr)

    def die(self, message: str) -> None:
        raise WatchError(f"{self.script_name}: {message}")

    def finish_status_line(self) -> None:
        if self.status_line_active and sys.stderr.isatty():
            print(file=sys.stderr)
        self.status_line_active = False

    def print_replacing_status_line(self, status: str) -> None:
        if not sys.stderr.isatty():
            return
        cols = shutil.get_terminal_size((80, 24)).columns
        if len(status) >= cols and cols > 1:
            status = status[: cols - 1]
        print("\r\033[K" + status + (" " * max(cols - len(status), 0)) + "\r", end="", file=sys.stderr)
        self.status_line_active = True

    def print_status_line(self) -> None:
        status = (
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] last poll completed; "
            f"watching {len(self.items)} item(s); next poll in {self.poll_seconds}s"
        )
        if self.last_status_issue_message:
            status += f"; {self.last_status_issue_message}"
        self.print_replacing_status_line(status)

    def record_status_issue_update(self) -> None:
        self.last_status_issue_message = f"status issue updated at {time.strftime('%H:%M:%S')}"

    @staticmethod
    def write_text_atomic(path: Path, text: str) -> None:
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

    def cleanup(self) -> None:
        self.finish_status_line()

    def command_path_for_log(self, command: str) -> str:
        return shutil.which(command) or "not found"

    def need_command(self, command: str) -> None:
        if not shutil.which(command):
            self.die(f"missing required command: {command}")

    def command_uses_windows_paths(self, command: str) -> bool:
        if not is_wsl_environment():
            return False
        if command.endswith(".exe"):
            return True
        resolved = shutil.which(command) or ""
        return resolved.endswith(".exe")

    def path_for_host_command(self, command: str, path: str | Path) -> str:
        path = str(path)
        if self.command_uses_windows_paths(command):
            self.need_command("wslpath")
            return self.run_cmd(["wslpath", "-w", path], check=True).stdout.strip()
        return path

    def path_for_git_path_arg(self, path: str | Path) -> str:
        return self.path_for_host_command(self.git_command, path)

    def finalize_agent_config(self) -> None:
        first_word = self.agent_command.split()[0] if self.agent_command.split() else ""
        self.agent_command_name = Path(first_word).name or "agent"
        if not self.agent_flags:
            if self.agent_command_name == "codex":
                self.agent_flags = "--dangerously-bypass-approvals-and-sandbox"

        default_ready = self.agent_command_name
        if self.agent_command_name == "codex":
            default_ready = r"Codex|gpt-[0-9]|(^|\s)›\s*$"
        elif self.agent_command_name in {"claude", "claude-code"}:
            default_ready = r"Claude|(^|\s)>\s*$"

        default_approval = r"Do you trust the contents of this directory|Do you want to proceed|(^|\s)❯\s+1[.] "
        default_shell = r"^(bash|dash|sh|zsh|fish|cmd|cmd[.]exe|powershell|powershell[.]exe|pwsh|pwsh[.]exe)$"
        self.agent_ready_pattern = self.translate_posix_regex(self.agent_ready_pattern or default_ready)
        self.agent_approval_pattern = self.translate_posix_regex(
            self.agent_approval_pattern or default_approval
        )
        self.agent_shell_command_pattern = self.translate_posix_regex(
            self.agent_shell_command_pattern or default_shell
        )
        self.agent_window_name = self.agent_window_name or self.agent_command_name
        self.agent_session_prefix = self.agent_session_prefix or self.agent_window_name

    @staticmethod
    def translate_posix_regex(pattern: str) -> str:
        return (
            pattern.replace("[[:space:]]", r"\s")
            .replace("[[:digit:]]", r"\d")
            .replace("[[:alnum:]]", r"[0-9A-Za-z]")
        )

    def skill_prefix_for_agent(self) -> str:
        if self.agent_skill_prefix:
            return self.agent_skill_prefix
        if self.agent_command_name == "codex":
            return "$"
        if self.agent_command_name in {"claude", "claude-code"}:
            return "/"
        return "$"

    def resolve_prompt_for_pr_resolve(self, repo: str, pr: str) -> str:
        return f"{self.skill_prefix_for_agent()}{RESOLVE_SKILL} https://github.com/{repo}/pull/{pr}\n"

    def resolve_prompt_for_issue(self, repo: str, issue: str) -> str:
        return (
            f"Work on GitHub issue https://github.com/{repo}/issues/{issue} in this worktree. "
            "Read the issue and comments, implement the requested changes, and run appropriate "
            "focused validation. Commit when the implementation is ready for the review.\n"
        )

    def resolve_prompt_for_pr_create(self, pr_repo: str) -> str:
        return f"{self.skill_prefix_for_agent()}{PR_CREATE_SKILL} {pr_repo}\n"

    def parse_args(self, argv: list[str]) -> None:
        parser = argparse.ArgumentParser(
            prog=self.script_name,
            description="Watch GitHub PR comments, reviews, CI checks, and assigned Copilot issues.",
        )
        parser.add_argument("--agent", choices=["claude", "codex"], default=None)
        parser.add_argument("--once", action="store_true")
        parser.add_argument("--status-issue", default=None, metavar="URL")
        args = parser.parse_args(argv)
        if args.agent:
            self.agent_command = args.agent
        self.once = args.once
        if args.status_issue:
            match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/issues/([0-9]+)/*", args.status_issue)
            if not match:
                self.die(f"bad status issue URL: {args.status_issue}")
            self.status_issue_repo = match.group(1)
            self.status_issue_number = match.group(2)
            self.status_enabled = True

    def print_startup_warning(self) -> None:
        print(
            f"WARNING: {self.script_name} dispatches local agent sessions from GitHub PR comments, "
            "CI changes, and assigned Copilot issues.\n"
            "Run it only for trusted repositories/authors, preferably inside a sandboxed system; "
            "untrusted comments can attempt prompt injection.",
            file=sys.stderr,
        )

    def log_startup_tools(self) -> None:
        self.log(f"using GitHub CLI: {self.command_path_for_log(self.gh_command)}")
        self.log(f"using Git: {self.command_path_for_log(self.git_command)}")
        self.log(f"using agent: {self.command_path_for_log(self.agent_command.split()[0])}")
        self.log(f"using tmux: {self.command_path_for_log('tmux')}")
        self.log(f"using cksum: {self.command_path_for_log('cksum')}")
        self.log(f"using PR create skill: {self.skill_prefix_for_agent()}{PR_CREATE_SKILL}")
        self.log(f"watch state file: {self.watch_state_file}")
        self.log(
            f"watch issue repo: {self.watch_issue_repo}; "
            f"Copilot issue discovery={self.watch_copilot_issues}; CI watch={self.watch_ci}"
        )

    def require_repo_root(self) -> None:
        if self.run_cmd([self.git_command, "rev-parse", "--is-inside-work-tree"]).returncode != 0:
            self.die("must be run from the root of a git worktree")
        cdup = self.run_cmd([self.git_command, "rev-parse", "--show-cdup"], check=True).stdout.strip()
        if cdup:
            self.die("must be run from the root of a git worktree")
        is_bare = self.run_cmd([self.git_command, "rev-parse", "--is-bare-repository"], check=True).stdout.strip()
        if is_bare != "false":
            self.die("must be run from a non-bare git worktree")
        self.run_cmd([self.git_command, "worktree", "list"], check=True)

    def resolve_default_branch(self) -> str | None:
        if self.default_branch:
            return self.default_branch
        result = self.run_cmd(
            [self.git_command, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
        )
        remote_head = result.stdout.strip()
        if remote_head.startswith("origin/"):
            return remote_head[len("origin/") :]
        if remote_head:
            return remote_head
        self.log("failed to determine default branch; set DEFAULT_BRANCH explicitly")
        return None

    def require_default_branch(self) -> None:
        current = self.run_cmd([self.git_command, "branch", "--show-current"], check=True).stdout.strip()
        if not current:
            self.die("must be run from the default branch; HEAD is detached")
        default = self.resolve_default_branch()
        if not default:
            self.die("failed to determine default branch; set DEFAULT_BRANCH explicitly")
        if current != default:
            self.die(f"must be run from the default branch ({default}); current branch is {current}")

    @staticmethod
    def repo_from_github_url(url: str) -> str | None:
        patterns = [
            r"https://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?",
            r"git@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?",
            r"ssh://git@github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?",
        ]
        for pattern in patterns:
            match = re.fullmatch(pattern, url)
            if match:
                return f"{match.group(1)}/{match.group(2).removesuffix('.git')}"
        return None

    def resolve_origin_repo(self) -> str | None:
        if self.pr_base_repo:
            return self.pr_base_repo
        result = self.run_cmd([self.git_command, "remote", "get-url", "origin"])
        if result.returncode != 0:
            self.log("failed to read origin remote URL")
            return None
        repo = self.repo_from_github_url(result.stdout.strip())
        if not repo:
            self.log("origin remote is not a GitHub repository URL; set PR_BASE_REPO explicitly")
        return repo

    def resolve_issue_repo(self) -> str | None:
        if self.watch_issue_repo:
            return self.watch_issue_repo
        result = self.run_cmd([self.gh_command, "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
        repo = result.stdout.strip()
        if result.returncode != 0 or not repo:
            self.log("failed to determine GitHub issue repo; set WATCH_ISSUE_REPO explicitly")
            return None
        return repo

    def current_github_login(self) -> str | None:
        result = self.run_cmd([self.gh_command, "api", "user", "--jq", ".login"])
        login = result.stdout.strip()
        return login if result.returncode == 0 and login else None

    def resolve_repo_default_branch(self, repo: str) -> str | None:
        result = self.run_cmd(
            [self.gh_command, "repo", "view", repo, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"]
        )
        branch = result.stdout.strip()
        return branch or self.resolve_default_branch()

    def state_key_for(self, repo: str, pr: str) -> str:
        return sanitize_name(f"{repo}-pr-{pr}")

    def state_key_for_issue(self, repo: str, issue: str) -> str:
        return sanitize_name(f"{repo}-issue-{issue}")

    def state_key_for_item(self, item: WatchItem) -> str:
        if item.pr:
            return self.state_key_for(item.repo, item.pr)
        return self.state_key_for_issue(item.repo, item.issue)

    def status_field_file_for(self, key: str, field: str) -> Path:
        return self.state_dir / f"{key}.{field}"

    def write_status_field(self, key: str, field: str, value: str) -> None:
        self.status_field_file_for(key, field).write_text(f"{value}\n")

    def write_status_field_if_absent(self, key: str, field: str, value: str) -> None:
        path = self.status_field_file_for(key, field)
        if not path.exists():
            path.write_text(f"{value}\n")

    def read_status_field(self, key: str, field: str, fallback: str = "") -> str:
        path = self.status_field_file_for(key, field)
        if not path.exists():
            return fallback
        try:
            lines = path.read_text().splitlines()
            return lines[0] if lines else ""
        except OSError:
            return fallback

    def short_status_date(self) -> str:
        return time.strftime("%m-%d %H:%M")

    def ensure_status_defaults(self, key: str) -> None:
        self.write_status_field_if_absent(key, "date", self.short_status_date())
        self.write_status_field_if_absent(key, "ci", "unknown")

    def set_status_phase(self, key: str, phase: str) -> None:
        self.write_status_field(key, "date", self.short_status_date())
        self.write_status_field(key, "phase", phase)

    def ci_status_for_counts(self, failure_count: int, pending_count: int) -> str:
        if self.watch_ci != "true":
            return "not watched"
        if failure_count > 0 and pending_count > 0:
            return f"{failure_count} failing, {pending_count} pending"
        if failure_count > 0:
            return f"{failure_count} failing"
        if pending_count > 0:
            return f"{pending_count} pending"
        return "passing"

    def parse_watch_state_fields(self, raw: str) -> WatchItem | None:
        line = raw.strip()
        if not line or line.startswith("#"):
            return None
        fields = line.split()
        if len(fields) > 4:
            self.log(f"too many fields in watch state line: {raw.rstrip()}")
            return None

        first = fields[0]
        second = fields[1] if len(fields) > 1 else ""
        third = fields[2] if len(fields) > 2 else ""
        fourth = fields[3] if len(fields) > 3 else ""
        repo = pr = issue = worktree = session = ""

        match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/pull/([0-9]+)/*", first)
        if match and not fourth:
            repo, pr, worktree, session = match.group(1), match.group(2), second, third
        else:
            match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/issues/([0-9]+)/*", first)
            if match and not fourth:
                repo, issue, worktree, session = match.group(1), match.group(2), second, third
            else:
                match = re.fullmatch(r"([^/\s]+/[^#\s]+)#([0-9]+)", first)
                if match and not fourth:
                    repo, pr, worktree, session = match.group(1), match.group(2), second, third
                else:
                    match = re.fullmatch(r"([^/\s]+/[^/\s]+)/pull/([0-9]+)", first)
                    if match and not fourth:
                        repo, pr, worktree, session = match.group(1), match.group(2), second, third
                    else:
                        match = re.fullmatch(r"([^/\s]+/[^/\s]+)/issues/([0-9]+)", first)
                        if match and not fourth:
                            repo, issue, worktree, session = match.group(1), match.group(2), second, third
                        else:
                            repo, pr, worktree, session = first, second, third, fourth

        if not repo or not worktree:
            self.log(f"bad watch state line: {raw.rstrip()}")
            return None
        if pr and not pr.isdigit():
            self.log(f"bad PR number in watch state line: {raw.rstrip()}")
            return None
        if issue and not issue.isdigit():
            self.log(f"bad issue number in watch state line: {raw.rstrip()}")
            return None
        if not pr and not issue:
            self.log(f"bad watch state line: {raw.rstrip()}")
            return None
        if not session:
            session = sanitize_name(f"{self.agent_session_prefix}-{repo}-pr-{pr}") if pr else sanitize_name(f"issue-{issue}")
        else:
            session = sanitize_name(session)
        if not session:
            self.log(f"empty tmux session name for watch state line: {raw.rstrip()}")
            return None
        return WatchItem(repo, pr, issue, worktree, session)

    def read_watch_state(self) -> bool:
        self.items = []
        if not self.watch_state_file.exists():
            if self.watch_copilot_issues == "true":
                self.watch_state_file.parent.mkdir(parents=True, exist_ok=True)
                self.watch_state_file.write_text("")
            else:
                self.log(f"watch state file not found: {self.watch_state_file}")
                return False
        for line in self.watch_state_file.read_text().splitlines():
            item = self.parse_watch_state_fields(line)
            if item:
                self.items.append(item)
        if not self.items and self.watch_copilot_issues != "true":
            self.log(f"watch state contains no items: {self.watch_state_file}")
            return False
        return True

    def watch_state_find_item(self, repo: str, pr: str, issue: str) -> WatchItem | None:
        for item in self.items:
            if item.repo != repo:
                continue
            if pr and item.pr == pr:
                return item
            if issue and item.issue == issue:
                return item
        return None

    def watch_state_has_item(self, repo: str, pr: str, issue: str) -> bool:
        return self.watch_state_find_item(repo, pr, issue) is not None

    def append_watch_state_item(self, repo: str, pr: str, issue: str, worktree: str, session: str) -> None:
        item_url = f"https://github.com/{repo}/pull/{pr}" if pr else f"https://github.com/{repo}/issues/{issue}"
        with self.watch_state_file.open("a") as f:
            f.write(f"{item_url} {worktree} {session}\n")
        self.log(f"appended watch-state item: {item_url} worktree={worktree} session={session}")
        self.items.append(WatchItem(repo, pr, issue, worktree, session))

    def replace_watch_state_item(
        self, old_repo: str, old_pr: str, old_issue: str, new_repo: str, new_pr: str, worktree: str, session: str
    ) -> None:
        replaced = False
        output: list[str] = []
        lines = self.watch_state_file.read_text().splitlines()
        for line in lines:
            parsed = self.parse_watch_state_fields(line)
            if (
                not replaced
                and parsed
                and parsed.repo == old_repo
                and ((old_pr and parsed.pr == old_pr) or (old_issue and parsed.issue == old_issue))
            ):
                output.append(f"https://github.com/{new_repo}/pull/{new_pr} {worktree} {session}\n")
                replaced = True
            else:
                output.append(line + "\n")
        if not replaced:
            output.append(f"https://github.com/{new_repo}/pull/{new_pr} {worktree} {session}\n")
        self.write_text_atomic(self.watch_state_file, "".join(output))
        self.log(f"updated watch-state item to https://github.com/{new_repo}/pull/{new_pr} worktree={worktree} session={session}")
        self.read_watch_state()

    def remove_watch_state_item(self, old_repo: str, old_pr: str, old_issue: str) -> None:
        removed = False
        output: list[str] = []
        for line in self.watch_state_file.read_text().splitlines():
            parsed = self.parse_watch_state_fields(line)
            if (
                parsed
                and parsed.repo == old_repo
                and ((old_pr and parsed.pr == old_pr) or (old_issue and parsed.issue == old_issue))
            ):
                removed = True
                continue
            output.append(line + "\n")
        self.write_text_atomic(self.watch_state_file, "".join(output))
        if removed:
            self.log(f"removed watch-state item for {old_repo}#{old_pr or old_issue}")
            self.read_watch_state()

    @staticmethod
    def parse_github_pr_url(url: str) -> tuple[str, str] | None:
        match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/pull/([0-9]+)/*", url)
        if not match:
            return None
        return match.group(1), match.group(2)

    def pr_state_for(self, repo: str, pr: str) -> str | None:
        result = self.run_cmd([self.gh_command, "api", f"repos/{repo}/pulls/{pr}"])
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
        state = "merged" if data.get("state") == "closed" and data.get("merged") else data.get("state", "")
        return state.lower() if state else None

    def pr_label_status(self, repo: str, pr: str) -> int:
        result = self.run_cmd([self.gh_command, "api", f"repos/{repo}/issues/{pr}"])
        if result.returncode != 0:
            return 2
        labels = [label.get("name", "") for label in json.loads(result.stdout).get("labels", [])]
        return 0 if any(label.lower() == self.copilot_label.lower() for label in labels) else 1

    @staticmethod
    def pr_head_ref_matches_issue(head_ref: str, issue: str) -> bool:
        return f"issue-{issue}" in head_ref

    def pr_url_is_open_for_issue_and_created_by(self, pr_url: str, author_login: str, issue: str) -> int:
        parsed = self.parse_github_pr_url(pr_url)
        if not parsed:
            return 2
        repo, pr = parsed
        result = self.run_cmd([self.gh_command, "api", f"repos/{repo}/pulls/{pr}"])
        if result.returncode != 0:
            return 2
        data = json.loads(result.stdout)
        state = "merged" if data.get("state") == "closed" and data.get("merged") else data.get("state", "")
        login = data.get("user", {}).get("login", "")
        head_ref = data.get("head", {}).get("ref", "")
        if state.lower() == "open" and login == author_login and self.pr_head_ref_matches_issue(head_ref, issue):
            return 0
        return 1

    def related_pr_urls_for_issue(self, repo: str, issue: str) -> list[str] | None:
        result = self.run_cmd(
            [
                self.gh_command,
                "issue",
                "view",
                issue,
                "--repo",
                repo,
                "--json",
                "closedByPullRequestsReferences",
            ]
        )
        if result.returncode != 0:
            return None
        urls = [
            ref.get("url", "")
            for ref in json.loads(result.stdout).get("closedByPullRequestsReferences", [])
            if ref.get("url")
        ]
        result = self.run_cmd(
            [self.gh_command, "api", "--paginate", f"repos/{repo}/issues/{issue}/timeline?per_page={self.comment_page_size}"]
        )
        if result.returncode != 0:
            return None
        for event in flatten_json_stream(result.stdout):
            for obj in (event.get("source", {}).get("issue"), event.get("subject")):
                if isinstance(obj, dict) and obj.get("pull_request") is not None:
                    url = obj.get("html_url") or obj.get("pull_request", {}).get("html_url")
                    if url:
                        urls.append(url)
        return sorted(set(urls))

    def open_issue_branch_pr_urls_for_issue(self, repo: str, issue: str, author_login: str) -> list[str] | None:
        result = self.run_cmd(
            [self.gh_command, "api", "--paginate", f"repos/{repo}/pulls?state=open&per_page={self.comment_page_size}"]
        )
        if result.returncode != 0:
            return None
        marker = f"issue-{issue}"
        urls: list[str] = []
        for pr in flatten_json_stream(result.stdout):
            if pr.get("user", {}).get("login", "") != author_login:
                continue
            if marker in pr.get("head", {}).get("ref", ""):
                url = pr.get("html_url", "")
                if url:
                    urls.append(url)
        return urls

    def open_related_prs_for_issue(self, repo: str, issue: str) -> tuple[int, list[str]]:
        viewer_login = self.current_github_login()
        if not viewer_login:
            return 2, []
        related = self.related_pr_urls_for_issue(repo, issue)
        if related is None:
            return 2, []
        inspect_failed = False
        branch_prs = self.open_issue_branch_pr_urls_for_issue(repo, issue, viewer_login)
        if branch_prs is None:
            inspect_failed = True
            branch_prs = []
        candidates = list(dict.fromkeys(related + branch_prs))
        open_prs: list[str] = []
        for pr_url in candidates:
            rc = self.pr_url_is_open_for_issue_and_created_by(pr_url, viewer_login, issue)
            if rc == 0:
                open_prs.append(pr_url)
            elif rc != 1:
                inspect_failed = True
        if inspect_failed:
            return 2, open_prs
        return (0, open_prs) if open_prs else (1, [])

    def first_open_related_pr_for_issue(self, repo: str, issue: str) -> tuple[int, str | None]:
        rc, open_prs = self.open_related_prs_for_issue(repo, issue)
        if rc == 0 and open_prs:
            return 0, open_prs[0]
        return rc, None

    def git_in_worktree(self, worktree: str, args: list[str], allow: set[int] | None = None) -> CommandResult:
        git_worktree = self.path_for_git_path_arg(worktree)
        return self.run_cmd([self.git_command, "-C", git_worktree, *args], allow=allow or {0})

    def git_commit_for_ref(self, worktree: str, ref: str) -> bool:
        return self.git_in_worktree(worktree, ["rev-parse", "--verify", f"{ref}^{{commit}}"]).returncode == 0

    def worktree_ref_contains_head(self, worktree: str, ref: str) -> int:
        if not self.git_commit_for_ref(worktree, ref):
            return 2
        rc = self.git_in_worktree(worktree, ["merge-base", "--is-ancestor", "HEAD", ref], allow={0, 1, 2}).returncode
        return rc if rc in {0, 1} else 2

    def worktree_head_is_in_default_branch(self, worktree: str, pr_repo: str) -> int:
        if not self.git_commit_for_ref(worktree, "HEAD"):
            return 2
        base_branch = self.resolve_repo_default_branch(pr_repo)
        if not base_branch:
            return 2
        refs = [f"refs/remotes/origin/{base_branch}", f"origin/{base_branch}", base_branch]
        result = self.git_in_worktree(
            worktree,
            ["for-each-ref", "--format=%(refname:short)", f"refs/remotes/*/{base_branch}"],
            allow={0},
        )
        refs.extend(line for line in result.stdout.splitlines() if line.strip())
        rc = 2
        for ref in dict.fromkeys(refs):
            current = self.worktree_ref_contains_head(worktree, ref)
            if current == 0:
                return 0
            if current == 1:
                rc = 1
        return rc

    def fetch_copilot_issues(self, repo: str) -> list[str] | None:
        result = self.run_cmd(
            [
                self.gh_command,
                "issue",
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
                self.issue_list_limit,
                "--json",
                "number",
            ]
        )
        if result.returncode != 0:
            return None
        return [str(item["number"]) for item in json.loads(result.stdout)]

    @staticmethod
    def issue_worktree_name(issue: str) -> str:
        return f"issue-{issue}"

    def issue_worktree_path(self, issue: str) -> str:
        return str(Path.cwd().resolve().parent / self.issue_worktree_name(issue))

    def issue_worktree_path_is_safe_to_delete(self, issue: str, worktree: str) -> bool:
        expected = self.issue_worktree_path(issue)
        return worktree == expected and Path(worktree).name == self.issue_worktree_name(issue)

    def delete_issue_worktree(self, issue: str, worktree: str) -> bool:
        path = Path(worktree)
        if not path.exists():
            return True
        if not self.issue_worktree_path_is_safe_to_delete(issue, worktree):
            self.log(f"refusing to delete unexpected issue worktree path: {worktree}")
            return False
        self.log(f"deleting existing issue worktree {path.name} before rediscovery")
        git_worktree = self.path_for_git_path_arg(worktree)
        if self.run_cmd([self.git_command, "worktree", "remove", "--force", "--force", git_worktree]).returncode != 0:
            self.log(f"git worktree remove failed for {worktree}; removing directory directly")
        self.run_cmd([self.git_command, "worktree", "prune"])
        if path.exists():
            shutil.rmtree(path, ignore_errors=False)
            self.run_cmd([self.git_command, "worktree", "prune"])
        return True

    def delete_issue_branch(self, branch: str, worktree_log: Path) -> bool:
        if self.run_cmd([self.git_command, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"]).returncode != 0:
            return True
        self.log(f"deleting existing issue branch {branch} before rediscovery")
        with worktree_log.open("a") as log_file:
            log_file.write(f"[{time.strftime('%H:%M:%S')}] Deleting existing issue branch before rediscovery: {branch}\n")
            subprocess.run([self.git_command, "worktree", "prune"], stdout=log_file, stderr=log_file, text=True)
            rc = subprocess.run([self.git_command, "branch", "-D", branch], stdout=log_file, stderr=log_file, text=True).returncode
        if rc != 0:
            self.log(f"failed to delete existing issue branch {branch}; see {worktree_log}")
            return False
        return True

    def clear_issue_agent_state(self, session: str) -> None:
        for target in (f"{session}:{self.agent_window_name}.0", f"{session}:0.0"):
            safe = sanitize_name(target)
            for suffix in ("idle-screen", "idle-screen-signature"):
                (self.state_dir / f"{safe}.{suffix}").unlink(missing_ok=True)

    def create_issue_worktree(self, repo: str, issue: str) -> str | None:
        worktree_name = self.issue_worktree_name(issue)
        worktree = self.issue_worktree_path(issue)
        worktree_log = self.state_dir / f"{self.state_key_for_issue(repo, issue)}.worktree-add.log"
        if Path(worktree).exists():
            self.log(f"issue worktree still exists before creation: {worktree}")
            return None
        worktree_log.write_text("")
        if not self.delete_issue_branch(worktree_name, worktree_log):
            return None
        self.log(f"creating issue worktree {worktree_name} for {repo}#{issue}")
        env = dict(os.environ)
        env["GIT_EXE"] = self.git_command
        with worktree_log.open("a") as log_file:
            rc = subprocess.run(
                ["extras/git-worktree-add.sh", worktree_name],
                stdout=log_file,
                stderr=log_file,
                text=True,
                env=env,
            ).returncode
        if rc != 0:
            self.log(f"git-worktree-add failed for {repo}#{issue}; see {worktree_log}")
            return None
        return worktree

    def start_discovered_issue(self, repo: str, issue: str) -> bool:
        key = self.state_key_for_issue(repo, issue)
        worktree_name = self.issue_worktree_name(issue)
        worktree = self.issue_worktree_path(issue)
        if self.tmux_session_exists(worktree_name):
            self.log(f"killing existing tmux session {worktree_name} before starting issue agent")
            if self.run_cmd(["tmux", "kill-session", "-t", f"={worktree_name}"]).returncode != 0:
                self.log(f"failed to kill existing tmux session {worktree_name}")
                return False
            if self.tmux_session_exists(worktree_name):
                self.log(f"tmux session {worktree_name} still exists after kill")
                return False
        if Path(worktree).exists() and not self.delete_issue_worktree(issue, worktree):
            return False
        worktree = self.create_issue_worktree(repo, issue)
        if not worktree:
            return False
        self.clear_issue_agent_state(worktree_name)
        target = self.ensure_agent_target(worktree_name, worktree)
        if not target:
            self.log(f"failed to start agent for {repo}#{issue}; will retry from issue discovery")
            return False
        state = self.tmux_state_for_session(worktree_name)
        if state in {"no session", "unknown"}:
            self.log(f"agent is not live in {worktree_name} after startup (state={state}); will retry from issue discovery")
            return False
        self.append_watch_state_item(repo, "", issue, worktree, worktree_name)
        self.set_status_phase(key, "Initalizing agent")
        self.write_status_field(key, "ci", "N/A")
        self.log(f"watching issue {repo}#{issue} in {worktree_name} after starting agent at {target}")
        return True

    def track_open_pr_for_issue(self, repo: str, issue: str, pr_url: str) -> int:
        parsed = self.parse_github_pr_url(pr_url)
        if not parsed:
            self.log(f"failed to parse related PR URL for {repo}#{issue}: {pr_url}")
            return 2
        pr_repo, pr_number = parsed
        if self.watch_state_has_item(pr_repo, pr_number, ""):
            if self.watch_state_has_item(repo, "", issue):
                self.remove_watch_state_item(repo, "", issue)
            return 0
        issue_item = self.watch_state_find_item(repo, "", issue)
        if issue_item:
            self.replace_watch_state_item(repo, "", issue, pr_repo, pr_number, issue_item.worktree, issue_item.session)
            self.set_status_phase(self.state_key_for(pr_repo, pr_number), "PR discovered")
            return 0
        worktree = self.issue_worktree_path(issue)
        session = self.issue_worktree_name(issue)
        self.append_watch_state_item(pr_repo, pr_number, "", worktree, session)
        self.set_status_phase(self.state_key_for(pr_repo, pr_number), "PR discovered")
        return 0

    def process_discovered_issue(self, repo: str, issue: str) -> None:
        rc, pr_url = self.first_open_related_pr_for_issue(repo, issue)
        if rc == 0 and pr_url:
            self.track_open_pr_for_issue(repo, issue, pr_url)
            return
        if rc not in {0, 1}:
            self.log(f"failed to inspect related PRs for {repo}#{issue}")
            return
        if self.watch_state_find_item(repo, "", issue):
            return
        self.start_discovered_issue(repo, issue)

    def discover_copilot_issues(self) -> None:
        if self.watch_copilot_issues != "true":
            return
        repo = self.resolve_issue_repo()
        if not repo:
            return
        issues = self.fetch_copilot_issues(repo)
        if issues is None:
            self.log(f"failed to fetch Copilot issues for {repo}")
            return
        for issue in issues:
            if issue:
                self.process_discovered_issue(repo, issue)

    def fetch_events(self, repo: str, pr: str) -> list[dict[str, Any]] | None:
        events: list[dict[str, Any]] = []
        endpoints = [
            (f"repos/{repo}/issues/{pr}/comments?per_page={self.comment_page_size}", "issue-comment", "issue"),
            (f"repos/{repo}/pulls/{pr}/comments?per_page={self.comment_page_size}", "review-comment", "review-comment"),
            (f"repos/{repo}/pulls/{pr}/reviews?per_page={self.comment_page_size}", "review", "review"),
        ]
        agent_re = re.compile(r"^\s*\[Agent\]")
        for endpoint, kind, prefix in endpoints:
            result = self.run_cmd([self.gh_command, "api", "--paginate", endpoint])
            if result.returncode != 0:
                return None
            for item in flatten_json_stream(result.stdout):
                body = item.get("body") or ""
                if kind == "review" and not body:
                    continue
                if agent_re.search(body):
                    continue
                created = item.get("submitted_at") if kind == "review" else item.get("created_at")
                updated = item.get("submitted_at") if kind == "review" else item.get("updated_at")
                events.append(
                    {
                        "id": f"{prefix}:{item.get('id')}",
                        "kind": kind,
                        "createdAt": created,
                        "updatedAt": updated,
                        "author": item.get("user", {}).get("login", ""),
                        "url": item.get("html_url", ""),
                        "body": body,
                    }
                )
        return sorted(events, key=lambda e: e.get("createdAt") or e.get("updatedAt") or "")

    def fetch_ci_attention_checks(self, repo: str, pr: str) -> list[dict[str, Any]] | None:
        result = self.run_cmd(
            [
                self.gh_command,
                "pr",
                "checks",
                pr,
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
        checks: list[dict[str, Any]] = []
        for check in raw_checks:
            if check.get("bucket") not in {"fail", "cancel", "pending"}:
                continue
            checks.append(
                {
                    "bucket": check.get("bucket", ""),
                    "workflow": check.get("workflow") or "",
                    "name": check.get("name") or "",
                    "state": check.get("state") or "",
                    "completedAt": check.get("completedAt") or "",
                    "startedAt": check.get("startedAt") or "",
                    "link": check.get("link") or "",
                    "description": check.get("description") or "",
                    "event": check.get("event") or "",
                }
            )
        return checks

    def signature_for(self, text: str) -> str:
        result = self.run_cmd(["cksum"], input_text=text, check=True)
        fields = result.stdout.split()
        return f"{fields[0]}:{fields[1]}" if len(fields) >= 2 else result.stdout.strip()

    def ci_attention_signature(self, checks: list[dict[str, Any]]) -> str:
        lines = []
        for check in sorted(checks, key=lambda c: (c["workflow"], c["name"], c["state"], c["completedAt"], c["link"])):
            lines.append("\t".join([check["bucket"], check["workflow"], check["name"], check["state"], check["completedAt"], check["link"]]))
        return self.signature_for("\n".join(lines) + ("\n" if lines else ""))

    @staticmethod
    def append_seen_ids(state_file: Path, events: list[dict[str, Any]]) -> None:
        seen = set(state_file.read_text().splitlines()) if state_file.exists() else set()
        seen.update(str(event["id"]) for event in events if event.get("id"))
        WatchGithub.write_text_atomic(state_file, "".join(f"{item}\n" for item in sorted(seen) if item))

    @staticmethod
    def collect_new_events(state_file: Path, events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        seen = set(state_file.read_text().splitlines()) if state_file.exists() else set()
        return [event for event in events if str(event.get("id", "")) not in seen]

    def tmux_session_exists(self, session: str) -> bool:
        return self.run_cmd(["tmux", "has-session", "-t", session]).returncode == 0

    def tmux_window_exists(self, session: str, window: str) -> bool:
        result = self.run_cmd(["tmux", "list-windows", "-t", session, "-F", "#{window_name}"])
        return result.returncode == 0 and window in result.stdout.splitlines()

    def target_for_session(self, session: str) -> str:
        if self.tmux_window_exists(session, self.agent_window_name):
            return f"{session}:{self.agent_window_name}.0"
        return f"{session}:0.0"

    def current_path_for_session(self, session: str) -> str | None:
        if not self.tmux_session_exists(session):
            return None
        target = self.target_for_session(session)
        result = self.run_cmd(["tmux", "display-message", "-p", "-t", target, "#{pane_current_path}"])
        path = result.stdout.strip()
        return path if path and Path(path).is_dir() else None

    @staticmethod
    def same_existing_dir(left: str, right: str) -> bool:
        left_path = Path(left)
        right_path = Path(right)
        return left_path.is_dir() and right_path.is_dir() and left_path.resolve() == right_path.resolve()

    def current_command_for_target(self, target: str) -> str:
        return self.run_cmd(["tmux", "display-message", "-p", "-t", target, "#{pane_current_command}"]).stdout.strip()

    def target_has_non_shell_process(self, target: str) -> bool:
        command_name = self.current_command_for_target(target)
        return bool(command_name) and not re.search(self.agent_shell_command_pattern, command_name)

    def session_pane_targets(self, session: str) -> list[str]:
        windows = self.run_cmd(["tmux", "list-windows", "-t", session, "-F", "#{window_index}"]).stdout.splitlines()
        targets: list[str] = []
        for window_index in windows:
            if not window_index:
                continue
            result = self.run_cmd(
                ["tmux", "list-panes", "-t", f"{session}:{window_index}", "-F", "#{session_name}:#{window_index}.#{pane_index}"]
            )
            targets.extend(line for line in result.stdout.splitlines() if line)
        return targets

    def agent_pane_targets_for_session(self, session: str) -> list[str]:
        if not self.tmux_session_exists(session):
            return []
        if self.tmux_window_exists(session, self.agent_window_name):
            result = self.run_cmd(
                ["tmux", "list-panes", "-t", f"{session}:{self.agent_window_name}", "-F", "#{session_name}:#{window_index}.#{pane_index}"]
            )
            return [line for line in result.stdout.splitlines() if line]
        return [self.target_for_session(session)]

    def pane_tail(self, target: str) -> str:
        result = self.run_cmd(["tmux", "capture-pane", "-p", "-J", "-S", f"-{self.capture_lines}", "-t", target])
        return result.stdout if result.returncode == 0 else ""

    def idle_screen_file_for_target(self, target: str) -> Path:
        return self.state_dir / f"{sanitize_name(target)}.idle-screen"

    def idle_screen_signature_file_for_target(self, target: str) -> Path:
        return self.state_dir / f"{sanitize_name(target)}.idle-screen-signature"

    def target_screen_is_idle(self, target: str, text: str) -> bool:
        if target in self.idle_screen_results:
            return self.idle_screen_results[target] == "idle"
        signature_file = self.idle_screen_signature_file_for_target(target)
        signature = self.signature_for(text + "\n")
        previous = signature_file.read_text().strip() if signature_file.exists() else ""
        self.idle_screen_texts[target] = text
        self.idle_screen_signatures[target] = signature
        if previous and previous == signature:
            self.idle_screen_results[target] = "idle"
            return True
        self.idle_screen_results[target] = "working"
        return False

    def persist_idle_screen_observations(self) -> None:
        for target, signature in self.idle_screen_signatures.items():
            self.idle_screen_file_for_target(target).write_text(self.idle_screen_texts.get(target, "") + "\n")
            self.idle_screen_signature_file_for_target(target).write_text(signature + "\n")
        self.idle_screen_texts = {}
        self.idle_screen_signatures = {}
        self.idle_screen_results = {}

    def pane_looks_like_agent(self, text: str) -> bool:
        return bool(re.search(self.agent_ready_pattern, text, re.MULTILINE))

    def target_looks_like_live_agent(self, target: str, text: str) -> bool:
        return self.target_has_non_shell_process(target) and self.pane_looks_like_agent(text)

    def approval_prompt_present(self, text: str) -> bool:
        if not self.agent_approval_pattern:
            return False
        tail_text = "\n".join(text.splitlines()[-self.match_tail_lines :])
        return bool(re.search(self.agent_approval_pattern, tail_text, re.MULTILINE))

    def maybe_approve_prompt(self, target: str, text: str) -> None:
        if not self.approval_prompt_present(text):
            return
        prompt_tail = "\n".join(text.splitlines()[-self.match_tail_lines :])
        signature = self.signature_for(prompt_tail + "\n")
        if self.approved_signatures.get(target) != signature:
            self.run_cmd(["tmux", "send-keys", "-t", target, "Enter"])
            self.approved_signatures[target] = signature
            self.log(f"approved agent prompt in {target}")

    def wait_for_agent_ready(self, target: str) -> bool:
        for _ in range(self.agent_start_attempts):
            time.sleep(self.agent_start_wait_seconds)
            text = self.pane_tail(target)
            self.maybe_approve_prompt(target, text)
            if self.target_looks_like_live_agent(target, text):
                time.sleep(self.agent_start_wait_seconds)
                return True
        return False

    def agent_launch_command(self) -> str:
        return f"{self.agent_command} {self.agent_flags}".strip()

    def start_agent_in_pane(self, target: str, worktree: str) -> bool:
        _ = worktree
        self.run_cmd(["tmux", "send-keys", "-t", target, self.agent_launch_command(), "Enter"])
        return self.wait_for_agent_ready(target)

    def ensure_agent_target(self, session: str, worktree: str) -> str | None:
        if not Path(worktree).is_dir():
            self.log(f"worktree does not exist: {worktree}")
            return None
        if not self.tmux_session_exists(session):
            self.log(f"creating tmux session {session} in {worktree}")
            rc = self.run_cmd(
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
            ).returncode
            if rc != 0:
                return None
            target = f"{session}:{self.agent_window_name}.0"
            if not self.wait_for_agent_ready(target):
                self.log(f"agent did not become ready in {target}")
                sys.stderr.write(self.pane_tail(target))
                return None
            return target

        if not self.tmux_window_exists(session, self.agent_window_name):
            target = self.target_for_session(session)
            text = self.pane_tail(target)
            if not self.target_looks_like_live_agent(target, text):
                self.log(f"session {session} exists; creating {self.agent_window_name} window in {worktree}")
                rc = self.run_cmd(
                    [
                        "tmux",
                        "new-window",
                        "-d",
                        "-t",
                        f"{session}:",
                        "-n",
                        self.agent_window_name,
                        "-c",
                        worktree,
                        "bash",
                        "-lc",
                        self.agent_launch_command(),
                    ]
                ).returncode
                if rc != 0:
                    return None
                target = f"{session}:{self.agent_window_name}.0"
                if not self.wait_for_agent_ready(target):
                    self.log(f"agent did not become ready in {target}")
                    sys.stderr.write(self.pane_tail(target))
                    return None

        target = self.target_for_session(session)
        text = self.pane_tail(target)
        if not self.target_looks_like_live_agent(target, text):
            if not self.start_agent_in_pane(target, worktree):
                self.log(f"agent did not become ready in existing target {target}")
                sys.stderr.write(self.pane_tail(target))
                return None
        return target

    def paste_prompt_once(self, target: str, buffer_name: str, prompt: str) -> bool:
        if self.run_cmd(["tmux", "load-buffer", "-b", buffer_name, "-"], input_text=prompt).returncode != 0:
            return False
        if self.run_cmd(["tmux", "paste-buffer", "-b", buffer_name, "-t", target]).returncode != 0:
            self.run_cmd(["tmux", "delete-buffer", "-b", buffer_name])
            return False
        self.run_cmd(["tmux", "delete-buffer", "-b", buffer_name])
        return True

    def send_prompt_to_target(self, target: str, prompt: str) -> bool:
        safe_target = sanitize_name(target)
        buffer_name = f"pr_watch_msg_{safe_target}"
        for _ in range(self.prompt_send_attempts):
            if not self.paste_prompt_once(target, buffer_name, prompt):
                continue
            time.sleep(self.prompt_enter_delay_seconds)
            if self.run_cmd(["tmux", "send-keys", "-t", target, "Enter"]).returncode == 0:
                return True
        return False

    def tmux_state_for_session(self, session: str) -> str:
        if not self.tmux_session_exists(session):
            return "no session"
        state = "unknown"
        for target in self.session_pane_targets(session):
            text = self.pane_tail(target)
            if not text:
                continue
            if not self.target_looks_like_live_agent(target, text):
                continue
            if self.approval_prompt_present(text):
                return "needs approval"
            if self.target_screen_is_idle(target, text):
                if state == "unknown":
                    state = "idle"
            elif state == "unknown":
                state = "working"
        return state

    @staticmethod
    def markdown_cell(value: str) -> str:
        return value.replace("\r", " ").replace("\n", " ").replace("|", "\\|")

    @staticmethod
    def render_markdown_code_block(text: str) -> str:
        fence = "```"
        while fence in text:
            fence += "`"
        body = text.rstrip("\n").replace("\r\n", "\n").replace("\r", "\n") if text else "[empty pane]"
        return f"{fence}text\n{body}\n{fence}\n"

    @staticmethod
    def capture_tail_lines(text: str) -> str:
        if not text:
            return "[empty pane]\n"
        return "\n".join(text.replace("\r\n", "\n").replace("\r", "\n").splitlines()[-10:]) + "\n"

    @staticmethod
    def capture_without_tail_lines(text: str) -> str:
        if not text:
            return "[no earlier captured lines]\n"
        lines = text.replace("\r\n", "\n").replace("\r", "\n").splitlines()
        if len(lines) <= 10:
            return "[no earlier captured lines]\n"
        return "\n".join(lines[:-10]) + "\n"

    def render_status_pane_captures(self) -> str:
        captured_targets: set[str] = set()
        chunks: list[str] = []
        for item in self.items:
            label = f"{item.repo}#{item.pr or item.issue}"
            item_url = f"https://github.com/{item.repo}/pull/{item.pr}" if item.pr else f"https://github.com/{item.repo}/issues/{item.issue}"
            for target in self.agent_pane_targets_for_session(item.session):
                if not target or target in captured_targets:
                    continue
                captured_targets.add(target)
                text = self.pane_tail(target)
                if not chunks:
                    chunks.append("\n## Tmux Pane Captures\n\n")
                chunks.append("<details>\n")
                chunks.append(f"<summary>{html.escape(label)} ({html.escape(target)})</summary>\n\n")
                chunks.append(f"[{label}]({item_url})\n\n")
                chunks.append("Earlier captured lines:\n\n")
                chunks.append(self.render_markdown_code_block(self.capture_without_tail_lines(text)))
                chunks.append("\n</details>\n\n")
                chunks.append("Last 10 lines:\n\n")
                chunks.append(self.render_markdown_code_block(self.capture_tail_lines(text)))
                chunks.append("\n")
        return "".join(chunks)

    def render_status_dashboard_block(self) -> str:
        rows = []
        for item in self.items:
            key = self.state_key_for_item(item)
            self.ensure_status_defaults(key)
            if item.pr:
                label = f"{item.repo}#{item.pr}"
                item_url = f"https://github.com/{item.repo}/pull/{item.pr}"
            else:
                label = f"{item.repo}#{item.issue}"
                item_url = f"https://github.com/{item.repo}/issues/{item.issue}"
                self.write_status_field_if_absent(key, "phase", "Initalizing agent")
                self.write_status_field(key, "ci", "N/A")
            phase = self.markdown_cell(self.read_status_field(key, "phase", "none"))
            ci = self.markdown_cell(self.read_status_field(key, "ci", "unknown"))
            rows.append(f"{label}\t| [{label}]({item_url}) | {phase} | {ci} |")
        body = [
            STATUS_BLOCK_START,
            "# Agent Watcher Status",
            "",
            f"Last updated: {time.strftime('%m-%d %H:%M %Z')}",
            "",
            "| Item | Phase | CI |",
            "|---|---|---|",
        ]
        body.extend(row.split("\t", 1)[1] for row in sorted(rows))
        captures = self.render_status_pane_captures()
        return "\n".join(body) + "\n" + captures + f"\n{STATUS_BLOCK_END}\n"

    @staticmethod
    def replace_status_block(current: str, block: str) -> str:
        if STATUS_BLOCK_START not in current:
            return (current.rstrip() + "\n\n" if current.strip() else "") + block
        lines = current.splitlines()
        output: list[str] = []
        skipping = False
        replaced = False
        for line in lines:
            if line == STATUS_BLOCK_START:
                output.extend(block.rstrip("\n").splitlines())
                skipping = True
                replaced = True
                continue
            if skipping and line == STATUS_BLOCK_END:
                skipping = False
                continue
            if not skipping:
                output.append(line)
        if not replaced:
            output.append(block.rstrip("\n"))
        return "\n".join(output) + "\n"

    def maybe_update_status_issue(self) -> None:
        if not self.status_enabled or not self.status_issue_repo or not self.status_issue_number:
            return
        block = self.render_status_dashboard_block()
        result = self.run_cmd(
            [
                self.gh_command,
                "issue",
                "view",
                self.status_issue_number,
                "--repo",
                self.status_issue_repo,
                "--json",
                "body",
                "-q",
                ".body",
            ]
        )
        if result.returncode != 0:
            self.log(f"failed to read status issue {self.status_issue_repo}#{self.status_issue_number}")
            return
        new_body = self.replace_status_block(result.stdout, block)
        if result.stdout == new_body:
            return
        edit = self.run_cmd(
            [
                self.gh_command,
                "issue",
                "edit",
                self.status_issue_number,
                "--repo",
                self.status_issue_repo,
                "--body-file",
                "-",
            ],
            input_text=new_body,
        )
        if edit.returncode == 0:
            self.record_status_issue_update()
        else:
            self.log(f"failed to update status issue {self.status_issue_repo}#{self.status_issue_number}")

    def dispatch_watch_prompt(self, repo: str, pr: str, worktree: str, session: str, comment_count: int, ci_failure_count: int) -> bool:
        self.log(f"dispatching prompt for {repo}#{pr} to tmux session {session} (comments={comment_count}, ci_failures={ci_failure_count})")
        target = self.ensure_agent_target(session, worktree)
        if not target:
            return False
        if not self.send_prompt_to_target(target, self.resolve_prompt_for_pr_resolve(repo, pr)):
            return False
        self.log(f"sent prompt for {repo}#{pr} to {target}")
        return True

    def process_issue_item(self, repo: str, issue: str, worktree: str, session: str) -> bool:
        key = self.state_key_for_issue(repo, issue)
        self.ensure_status_defaults(key)
        self.write_status_field(key, "ci", "N/A")
        self.write_status_field_if_absent(key, "phase", "Initalizing agent")
        if not Path(worktree).is_dir():
            self.log(f"removing stale issue row for {repo}#{issue} because worktree is missing: {worktree}")
            self.remove_watch_state_item(repo, "", issue)
            return False
        state = self.tmux_state_for_session(session)
        if state in {"no session", "unknown"}:
            self.log(f"removing stale issue row for {repo}#{issue} because agent state is {state}")
            self.remove_watch_state_item(repo, "", issue)
            return False
        pane_path = self.current_path_for_session(session)
        if not pane_path or not self.same_existing_dir(pane_path, worktree):
            self.log(f"removing stale issue row for {repo}#{issue} because session {session} is not rooted in {worktree}")
            self.remove_watch_state_item(repo, "", issue)
            return False
        if state != "idle":
            return True
        target = self.target_for_session(session)
        text = self.pane_tail(target)
        if not self.target_looks_like_live_agent(target, text):
            self.log(f"removing stale issue row for {repo}#{issue} because agent is not live in {target}")
            self.remove_watch_state_item(repo, "", issue)
            return False
        pr_base_repo = self.resolve_origin_repo()
        if not pr_base_repo:
            self.set_status_phase(key, "repo check failed")
            return True
        compare_status = self.worktree_head_is_in_default_branch(worktree, pr_base_repo)
        if compare_status == 0:
            if self.send_prompt_to_target(target, self.resolve_prompt_for_issue(repo, issue)):
                self.set_status_phase(key, "issue prompt")
                self.log(f"sent initial issue prompt for {repo}#{issue} to {target}")
            else:
                self.set_status_phase(key, "dispatch failed")
                self.log(f"failed to send initial issue prompt for {repo}#{issue}")
            return True
        if compare_status == 2:
            self.set_status_phase(key, "head check failed")
            self.log(f"could not determine whether {worktree} HEAD is already in the default branch history")
            return True
        if self.send_prompt_to_target(target, self.resolve_prompt_for_pr_create(pr_base_repo)):
            self.set_status_phase(key, "create PR")
            self.log(f"sent PR create prompt for issue {repo}#{issue} to {target}")
        else:
            self.set_status_phase(key, "dispatch failed")
            self.log(f"failed to send PR create prompt for issue {repo}#{issue}")
        return True

    def process_watch_item(self, repo: str, pr: str, worktree: str, session: str) -> None:
        key = self.state_key_for(repo, pr)
        self.ensure_status_defaults(key)
        pr_state = self.pr_state_for(repo, pr)
        if not pr_state:
            self.log(f"failed to fetch PR state for {repo}#{pr}")
            self.set_status_phase(key, "PR state unknown")
            return
        if pr_state != "open":
            self.log(f"removing watch-state item for {repo}#{pr} because PR state is {pr_state}")
            self.remove_watch_state_item(repo, pr, "")
            return

        pr_allows_dispatch = True
        label_status = self.pr_label_status(repo, pr)
        if label_status != 0:
            pr_allows_dispatch = False
            if label_status == 2:
                self.log(f"failed to fetch PR labels for {repo}#{pr}; prompts paused")
            else:
                self.log(f"prompts paused for {repo}#{pr} because it does not have label {self.copilot_label}")

        comment_state_file = self.state_dir / f"{key}.seen"
        ci_state_file = self.state_dir / f"{key}.ci-failures"
        new_comment_count = 0
        ci_failure_count = 0
        ci_pending_count = 0
        current_signature = ""
        comment_needs_dispatch = False
        ci_needs_dispatch = False
        ci_pending_changed = False
        ci_passing_changed = False
        ci_state_ready = False
        ci_was_primed = False

        events = self.fetch_events(repo, pr)
        new_events: list[dict[str, Any]] = []
        if events is not None:
            if not comment_state_file.exists():
                comment_state_file.write_text("")
                if self.bootstrap_mode != "trigger":
                    self.append_seen_ids(comment_state_file, events)
                    self.log(f"primed {repo}#{pr} with {len(events)} existing comment event(s)")
                else:
                    new_events = self.collect_new_events(comment_state_file, events)
            else:
                new_events = self.collect_new_events(comment_state_file, events)
            new_comment_count = len(new_events)
            comment_needs_dispatch = new_comment_count > 0
        else:
            self.log(f"failed to fetch comments for {repo}#{pr}")

        if self.watch_ci == "true":
            checks = self.fetch_ci_attention_checks(repo, pr)
            if checks is not None:
                ci_failure_count = sum(1 for check in checks if check["bucket"] in {"fail", "cancel"})
                ci_pending_count = sum(1 for check in checks if check["bucket"] == "pending")
                current_signature = self.ci_attention_signature(checks)
                self.write_status_field(key, "ci", self.ci_status_for_counts(ci_failure_count, ci_pending_count))
                previous_signature = ci_state_file.read_text().strip() if ci_state_file.exists() else ""
                ci_signature_changed = current_signature != previous_signature
                if not ci_state_file.exists() and self.ci_bootstrap_mode != "trigger":
                    ci_state_file.write_text(current_signature + "\n")
                    self.log(f"primed {repo}#{pr} CI with {ci_failure_count} current failure(s), {ci_pending_count} pending check(s)")
                    ci_signature_changed = False
                    ci_was_primed = True
                if ci_signature_changed:
                    if ci_failure_count > 0:
                        ci_needs_dispatch = True
                    elif ci_pending_count > 0:
                        ci_pending_changed = True
                    else:
                        ci_passing_changed = True
                ci_state_ready = True
            else:
                self.write_status_field(key, "ci", "unknown")
                self.log(f"failed to fetch CI checks for {repo}#{pr}")
        else:
            self.write_status_field(key, "ci", "not watched")

        if comment_needs_dispatch or ci_needs_dispatch:
            if not pr_allows_dispatch:
                # self.log(f"skipping prompt for {repo}#{pr} while PR is paused")
                pass
            elif self.dispatch_watch_prompt(repo, pr, worktree, session, new_comment_count, ci_failure_count):
                self.set_status_phase(key, "Addressing comments" if comment_needs_dispatch else "All comments resolved")
                if comment_needs_dispatch:
                    self.append_seen_ids(comment_state_file, new_events)
                if ci_needs_dispatch:
                    ci_state_file.write_text(current_signature + "\n")
            else:
                self.set_status_phase(key, "dispatch failed")
                self.log(f"dispatch failed for {repo}#{pr}; will retry pending comment/CI changes on next poll")
        elif ci_pending_changed:
            ci_state_file.write_text(current_signature + "\n")
            self.set_status_phase(key, "CI pending")
            # self.log(f"CI pending for {repo}#{pr}")
        elif ci_passing_changed:
            ci_state_file.write_text(current_signature + "\n")
            self.set_status_phase(key, "CI passing")
            # self.log(f"CI passing for {repo}#{pr}")
        elif ci_was_primed:
            if ci_failure_count > 0:
                self.set_status_phase(key, "CI failing")
            elif ci_pending_count > 0:
                self.set_status_phase(key, "CI pending")
            elif ci_state_ready:
                self.set_status_phase(key, "CI passing")

        if not pr_allows_dispatch:
            self.set_status_phase(key, "paused")

    def monitor_configured_sessions(self) -> None:
        for item in self.items:
            if not self.tmux_session_exists(item.session):
                continue
            for target in self.session_pane_targets(item.session):
                text = self.pane_tail(target)
                if text:
                    self.maybe_approve_prompt(target, text)

    def poll_once(self) -> None:
        if not self.read_watch_state():
            return
        initial_issue_rows = [(item.repo, item.issue) for item in self.items if item.issue]
        self.discover_copilot_issues()
        for repo, issue in initial_issue_rows:
            item = self.watch_state_find_item(repo, "", issue)
            if item and not self.process_issue_item(repo, issue, item.worktree, item.session):
                self.start_discovered_issue(repo, issue)
        for item in list(self.items):
            if item.pr:
                self.process_watch_item(item.repo, item.pr, item.worktree, item.session)
        self.monitor_configured_sessions()

    def run(self, argv: list[str]) -> int:
        self.parse_args(argv)
        self.finalize_agent_config()
        self.print_startup_warning()
        for command in (
            self.gh_command,
            self.git_command,
            self.agent_command.split()[0],
            "bash",
            "cksum",
            "tmux",
        ):
            self.need_command(command)
        if self.command_uses_windows_paths(self.git_command):
            self.need_command("wslpath")
        self.log_startup_tools()
        self.require_repo_root()
        self.require_default_branch()
        if self.run_cmd([self.gh_command, "auth", "status"]).returncode != 0:
            self.die(f"{self.gh_command} is not authenticated")
        self.state_dir.mkdir(parents=True, exist_ok=True)

        while True:
            self.poll_once()
            self.maybe_update_status_issue()
            self.persist_idle_screen_observations()
            self.print_status_line()
            if self.once:
                break
            time.sleep(self.poll_seconds)
        return 0


def main(argv: list[str]) -> int:
    watcher = WatchGithub()

    def handle_signal(signum: int, _frame: Any) -> None:
        watcher.cleanup()
        raise SystemExit(130 if signum == signal.SIGINT else 143)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    try:
        return watcher.run(argv)
    except WatchError as exc:
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
