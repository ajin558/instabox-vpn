# instabox-vpn

把 InstaBox 的免费云端 Linux 机器变成一个**仅供自己使用的个人代理节点**，
并让另一个 Muse（或其他 AI 助手）拿到这份仓库后，能按同一套流程自动完成：
建机器、装 Xray、发布端口、实测验证、生成 Clash 配置。

> 定位：个人测试 / 备用节点，不是 24 小时稳定的主力节点，也不是公开代理服务。
> 不要把生成的节点链接、UUID 公开发布，也不要给别人用。

## 它是怎么工作的

```
你的电脑（Clash Verge / Mihomo）
  │  TLS + VLESS + XHTTP（主推）或 WS（备用）
  ▼
InstaBox 公开端口网关（HTTPS，instabox.tech）
  │  网关终止 TLS，转发明文 HTTP 到机器本地端口
  ▼
机器里的 Xray（systemd 服务）
  ├─ 10000：VLESS + XHTTP，路径 /xhttp，模式 packet-up
  └─ 10001：VLESS + WS，路径 /ws
  ▼
互联网（出口是这台机器的 IP）
```

关键点：

- InstaBox 对外**没有独立公网 IP**，只有 HTTPS 网关和 SSH 网关。
  所以 WireGuard UDP、VLESS 直连 TCP 这条路走不通，
  只能走网关里的 HTTPS 协议：XHTTP 或 WS。
- 机器里跑的是明文端口，TLS 由网关做，不要在机器里再套一层 TLS。
- 公开端口默认任何人拿到链接都能访问该端口的服务，
  所以鉴权只能靠 VLESS 的 UUID。UUID 泄露 = 节点泄露，泄露后立即换一个。

## 免费档的真实限制（先说清楚，再决定用不用）

| 项目 | 免费档 |
| --- | --- |
| 机器 | 1 台，4 vCPU / 8 GiB，20 GiB 盘 |
| 单次连续运行 | 最多 480 分钟，到点暂停 |
| 闲置暂停 | 30 分钟无活动固定暂停（免费档改不了） |
| 暂停后冷却 | 最长运行到点后，冷却 5–20 分钟，期间无法唤醒 |
| 唤醒 | 公开端口请求、exec、SSH 都能唤醒闲置暂停的机器，请求最多等 45 秒 |
| 出站流量 | 每月 100 GiB |
| 公开端口 | 每台机器最多 16 个 |

这意味着：暂停后第一次连接可能要等唤醒、测延迟时多点两次；
单次 8 小时到点后要等冷却再唤醒；不要用保活脚本去绕闲置暂停，
那是平台用来回收资源的机制，绕过去容易被判定滥用。

## 快速开始（给另一个 Muse 的一句话）

> 请按本仓库 `AGENT.md` 的流程帮我做完：连 InstaBox、建一台
> agent-browser 机器、跑 `server/setup.sh`、发布 10000 和 10001 端口、
> 用 `server/test.sh` 实测通过后，再用 `clash/generate.py` 生成 Clash 配置交给我。

人工也可以按下面走，但推荐让 Muse 按 `AGENT.md` 走，少踩坑。

## 手动流程

### 1. 准备 InstaBox

1. 在 InstaBox 后台建一台 `agent-browser` 机器，记下机器 ID。
2. 在后台 API keys 里新建一把专用的 key，**不要把 key 贴进聊天记录**，
   走你所用助手的的安全凭证流程保存（例如 Muse 的安全卡片）。
   旧的、已经贴进聊天的 key 不要再用，删掉轮换。
3. 确认机器状态是 running。

### 2. 在机器里安装并启动 Xray

把 `server/setup.sh` 传到机器里执行（需要能执行 `sudo`，InstaBox
的 agent-browser 模板默认有免密 sudo）：

```bash
bash server/setup.sh
```

它会做这些事，全部幂等，可重复跑：

- 下载脚本里钉住版本的 Xray（linux/amd64，当前 v26.10.31）到 `/data/xray/`，下载后先验官方 sha256 再安装；已装同版本则跳过，升级 = 改脚本顶部的版本号 + sha256 后重跑
- 如果 `/data/xray/uuid.txt` 不存在，就生成一个新 UUID 存进去；
  已存在就复用，**不要每次重跑都换 UUID，否则客户端配置就失效了**
- 写 `/data/xray/config.json`：10000 走 XHTTP，10001 走 WS，日志级别 error
- 备份旧配置到 `/data/xray/config.json.bak`
- 写 systemd 服务 `/etc/systemd/system/xray.service` 并 enable + start，
  崩了自动重起（Restart=always，5 秒后重试）
- 写 `/data/xray/start.sh`：双端口检查，机器重启后手动拉起的兜底

验证服务：

```bash
sudo systemctl status xray --no-pager
ss -ltn | grep -E '10000|10001'
```

### 3. 发布端口

