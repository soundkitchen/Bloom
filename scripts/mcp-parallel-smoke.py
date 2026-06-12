#!/usr/bin/env python3
"""並列ツール呼び出し + 背圧の混線検査。

snapshot(巨大応答)を 2 連発し、しばらく読まずに放置してソケット送信バッファを
満杯にする(サーバ側の送信が EAGAIN で suspension する状況を作る)。
その後すべて読み出し、(1) 全行が JSON としてパースできる、(2) 両方の応答が届く、
ことを検証する。送信が混線すると壊れた JSON 行になり、応答が永遠に届かない
(2026-06-12 の実セッションで発生した 21 分スタックの再現)。

usage: BLOOM_MCP_SOCKET=... mcp-parallel-smoke.py <bridge-path>
"""
import json
import os
import subprocess
import sys
import time

bridge = sys.argv[1]
proc = subprocess.Popen(
    [bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL, env=os.environ,
)

def send(obj):
    proc.stdin.write((json.dumps(obj) + "\n").encode())
    proc.stdin.flush()

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                 "clientInfo": {"name": "parallel-smoke", "version": "0"}}})
time.sleep(0.5)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

# 並列呼び出し相当: 2 つの tools/call を間髪入れず送る
send({"jsonrpc": "2.0", "id": 11, "method": "tools/call",
      "params": {"name": "snapshot", "arguments": {}}})
send({"jsonrpc": "2.0", "id": 12, "method": "tools/call",
      "params": {"name": "snapshot", "arguments": {}}})

# 読まずに放置 → パイプ・ソケットのバッファが埋まり、サーバ側が EAGAIN で待つ。
# stdin はまだ閉じない(閉じるとセッション終了の半クローズになり、別の事象を測ってしまう)
time.sleep(3)

deadline = time.time() + 30
received, corrupt = set(), 0
while time.time() < deadline and received < {11, 12}:
    line = proc.stdout.readline()
    if not line:
        break
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        corrupt += 1
        continue
    if msg.get("id") in (11, 12) and "result" in msg:
        received.add(msg["id"])

proc.stdin.close()
proc.kill()
if corrupt:
    print(f"NG: 壊れた JSON 行が {corrupt} 行(送信の混線)")
    sys.exit(1)
if received < {11, 12}:
    print(f"NG: 応答が欠落(届いた id: {sorted(received)})")
    sys.exit(1)
print("OK: 並列・背圧でも全応答が無傷で届いた")
