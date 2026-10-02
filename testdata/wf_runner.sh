#!/bin/sh
# uya-agent workflow 的测试替身：忽略 run 子命令，直接跑脚本
shift
exec /bin/sh "$1"
