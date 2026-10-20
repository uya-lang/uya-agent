# testdata/windows — Windows 产物在真机上的验收

这里的东西**只在 Windows 客户机上跑**（宿主 Linux 编不出来也说不出结论）。

## 文件

| 文件 | 干什么 |
|---|---|
| `run_guest_verify.sh` | 宿主侧入口：交叉编译取证工具 → 投递 → 逐条跑用例 → 断言报告 |
| `case_*.bat` | 客户机侧的用例（纯 ASCII、CRLF、自带看门狗） |
| `cap.c` / `kbd.c` | 取证工具：前者把子进程接到**真实 `CONOUT$`** 上再读回屏幕字符，后者往控制台注入真 `KEY_EVENT` |
| `clipset.ps1` / `clipimg.ps1` | 往客户机剪贴板放文本 / 图片（UTF-8 **带 BOM** —— PowerShell 5.1 读无 BOM 的 `.ps1` 会按 ANSI 解码） |

## 为什么必须真机

| 想验的 | 为什么重定向 / wine 测不出 |
|---|---|
| 控制台中文不乱码 | `prog --help > out.txt` 走字节路径，代码页转换根本不发生 |
| 按键翻译（回车 / 方向键 / 退格） | 往管道写字节绕过了 conhost 的 `KEY_EVENT` |
| 剪贴板 | `OpenClipboard` 是会话级的，wine 与重定向都不等价 |
| 启动期 UB（UBSan panic） | 宿主 GCC 默认不插桩，而 zig cc（clang）默认开 |

完整现场（两个真机抓到的自身缺陷、修法与判据）见 DESIGN.md §19.30.4。

## 跑法

```bash
make windows                          # 先有 build/uya-agent.exe
sh testdata/windows/run_guest_verify.sh          # 全量
sh testdata/windows/run_guest_verify.sh clip img # 只跑剪贴板两条
```

前置：docker 容器 `win10`（dockur/windows）已起且客户机可达；helper 在
`~/.agents/skills/uya-ssh-win10-verify/scripts/win_guest.sh`（可用 `WIN_GUEST_SH` 覆盖）。

## 出处

`cap.c` / `kbd.c` 与 `case_*.bat` 的骨架来自同一作者的 `uya-term` 仓库
（`tests/windows/`）——那套工具已经在 Win10 客户机上实测过，直接复用而不是再造一套
取证工具。本仓只改了用例内容（针对 uya-agent 的 `--help` / `--print-config` /
`--tui-demo` / `/paste`）。
