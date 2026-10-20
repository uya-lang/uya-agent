# GOOD-FIRST-ISSUES.md — 能插手的入口（给第一次来的贡献者）

一个陌生人在这个仓里做的第一件事，决定他会不会做第二件。这份清单只放
**边界清楚、判据可跑、不用先读懂 9600 行 DESIGN** 的活儿。

每条都写明：**改哪个文件**、**跑什么验证**、**怎么算做完**。
开成 issue 时直接用标题，正文贴对应那一段。

---

## 一、文档类（30 分钟，零风险）

### 1. 把 README 里所有「P 阶段号」解释一遍，或者移走

`P0`–`P108` 是本仓内部的开发阶段记法。对贡献者有用（能顺着查 DESIGN），
对第一次来的人是天书。

**改**：`README.md` §0.1 末尾已经有一段「开发阶段记法」，把它扩成一条链接指向
`DESIGN.md §19` 的目录，或者把 README 正文里剩下的 `P107`（§0.1 能力一览里）改成
人话 + 括号里保留编号。

**验证**：`grep -c 'P1[0-9][0-9]' README.md` 的数字不增加；`make doc-audit` 绿。

**做完的标志**：一个从没看过本仓的人读完 §0 + §1，不再遇到没解释的编号。

### 2. `README.en.md` 与中文版对齐

英文版是**摘要**，不是逐节翻译。当中文版新增了一节（比如某个新能力），
英文版要在同一周补上对应的一两句，否则两边会越差越远。

**改**：`README.en.md`。

**验证**：`grep -c '^## ' README.md` 与英文版的章节数差不超过 1。

### 3. 给 `--help` 的每一组选项加一个「我该用哪个」的例子

`--effort` / `--exec-effort` / `--exec-after` / `--grace-steps` 这几个
**只在特定场景才该用**，而 `--help` 只说了它们是什么，没说什么时候用。

**改**：`README.md` §1.1 对应几行。

**验证**：照着写的话，每条命令能真的跑起来（`--print-config` 会回显来源）。

---

## 二、测试类（半天，需要读一点代码）

### 4. 给 `scripts/lint_size.py` 加一条「函数头超长」的判据

现状：函数**体**超 100 行会红，但函数**签名**（参数列表学到十几行）不会。
本仓有几处签名折叠得很勉强。

**改**：`scripts/lint_size.py`（`scan_functions` 附近）+ 一处自测。

**验证**：`python3 scripts/lint_size.py --all` 能报出存量；`--changed` 对
一次干净改动仍然绿。

### 5. `make selftest-fast` 的输出给一个失败摘要

现状：某轮红了就 `exit 1`，输出里要和几十行 `selftest[...] ok` 里找那一行 FAIL。

**改**：`Makefile` 的 `selftest-fast` 目标（把 `>/dev/null` 改成捕获到临时文件，
红了再 `grep 'FAIL'` 打出来）。

**验证**：故意让某一轮红（例如临时把某个 `UYA_SELFTEST_*_ONLY` 名字写错成
一个不存在的轮次 → 会落回全量，这个不算；改成故意让 `SHELL` 轮失败）
之后，输出**第一屏**就有 FAIL 行。

### 6. 给 Windows 产物的 `make win-check` 加一条「能跑」判据

现状：`win-check` 只看 PE 头（PE32+ / x86-64 / 控制台子系统），不看它真能不能跑。

**改**：`Makefile` 的 `win-check`，或者新增 `testdata/win_smoke.sh`（用 wine 跑
`--tui-demo` 并比对输出；没装 wine 就跳过，退出码 0）。

**验证**：本机没有 wine 时 `make win-check` 仍然绿（跳过而不是失败）。

---

## 三、能力类（一天以上，要读 DESIGN 对应章）

### 7. `--web` 加一个可选的访问令牌

现状：web 界面**没有任何认证**（README §7 把它写成已知限制，理由是
「同一台机器上自己用」）。但想给它套个反代放到内网的人不少，而反代之外
多一层门槛没有坏处。

**改**：`src/web/websrv.uya`（请求入口）+ `src/agent/agent.uya`（`--web-token`）。
判据走 `st_web.uya`：带 token 过、不带 403、`/api` 与静态资源都要管。

**先读**：DESIGN.md 里 `--web` 那一节（§11.8 附近）与踩坑 106–117。

**边界**：**不能**顺手加 HTTPS（那要证书管理，与本仓「零配置文件」冲突）；
只能加一个可选的 token，默认关。

### 8. 图片附件支持 WebP 的解码

现状：超预算的 JPEG 会自动缩小，PNG/GIF/WebP 只能拒 —— 因为纯 Uya 没有 zlib，
而 PNG/WebP 都要解压。

**改**：`src/media/imgz.uya`（需要先把 zlib 的 inflate 写出来，约 300 行）。
这是一个**独立的、可单独自测**的活儿，不碰 agent 主循环。

**验证**：`selftest[img-sniff]` 扩一条；`testdata/` 放三张小图（PNG/WebP 各一）。

**先读**：DESIGN §13.1.1。

---

## 怎么开始

1. 挑一条，在对应 issue 下说「我来做这条」，避免两个人撞车。
2. `git clone` → `make build`（42 s）→ `make selftest-fast`（10 s）确认起点是绿的。
3. 改完跑 `make check selftest-fast lint-size`，三条都绿再提 PR。
4. 拿不准就开 issue 问 —— **问题本身也是贡献**：它说明文档哪里没写清。
