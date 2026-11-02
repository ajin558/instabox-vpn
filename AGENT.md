# AGENT.md：给另一个 Muse 的执行流程

目标：不靠用户手动敲命令，从零到一个**实测通过的个人节点**，
最后交出 Clash 配置。用户说“按 AGENT.md 做”时，就按下面顺序做，
每一步都要拿回真实结果再往下走，不要凭猜测报通过。

## 0. 安全红线（先读完再动手）

- 永远不要让用户把 InstaBox API key、UUID、节点链接贴进聊天。
  API key 走助手的安全凭证流程保存；UUID 只在机器里生成和保存，
  只在最后交付给用户本人的那份 Clash 配置里出现一次。
- 不要把任何真实的 key、UUID、主机名、机器 ID、组织 ID 写进本仓库、
  记忆、公开文档或截图里。本仓库里只允许占位符。
- 不要把节点公开分享，不要给多人用，不要做公开代理服务。
- 不要用保活脚本绕过免费档的 30 分钟闲置暂停。
- 写操作（建机器、发布端口、重启服务）之前，先确认用户已经授权
  在这台免费账号上操作；免费账号、无付费、无重要数据是常见前提，
  但仍以用户当次的授权为准。

## 1. 连接 InstaBox

- API 基础地址：`https://api.instabox.sh`
- 认证：请求头 `X-API-Key: <key>`，或 `Authorization: Bearer <key>`。
- key 的权限决定能做什么：读机器至少要 `machines:read`，
  建机器、发布端口、exec 需要 `machines:write`。
- 连接后先做无害读验证，不要直接建机器：
  - `GET /v1/orgs`：确认工作区、免费档、允许的规格（应为 4 vCPU / 8 GiB）。
  - `GET /v1/machines`：确认已有机器，避免重复建。

如果 401，先确认请求确实带了凭证、主机已注册、请求头位置对不对；
如果 403，先确认 key 的 scope；不要在没带凭证的情况下重发同一请求。

## 2. 建机器（如果还没有）

- 模板选 `agent-browser`（免费档可建的模板之一，带 Docker、桌面、
  Node、Go、Rust、JDK，免密 sudo）。
- 建好后等状态为 running 再继续。
- 记下机器 ID，后面所有 API 和 exec 都用它。

## 3. 在机器里安装 Xray

把本仓库 `server/setup.sh` 传到机器里执行：

```bash
bash server/setup.sh
```

执行后必须逐项核对，不要只看脚本退出码：

- `sudo systemctl status xray --no-pager`：active (running)，且是 enabled。
- `ss -ltn`：10000 和 10001 都在监听。
- `/data/xray/config.json`：10000 是 XHTTP（`/xhttp`，packet-up），
  10001 是 WS（`/ws`），日志级别 error。
- `/data/xray/uuid.txt`：只生成一次，后续重跑 setup.sh 必须复用，
  换 UUID 会导致已交付的客户端配置失效。

如果 systemd 不可用，退回 `nohup` + `/data/xray/start.sh`，
并在交付时明确说明：停机后需要手动拉起。

## 4. 发布端口

用 API 发布，不要只在机器里监听就宣称完成：

- `POST /v1/machines/{id}/ports`，body `{"port": 10000, "name": "xray"}`，
  必须带一个唯一的 `Idempotency-Key` 请求头。
- `POST /v1/machines/{id}/ports`，body `{"port": 10001, "name": "xray-ws"}`，
  同样带唯一的 `Idempotency-Key`。
- 用 `GET /v1/machines/{id}/ports` 核对两个 URL 都在，记下两个主机名。

公开端口不是秘密，任何人拿到链接都能访问该端口的服务，
所以下一步的实测必须包含错 UUID 必须失败这一项。

## 5. 实测验证（这是验收，不是可选项）

在机器本机跑：

```bash
bash server/test.sh <xhttp-host> <ws-host> <uuid>
```

脚本会用 Xray 客户端经公开地址连回来，测两路传输。
通过标准：

- XHTTP：google generate_204 = 204，youtube generate_204 = 204，
  github = 200，ipify 返回机器出口 IP。
- WS：同上。
- 错 UUID：必须失败，返回 000 或连接失败。

如果只在助手自己的沙箱里测，TLS 可能被沙箱出口代理拦截而报错，
那不是节点故障，要改用机器本机经公开地址的测试为准，
并在交付时把这一点说清楚。

如果某一路不通，不要直接换另一路交差：先看服务端日志、
客户端日志的报错行，再决定是改配置、换传输，还是先停下来问用户。

## 6. 生成并校验 Clash 配置

```bash
python3 clash/generate.py \
  --xhttp-host <xhttp-host> \
  --ws-host <ws-host> \
  --uuid <uuid> \
  --out clash.yaml
```

校验：

```bash
mihomo -t -f clash.yaml
```

必须通过才交付。`-t` 通过只证明配置能解析，
不证明旧内核能发 XHTTP，所以交付前还要问用户一句 Mihomo 版本。
交付时说明：

- 导入为 Clash Verge 本地配置，必须用 Mihomo 内核，原版 Clash 不支持 VLESS。
- **XHTTP 要求 Mihomo ≥ v1.19.22，实测通过 v1.19.33。**
  如果用户版本低于 v1.19.22，先让他升级内核（先备份旧核心，
  从官方发布页下载，核对校验信息，重启后再测），
  不要先改服务端配置。本仓库不打包 Mihomo，
  不要假装仓库里有个可以升级的内核包。
- 用户本地实测才是最终验收：XHTTP 和 WS 都要在用户电脑上测延迟，
  机器本机实测的回环延迟不算数。
- PROXY 组先选 xhttp，不行再切 ws；开启系统代理再测延迟。
- 配置里的 DNS 是阿里 + Google DoH，没有 fallback（fallback 会触发
  GeoIP 下载，之前实测中在某些环境会失败）。
- 暂停后第一次连可能要等唤醒，测两次；单次 8 小时到点后是冷却，
  等 5–20 分钟再唤醒。
- 明确告诉用户：机器本机实测的延迟是回环延迟，不代表用户本地延迟，
  用户本地实测才是最终验收。

## 7. 交付清单（缺一项都不算做完）

- [ ] 机器 running，systemd 服务 active 且 enabled
- [ ] 10000 / 10001 都监听，两个公开端口都已发布并核对过 URL
- [ ] XHTTP 和 WS 实测都通过，错 UUID 实测都失败
- [ ] Clash 配置已用 `mihomo -t` 校验通过，且已确认用户 Mihomo 版本 ≥ v1.19.22（推荐 v1.19.33）
- [ ] 用户本地 XHTTP 和 WS 延迟都实测过，不只机器本机回环实测
- [ ] 交付时说明了免费档限制：30 分钟闲置暂停、单次 480 分钟、
  冷却 5–20 分钟、每月 100 GiB、不要公开分享
- [ ] 没有把真实 key、UUID、主机名写进仓库、记忆或公开文档

## 8. 用户说“用不了”时的第一步

先查服务端，不要先怪客户端：

1. 机器是不是 running，Xray 进程在不在，端口在不在监听。
2. 服务端日志在用户测试的时间段里有没有新记录。
   没有新记录 = 请求根本没到 Xray，先查客户端到网关这一段。
3. 再看客户端：代理组选对没有、系统代理开了没有、内核版本够不够
   （XHTTP 要求 ≥ v1.19.22；WS 通、XHTTP 不通先怀疑旧内核）、
   Clash 日志报错行是什么、浏览器能不能打开公开地址。

详细排障见 `docs/TROUBLESHOOTING.md`。
