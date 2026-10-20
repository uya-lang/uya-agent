---
name: Bug report
about: 报告一个可复现的问题
labels: bug
---

## 现象

<!-- 发生了什么。如果是界面上看到的，贴一张截图或 --tool-lines N 的文本片段。 -->

## 复现

```bash
# 最小的一组命令 / 最少的一次输入
```

## 期望

<!-- 你以为会发生什么。 -->

## 环境

```text
$ ./uya-agent --print-config | head -5
$ uname -srm
$ file build/uya-agent      # 或 release 那个二进制
```

- 版本：`<release 标签 / git rev-parse --short HEAD>`
- 终端：<!-- deepin-terminal / kitty / Windows Terminal / 管道 … -->

## 诊断

<!-- 先把这几条跑一遍再贴：它们不需要 key、不联网，几秒钟就有结论。 -->

```bash
./uya-agent --selftest 2>&1 | tail -20    # 在仓库根跑；哪一轮红就是它的域
./uya-agent --print-config                 # 生效配置与**来源**（cli/env/dsh-settings/default）
./uya-agent --tui-demo                     # 界面渲染的纯文本快照
```

如果涉及网关返回的错误体，`--debug-dump FILE` 会把**原始字节**落盘
（转录里只有转义预览）。**贴之前删掉 key。**
