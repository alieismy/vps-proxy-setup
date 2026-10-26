# vps-proxy-setup

Proxy service setup on a hardened Debian/Ubuntu VPS, using 3X-UI as the example. **Status: requirements stage; nothing to install yet.**

在已经用 [vps-hardening](https://github.com/alieismy/vps-hardening) 加固的 Debian/Ubuntu VPS 上搭建代理服务，以 3X-UI 为例。

**当前状态：需求阶段，还没有可用的脚本或发行版。**

## 与另外两个仓库的关系

| 仓库 | 用途 |
|---|---|
| [vps-tuning](https://github.com/alieismy/vps-tuning) | 网络调优、诊断与测量 |
| [vps-hardening](https://github.com/alieismy/vps-hardening) | 基础安全加固：SSH 只用密钥、UFW、Fail2ban、自动安全更新 |
| vps-proxy-setup（本仓库） | 安装和配置 3X-UI：代理入站、面板、证书、订阅 |

建议的执行顺序沿用 vps-hardening 的需求（D27、D41、D42）：

1. 更新系统、安装基础工具并重启；
2. 加固并确认，这时 UFW 只放行 22/tcp；
3. 调优：应用 → 重启 → 验证；
4. 安装并配置 3X-UI（本仓库），再用 `vps-hardening ports` 开放它的端口并确认；
5. 调优仓库的严格验证；
6. 重启后复核。

## 已经约定的边界

以下各条来自 vps-hardening 已批准的需求（[第 7.2 节](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md#72-与-vps-proxy-setup-的约定3x-ui-v3102)、D14、D16、D32），本仓库的需求以它们为前提：

- 3X-UI 安装时带版本参数 `v3.10.2`，运行前按固定的摘要校验 `install.sh`。
- 安装时设 `XUI_ENABLE_FAIL2BAN=false`，不启用 IP Limit；Fail2ban 由 vps-hardening 管理。
- 面板端口用加固时记录的值（默认 2053），通过 `XUI_PANEL_PORT` 传入。安装后执行 `x-ui setting -listenIP 127.0.0.1` 并重启 x-ui，使面板只监听回环地址，只经 SSH 隧道访问。
- 公开端口（例如 443/tcp 和订阅端口 2096/tcp）由管理员用 `vps-hardening ports --add` 开放，并从新的 SSH 会话确认。本仓库不直接改 UFW 规则，不使用 3X-UI 的防火墙菜单和 BBR 菜单。
- 80/tcp 不开放。证书用 Cloudflare API Token 走 DNS-01 签发；Token 会保存在 VPS 上，只授予签发证书所需的最小权限，例如只能编辑单个 Zone 的 DNS。
- v3.10.2 自带的 Xray 只接受提供 X25519MLKEM768 密钥交换的 REALITY 客户端，客户端要先开启 ML-KEM，例如 Mihomo 设 `support-x25519mlkem768: true`。

## 下一步

先写需求规格说明：目标与场景、入站类型、证书、订阅、面板访问、升级与回滚、验收方式。之后是方案设计、详细设计和实现。测试沿用 vps-hardening 的方式：CI 虚拟机，再加一台测试 VPS。

## 许可证

[MIT License](LICENSE)
