# VPS Proxy Setup

[English](README.md) | 简体中文

[![static](https://github.com/alieismy/vps-proxy-setup/actions/workflows/static.yml/badge.svg?branch=master)](https://github.com/alieismy/vps-proxy-setup/actions/workflows/static.yml)
[![vm](https://github.com/alieismy/vps-proxy-setup/actions/workflows/vm.yml/badge.svg?branch=master)](https://github.com/alieismy/vps-proxy-setup/actions/workflows/vm.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

在已经用 [vps-hardening](https://github.com/alieismy/vps-hardening) 加固、按 [vps-tuning](https://github.com/alieismy/vps-tuning) 调优的 VPS 上搭建代理服务，以 3X-UI 为例：一个 VLESS + REALITY 节点，供 5～8 人使用；面板只经 SSH 隧道访问，订阅经 Cloudflare Tunnel 以 HTTPS 发布。

**当前状态：开发中，还没有发行版，因此还不能安装。** M1 已实现并在虚拟机测试中通过：`deploy` 只做预检，另有 `check`、`target-check` 和 `install.sh`；部署从 M2 开始，见[项目状态](#项目状态)。

## 计划的功能

以下按[需求规格说明](docs/requirements.md)列出，M1 只实现了预检、只读检查和安装脚本，其余在之后的里程碑实现。

- **3X-UI**：按固定版本安装并校验摘要；面板只监听回环地址，只经 SSH 隧道访问（FR-01）。
- **首次部署脚本**：在全新安装的 3X-UI 上写入入站、使用者、订阅设置和分流规则；之后的变更在面板中进行（FR-12）。
- **入站**：一个 VLESS + REALITY 入站，443/tcp（FR-02）。
- **使用者**：每人一个客户端（UUID 和订阅 ID），可以单独停用和撤销（FR-03）。
- **订阅**：3X-UI 的订阅只监听回环地址，经 Cloudflare Tunnel 以 HTTPS 发布，输出 Mihomo 配置；cloudflared 固定版本、不自动更新（FR-04、FR-05）。
- **只读检查**：`check` 逐项核对 3X-UI、订阅、监听、cloudflared 和加固状态（FR-07）。
- **备份、恢复与迁移，升级与回退**（FR-09、FR-10，P1）。
- **双栈出站**：双栈 VPS 上，OpenAI、Anthropic 的连接经 IPv6 出站（FR-13，P1）。

## 适用范围

| 项目 | 说明 |
|---|---|
| 平台 | Debian 13 x86_64（NFR-03）；Debian 12 和 Ubuntu 24.04 为 P2。CI 虚拟机用 Debian 13 amd64 |
| 前提 | 已按 vps-hardening 加固并确认，并按 vps-tuning 调优（版本见[需求第 9 节](docs/requirements.md#9-假设)的 A-1） |
| 主机 | 首次部署只在新机上进行，不在已有的现网 3X-UI 主机上安装或写入 |
| 客户端 | 基于 Mihomo 内核的客户端（Sparkle、FlClash、Clash Verge Rev），要开启 ML-KEM，见[已经约定的边界](#已经约定的边界) |
| 范围外 | 见[需求第 8 节](docs/requirements.md#8-范围外p3) |

## 命令

还没有发行版，下表是 M1 的现状。三个命令都要以 root 执行。

| 命令 | 作用 |
|---|---|
| `vps-proxy-setup deploy [--input <文件>] [--migrate]` | 首次部署，须在交互终端中执行。当前版本只执行预检，不改动主机 |
| `vps-proxy-setup check` | 只读检查：逐项核对 3X-UI、订阅、监听、cloudflared 和加固状态 |
| `vps-proxy-setup target-check <主机名> [--probe-host <主机名>]` | 在本机核实候选的 REALITY target |
| `install.sh` | 发行版安装脚本：按 `SHA256SUMS` 校验后放置文件，不执行上面的命令。发布和从公开地址的回验在 M4 |

退出码：0 全部通过；1 有不符合项或被拒绝；2 用法或输入错误；3 内部错误。命令契约见[详细设计第 2 节](docs/detailed-design.md#2-命令契约)。

## 配套仓库与执行顺序

三个仓库按下表的顺序使用：先加固，再调优，最后搭建代理（vps-hardening 需求 D27；本仓库需求 D11，评估见[需求第 11.4 节](docs/requirements.md#114-执行顺序评估先调优还是先安装-3x-ui)）。

| 顺序 | 仓库 | 用途 |
|---|---|---|
| 1 | [vps-hardening](https://github.com/alieismy/vps-hardening) | 基础安全加固：SSH 只用密钥、UFW、Fail2ban、自动安全更新 |
| 2 | [vps-tuning](https://github.com/alieismy/vps-tuning) | 网络调优、诊断与测量 |
| 3 | vps-proxy-setup（本仓库） | 安装和配置 3X-UI：代理入站、面板、订阅（经 Cloudflare Tunnel 发布） |

完整流程（vps-hardening 需求 D27、D41、D42）：

1. **准备**：更新系统、安装基础工具并重启，由管理员执行；
2. **vps-hardening**：加固并确认；
3. **vps-tuning**：调优（应用 → 重启 → 验证）；
4. **vps-proxy-setup**（本仓库）：安装并配置 3X-UI 和 cloudflared；完成之后用 `vps-hardening ports --add 443/tcp` 开放节点端口并确认。订阅经 Cloudflare Tunnel 发布，不开放订阅端口（需求 D21、FR-06）；
5. **收尾验证**：vps-tuning 的严格验证；重启后再用 `vps-hardening verify`、调优的严格验证和代理客户端连接复核。

调优的应用和重启要在加固确认之后进行，确认前重启会自动撤销加固。

## 已经约定的边界

以下各条来自 vps-hardening 已批准的需求（[第 7.2 节](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md#72-与-vps-proxy-setup-的约定3x-ui-v3102)、D14、D16、D32），本仓库的需求以它们为前提；3X-UI 的版本按本仓库需求 D10 改变，公开端口和证书按 D21 收窄，仍在约定的范围之内：

- 3X-UI 安装时带版本参数，运行前按固定的摘要校验 `install.sh`。vps-hardening 约定的是 `v3.10.2`；本仓库改用 `v3.11.0`，因为 v3.10.2 自带的 Xray 已被撤版。v3.11.0 的 `install.sh` 与 v3.10.2 的相同，摘要不变。
- 安装时设 `XUI_ENABLE_FAIL2BAN=false`，不启用 IP Limit；Fail2ban 由 vps-hardening 管理。
- 面板端口用加固时记录的值（默认 2053），通过 `XUI_PANEL_PORT` 传入。安装后执行 `x-ui setting -listenIP 127.0.0.1` 并重启 x-ui，使面板只监听回环地址，只经 SSH 隧道访问。
- 公开端口（例如 443/tcp 和订阅端口 2096/tcp）由管理员用 `vps-hardening ports --add` 开放，并从新的 SSH 会话确认。本仓库不直接改 UFW 规则，不使用 3X-UI 的防火墙菜单和 BBR 菜单。按 D21，本仓库只开放 443/tcp。
- 80/tcp 不开放。证书用 Cloudflare API Token 走 DNS-01 签发；Token 会保存在 VPS 上，只授予签发证书所需的最小权限，例如只能编辑单个 Zone 的 DNS。按 D21，本仓库不在 VPS 上签发证书，也不保存 API Token：订阅经 Cloudflare Tunnel 发布，HTTPS 由 Cloudflare 边缘提供。
- Xray 从 v26.9.8 起只接受提供 X25519MLKEM768 密钥交换的 REALITY 客户端（v3.11.0 自带 v26.10.21），客户端要先开启 ML-KEM，例如 Mihomo 设 `support-x25519mlkem768: true`。

## 项目状态

- **文档**：需求规格说明 v1.6、方案设计 v1.4、验证计划 v1.3 已批准；详细设计 v1.1（v1.0 已批准，按 M1 的运行证据补的一行读取前提已确认），各契约按里程碑实现和验证。
- **实现**：按 M1～M5 推进。M1 已实现，在 CI 虚拟机中通过；M2（首次部署）尚未完成；还没有发行版。
- **验收**：真实的 Tunnel、真实 target 和三个客户端在测试 VPS 上验收，要另行授权，尚未进行。

各项决定和批准的经过记录在[需求规格说明第 2 节](docs/requirements.md#2-需求来源与已确认决定)，每份文档的版本和评审状态见其开头的表格。

## 文档

| 文档 | 内容 |
|---|---|
| [需求规格说明](docs/requirements.md) | 功能需求（FR）、非功能需求、与其他仓库的约定，以及用户原话（U）和已确认决定（D）的记录 |
| [方案设计](docs/solution-design.md) | 组件、边界、流程和关键机制 |
| [详细设计](docs/detailed-design.md) | 命令契约、检查项、模块划分、测试框架、运行证据和已知限制 |
| [验证计划](docs/verification-plan.md) | 验证什么、在哪里验证、怎样判定通过（测试项编号为 VT） |

## 反馈

问题和建议请提交到 [GitHub Issues](https://github.com/alieismy/vps-proxy-setup/issues)。安全漏洞请不要提交到 Issues，按 [SECURITY.md](SECURITY.md) 私密报告。

## 许可证

[MIT License](LICENSE)
