"""OpenBench adapter for `uya-agent` (pure-Uya coding agent, this repo).

Headless invocation (observed working against the aigw-local gateway):

    cd <workdir>
    UYA_AGENT_API_KEY=<key> uya-agent \
        --no-tui --quiet --no-dsh-config \
        --base-url http://127.0.0.1:8088/v1 \
        --model DeepSeek-V4.1-Flash --api=responses --effort max \
        --tls-verify=none \
        --agent-home <isolated> --permission danger-full-access \
        --no-memory \
        <instruction>

Fairness pins (see ../README.md for the full rationale):
- `--no-memory`  : no project-memory pack injected, so the run is repeatable
                   and does not carry state from earlier cells.
- `--no-dsh-config`: model route / permission / TLS come from argv only, so the
                   adapter cannot silently inherit the operator's live DSH
                   settings (the live file currently fails dsh's provider
                   registration anyway; see dsh.py).
- isolated `--agent-home`: sessions land in a throwaway dir, never in the
                   operator's real agent home.

Scoring is NOT done here. `completed` only says the process exited 0 within the
timeout; the OpenBench checker decides task success from the workspace.

Usage accounting: uya-agent's `--show-usage` prints one line per model round to
stderr (`[usage] in=… out=… cache_read=… reasoning=…`); we merge stderr into
stdout and parse it. Field semantics were verified against the gateway ledger
rather than assumed -- see `_parse_usage`.
"""

import os
import re
import shutil
import subprocess
import tempfile

NAME = "uyaagent"

# Canonical OpenBench model name -> uya-agent `--model` string. The run uses
# the gateway model id directly; this map exists so `--model` stays canonical
# on the results row like every other arm.
MODELS = {
    "DeepSeek-V4.1-Flash": os.environ.get(
        "OPENBENCH_UYAAGENT_MODEL_ID", "DeepSeek-V4.1-Flash"
    ),
}

# Where the built binary lives. Overridable so a docker/local lane can point
# somewhere else without editing this file.
DEFAULT_BINARY = os.environ.get(
    "OPENBENCH_UYAAGENT_BIN",
    "/home/winger/uya-agent/build/uya-agent",
)
BASE_URL = os.environ.get(
    "OPENBENCH_UYAAGENT_BASE_URL", "http://127.0.0.1:8088/v1"
)
API_KEY_ENV = "UYA_AGENT_API_KEY"

# `--show-usage` writes one line per model round to STDERR:
#   [usage] in=123 out=45 cache_read=67 reasoning=8
# `cache_read` degrades to `?(未回明细)` when the provider omits the split; the
# adapter merges stderr into stdout, so this regex sees the line either way.
_USAGE_RE = re.compile(
    r"\[usage\]\s+in=(?P<in>\d+)\s+out=(?P<out>\d+)"
    r"(?:\s+cache_read=(?P<cache>\?|\d+))?"
    r"(?:\s+reasoning=(?P<reasoning>\?|\d+))?"
)


def _binary():
    """Pick the binary to measure.

    `OPENBENCH_UYAAGENT_BIN` wins over PATH. The reverse order (which this
    adapter used to have) silently measured whatever `uya-agent` happened to be
    installed: a cell ran the operator's stale `~/.local/bin/uya-agent`
    (0.1.0-p83) instead of the fresh build, and the only visible symptom was
    `exit 3` with an EMPTY output tail -- old builds do not know the newer
    flags, so they die in argument parsing before printing anything. The
    results row still looked like a normal low score.
    """
    explicit = os.environ.get("OPENBENCH_UYAAGENT_BIN")
    if explicit:
        return explicit
    return shutil.which("uya-agent") or DEFAULT_BINARY


def _read_key():
    """Resolve the gateway key without ever printing it.

    Priority: process env, then an explicit credentials path, then the isolated
    DSH home, then the operator's DSH credentials (read-only).
    """
    for name in (API_KEY_ENV, "AIGW_LOCAL_API_KEY"):
        value = os.environ.get(name)
        if value:
            return value
    candidates = []
    explicit = os.environ.get("OPENBENCH_UYAAGENT_CREDENTIALS")
    if explicit:
        candidates.append(explicit)
    dsh_home = os.environ.get("DSH_HOME")
    if dsh_home:
        candidates.append(os.path.join(dsh_home, ".credentials.yaml"))
    candidates.append(os.path.expanduser("~/.dsh/.credentials.yaml"))
    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        match = re.search(r"AIGW_LOCAL_API_KEY:\s*(\S+)", text)
        if match:
            return match.group(1)
    return None