通过 InstaBox API 发布两个端口（建议带 Idempotency-Key，见 `AGENT.md`）：

- `POST /v1/machines/{id}/ports`，`{"port": 10000, "name": "xray"}`
- `POST /v1/machines/{id}/ports`，`{"port": 10001, "name": "xray-ws"}`

返回的 URL 形如：

```
https://10000-<machine-id>.instabox.tech
https://10001-<machine-id>.instabox.tech
```

记下这两个主机名（去掉 `https://` 的部分），下一步要用。

### 4. 实测验证（部署完成不等于能用）

在机器本机跑客户端测试，走公开地址连回来：

```bash
bash server/test.sh <xhttp-host> <ws-host> <uuid>
```

通过标准是三条全过，缺一不可：

- XHTTP 和 WS 各自测 `https://www.google.com/generate_204` 返回 204
- `https://api.ipify.org` 返回机器出口 IP
- 错 UUID 测一次必须失败（证明不是开放代理）

注意：测试客户端和服务端在同一台机器上时，延迟（本项目实测约
0.15–0.29 秒）是回环延迟，**不代表用户本地的延迟**。
用户本地的延迟和可用性，还要用户在自己电脑上实测。

用户本地实测已补上（2026-11-02，Windows + Clash Verge）：
把 Mihomo 内核从 v1.19.3 升到 v1.19.33 后，配置一行没改，
XHTTP 测 `https://www.google.com/generate_204` 为 259 ms，
WS 为 207 ms，两路都通。这才是最终验收，
机器本机实测通过不等于用户本地能用。

### 5. 生成 Clash 配置

```bash
python3 clash/generate.py \
  --xhttp-host <xhttp-host> \
  --ws-host <ws-host> \
  --uuid <uuid> \
  --out clash.yaml
```

生成的文件用 Mihomo 校验：

```bash
mihomo -t -f clash.yaml
```

然后在 Clash Verge 里导入为**本地配置**，注意：

- 必须用 Mihomo 内核，原版 Clash 不支持 VLESS。
  **XHTTP 需要 Mihomo v1.19.22 及以上**（XHTTP 传输支持自 v1.19.22
  加入），本项目在用户本地实测通过的版本是 **v1.19.33**
  （Windows amd64-v1）。低于 v1.19.22 的旧核心会出现
  “WS 能用、XHTTP 不能用”的典型表现，配置本身没错，不要因此改服务端。
- 本仓库**不打包、不分发 Mihomo 二进制**，内核由用户在
  Clash Verge 里自行更新：先备份旧核心，换上官方发布页下载的新核心，
  重启 Clash Verge 后再测。更新前先核对官方发布页的校验信息，
  核对不上就不要用。
- PROXY 组里先选 `instabox-muse-xhttp`，不行再切 `instabox-muse-ws`。
- 开启系统代理，再测延迟。
- 配置里的 DNS 用了阿里 + Google 的 DoH，帮助解析 instabox.tech，
  没有加 fallback，避免触发 GeoIP 下载。

## 排障

完整排障见 `docs/TROUBLESHOOTING.md`，最常见的三类：

1. **服务端日志里完全没有用户那次请求的记录**：请求根本没到 Xray，
   先查客户端到网关这一段：浏览器能不能打开公开地址、
   Clash 选没选对代理组、系统代理开了没有、内核版本够不够新
   （XHTTP 要求 Mihomo ≥ v1.19.22，实测通过 v1.19.33；
   旧核心 v1.19.3 的实测表现就是 WS 通、XHTTP 不通）。
2. **两个传输都延迟“-”**：先确认网关地址在用户本地能不能解析、
   能不能 TLS 连通；再看 Clash 日志的报错行。
3. **暂停后第一次连超时**：正常，闲置暂停后唤醒最多等 45 秒，
   多测两次；单次 8 小时到点后是冷却，不是故障，等 5–20 分钟再唤醒。

## 安全与合规提醒

- 本项目只做**自己用的个人节点**，不要公开分享、不要转卖、不要给多人用。
- UUID、节点链接、InstaBox API key 都不要写进公开仓库、截图和聊天记录外发。
- InstaBox 还是内测免费服务，价格、条款、免费档都可能变，
  把它当备用节点，不要把重要业务押在上面。
- 遵守你所在地的法律法规和 InstaBox 的使用条款。

## 目录

```
instabox-vpn/
  README.md                  本文件
  AGENT.md                   给另一个 Muse 的完整执行流程
  LICENSE                    MIT
  server/
    setup.sh                 机器端安装 + systemd 服务
    test.sh                  机器端经公开地址的客户端实测
    start.sh                 启动脚本模板（setup.sh 会生成一份到机器上）
  clash/
    template.yaml            Clash 模板（占位符，不含真实值）
    generate.py              按主机名和 UUID 渲染出可用的 Clash 配置
  docs/
    TROUBLESHOOTING.md       排障手册
```

## License

MIT，见 `LICENSE`。
