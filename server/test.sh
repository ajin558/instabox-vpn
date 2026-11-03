#!/bin/bash
# 在机器本机跑：用 Xray 客户端经公开地址连回来，验证节点真的能用。
# 注意：测试客户端和服务端在同一台机器上时，延迟是回环延迟，不代表用户本地延迟。
# 用法：bash test.sh <xhttp-host> <ws-host> <uuid>
#   xhttp-host 例：10000-<machine-id>.instabox.tech
#   ws-host 例：10001-<machine-id>.instabox.tech
set -uo pipefail

XHTTP_HOST="${1:-}"
WS_HOST="${2:-}"
UUID="${3:-}"

if [ -z "$XHTTP_HOST" ] || [ -z "$WS_HOST" ] || [ -z "$UUID" ]; then
  echo "Usage: bash test.sh <xhttp-host> <ws-host> <uuid>" >&2
  exit 2
fi

XRAY_BIN="/data/xray/xray"
if [ ! -x "$XRAY_BIN" ]; then
  echo "Xray binary not found at $XRAY_BIN, run setup.sh first" >&2
  exit 2
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
PASS=0
FAIL=0

check() {
  local label="$1" code="$2"
  if [ "$code" = "$3" ]; then
    echo "PASS $label code=$code"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label code=$code (expected $3)"
    FAIL=$((FAIL + 1))
  fi
}

run_client() {
  # $1 = client config file, $2 = socks port, $3 = label
  local cfg="$1" port="$2" label="$3"
  ("$XRAY_BIN" -c "$cfg" > "$WORKDIR/$label.log" 2>&1 & echo $! > "$WORKDIR/$label.pid")
  sleep 2
  for url in https://www.google.com/generate_204 https://www.youtube.com/generate_204 https://github.com; do
    # 不要写 || echo 000：curl 失败时 -w 已经输出 000，再追加会拼成 000000，
    # 状态码判断永远对不上（错 UUID 那项曾因此误报 FAIL）。失败时 -w 的 000 已够用，
    # 极端情况下输出为空再用 :-000 兜底。
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 25 --socks5-hostname "127.0.0.1:$port" "$url" || true)
    code=${code:-000}
    expected=200
    if [[ "$url" == *generate_204 ]]; then expected=204; fi
    check "$label $url" "$code" "$expected"
  done
  echo -n "$label ipify: "
  curl -s -m 20 --socks5-hostname "127.0.0.1:$port" https://api.ipify.org || echo " (failed)"
  echo
  kill "$(cat "$WORKDIR/$label.pid")" 2>/dev/null || true
  sleep 1
}

# XHTTP 客户端
cat > "$WORKDIR/xhttp.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"port": 10808, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "$XHTTP_HOST", "port": 443, "users": [{"id": "$UUID", "encryption": "none", "flow": ""}]}]},
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {"path": "/xhttp", "mode": "packet-up"},
      "security": "tls",
      "tlsSettings": {"serverName": "$XHTTP_HOST"}
    }
  }]
}
EOF
run_client "$WORKDIR/xhttp.json" 10808 "xhttp"

# WS 客户端
cat > "$WORKDIR/ws.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"port": 10809, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "$WS_HOST", "port": 443, "users": [{"id": "$UUID", "encryption": "none", "flow": ""}]}]},
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/ws"},
      "security": "tls",
      "tlsSettings": {"serverName": "$WS_HOST"}
    }
  }]
}
EOF
run_client "$WORKDIR/ws.json" 10809 "ws"

# 错 UUID 必须失败：证明不是开放代理
sed "s/$UUID/00000000-0000-0000-0000-000000000000/" "$WORKDIR/xhttp.json" > "$WORKDIR/wrong.json"
("$XRAY_BIN" -c "$WORKDIR/wrong.json" > "$WORKDIR/wrong.log" 2>&1 & echo $! > "$WORKDIR/wrong.pid")
sleep 2
code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 --socks5-hostname 127.0.0.1:10808 https://www.google.com/generate_204 || true)
code=${code:-000}
kill "$(cat "$WORKDIR/wrong.pid")" 2>/dev/null || true
if [ "$code" = "000" ]; then
  echo "PASS wrong-uuid must fail code=000"
  PASS=$((PASS + 1))
else
  echo "FAIL wrong-uuid should fail, got code=$code"
  FAIL=$((FAIL + 1))
fi

echo "=== result: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -ne 0 ]; then exit 1; fi
