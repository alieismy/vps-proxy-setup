# 安全策略 / Security Policy

[中文](#中文) | [English](#english)

## 中文

### 支持的版本

本仓库还没有发行版。在首个发行版发布之前，安全修复直接进入 `master` 分支的当前代码；发布之后，本节改为说明哪些发行版接收安全修复。

### 报告漏洞

请不要在公开的 Issue 或拉取请求中报告漏洞。请使用 GitHub 的私密漏洞报告：打开 [Report a vulnerability](https://github.com/alieismy/vps-proxy-setup/security/advisories/new) 填写。报告不公开，只有仓库维护者和维护者加入这份报告的协作者能看到。中文或英文均可。

报告请尽量包含：

- 受影响的提交（`git rev-parse HEAD`）或版本（`vps-proxy-setup --version`），以及发行版；
- 问题和影响，例如面板或订阅在回环地址以外可以访问、秘密出现在日志或 `check` 的输出中、未认证的连接经 REALITY 入站到达伪装目标以外的地方、安装脚本或 3X-UI、cloudflared 的摘要校验被绕过；
- 复现步骤或概念验证；
- 已知的缓解办法。

请不要在报告中附上私钥、面板的用户名和密码、Cloudflare Tunnel 的令牌、REALITY 的私钥、使用者的 UUID 和订阅地址、真实的 IP 和域名，必要的日志请先脱敏。

维护者会在私密报告中确认问题、沟通进展；确认的漏洞在修复合并（有发行版之后为修复版本发布）后，通过 GitHub 安全公告公开。

### 范围

范围内：本仓库的代码（`bin/`、`lib/`、`install.sh`），以及之后的发行版资产。

范围外：

- 3X-UI、Xray、cloudflared、Mihomo 等上游组件自身的漏洞，请报告给相应的项目；
- SSH、UFW、Fail2ban 和自动安全更新由 vps-hardening 负责，这些方面的问题请按 [vps-hardening 的安全策略](https://github.com/alieismy/vps-hardening/blob/master/SECURITY.md)报告；
- 需要事先取得目标主机 root 权限才能利用的问题：本工具以 root 运行，不防范同一主机上的 root；
- 需求中已经接受的风险，例如 Cloudflare 在边缘终结 HTTPS，能看到订阅的明文内容（[需求](docs/requirements.md) D21、R-17）；
- [需求第 8 节](docs/requirements.md#8-范围外p3)明确不做的事项，以及[详细设计第 11 节](docs/detailed-design.md#11-已知限制)已记录的已知限制，除非你发现了新的利用方式。

## English

### Supported versions

This repository has no release yet. Until the first release, security fixes go directly into the current code on the `master` branch; after it, this section will state which releases receive security fixes.

### Reporting a vulnerability

Do not report vulnerabilities in public issues or pull requests. Use GitHub private vulnerability reporting: open [Report a vulnerability](https://github.com/alieismy/vps-proxy-setup/security/advisories/new) and fill in the form. The report is not public: only the repository maintainers and any collaborators they add to the report can see it. Reports in English or Chinese are welcome.

Please include, where possible:

- the affected commit (`git rev-parse HEAD`) or version (`vps-proxy-setup --version`), and the distribution;
- the problem and its impact, for example the panel or the subscriptions being reachable beyond the loopback address, secrets appearing in logs or in the output of `check`, unauthenticated connections reaching anything other than the camouflage target through the REALITY inbound, or bypassing the digest checks of the installer, 3X-UI or cloudflared;
- steps to reproduce or a proof of concept;
- any known mitigation.

Do not attach private keys, panel user names and passwords, Cloudflare Tunnel tokens, REALITY private keys, users' UUIDs and subscription URLs, or real IP addresses and domains; redact logs before sharing them.

The maintainers will confirm the issue and share progress in the private report. Confirmed vulnerabilities are disclosed through a GitHub security advisory after the fix is merged (once there are releases, after the fixed release is published).

### Scope

In scope: the code in this repository (`bin/`, `lib/`, `install.sh`) and future release assets.

Out of scope:

- vulnerabilities in upstream components such as 3X-UI, Xray, cloudflared or Mihomo; report them to those projects;
- SSH, UFW, Fail2ban and automatic security updates, which vps-hardening is responsible for; report issues there as described in [vps-hardening's security policy](https://github.com/alieismy/vps-hardening/blob/master/SECURITY.md);
- issues that require root on the target host beforehand: the tool runs as root and does not defend against root on the same host;
- risks the requirements have accepted, for example that Cloudflare terminates HTTPS at its edge and can see the subscription content in plain text ([requirements](docs/requirements.md) D21, R-17);
- what [requirements §8](docs/requirements.md#8-范围外p3) explicitly excludes, and the known limitations recorded in [detailed design §11](docs/detailed-design.md#11-已知限制), unless you have found a new way to exploit them.
