# vps-proxy-setup

Proxy service setup on a hardened Debian/Ubuntu VPS, using 3X-UI as the example. **Status: requirements v1.3, solution design v1.0 and verification plan v1.0 approved; nothing to install yet.**

在已经用 [vps-hardening](https://github.com/alieismy/vps-hardening) 加固的 Debian/Ubuntu VPS 上搭建代理服务，以 3X-UI 为例。

**当前状态：[需求规格说明](docs/requirements.md) v1.3 已批准，[方案设计](docs/solution-design.md) v1.0 已批准，[验证计划](docs/verification-plan.md) v1.0 已批准；还没有可用的脚本或发行版。**

## 与另外两个仓库的关系

| 仓库 | 用途 |
|---|---|
| [vps-tuning](https://github.com/alieismy/vps-tuning) | 网络调优、诊断与测量 |
| [vps-hardening](https://github.com/alieismy/vps-hardening) | 基础安全加固：SSH 只用密钥、UFW、Fail2ban、自动安全更新 |
| vps-proxy-setup（本仓库） | 安装和配置 3X-UI：代理入站、面板、订阅（经 Cloudflare Tunnel 发布） |

建议的执行顺序沿用 vps-hardening 的需求（D27、D41、D42）：

1. 更新系统、安装基础工具并重启；
2. 加固并确认，这时 UFW 只放行 22/tcp；
3. 调优：应用 → 重启 → 验证；
4. 安装并配置 3X-UI 和 cloudflared（本仓库）；完成之后用 `vps-hardening ports --add 443/tcp` 开放节点端口并确认。订阅经 Cloudflare Tunnel 发布，不开放订阅端口（需求 D21、FR-06）；
5. 调优仓库的严格验证；
6. 重启后复核。

## 已经约定的边界

以下各条来自 vps-hardening 已批准的需求（[第 7.2 节](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md#72-与-vps-proxy-setup-的约定3x-ui-v3102)、D14、D16、D32），本仓库的需求以它们为前提；3X-UI 的版本按本仓库需求 D10 改变，公开端口和证书按 D21 收窄，仍在约定的范围之内：

- 3X-UI 安装时带版本参数，运行前按固定的摘要校验 `install.sh`。vps-hardening 约定的是 `v3.10.2`；本仓库改用 `v3.11.0`，因为 v3.10.2 自带的 Xray 已被撤版。v3.11.0 的 `install.sh` 与 v3.10.2 的相同，摘要不变。
- 安装时设 `XUI_ENABLE_FAIL2BAN=false`，不启用 IP Limit；Fail2ban 由 vps-hardening 管理。
- 面板端口用加固时记录的值（默认 2053），通过 `XUI_PANEL_PORT` 传入。安装后执行 `x-ui setting -listenIP 127.0.0.1` 并重启 x-ui，使面板只监听回环地址，只经 SSH 隧道访问。
- 公开端口（例如 443/tcp 和订阅端口 2096/tcp）由管理员用 `vps-hardening ports --add` 开放，并从新的 SSH 会话确认。本仓库不直接改 UFW 规则，不使用 3X-UI 的防火墙菜单和 BBR 菜单。按 D21，本仓库只开放 443/tcp。
- 80/tcp 不开放。证书用 Cloudflare API Token 走 DNS-01 签发；Token 会保存在 VPS 上，只授予签发证书所需的最小权限，例如只能编辑单个 Zone 的 DNS。按 D21，本仓库不在 VPS 上签发证书，也不保存 API Token：订阅经 Cloudflare Tunnel 发布，HTTPS 由 Cloudflare 边缘提供。
- Xray 从 v26.9.8 起只接受提供 X25519MLKEM768 密钥交换的 REALITY 客户端（v3.11.0 自带 v26.10.21），客户端要先开启 ML-KEM，例如 Mihomo 设 `support-x25519mlkem768: true`。

## 下一步

v1.3（需求 U11、D21）关闭 OQ-2，选定订阅与节点去同址的机制，已批准：3X-UI 的订阅只监听回环地址，经 Cloudflare Tunnel 以 HTTPS 发布；节点地址显式用 VPS 的公网 IP；2096/tcp 不开放；VPS 上不签发证书、不保存 Cloudflare API Token，只保存 Tunnel 的令牌；cloudflared 固定版本、不自动更新。用户接受 Cloudflare 看到订阅内容，VPS 的 IP 基本固定。评估见需求第 11.6 节。

v1.2（需求 U10、D18、D19、D20）在 v1.1 的基础上做两件事：按研究结论处理订阅与节点同址削弱伪装的问题（只定原则——节点优先用纯 IP、不挂证书、地址形式在方案设计中确定，订阅不与节点共用同一公网 IP，重开 OQ-2，机制留到方案设计），并按 CodeRabbit 对 v1.1 的三条意见修改（第 1 节范围、第 11.5 节和 FR-02 默认排除共享 CDN 的 target、FR-02 验收补用例），已批准。需求规格说明 v1.1 已批准：v1.0 的内容与 v0.4 草案相同（需求 U8、D16），v1.1 按 CodeRabbit 的意见修改了三处（需求 U9、D17）。v0.3 按需求 U6 决定了全部待决事项（v0.2 的其余内容已无异议）：

- 3X-UI 改用 v3.11.0（D10，第 11.3 节）；
- 先调优、再安装 3X-UI，顺序不变（D11，第 11.4 节）；
- 交付形态为首次部署脚本加只读检查：脚本只在全新安装的 3X-UI 上写入设置，之后的变更在面板中进行（D12，第 11.1 节）；
- 分流规则以 Loyalsoldier/clash-rules 的白名单模式为基础，规则集用 MetaCubeX/meta-rules-dat 的 mrs 格式（D13，第 11.2 节）。

v0.4 按需求 U7 增加：

- 入站的备注以国旗开头，例如 `🇺🇸 LA-Reality`（D14）；
- 伪装目标仍用第三方站点，在部署所用的 VPS 上按标准选择；未认证的连接只能到达伪装目标本身；不改为以自己的域名为目标（D15，第 11.5 节）。

[方案设计](docs/solution-design.md) v1.0 已批准（需求 U12～U14、D22）：Bash 工具 `vps-proxy-setup`（`deploy`、`check`、`target-check`），经回环地址上的 3X-UI API 写入设置，检查只读；REALITY 的 target 指向 Xray 自己的本机转发入站，它的目的地址是占位的回环 IP，只有嗅探到 target 的 SNI 才改写并转发，不带 SNI 的连接不转发；服务端屏蔽经 REALITY 入站的回国流量；订阅经远程管理的 Cloudflare Tunnel 发布，cloudflared 用固定的程序文件和本仓库的服务单元，以动态用户运行。之后是验证计划、详细设计和实现。测试沿用 vps-hardening 的方式：CI 虚拟机，再加一台测试 VPS。

[验证计划](docs/verification-plan.md) v1.0 已批准（需求 U15、D23）：CI 虚拟机用 Debian 13 amd64，在客体内用两个网络命名空间分别放 Mihomo 客户端和 target 替身，FR-02 的负面用例在转发入站的外连侧取三处证据；真实的 Tunnel、真实 target 和三个客户端在测试 VPS 上验收（要另行授权）。之后是详细设计和实现。

## 许可证

[MIT License](LICENSE)
