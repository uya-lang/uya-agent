# uya-agent — an entire coding agent in one 9 MB static binary

Give it one sentence. It reads files, edits them, runs commands, and loops until
the task is done. **One file is the whole thing**: full-screen TUI, browser UI,
kernel sandbox (bwrap), and its own TLS stack — `scp` it to any x86-64 Linux box
and run it. No node, no python, no glibc, no container (`readelf -lW` shows no
`PT_INTERP`, `readelf -dW` shows no `NEEDED`).

![uya-agent finishing a real task: read → edit one line → run → report](docs/tui-demo.png)

```bash
curl -fsSL https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh
~/.local/bin/uya-agent --tui-demo     # see the UI first: no network, no API key
~/.local/bin/uya-agent "change the greeting in hello.uya to Hello, uya!"
```

`install.sh` does exactly three things: pick an architecture, download that one
binary, `chmod` it. It writes no config and never touches `PATH`.

**By the way, it is written in a language hardly anyone has heard of.** All
152,000 lines under `src/` are [Uya](https://github.com/uya-lang/uya) source,
with zero `@c_import`. The only C is 840 lines under `src/cshim/` — a Windows
console bridge (used only by `make windows`) plus a header of C prototypes for
GCC 15. **The Linux build contains no C logic written by this project.**

| What you want | Where |
|---|---|
| Install, run, every flag and slash command | [README.md](README.md) §1–§2 (Chinese) |
| **Why it is built this way**: layers, invariants, trade-offs | [DESIGN.md](DESIGN.md) (Chinese) |
| Conventions for changing the code | [CODING.md](CODING.md) (Chinese) |

---

## 0. Why it fits in one file

| | |
|---|---|
| **9 MB, statically linked** | 8.98 MB in one file, no `PT_INTERP`, no `NEEDED` — checked by `make link-audit` on every build |
| **Self-contained toolchain** | `uya/` ships the compiler and its stdlib (2.4 MB); `make build` needs nothing pre-installed |
| **Zero external runtime** | No xterm.js, no CDN, no zlib — the browser terminal emulator and the JPEG encoder are both written here |
| **Provably offline** | 104 assertions, 35 `make e2e-*` targets, a built-in mock LLM: `make selftest` never touches the network |

**The constraint chain** — not showing off, just three constraints pushing
downhill:

1. **No general-purpose libc facilities** → TLS, both OpenAI wire protocols,
   SSE, YAML, diff and markdown are all implemented here (`src/net/` 9.8k
   lines, `src/diff/` 2.2k lines).
2. **xterm.js is not an option** — it means either a CDN (which kills the
   offline test suite) or vendoring hundreds of KB of minified JS (which
   collides with "pure Uya"). So **the terminal emulator for the browser UI
   lives on the server** (`src/web/ttyemu.uya`).
3. **No zlib** → image downscaling is hand-written, and PNG/GIF/WebP can only
   be rejected, never silently corrupted.

## 1. Build and run

Three ways, easiest first:

1. **The release binary** (recommended): the `curl` above.
2. **Docker**: `docker build -t uya-agent . && docker run -it --rm uya-agent`.
   The image is `FROM scratch` plus that one binary — see `Dockerfile`.
3. **From source**: the repository ships its own compiler, so `make build`
   works with no pre-installed Uya and no network:

```bash
git clone https://github.com/uya-lang/uya-agent.git && cd uya-agent
make build          # produces build/uya-agent, statically linked
make selftest-fast  # 17 domains, one round each, ~10 s of test time
make selftest       # the full offline suite
```

The full `--selftest` takes about two minutes, and that is not slack: the
clipboard round waits on a real clipboard probe timeout. It must be run from
the repository root, because it uses the fixtures under `testdata/` and the
scratch directories under `build/`. To verify that the binary itself runs on a
given machine, use `--tui-demo` instead: one screen of plain text, a few
milliseconds, zero dependencies.

```bash
./build/uya-agent "task..."     # one-shot
./build/uya-agent               # REPL (blank line / exit / Ctrl-D to quit)
./build/uya-agent --selftest    # offline end-to-end suite
./build/uya-agent --probe       # transport probe (expects HTTP 401)
./build/uya-agent --help
```

### 1.1 Interface

* **Full-screen TUI**, written in pure Uya: persistent status area, a live
  reasoning line, stats (`ctx` / `cpu` / memory), task blocks, a `/diff`
  overlay, markdown rendering, overlay full-screen, and terminal titles. Text
  that does not fit **scrolls** rather than being cut.
* **Browser UI** (`--web`): a tab per session showing **that session's real
  TTY**, with a `+` to create one. The page has zero external dependencies —
  no xterm.js, no CDN; the terminal emulator runs server-side.
* **Scrolling mode** (`--no-tui`) falls back to a plain-text transcript, for
  pipes and CI.

### 1.2 Capabilities

* **Protocols**: streaming SSE, a strict tool protocol, and two wire protocols
  (`openai-responses` by default, `openai-completions`), with `--no-stream`
  and `--compat-fold` fallbacks.
* **DSH interop**: reads `~/.dsh` directly (zero-config against a real
  gateway), uses DSH's original tool names, honours the read-before-write
  observation policy, and can import DSH's own sessions, including zstd.
* **Sessions**: on disk and resumable (`--continue` / `--resume` /
  `/sessions`), with pruning and automatic compaction.
* **Delegation**: subagents, `ralph` loops, `/watch` live following, and
  `workflow` (orchestration from a `.ush` script).
* **Safety**: three permission tiers plus a bwrap kernel sandbox; Git worktree
  sessions (execute → merge → delete, with leftover reclamation).
* **Project memory**: remembers across sessions how a project is built, where
  the key files are, and what was still red last time. Stored as append-only
  shards keyed by normalised repository root, injected as a single user
  message at session start so the prompt prefix cache survives.
* **Images and clipboard**: image attachments (`/image`, `ctrl+v`, `/paste`)
  through a clipboard client written in pure Uya over X11.

### 1.3 Known limits worth reading up front

* The browser UI has **no authentication and no HTTPS**; it binds
  `127.0.0.1` by default, and binding a non-loopback address is an explicit,
  warned-about decision.
* The browser terminal emulator is a whitelist implementation: it understands
  exactly the sequences this TUI emits, not the full VT100 repertoire.
* Markdown rendering covers a practical subset — no syntax highlighting, no
  reference links, no HTML blocks, no footnotes.
* Linux and Windows only. There is no macOS build.

The exhaustive list, with the reason for every item, is in
[README.md §7](README.md) (Chinese).

## 2. Testing

```bash
make check          # lex / parse / type check
make link-audit     # assert the binary really is static
make selftest-fast  # 17 domains, one round each, ~10 s of test time
make selftest       # the full suite: offline, no API key, no network
make doc-audit      # no merge-conflict markers anywhere
make codegen-audit  # assert the codegen never casts slice headers to pointers
make lint-size      # the three hard limits, on this diff only
make shot           # regenerate docs/tui-demo.svg + .png
```

Every one of these runs offline. The suite uses a mock LLM that speaks both
wire protocols and asserts on the request bodies it receives — so "it works"
means the wire format is right, not that a model happened to agree.

## 3. License

MIT — see [LICENSE](LICENSE). No third-party code is vendored: the build uses
the Uya compiler and its standard library (also MIT), and the runtime talks to
Linux syscalls and libc directly.
