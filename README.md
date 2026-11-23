# VPS Proxy Setup

English | [简体中文](README.zh-CN.md)

[![static](https://github.com/alieismy/vps-proxy-setup/actions/workflows/static.yml/badge.svg?branch=master)](https://github.com/alieismy/vps-proxy-setup/actions/workflows/static.yml)
[![vm](https://github.com/alieismy/vps-proxy-setup/actions/workflows/vm.yml/badge.svg?branch=master)](https://github.com/alieismy/vps-proxy-setup/actions/workflows/vm.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Proxy service setup on a VPS that has been hardened with [vps-hardening](https://github.com/alieismy/vps-hardening) and tuned with [vps-tuning](https://github.com/alieismy/vps-tuning), using 3X-UI as the example: one VLESS + REALITY node for 5 to 8 people, a panel reachable only through an SSH tunnel, and subscriptions published over HTTPS through Cloudflare Tunnel.

> This README is translated from the [Chinese README](README.zh-CN.md). The documents under `docs/` and the tool's own messages are in Chinese. Where the two READMEs differ, the Chinese README prevails.

**Status: in development. There is no release yet, so there is nothing to install.** M1 is implemented and passes the VM tests: `deploy` runs the preflight only, plus `check`, `target-check` and `install.sh`. Deployment comes in M2; see [Project status](#project-status).

## Planned features

Listed from the [requirements specification](docs/requirements.md). M1 implements only the preflight, the read-only check and the installer; the rest comes in later milestones.

- **3X-UI**: installed at a pinned version with its digest verified; the panel listens on the loopback address only and is reached through an SSH tunnel (FR-01).
- **First-deployment script**: writes the inbound, users, subscription settings and routing rules on a freshly installed 3X-UI; later changes are made in the panel (FR-12).
- **Inbound**: one VLESS + REALITY inbound on 443/tcp (FR-02).
- **Users**: one client per person (UUID and subscription ID), each of which can be disabled or revoked on its own (FR-03).
- **Subscriptions**: 3X-UI's subscription service listens on the loopback address only and is published over HTTPS through Cloudflare Tunnel, serving Mihomo configurations; cloudflared is pinned and does not update itself (FR-04, FR-05).
- **Read-only check**: `check` verifies 3X-UI, the subscriptions, the listeners, cloudflared and the hardening state item by item (FR-07).
- **Backup, restore and migration; upgrade and rollback** (FR-09, FR-10, P1).
- **Dual-stack egress**: on a dual-stack VPS, connections to OpenAI and Anthropic leave over IPv6 (FR-13, P1).

## Scope

| Item | Description |
|---|---|
| Platform | Debian 13 x86_64 (NFR-03); Debian 12 and Ubuntu 24.04 are P2. The CI virtual machines run Debian 13 amd64 |
| Prerequisites | Hardened and confirmed with vps-hardening, then tuned with vps-tuning (versions in A-1 of [requirements §9](docs/requirements.md#9-假设)) |
| Hosts | First deployment happens on new hosts only; nothing is installed or written on an existing production 3X-UI host |
| Clients | Clients built on the Mihomo core (Sparkle, FlClash, Clash Verge Rev), with ML-KEM turned on; see [Agreed boundaries](#agreed-boundaries) |
| Out of scope | See [requirements §8](docs/requirements.md#8-范围外p3) |

## Commands

There is no release yet; the table describes M1. All three commands run as root.

| Command | What it does |
|---|---|
| `vps-proxy-setup deploy [--input <file>] [--migrate]` | First deployment, run in an interactive terminal. The current version runs the preflight only and changes nothing on the host |
| `vps-proxy-setup check` | Read-only check of 3X-UI, the subscriptions, the listeners, cloudflared and the hardening state, item by item |
| `vps-proxy-setup target-check <host> [--probe-host <host>]` | Checks a candidate REALITY target from this host |
| `install.sh` | Release installer: places the files after verifying them against `SHA256SUMS` and runs none of the commands above. Publishing and verification from the public URLs come in M4 |

Exit codes: 0 all passed; 1 non-compliant items or refused; 2 usage or input error; 3 internal error. The command contract is in [detailed design §2](docs/detailed-design.md#2-命令契约).

## Companion repositories and order

The three repositories are used in the order of the table below: harden first, then tune, then set up the proxy (vps-hardening requirements D27; this repository's requirements D11, assessed in [requirements §11.4](docs/requirements.md#114-执行顺序评估先调优还是先安装-3x-ui)).

| Order | Repository | Purpose | Status |
|---|---|---|---|
| 1 | [vps-hardening](https://github.com/alieismy/vps-hardening) | Baseline security hardening: key-only SSH, UFW, Fail2ban, automatic security updates | Release v0.2.1 |
| 2 | [vps-tuning](https://github.com/alieismy/vps-tuning) | Network tuning, diagnostics and measurement | Pre-release v0.2.0-rc.4 |
| 3 | vps-proxy-setup (this repository) | Installs and configures 3X-UI: the proxy inbound, the panel and the subscriptions (published through Cloudflare Tunnel) | In development, no release yet |

Full flow (vps-hardening requirements D27, D41, D42):

1. **Preparation**: update the system, install basic tools and reboot; done by the administrator;
2. **vps-hardening**: harden and confirm;
3. **vps-tuning**: tune (apply → reboot → verify);
4. **vps-proxy-setup** (this repository): install and configure 3X-UI and cloudflared; then open the node port with `vps-hardening ports --add 443/tcp` and confirm. Subscriptions are published through Cloudflare Tunnel, so no subscription port is opened (requirements D21, FR-06);
5. **Final checks**: vps-tuning's strict verification; after a reboot, check again with `vps-hardening verify`, the strict tuning verification and a proxy client connection.

Apply and reboot for tuning only after the hardening is confirmed: a reboot before confirmation automatically undoes the hardening.

## Agreed boundaries

The items below come from vps-hardening's approved requirements ([§7.2](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md#72-与-vps-proxy-setup-的约定3x-ui-v3102), D14, D16, D32), on which this repository's requirements are based. The 3X-UI version changes under this repository's requirements D10, and the public ports and certificates are narrowed under D21; both stay within the agreement:

- 3X-UI is installed with a version argument, and `install.sh` is verified against a pinned digest before it runs. vps-hardening agreed on `v3.10.2`; this repository uses `v3.11.0` instead, because the Xray bundled with v3.10.2 has been withdrawn. The `install.sh` of v3.11.0 is identical to that of v3.10.2, so the digest is unchanged.
- Installation sets `XUI_ENABLE_FAIL2BAN=false` and does not enable IP Limit; Fail2ban is managed by vps-hardening.
- The panel port is the value recorded at hardening (2053 by default), passed through `XUI_PANEL_PORT`. After installation, `x-ui setting -listenIP 127.0.0.1` and a restart of x-ui make the panel listen on the loopback address only, reachable only through an SSH tunnel.
- Public ports (for example 443/tcp and the subscription port 2096/tcp) are opened by the administrator with `vps-hardening ports --add` and confirmed from a new SSH session. This repository does not change UFW rules directly and does not use 3X-UI's firewall or BBR menus. Under D21, this repository opens only 443/tcp.
- 80/tcp is not opened. Certificates are issued through DNS-01 with a Cloudflare API Token; the token is stored on the VPS with only the permissions needed to issue certificates, for example editing the DNS of a single zone. Under D21, this repository neither issues certificates on the VPS nor stores an API Token: subscriptions are published through Cloudflare Tunnel, and HTTPS is provided by Cloudflare's edge.
- Since v26.9.8, Xray accepts only REALITY clients that offer the X25519MLKEM768 key exchange (v3.11.0 bundles v26.10.21), so clients must turn on ML-KEM first; for example, set `support-x25519mlkem768: true` in Mihomo.

## Project status

- **Documents**: requirements v1.6, solution design v1.4 and verification plan v1.3 are approved; detailed design v1.1 (v1.0 approved, plus a confirmed read rule from the M1 evidence). The contracts are implemented and verified milestone by milestone.
- **Implementation**: milestones M1 to M5. M1 is implemented and passes in the CI virtual machines; M2 (first deployment) is not finished; there is no release yet.
- **Acceptance**: the real Tunnel, a real target and the three clients are to be accepted on a test VPS, which needs separate authorization and has not been done.

The decisions and approvals are recorded in [requirements §2](docs/requirements.md#2-需求来源与已确认决定); each document's version and review status are in the table at its top.

## Documentation

The documents are in Chinese.

| Document | Contents |
|---|---|
| [Requirements specification](docs/requirements.md) | Functional requirements (FR), non-functional requirements, agreements with the other repositories, and the record of user statements (U) and confirmed decisions (D) |
| [Solution design](docs/solution-design.md) | Components, boundaries, flows and key mechanisms |
| [Detailed design](docs/detailed-design.md) | Command contract, check items, module layout, test framework, run evidence and known limitations |
| [Verification plan](docs/verification-plan.md) | What is verified, where, and how a pass is judged (test items are numbered VT) |

## Feedback

Report bugs and suggestions in [GitHub Issues](https://github.com/alieismy/vps-proxy-setup/issues). Do not report security vulnerabilities in Issues; report them privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT License](LICENSE)
