# RELEASE.md — 发布清单（需要凭据，只能在有 owner 权限的机器上跑）

这份文档是**给发布者**的，不是给使用者的。使用者要的只有 README 首屏那三行。

本仓的发布**没有一次是自动的**：下面这些步骤要用 `uya-lang` 的 owner 身份，
我把能做的那一半（工作流、install.sh、产物命名）都写进仓了，剩下的是敲几条命令。

---

## 0. 发版前必须为真的三件事

```bash
make link-audit      # 产物真的是静态链接（无 PT_INTERP / 无 NEEDED）
make selftest-fast   # 17 个域各跑一轮，约 10 s
make lint-size       # 三条硬指标，只看本次 diff
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
| Website | release 页；没有站点就**空着**（放一个 404 比空着差） |
| Discussions | 打开（`Settings → Features`）。仓最缺的是**提问的地方**，issue 门槛太高 |
| Social preview | `docs/tui-demo.png`（Settings → Social preview）。**第一次被贴到群里时，预览卡就是它** |

（表格行不折：markdown 表格里断行会散架。80 列的规矩对**正文**生效。）

---

## 2. 打一个 release

工作流已经写好了（`.github/workflows/release.yml`）：推一个 `v*` 标签即可。

```bash
git tag -a v0.1.0 -m "uya-agent v0.1.0：第一个可下载的二进制"
git push origin v0.1.0
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
gh release create v0.1.0 uya-agent-linux-x86_64 SHA256SUMS \
   --title "uya-agent v0.1.0" --generate-notes
```

产物名**必须是** `uya-agent-linux-x86_64`：`install.sh` 按 `uya-agent-${ARCH}` 拼 URL，
改名字等于让所有 `curl | sh` 的用户拿到 404。

---

## 3. 发布后立刻验一遍（三分钟）

```bash
# ① 装得上、跑得起来（在一台干净机器 / 容器里跑）
curl -fsSL \
  https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh

# ② 语言条不是 Makefile 了（.gitattributes 的 linguist 规则生效）
#    GitHub 的语言统计是**异步重算**的，刚推上去那几分钟可能还是旧值。

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
