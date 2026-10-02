#!/bin/bash
# 假 workflow 脚本：只通过钩子协议和父进程说话（bash 的 /dev/tcp），用来验证协议本身。
# 由 selftest 的 workflow 轮使用；真实路径是 `uya run` 跑 Uya 的 .ush 脚本。
port="$UYA_AGENT_WF_PORT"
hook() {
  exec 3<>/dev/tcp/127.0.0.1/"$port" || { echo "hook: connect failed" >&2; return 1; }
  printf '%s\n' "$1" >&3
  IFS= read -r reply <&3
  exec 3<&- 2>/dev/null
  exec 3>&- 2>/dev/null
  printf '%s' "$reply"
}
# 从 {"ok":true,"text":"…"} 里取 text
text_of() {
  printf '%s' "$1" | sed -n "s/.*\"text\": *\"\([^\"]*\)\".*/\1/p"
}

hook 'phase audit files' >/dev/null
hook 'log 开始审计 a.uya' >/dev/null
raw=$(hook 'agent_start {"prompt":"审计 a.uya 并给出结论","label":"audit a"}')
handle=$(text_of "$raw")
echo "wf_stub: handle=$handle" >&2
raw2=$(hook "agent_wait $handle")
res=$(text_of "$raw2")
echo "wf_stub: agent said: $res" >&2
hook "done 审计完成：$res" >/dev/null
echo "wf_stub: done"
# MARKER-1790953753