def _clean_env(key, agent_home):
    """Minimal child env: no inherited DSH discovery, no stray provider keys."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": agent_home,
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        API_KEY_ENV: key,
    }
    for name in ("TERM", "TMPDIR"):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def _parse_usage(text):
    """Sum `--show-usage` lines into the runner's split token fields.

    Field semantics were verified against the gateway ledger, not assumed:
    for a two-round run the adapter printed `in=7633 out=44 cache_read=0` then
    `in=172 out=4 cache_read=7552`, and `usage_records.dimensions_json` held
    `input_cache_miss=7633/172`, `output=44/4`, `input_cache_hit=0/7552`.
    So `in` is ALREADY the uncached input only -- it does not include the cached
    part -- and the three fields add up to the billed total.

    Returns a dict; every value is None when no line matched, so a shape drift
    yields "unknown" instead of a fabricated number.
    """
    in_uncached = 0
    cache_read = 0
    out = 0
    reasoning = 0
    turns = 0
    found = False
    for match in _USAGE_RE.finditer(text):
        found = True
        turns += 1
        in_uncached += int(match.group("in"))
        cache = match.group("cache")
        if cache is not None and cache.isdigit():
            cache_read += int(cache)
        out += int(match.group("out"))
        reason = match.group("reasoning")
        if reason is not None and reason.isdigit():
            reasoning += int(reason)
    if not found:
        return {
            "tokens": None, "tokens_input_uncached": None,
            "tokens_cache_read": None, "tokens_output": None,
            "tokens_reasoning": None, "turns": None,
        }
    return {
        "tokens": in_uncached + cache_read + out,
        "tokens_input_uncached": in_uncached,
        "tokens_cache_read": cache_read,
        "tokens_output": out,
        "tokens_reasoning": reasoning,
        "turns": turns,
    }


def _unsupported(model):
    return {
        "completed": False,
        "error": "unsupported model: {}".format(model),
        "output_tail": "",
        "tokens": None,
        "turns": None,
        "cmd": "uya-agent",
    }


def run(instruction, workdir, model, timeout_s):
    if model not in MODELS:
        return _unsupported(model)

    key = _read_key()
    if not key:
        return {
            "completed": False,
            "error": "SETUP-NEEDED: no AIGW_LOCAL_API_KEY in env or credentials",
            "output_tail": "",
            "tokens": None,
            "turns": None,
            "cmd": "uya-agent",
        }

    agent_home = tempfile.mkdtemp(prefix="uyaagent_home_")
    try:
        cmd = [
            _binary(),
            "--no-tui", "--quiet", "--no-dsh-config",
            "--base-url", BASE_URL,
            "--model", MODELS[model],
            "--api=responses", "--effort", "max",
            "--tls-verify=none",
            "--agent-home", agent_home,
            "--permission", "danger-full-access",
            "--no-memory",
            "--show-usage",
            instruction,
        ]
        env = _clean_env(key, agent_home)
        try:
            proc = subprocess.run(
                cmd, cwd=workdir, env=env, timeout=timeout_s,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            out = proc.stdout.decode("utf-8", errors="replace")
            completed = proc.returncode == 0
            error = None if completed else "exit {}".format(proc.returncode)
        except subprocess.TimeoutExpired as exc:
            out = (exc.stdout or b"").decode("utf-8", errors="replace")
            completed = False
            error = "timeout after {}s".format(timeout_s)
        except OSError as exc:
            return {
                "completed": False,
                "error": "exec failed: {}".format(exc),
                "output_tail": "",
                "tokens": None,
                "turns": None,
                "cmd": cmd,
            }
        usage = _parse_usage(out)
        return {
            "completed": completed,
            "error": error,
            "output_tail": out[-2000:],
            "full_output": out,
            "cmd": cmd,
            **usage,
        }
    finally:
        shutil.rmtree(agent_home, ignore_errors=True)
