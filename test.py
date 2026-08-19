#!/usr/bin/env python3
"""拼音补全 CLI 测试脚本

用法:
    python test.py              # 使用内置测试候选项
    python test.py build/linux/x86_64/release/cli   # 指定 CLI 路径
"""

import subprocess
import sys

CLI = sys.argv[1] if len(sys.argv) > 1 else "lua/cmp_pinyin/bin/cli"


def run(query, candidates, notations=("简拼", "全拼")):
  """调用 CLI 并返回结果列表 [(word, score), ...]"""
  cmd = [CLI]
  for n in notations:
    cmd += ["--notation", n]
  cmd.append(query)
  proc = subprocess.run(
    cmd, input="\n".join(candidates), capture_output=True, text=True
  )
  if proc.returncode != 0:
    print(f"  stderr: {proc.stderr.strip()}")
    return []
  results = []
  for line in proc.stdout.strip().split("\n"):
    if "\t" in line:
      word, score = line.split("\t", 1)
      try:
        results.append((word, int(score)))
      except ValueError:
        continue  # 忽略无法解析的输出行
  return results


def test(
  name,
  query,
  candidates,
  notations=("简拼", "全拼"),
  expect_word=None,
  expect_empty=False,
):
  results = run(query, candidates, notations)
  if expect_empty:
    ok = len(results) == 0
  elif expect_word:
    ok = any(r[0] == expect_word for r in results)
  else:
    ok = len(results) > 0
  status = "✓" if ok else "✗ FAIL"
  print(f"  {status} {name}: query='{query}' → {len(results)} matches")
  for word, score in results[:5]:
    print(f"      {word} (score={score})")
  return ok


CANDIDATES = [
  "用户管理",
  "用户名",
  "用户密码",
  "用户列表",
  "搜索结果",
  "搜索关键词",
  "拼音输入法",
  "拼音补全",
  "数据处理",
  "数据库连接",
  "文件路径",
  "文件内容",
  "打印输出",
  "请求响应",
  # 双拼多候选韵母测试词（加加: 国=gojw, 华宇: 想象=xdxd, 雄心=xsxb）
  "国家",
  "想象",
  "雄心",
]

print("拼音补全 CLI 测试")
print(f"CLI: {CLI}")
print(f"候选项: {len(CANDIDATES)} 个\n")

all_pass = True

# 简拼测试
print("[简拼]")
all_pass &= test("单字", "yh", CANDIDATES, ("简拼",), expect_word="用户管理")
all_pass &= test("双字", "yhgl", CANDIDATES, ("简拼",), expect_word="用户管理")
all_pass &= test("部分", "ssjg", CANDIDATES, ("简拼",), expect_word="搜索结果")

# 全拼测试
print("\n[全拼]")
all_pass &= test("全拼匹配", "yonghu", CANDIDATES, ("全拼",), expect_word="用户管理")
all_pass &= test("拼音", "pinyin", CANDIDATES, ("全拼",), expect_word="拼音输入法")

# 简拼+全拼
print("\n[简拼+全拼]")
all_pass &= test("混合", "yonghu", CANDIDATES, expect_word="用户管理")

# 边界情况
print("\n[边界]")
all_pass &= test("空结果", "xyz", CANDIDATES, expect_empty=True)
all_pass &= test("短查询", "a", CANDIDATES, expect_empty=True)

# 双拼测试（多候选韵母按声母选择）
print("\n[双拼]")
all_pass &= test(
  "加加双拼 w=ua (go→guo)", "gojw", CANDIDATES, ("加加双拼",), expect_word="国家"
)
all_pass &= test(
  "加加双拼用户 (yshu→yonghu)",
  "yshu",
  CANDIDATES,
  ("加加双拼",),
  expect_word="用户管理",
)
all_pass &= test(
  "华宇双拼 d=iang (xd→xiang)", "xdxd", CANDIDATES, ("华宇双拼",), expect_word="想象"
)
all_pass &= test(
  "华宇双拼 s=iong (xs→xiong)", "xsxb", CANDIDATES, ("华宇双拼",), expect_word="雄心"
)

# 两阶段去重：加加双拼第一阶段(0x20)命中 + 第二阶段转换命中，不应重复输出
print("\n[去重]")
results = run("yshu", CANDIDATES, ("加加双拼",))
words = [w for w, _ in results]
dedup_ok = len(words) == len(set(words))
print(
  f"  {'✓' if dedup_ok else '✗ FAIL'} 加加双拼结果无重复: {len(words)} 条 = {len(set(words))} 唯一"
)
all_pass &= dedup_ok

# 非法 --notation
print("\n[非法输入]")
proc = subprocess.run(
  [CLI, "--notation", "0xGG", "yh"],
  input="\n".join(CANDIDATES),
  capture_output=True,
  text=True,
)
bad_ok = proc.returncode != 0
print(f"  {'✓' if bad_ok else '✗ FAIL'} 0xGG 非零退出码 (实际 {proc.returncode})")
all_pass &= bad_ok

print(f"\n{'全部通过!' if all_pass else '有失败用例!'}")
sys.exit(0 if all_pass else 1)
