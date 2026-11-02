#!/bin/bash
# 在 InstaBox 机器里运行：安装 Xray，配置 VLESS + XHTTP / WS，交给 systemd 管理。
# 幂等：可重复跑。UUID 只生成一次，存在 /data/xray/uuid.txt，重复跑不会换 UUID。
# 用法：bash setup.sh
set -euo pipefail

XRAY_DIR="/data/xray"
UUID_FILE="$XRAY_DIR/uuid.txt"
CONFIG_FILE="$XRAY_DIR/config.json"

mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

# 1. 安装 Xray（如果已有可执行文件就跳过下载）
if [ ! -x "$XRAY_DIR/xray" ]; then
  echo "Downloading Xray..."
  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o -q xray.zip
  chmod +x xray
fi
"$XRAY_DIR/xray" version | head -1

# 2. UUID：只生成一次
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo "Reusing existing UUID from $UUID_FILE"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo "Generated new UUID, saved to $UUID_FILE (do not publish it)"
fi

# 3. 配置：10000 = XHTTP，10001 = WS，机器里都是明文，TLS 由 InstaBox 网关做
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
  echo "Backed up old config to $CONFIG_FILE.bak"
fi

cat > "$CONFIG_FILE" <<EOF
{
  "log": {"loglevel": "error"},
  "inbounds": [
    {
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/xhttp", "mode": "packet-up"},
        "security": "none"
      }
    },
    {
      "port": 10001,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/ws"},
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF

"$XRAY_DIR/xray" -test -c "$CONFIG_FILE"

# 4. systemd 服务：开机自启，崩了 5 秒后自动重起
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  sudo tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray VLESS server
After=network.target

[Service]
Type=simple
User=$(whoami)
ExecStart=$XRAY_DIR/xray -c $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable xray
  sudo systemctl restart xray
  sleep 2
  sudo systemctl status xray --no-pager | head -12 || true
else
  echo "systemd not available, falling back to nohup + start.sh"
  # 停掉旧的 nohup 进程（按 PID 杀，不用 pkill  pattern，避免杀掉自己）
  OLD_PID=$(ps aux | grep "[x]ray -c $CONFIG_FILE" | awk '{print $2}' || true)
  if [ -n "$OLD_PID" ]; then kill "$OLD_PID" || true; sleep 2; fi
  nohup "$XRAY_DIR/xray" -c "$CONFIG_FILE" > "$XRAY_DIR/xray.log" 2>&1 &
fi

# 5. 启动脚本：双端口检查，停机后手动拉起的兜底
cat > "$XRAY_DIR/start.sh" <<'EOS'
#!/bin/bash
if ss -ltn | grep -q ":10000 " && ss -ltn | grep -q ":10001 "; then
  echo already-running
else
  sudo systemctl start xray 2>/dev/null || nohup /data/xray/xray -c /data/xray/config.json > /data/xray/xray.log 2>&1 &
  echo started
fi
EOS
chmod +x "$XRAY_DIR/start.sh"

echo "--- listening ports ---"
ss -ltn | grep -E '10000|10001' || echo "WARNING: ports not listening, check systemctl status xray"
echo "Done. Next: publish ports 10000 and 10001 via the InstaBox API, then run test.sh."
