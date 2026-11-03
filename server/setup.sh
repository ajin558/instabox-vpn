#!/bin/bash
# 在 InstaBox 机器里运行：安装 Xray，配置 VLESS + XHTTP / WS，交给 systemd 管理。
# 幂等：可重复跑。UUID 只生成一次，存在 /data/xray/uuid.txt，重复跑不会换 UUID。
# 用法：bash setup.sh
set -euo pipefail

XRAY_DIR="/data/xray"
UUID_FILE="$XRAY_DIR/uuid.txt"
CONFIG_FILE="$XRAY_DIR/config.json"

# Xray 版本钉死，不用 latest：重跑结果可复现，升级时改版本号 + 对应 sha256 再重跑。
# XRAY_SHA256 是官方 release 的 Xray-linux-64.zip.dgst 里的 SHA2-256，
# 换版本时去 https://github.com/XTLS/Xray-core/releases 对应版本的 .dgst 核对后更新。
XRAY_VERSION="v26.10.31"
XRAY_SHA256="e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214"

# 有些机器上 /data 根目录归 root、当前用户建不了子目录（本项目实测踩过）：
# 先按普通权限建，失败就用 sudo 建好并把所有权给当前用户，再继续。
if ! mkdir -p "$XRAY_DIR" 2>/dev/null; then
  sudo mkdir -p "$XRAY_DIR"
  sudo chown "$(id -un):$(id -gn)" "$XRAY_DIR"
fi
cd "$XRAY_DIR"

# 1. 安装 Xray：没装、或已装版本与钉住的版本不一致时，才下载、校验后安装。
# 升级 = 改上面的 XRAY_VERSION / XRAY_SHA256 后重跑本脚本。
INSTALLED_VERSION=""
if [ -x "$XRAY_DIR/xray" ]; then
  INSTALLED_VERSION="v$("$XRAY_DIR/xray" version | head -1 | awk '{print $2}')"
fi
if [ "$INSTALLED_VERSION" != "$XRAY_VERSION" ]; then
  echo "Downloading Xray $XRAY_VERSION (installed: ${INSTALLED_VERSION:-none})..."
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
  echo "$XRAY_SHA256  xray.zip" | sha256sum -c -
  unzip -o -q xray.zip
  chmod +x xray
else
  echo "Xray $XRAY_VERSION already installed, skipping download"
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
