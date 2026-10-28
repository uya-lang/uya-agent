# RELEASE.md — 发布清单（需要凭据，只能在有 owner 权限的机器上跑）

这份文档是**给发布者**的，不是给使用者的。使用者要的只有 README 首屏那三行。

本仓的发布**没有一次是自动的**：下面这些步骤要用 `uya-lang` 的 owner 身份，
我把能做的那一半（工作流、install.sh、产物命名）都写进仓了，剩下的是敲几条命令。

---

## 0. 发版前必须为真的四件事

```bash
make link-audit      # 产物真的是静态链接（无 PT_INTERP / 无 NEEDED）
make selftest-fast   # 17 个域各跑一轮，约 10 s（含 e2e-version）
make lint-size       # 三条硬指标，只看本次 diff
git tag -l           # 打标之前：版本号对不对
```

**版本号只有一处**：`src/foundation/verx.uya` 的 `VER_SEMVER`（另有一个开发阶段串
`AGENT_VERSION` 并列，P114 起是空串，**不随发版动**）。打 `v0.1.1` 之前先确认两件事
逐字节相符：

```bash
grep -n 'VER_SEMVER' src/foundation/verx.uya     # 印出 0.1.1
./build/uya-agent --version                      # 印出 uya-agent 0.1.1
```

`--version` 里那个语义版本同时是 `User-Agent: uya-agent/0.1.1 (...)` 的身份段与
`--dsh-web` 的 `host.describe.version`。**改了 `VER_SEMVER` 却忘了发版**的代价不是
好看与否：用户按 UA 里的版本去找对应的 release，会找到一个不存在的号。

**自测必须在「没有任何宿主配置」的机器上也是绿的** —— 这是 P113 的教训：本仓 CI 从 P37
起红了很久，因为自测夹具依赖宿主的 `~/.gitconfig`（本机配过 git 身份，runner 没有）。
发版前用**干净 HOME** 跑一次，这一条 CI 现在也会跑，但别指望它替你发现：

```bash
env -i PATH=/usr/bin:/bin HOME=$(mktemp -d) make selftest-fast
```

外加一条**文件级**的：`docs/tui-demo.svg` 必须与当前界面一致 ——
改了 TUI 而没重出图，README 首屏就在撒谎。判据是 `make shot` 之后
`git status --short docs/` 为空。

---

## 1. 仓库元数据（只能在网页或 API 上改）

这三条决定「第一次被看见时，页面长什么样」，比任何代码都重要。

### 1.1 简介（About）

现在是 `ai agent 可以读取dsh的配置` —— 写的是内部实现细节，路人完全不知所云。

```text
A coding agent in a single statically linked binary (TUI + browser UI +
sandbox). Written in Uya, a language you probably have not heard of.
```

### 1.2 Topics

```text
coding-agent  cli  tui  llm  agent  statically-linked  self-contained
terminal-ui  sandbox  openai  anthropic-alternative  uya
```

（`anthropic-alternative` 这类蹭词不要用 —— 本仓与 Anthropic 无关，用了会招反感。）

### 1.3 别忘的三处

| 位置 | 改成 |
|---|---|
| Website | 仓根 `index.html`（GitHub Pages：`Settings → Pages` 选 `main` / `/` 即可，不用另建目录；仓根的 `.nojekyll` 关掉 Jekyll，否则整棵源码树都会被它预处理一遍） |
| Discussions | 打开（`Settings → Features`）。仓最缺的是**提问的地方**，issue 门槛太高 |
| Social preview | `docs/tui-demo.png`（Settings → Social preview）。**第一次被贴到群里时，预览卡就是它** |

（表格行不折：markdown 表格里断行会散架。80 列的规矩对**正文**生效。）

---

## 2. 打一个 release

工作流已经写好了（`.github/workflows/release.yml`）：推一个 `v*` 标签即可。

```bash
git tag -a v0.1.1 -m "uya-agent v0.1.1：版本号只剩语义版本（0.1.0 的括号里那串去掉）"
git push origin v0.1.1
```

它做四件事：构建 Linux 静态二进制 → `make link-audit` → 跑 `selftest-fast`
→ 连同 Windows 产物（若 zig 那一步绿了）一起发到 Releases，并生成 `SHA256SUMS`。

**本机没有 zig 时**（`command -v zig` 为空）：Windows 那一段是
`continue-on-error: true`，Linux 照常发。想本地产 Windows 产物再跑
`make windows`（它会在 Makefile 里找 `zig`，找不到就用 `ZIG=` 指定的路径）。

### 2.1 手工兜底（工作流不可用时）

```bash
make build STATIC=1 && make link-audit
cp build/uya-agent uya-agent-linux-x86_64
chmod 755 uya-agent-linux-x86_64
strip --strip-all uya-agent-linux-x86_64      # 8.98 MB → 8.27 MB（实测，能跑）
sha256sum uya-agent-linux-x86_64 > SHA256SUMS
gh release create v0.1.1 uya-agent-linux-x86_64 SHA256SUMS \
   --title "uya-agent v0.1.1" --generate-notes
```

产物名**必须是** `uya-agent-linux-x86_64`：`install.sh` 按 `uya-agent-${ARCH}` 拼 URL，
改名字等于让所有 `curl | sh` 的用户拿到 404。

---

## 3. 发布后立刻验一遍（三分钟）

```bash
# ① 装得上、跑得起来（在一台干净机器 / 容器里跑）
curl -fsSL \
  https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh

# ② 语言条：先把口径对上，别只「看一眼」。
#    linguist 按 **blob 字节数**算，不按行数；本仓 Makefile 就是 18.3 万字节
#    （recipe 里全是大段 YAML/JSON），所以判据是**字节占比**，不是行数。
#    本地用发布用的那份 linguist 复算一遍，与 GitHub 的数字逐项对得上：
gem install github-linguist --user-install --no-document
OID=$(git rev-parse HEAD)
"$HOME/.local/share/gem/ruby/3.3.0/bin/git-linguist" stats -c $OID
#    GitHub 的语言统计是**异步重算**的，刚推上去那几分钟可能还是旧值。
#
#    ⚠ 已知未生效：`Uya` 还没进 linguist 的 languages.yml（PR #8296 开着），
#    所以 `.uya` 目前**一个字节都不进统计**，上面那条命令的输出里不会有 Uya，
#    首页仍显示 `Makefile`。这是上游的事，本仓改不动 —— 别以为是自己没修好，
#    也别为此去删 .gitattributes 里的 `*.uya` 那一行（它是预埋，见该文件注释）。

# ③ README 首屏那张图能显示（相对路径 docs/tui-demo.png）
```

---

## 4. 这一仓**不做**的发布动作

* **不往 npm / PyPI / Homebrew 上架**：那三个生态各自要求引一个包管理器、
  一套构建脚本，而本仓卖的就是「不需要那三样」。要装就一个 curl。
* **不引 CDN**：`docs/` 里的图必须进仓（相对路径引用），否则离线自测与外网
  不通的环境都会看到碎图。
* **不发布「还在红」的产物**：`selftest-fast` 有一条红就不发。发布门是
  `make link-audit && make selftest-fast && make lint-size`，不是「我觉得没问题」。
