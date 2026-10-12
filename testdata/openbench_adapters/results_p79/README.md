# P79 复测的原始结果行

结论写在 [DESIGN.md §19.3](../../../DESIGN.md)；这里只放**可复盘的原始行**
（已裁掉 `checker_workspace_files` 这类大正文，只留判分与用量字段）。

| 文件 | 是什么 |
|---|---|
| `ctrl_neg.jsonl` | 负控：`--harness null` 打 4 题，必须拿基线分（`0.28 / 0.3125 / 0.40 / 0.30`） |
| `results.jsonl` | 4 题 × 2 臂 **n=1**（含 `webcore` 本仓被上游 `upstream_error` 掐断那一格） |
| `results_tf3.jsonl` | `taskflow` × 2 臂 **n=3** —— 推翻 §19.1「dsh 快 1.8×」的那组 |
| `results_other3.jsonl` | `make-ci-green` + `add-feature` × 2 臂 **n=3** |

字段口径：`turns` = 模型调用轮数；`tokens` = 输入（未命中）+ 输入（命中）+ 输出；
`wall_time_s` 含除 checker 外的全部耗时。两侧 token 口径均已与网关账本逐数对上
（见 [../README.md](../README.md)）。

**怎么读这组数据**（这条比数字本身重要）：`taskflow` 本仓轮数 22/21/23（极差 2），
dsh 是 **17/96/13（极差 83）**。**先看极差再看中位数** —— 极差远大于中位数差时，
那个差不是结论。§19.1 的「dsh 快 1.8×」就是单抽到 dsh 17 轮那次得出的。

复现命令见 [../README.md](../README.md)；`--trials 3` 即可。
