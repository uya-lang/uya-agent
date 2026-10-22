"""OpenBench adapter for `dsh` (DeepSeek Harness, the reference harness).

Headless invocation (observed working against the aigw-local gateway):

    cd <workdir>
    DSH_HOME=<isolated> dsh --profile headless "<instruction>"

Isolation, and why it is not optional here
------------------------------------------
`dsh` resolves its provider table from `$DSH_HOME/settings.yaml`. The
operator's live `~/.dsh/settings.yaml` currently fails provider registration
for `aigw-local` outright (`NO_ADAPTER: no adapter registered for provider
"aigw-local"`), because one catalog entry (`hy4-preview`) carries
`compat: { supportsReasoningEffort: false }`. Bisecting that file showed any
model entry with a `compat.supportsReasoningEffort` key -- `true` or `false` --
kills registration for the whole provider.

So this adapter never reads the live home. It copies a prepared template home
(`OPENBENCH_DSH_HOME_TEMPLATE`) into a fresh temp dir per cell: clean
`settings.yaml` (no `compat` on any model), the credentials file, and
`permission.defaultPreset: danger-full-access`. The operator's real files are
only ever read, never written.

**The output cap must be matched to the other arm** (see ../README.md "坑一"):
the pi-ai catalog defaults this model to `maxTokens: 32768`, while this repo's
`--max-tokens` defaults to 256000. Unmatched, dsh truncates at 32k output
tokens mid-implementation and scores the untouched baseline, which reads as a
capability gap when it is really a budget mismatch. Use a template that sets
`maxTokens: 256000`.

Usage accounting
----------------
`dsh` prints only the final assistant message, so tokens come from its own
session log under `<home>/sessions/<workspace-key>/<session-id>/`. Because the
home is fresh per cell it holds exactly one session, so the attribution is
exact. Two log layouts exist and `_record_usage` reads both:

    older builds : session.jsonl.zstd      assistant/chunk, chunk.type=usage
    0.2.0-rc.2   : session.v4.jsonl.zstd   assistant/message, data.usage

The v4 filename is why this adapter once reported `turns=None` on every cell:
the glob matched `session.jsonl*` only, so the log was never opened. Verified
against the gateway ledger for one run (older layout):

    session log : inputTokens 7776/239, cacheReadTokens 7680, outputTokens 90/2
    ledger      : input_cache_miss 7776/239, input_cache_hit 7680, output 90/2

`inputTokens` is the uncached input only (it does not include the cached part),
so the three fields add up to the billed total -- the same convention the
uya-agent arm uses. Decompression needs the `zstd` CLI; without it the adapter
reports tokens=None rather than guessing.

Neither layout emits `reasoningTokens` (the gateway ledger does count
reasoning), so `tokens_reasoning` stays 0 and the two arms' reasoning columns
are NOT comparable. Reported as-is rather than estimated.

Scoring is NOT done here; the OpenBench checker decides success from the
workspace.
"""

import json
import os
import shutil
import subprocess
import tempfile

NAME = "dsh"

# Canonical OpenBench name -> the model id dsh is configured with.
# Route-specific, same as the uya-agent arm: the aigw-local template uses
# `DeepSeek-V4.1-Flash`, the opencode patch uses `deepseek-v4.1-flash`.
MODELS = {
    "DeepSeek-V4.1-Flash": os.environ.get(
        "OPENBENCH_DSH_MODEL_ID", "DeepSeek-V4.1-Flash"
    ),
}

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEMPLATE = os.path.abspath(os.path.join(_HERE, "template_dsh"))
PROFILE = os.environ.get("OPENBENCH_DSH_PROFILE", "headless")


def _unsupported(model):
    return {
        "completed": False,
        "error": "unsupported model: {}".format(model),
        "output_tail": "",
        "tokens": None,
        "turns": None,
        "cmd": "dsh",
    }


def _stage_home():
    """Fresh DSH_HOME per cell: only the pinned template FILES are copied.

    Directories are deliberately skipped. `dsh` materializes `profiles/` (with
    an install-fallback symlink farm) and `sessions/` on first boot; copying a
    previously materialized copy would hand the new home a real directory where
    dsh expects to create a symlink, and it aborts with
    "exists and is not a symlink". Letting dsh create them itself is both
    cleaner and faster.
    """
    template = os.environ.get("OPENBENCH_DSH_HOME_TEMPLATE", DEFAULT_TEMPLATE)
    if not os.path.isdir(template):
        return None, "SETUP-NEEDED: template home not found at {}".format(template)
    home = tempfile.mkdtemp(prefix="dsh_home_")
    copied = 0
    for name in sorted(os.listdir(template)):
        src = os.path.join(template, name)
        if not os.path.isfile(src):
            continue
        shutil.copy2(src, os.path.join(home, name))
        copied += 1
    if copied == 0:
        shutil.rmtree(home, ignore_errors=True)
        return None, "SETUP-NEEDED: template home {} has no files".format(template)
    creds = os.path.join(home, ".credentials.yaml")
    if os.path.isfile(creds):
        os.chmod(creds, 0o600)
    return home, None


