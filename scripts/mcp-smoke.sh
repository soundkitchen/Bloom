#!/bin/sh
# MCP サーバのスモークテスト(Claude 不要)。
# アプリをバックグラウンド起動 → ソケット出現を待つ → ブリッジ経由で
# initialize / tools/list / tools/call(get_canvas_info)を流して応答を検証 → 後始末。
# 専用ソケットパス(BLOOM_MCP_SOCKET)を使うので、起動中の普段使いの Bloom とは干渉しない。
set -u

DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Bloom-cli"
APP="$DERIVED/Build/Products/Debug/BloomApp.app/Contents/MacOS/BloomApp"
BRIDGE="$DERIVED/Build/Products/Debug/bloom-mcp"
SOCK="$(mktemp -d /tmp/bloom-mcp-smoke.XXXXXX)/mcp.sock"
OUT="$(mktemp /tmp/bloom-mcp-smoke-out.XXXXXX)"

fail() { echo "NG: $1" >&2; cleanup; exit 1; }
cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    rm -rf "$(dirname "$SOCK")" "$OUT"
}

[ -x "$APP" ] || fail "アプリ未ビルド($APP)。make build を実行してください"
[ -x "$BRIDGE" ] || fail "ブリッジ未ビルド($BRIDGE)。make build を実行してください"

BLOOM_MCP_SOCKET="$SOCK" "$APP" &
APP_PID=$!

# ソケット出現待ち(最大 10 秒)
i=0
while [ ! -S "$SOCK" ]; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && fail "ソケットが現れません: $SOCK"
    kill -0 "$APP_PID" 2>/dev/null || fail "アプリが起動できませんでした"
    sleep 0.1
done

# JSON-RPC を 1 行ずつ流す(応答時間を稼ぐため少し間を置く)
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-smoke","version":"0"}}}'
    sleep 0.5
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 0.5
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_canvas_info","arguments":{}}}'
    sleep 1
} | BLOOM_MCP_SOCKET="$SOCK" "$BRIDGE" > "$OUT" 2>/dev/null

grep -q '"serverInfo"' "$OUT" || fail "initialize の応答がありません"
grep -q '"draw_strokes"' "$OUT" || fail "tools/list に draw_strokes がありません"
grep -q 'wet_fraction' "$OUT" || fail "get_canvas_info の応答がありません"

# 並列ツール呼び出し + 背圧での送信混線検査(再接続の検証も兼ねる)
BLOOM_MCP_SOCKET="$SOCK" python3 "$(dirname "$0")/mcp-parallel-smoke.py" "$BRIDGE" \
    || fail "並列・背圧の混線検査(mcp-parallel-smoke.py)"

cleanup
echo "OK: initialize / tools/list / tools/call / 並列混線検査 すべてパス"
