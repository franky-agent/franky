"""Harbor installed-agent wrapper for local-checkout Franky runs.

Run with Harbor, for example:

    FRANKY_BENCH_ARGS='--provider gateway --base-url http://host.docker.internal:11434/v1 --model qwen3-coder' \
    harbor run \
      -d terminal-bench/terminal-bench-2 \
      --agent-import-path bench.harbor.franky_agent:FrankyAgent \
      --task-id <task-id> \
      -n 1
"""

from __future__ import annotations

import os
import shlex
import shutil
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment

if TYPE_CHECKING:
    from harbor.models.agent.context import AgentContext


CONTAINER_CHECKOUT = "/installed-agent/franky"
INSTALL_SCRIPT = "/installed-agent/install_franky.sh"
FRANKY_HOME = "/tmp/franky"

# Keep this list conservative. Users can add names with
# FRANKY_BENCH_FORWARD_ENV=NAME1,NAME2.
DEFAULT_FORWARDED_ENV = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "MISTRAL_API_KEY",
    "CEREBRAS_API_KEY",
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "FRANKY_LOG",
    "FRANKY_HTTP_TRACE_DIR",
)

PROMPT_TEMPLATE = """You are running inside a Terminal-Bench task container.

Complete the task described below. You may inspect and modify files, run shell
commands, install dependencies if needed, and run tests. Work autonomously; do
not ask the user for clarification.

When you think the task is complete, look for any test or verification scripts
(e.g. /app/test_outputs.py) and run them. Only stop when all tests pass.
If tests fail, diagnose and fix the issue, then re-run them.

Task:

{instruction}
"""


def _repo_root() -> Path:
    # bench/harbor/franky_agent.py -> repo root
    return Path(__file__).resolve().parents[2]


def _checkout_path() -> Path:
    raw = os.environ.get("FRANKY_CHECKOUT")
    return Path(raw).expanduser().resolve() if raw else _repo_root()


def _forwarded_env() -> dict[str, str]:
    names = set(DEFAULT_FORWARDED_ENV)
    extra = os.environ.get("FRANKY_BENCH_FORWARD_ENV", "")
    for name in extra.split(","):
        stripped = name.strip()
        if stripped:
            names.add(stripped)

    env: dict[str, str] = {}
    for name in sorted(names):
        value = os.environ.get(name)
        if value is not None:
            env[name] = value
    return env


class FrankyAgent(BaseInstalledAgent):
    """Run Franky from the current local checkout inside Harbor tasks."""

    @staticmethod
    def name() -> str:
        return "franky"

    async def install(self, environment: BaseEnvironment) -> None:
        checkout = _checkout_path()
        if not checkout.is_dir():
            raise RuntimeError(f"FRANKY_CHECKOUT is not a directory: {checkout}")
        if not (checkout / "build.zig").is_file():
            raise RuntimeError(f"FRANKY_CHECKOUT does not look like a Franky checkout: {checkout}")

        install_script = Path(__file__).with_name("install_franky.sh")
        if not install_script.is_file():
            raise RuntimeError(f"install script missing: {install_script}")

        await self.exec_as_root(environment, "rm -rf /installed-agent && mkdir -p /installed-agent")

        with tempfile.TemporaryDirectory(prefix="franky-harbor-") as tmp:
            staged = Path(tmp) / "franky"
            shutil.copytree(
                checkout,
                staged,
                ignore=shutil.ignore_patterns(
                    ".git",
                    ".zig-cache",
                    ".franky-sessions",
                    ".claude",
                ),
            )
            await environment.upload_dir(staged, CONTAINER_CHECKOUT)

        await environment.upload_file(install_script, INSTALL_SCRIPT)
        await self.exec_as_root(environment, f"chmod +x {shlex.quote(INSTALL_SCRIPT)}")
        await self.exec_as_root(
            environment,
            f"{shlex.quote(INSTALL_SCRIPT)} {shlex.quote(CONTAINER_CHECKOUT)}",
            timeout_sec=int(os.environ.get("FRANKY_BENCH_INSTALL_TIMEOUT_SEC", "600")),
        )

    def get_version_command(self) -> str | None:
        return "franky --version"

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: "AgentContext",
    ) -> None:
        del context

        bench_args = os.environ.get("FRANKY_BENCH_ARGS", "").strip()
        if not bench_args:
            raise RuntimeError(
                "FRANKY_BENCH_ARGS must be set with provider/model flags; "
                "refusing to run a benchmark with Franky's default/faux provider"
            )

        max_turns = os.environ.get("FRANKY_BENCH_MAX_TURNS", "100").strip() or "100"
        timeout_sec = int(os.environ.get("FRANKY_BENCH_RUN_TIMEOUT_SEC", "7200"))

        env = _forwarded_env()
        env["FRANKY_HOME"] = FRANKY_HOME

        quoted_instruction = shlex.quote(instruction)
        command = " ".join(
            [
                "mkdir -p /tmp/franky/sessions &&",
                "franky",
                "--mode print",
                "--role full",
                "--yes",
                "--tools read,write,edit,bash,ls,find,grep",
                "--session-dir /tmp/franky/sessions",
                "--log-file /tmp/franky/franky.log",
                # "--register http://host.docker.internal:9000",
                "--max-turns",
                shlex.quote(max_turns),
                bench_args,
                "--",
                quoted_instruction,
            ]
        )

        try:
            await self.exec_as_agent(
                environment,
                command=command,
                env=env,
                timeout_sec=timeout_sec,
            )
        finally:
            await self._download_franky_artifacts(environment)

    async def _download_franky_artifacts(self, environment: BaseEnvironment) -> None:
        target = self.logs_dir / "franky"
        try:
            if target.exists():
                shutil.rmtree(target)
            target.mkdir(parents=True, exist_ok=True)
            await environment.download_dir(FRANKY_HOME, target)
            self.logger.info("Downloaded Franky artifacts", extra={"path": str(target)})
        except Exception as exc:  # best-effort; do not mask the benchmark result
            self.logger.warning("Failed to download Franky artifacts: %s", exc)

    def render_instruction(self, instruction: str) -> str:
        # Avoid depending on an external prompt-template file for the default
        # Harbor import-path workflow. Users can subclass later if they need a
        # different benchmark prompt.
        return PROMPT_TEMPLATE.format(instruction=instruction)

    def populate_context_post_run(self, context: "AgentContext") -> None:
        # v1 relies on Harbor stdout/stderr plus /tmp/franky artifacts.
        # We can parse Franky's session transcript here later if Harbor result
        # archives need structured trajectories/token counts.
        del context