def _zstd_available():
    return shutil.which("zstd") is not None


def _record_usage(record):
    """Return the `usage` object for one session record, or None.

    One model call = one step = at most one usage, so this returns a single
    dict rather than a list. Two layouts exist and both must be read, or the
    arm reports `turns=None` for a run that plainly used tokens:

    * **v3 / older builds** (`session.jsonl.zstd`): one `assistant/chunk`
      record per streamed piece, usage under `data.chunk.usage` with
      `chunk.type == "usage"`.
    * **v4 / 0.2.0-rc.2** (`session.v4.jsonl.zstd`): a single
      `assistant/message` record per step, usage under `data.usage`, mirrored
      once per chunk in `data.stream[].chunk.usage`. Counting every mirror
      would multiply the totals, so `data.usage` wins when present; without
      it, the first mirrored chunk is used.

    Measured on 0.2.0-rc.2 (2026-10-22): the file is `session.v4.jsonl.zstd`
    and `assistant/chunk` records do not exist at all.
    """
    data = record.get("data") or {}
    kind = record.get("type")
    if kind == "assistant/chunk":
        chunk = data.get("chunk") or {}
        if chunk.get("type") == "usage":
            return chunk.get("usage")
        return None
    if kind != "assistant/message":
        return None
    if data.get("usage"):
        return data["usage"]
    for item in data.get("stream") or []:
        chunk = (item or {}).get("chunk") or {}
        if chunk.get("type") == "usage" and chunk.get("usage"):
            return chunk["usage"]
    return None


def _parse_session_usage(home):
    """Read the single session log under `home` and sum usage records."""
    root = os.path.join(home, "sessions")
    if not os.path.isdir(root) or not _zstd_available():
        return None
    logs = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for filename in filenames:
            # `session.jsonl*` (older) and `session.v4.jsonl*` (0.2.0-rc.2).
            if filename.startswith("session.") and ".jsonl" in filename:
                logs.append(os.path.join(dirpath, filename))
    if not logs:
        return None

    in_uncached = 0
    cache_read = 0
    out = 0
    reasoning = 0
    steps = 0
    found = False
    for path in logs:
        try:
            proc = subprocess.run(
                ["zstd", "-dc", path], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=60,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if proc.returncode != 0:
            continue
        for line in proc.stdout.decode("utf-8", errors="replace").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            usage = _record_usage(record)
            if usage is None:
                continue
            found = True
            steps += 1
            in_uncached += int(usage.get("inputTokens") or 0)
            cache_read += int(usage.get("cacheReadTokens") or 0)
            out += int(usage.get("outputTokens") or 0)
            reasoning += int(usage.get("reasoningTokens") or 0)
    if not found:
        return None
    return {
        "tokens": in_uncached + cache_read + out,
        "tokens_input_uncached": in_uncached,
        "tokens_cache_read": cache_read,
        "tokens_output": out,
        "tokens_reasoning": reasoning,
        "turns": steps,
    }


def _clean_env(home):
    """Minimal child env: HOME + DSH_HOME are the isolated ones, nothing else."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": home,
        "DSH_HOME": home,
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    for name in ("TERM", "TMPDIR"):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def run(instruction, workdir, model, timeout_s):
    if model not in MODELS:
        return _unsupported(model)

    exe = shutil.which("dsh")
    if not exe:
        return {
            "completed": False,
            "error": "SETUP-NEEDED: dsh not on PATH",
            "output_tail": "",
            "tokens": None,
            "turns": None,
            "cmd": "dsh",
        }

    home, err = _stage_home()
    if err:
        return {
            "completed": False, "error": err, "output_tail": "",
            "tokens": None, "turns": None, "cmd": "dsh",
        }

    try:
        cmd = [exe, "--profile", PROFILE]
        patch = os.environ.get("OPENBENCH_DSH_PATCH")
        if patch:
            cmd += ["--patch", patch]
        cmd.append(instruction)
        env = _clean_env(home)
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

        usage = _parse_session_usage(home)
        if usage is None:
            usage = {
                "tokens": None, "tokens_input_uncached": None,
                "tokens_cache_read": None, "tokens_output": None,
                "tokens_reasoning": None, "turns": None,
            }
        return {
            "completed": completed,
            "error": error,
            "output_tail": out[-2000:],
            "full_output": out,
            "cmd": cmd,
            **usage,
        }
    finally:
        # Diagnostic escape hatch: keep the staged home so a failed cell's own
        # session log can be read instead of guessed at. Off by default so a
        # normal run leaves nothing behind.
        if os.environ.get("OPENBENCH_DSH_KEEP_HOME"):
            print("dsh: kept home at {}".format(home), flush=True)
        else:
            shutil.rmtree(home, ignore_errors=True)
