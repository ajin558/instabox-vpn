#!/bin/bash
# 启动脚本模板：setup.sh 会在机器上生成一份内容相同的脚本。
# 机器重启后，如果 systemd 服务没有自动拉起，就跑这个。
if ss -ltn | grep -q ":10000 " && ss -ltn | grep -q ":10001 "; then
  echo already-running
else
  sudo systemctl start xray 2>/dev/null || nohup /data/xray/xray -c /data/xray/config.json > /data/xray/xray.log 2>&1 &
  echo started
fi
