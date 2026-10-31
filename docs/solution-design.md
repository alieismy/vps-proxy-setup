# VPS Proxy Setup 方案设计

| 项目 | 内容 |
|---|---|
| 状态 | v1.4 已批准：用户 2026-10-31 决定 OD-5（需求 U21、D32）：FR-13 用设了 `ForceIPv6v4` 的新增出站实现，路由保持 `AsIs`，不采用配置样例，不固定 IPv6 源地址（第 7.4、10、11 节）。v1.3 已批准：按需求 v1.6（U20、D31）做的一致性修改：FR-13 改为 IPv6 失败时不改走 IPv4，第 7.4 节和 OD-5 的建议随之改写，并列出用户提供的配置样例的做法作为对照。OD-5 仍待决，其中的建议不是决定。v1.2 已批准：按需求 v1.5（U19、D29）做的一致性修改，同步 FR-13 已定的取值：第 7.4 节和 OD-5 的建议改为在 IPv6 连接失败时能改走 IPv4 的机制，是否启用由部署输入决定。OD-5 仍待决，其中的建议不是决定。v1.1 已批准：用户 2026-10-31 批准（需求 U17、D25），按需求 v1.4 修订。第 7.8 节的迁移和恢复前提（需求 D24）；迁移默认沿用同一个 Tunnel 的令牌，怀疑入侵或需要隔离旧连接器时轮换（第 7.8、7.9 节，需求 D26）；FR-13 的机制列为 OD-5，在 M2 实现之前决定（第 7.4、10、11 节，需求 D27）；shortId 改由部署脚本在 VPS 上生成（第 7.3、7.4、7.9 节，需求 D28）。v1.0 的架构选择不变。v1.0 已批准：用户于 2026-10-29 评审通过（需求 U14、D22），第 11 节的 OD-1～OD-4 都已决定。按需求 v1.3 起草，确定实现形态、写入方式、REALITY 的转发限制、订阅与 Tunnel、只读检查、迁移与升级，以及需求中留给方案设计的各项取值。按 CodeRabbit 对草案的意见，转发入站的目的地址改为占位的回环 IP，使不带 SNI 的连接不被转发（第 4.4、7.4 节）。按一份外部评审的意见（用户 2026-10-29 确认，需求 U12、U13）修订：检查不再调用 `x-ui setting`；转发入站只嗅探 TLS，并写明嗅探失败的代价和相应用例；写明安装核对的残余风险、虚拟机与真实 Tunnel 的判定边界、`check` 结论的范围。OD-2、OD-4 已决定（第 11 节） |
| 日期 | 2026-10-31（v1.1～v1.3 同日，v1.0 为 2026-10-29） |
| 本次修订 | 2026-10-31，v1.4：按需求 U21、D32 关闭 OD-5；v1.3（同日）：按需求 U20、D31 改写 FR-13 的机制建议；v1.2（同日）：按需求 U19、D29 同步 FR-13 的取值和 OD-5 的建议；v1.1（同日）：按需求 U16、D24 澄清第 7.8 节的迁移和恢复前提，按需求 U17（D25～D28）修改令牌、shortId 和双栈出站的相关条目；v1.0 的架构选择不变 |
| 上游 | [需求规格说明 v1.6](requirements.md)（已批准）；[vps-hardening 方案设计](https://github.com/alieismy/vps-hardening/blob/master/docs/solution-design.md)的形态和惯例 |
| 下游 | [验证计划](verification-plan.md)（v1.3 已批准，补入 FR-13 的用例，含 UDP 的判定）；[详细设计](detailed-design.md)（v1.0 已批准，M1 及后续阶段的接口、生命周期和测试契约）；实现（还没有开始） |
| 深度 | 高层设计：确定组件、边界、流程和关键机制，不含代码和操作手册 |

**证据状态。** 本文只是设计，仓库里还没有实现，也没有任何运行证据。标"已核实"的，是 2026-10-29 对照 3X-UI v3.11.0（及其自带的 Xray v26.10.21）、cloudflared 2026.10.5、vps-hardening `v0.1.1` 的源码或文档核实的结果，出处见第 13 节和需求第 10.1 节；标"推断"的，要在虚拟机测试或测试 VPS 上证实。

## 1. 背景与目标

需求 v1.6 已经确定要做什么，本文回答怎么做：

- 首次部署脚本和只读检查用什么形态实现（D12）；
- 部署脚本怎样把入站、使用者、订阅设置和分流规则写入全新的 3X-UI（FR-12）；
- 3X-UI 的安装文件怎样核对（FR-01）；
- 怎样做到"未认证的连接只能到达伪装目标本身"（FR-02）；
- 订阅怎样经 Cloudflare Tunnel 发布，cloudflared 怎样安装和运行，Tunnel 的路由放在哪里管理（FR-04、FR-05）；
- 只读检查读什么、怎样分级（FR-07）；
- 备份、迁移、升级和回退由脚本还是文档步骤执行（FR-09、FR-10）；
- 需求中留给方案设计的取值：传输方式和 flow、fingerprint、节点地址用 IPv4 还是 IPv6、订阅地址的显示、更新间隔等。

## 2. 需求摘要

驱动设计的需求：

| 驱动因素 | 需求 | 对设计的影响 |
|---|---|---|
| 只在全新安装上写入一次 | D12、FR-12 | 预检和写入前核对都要能可靠地判定"全新"；之后的变更在面板中进行，脚本不提供合并 |
| 节点 IP 上不暴露自己的身份 | D18、D21、R-15 | 订阅只监听回环地址，公网地址上只有 22 和 443；节点地址显式填 IP |
| 未认证的连接只能到达 target | FR-02、R-13 | REALITY 的 target 不能直接指向外部站点，要经过一个只放行 target SNI 的本机转发 |
| 固定版本 | NFR-05、FR-01、FR-05 | 3X-UI 和 cloudflared 都按固定的摘要核对，不自动更新 |
| 秘密 | NFR-01、FR-12、R-16 | 3X-UI 的安装输出含面板凭据和 API token（已核实），不能进日志；部署用的 API token 用完即删 |
| 检查只读 | FR-07、NFR-07 | 检查不持有可写的凭据：不用 API，读数据库和本机接口 |
| 与另外两个仓库共存 | NFR-04、需求第 7 节 | 不改 UFW 规则，只用 `vps-hardening ports`；不碰 vps-tuning 的 drop-in |

## 3. 约束

| 类型 | 内容 | 来源 |
|---|---|---|
| 已批准 | Debian 13 x86_64，systemd；Debian 12 和 Ubuntu 24.04 为 P2 | NFR-03 |
| 已批准 | 3X-UI v3.11.0，SQLite 数据库；面板只监听 127.0.0.1 | D10、需求第 2.2 节 |
| 已批准 | 订阅经 Cloudflare Tunnel 发布；VPS 上不签发证书、不保存 Cloudflare API Token | D21 |
| 已批准 | 公开端口只经 `vps-hardening ports` 开放；它只接受"端口/协议"，不能限制来源地址 | 需求第 7 节、第 10.1 节 |
| 已批准 | 交付形态：首次部署脚本加只读检查 | D12 |
| 沿用的惯例（可以改） | vps-hardening 和 vps-tuning 用 Bash + ShellCheck、Release 资产 + 校验安装器、QEMU 虚拟机 CI；检查结果分 PASS/WARN/FAIL/SKIP，退出码 0 通过、1 不符合、2 用法错误、3 内部错误 | 两个仓库 |
| 资源 | 一人维护三个仓库 | vps-hardening R-9 |

## 4. 候选方案

### 4.1 实现形态

| 候选 | 说明 | 评价 |
|---|---|---|
| A. Bash 工具（推荐） | 一个入口命令 `vps-proxy-setup`，子命令 `deploy`、`check`、`target-check` | 与另外两个仓库同栈，复用 ShellCheck、安装器和虚拟机 CI。调用 3X-UI 的 API 要处理 JSON：用 Debian 官方仓库的 `jq` 构造和解析，不拼接字符串 |
| B. Python 3 工具 | 命令面相同 | JSON 和错误处理更稳；三个仓库出现两套语言和测试栈 |
| C. 只有文档加检查脚本 | v0.2 的建议 | D12 已经改为首次部署脚本，不再考虑 |

### 4.2 写入 3X-UI 设置的方式（FR-12）

| 候选 | 说明 | 评价 |
|---|---|---|
| A. 回环地址上的 REST API（推荐） | 用安装时生成的 admin 范围 API token，调用 `/panel/api/inbounds/add`、`/panel/api/setting/update`、`/panel/api/xray/update` 等接口（已核实存在于 v3.11.0 的 OpenAPI 文档） | 经过 3X-UI 自己的校验和默认值处理，写入后与在面板中操作的结果一致。接口随版本变化，版本固定（D10）并在 CI 中每次验证 |
| B. 直接写 SQLite | 用 `sqlite3` 插入记录 | 绕过 3X-UI 的校验，字段的默认值和关联表（客户端流量统计等）要自己维护；表结构是内部实现。不采用 |
| C. 只用 `x-ui setting` | 命令行只能改面板端口、凭据、路径、监听地址和 token（已核实） | 覆盖不了入站、使用者和订阅设置。只在部署时用于 `-listenIP`。不能用来读取：v3.11.0 中除 `-reset` 外，每次执行都先初始化数据库——以读写方式打开、收紧文件权限、迁移表结构、写入种子数据、删除数据库目录下以 `.x-ui-backup-` 开头的目录（已核实，第 13 节） |

token 的来源：v3.11.0 的 `install.sh` 在全新安装时生成一个 admin 范围的 token，连同面板凭据写入只有 root 可读的 `/etc/x-ui/install-result.env`（已核实）。token 在数据库中只存 SHA-256 摘要，可以经 API 删除（已核实）。部署脚本读取它，写完设置之后删除这个 token 和这个文件，面板凭据转写到交给管理员的文件中（第 7.9 节）。

### 4.3 3X-UI 安装文件的核对（FR-01）

| 候选 | 评价 |
|---|---|
| A. 安装前预取比对，安装后再核对所装的文件（推荐） | 预取的发布包、`x-ui.sh` 和服务单元文件按固定的摘要比对，不符时在任何改动之前停止；`install.sh` 自己下载之后，再核对实际安装的文件。两次核对之间上游文件被替换时，第二次核对发现，在写入设置之前停止。第二次核对只能发现、不能阻止：在它之前，`install.sh` 已经以 root 执行过所装的 `x-ui`（设置凭据）并启动了服务（已核实）。残余风险是两次下载之间上游文件被替换，tag 指向固定的提交、摘要固定，窗口很小；要消除须用 C（SR-9） |
| B. 只在安装后核对 | 发现不符时已经安装，要按清理步骤处理 |
| C. 脚本自己下载、校验，再交给安装 | 要改变 `install.sh` 的下载行为。v3.11.0 是否支持从本地文件安装，没有核实；不依赖它 |

`install.sh` 以非交互方式运行（`XUI_NONINTERACTIVE=1`，并传入 `XUI_PANEL_PORT`、`XUI_ENABLE_FAIL2BAN=false`、`XUI_DB_TYPE=sqlite`、`XUI_SSL_MODE=none`）。非交互时 SSL 默认就是不配置，数据库默认是 SQLite（已核实），这里显式传入是为了不依赖默认值。它的输出含面板凭据、访问地址和 API token（已核实），部署脚本把输出存在只有 root 可读的临时文件中，失败时只显示去掉这些行之后的末尾部分。它还会访问几个第三方的查 IP 服务，只用来显示访问地址（已核实），不影响结果。

### 4.4 REALITY 未认证连接的转发限制（FR-02）

| 候选 | 说明 | 评价 |
|---|---|---|
| A. Xray 自己的本机转发入站（推荐） | REALITY 的 target 指向回环地址上的一个 `tunnel` 入站（即 dokodemo-door）。它的目的地址是占位的回环 IP、端口 443，开启 TLS 嗅探，用嗅探到的 SNI 改写目的地址（`destOverride` 只有 `tls`，不用 `routeOnly`）。路由规则：这个入站的目的域名等于 target 主机名时走 `direct`，其余（别的 SNI；没有 SNI 或不是 TLS、目的地址仍是占位 IP 的）走 `blocked` | 不增加组件，规则写在 3X-UI 的 Xray 配置模板中，面板中可以看到 |
| B. nginx stream 的 `ssl_preread` | 在回环地址上按 SNI 转发 | 多一个常驻组件和一套配置，功能与 A 相同 |
| C. 直接指向 target，只靠回落限速 | 3X-UI 的默认做法 | FR-02 不允许：限速不能代替 SNI 白名单 |

A 的机制：REALITY 对 SNI 不在 `serverNames` 中、或者认证失败的连接，原样转发到 target（需求第 10.1 节）。target 是本机转发入站时，只有 SNI 等于 target 的连接被继续转发；SNI 不在白名单中、不带 SNI 的 ClientHello 都在本机被丢弃，不会离开 VPS。这正是 FR-02 验收要在外连边界观测的行为。

转发入站的目的地址不能写成 target 的主机名、再用 `routeOnly` 只按嗅探结果路由：不带 SNI 的 ClientHello 嗅探失败，路由用的仍是入站配置的目的地址，其中的域名就是 target，`direct` 规则会匹配，连接被转发到 target，不符合 FR-02 的验收。所以目的地址用占位的回环 IP：只有嗅探到 SNI、目的地址被改写之后，连接才有域名可以匹配；没有 SNI 的连接目的地址仍是 IP，落到 `blocked`。嗅探、改写和取路由域名的这段逻辑已对照 Xray v26.10.21 的源码核实（第 13 节）；实际效果在 M2 的虚拟机测试中按 FR-02 的三个负面用例证实。`destOverride` 只能有 `tls`：如果也有 `http`，不是 TLS、但带 `Host: <target>` 的明文请求也会被改写成 target 并放行。

A 的代价：嗅探失败的连接一律落到 `blocked`，SNI 正确的也一样。Xray v26.10.21 的 TLS 嗅探只解析第一个 TLS 记录，得到两次"没有结论"或累计等满 200ms 就放弃（已核实，第 13 节）。所以 SNI 正确、但 ClientHello 拆成多个 TLS 记录的未认证连接会被关闭（读源码的推断，置信度高），分三段以上或慢速到达的也可能被关闭；而直接连 target 能正常握手。这是一个可区分的特征。不带 SNI、SNI 不对时与 target 表现不同，是 FR-02 白名单必然的代价；SNI 正确却被关闭不是。M2 用三个 SNI 正确的用例检验（第 8 节）：都被转发，保留 A；有被关闭的，要么接受并记入 SR-3，要么改用 B（nginx 怎样处理拆成多个记录的 ClientHello，没有核实）。

### 4.5 Tunnel 的路由管理与 cloudflared 的安装（FR-05）

路由放在哪里管理：

| 候选 | 说明 | 评价 |
|---|---|---|
| A. 在 Cloudflare 上管理（远程管理，推荐） | 管理员在 Cloudflare 控制台创建 Tunnel，添加订阅主机名到 `http://127.0.0.1:2096` 的公开主机名；VPS 上只有令牌 | 创建最简单，控制台同时创建 DNS 记录（推断，在 M3 中证实），与 FR-05 的"只保存令牌、`--token-file` 读取"一致。路由在 VPS 之外，偏差靠 FR-07 经本机 `/config` 接口发现（需求第 10.1 节） |
| B. 在 VPS 上的配置文件中管理（本地管理） | 用命令行创建 Tunnel，路由写在 VPS 上的配置文件中，由部署脚本写入 | 路由在本仓库的控制之下，控制台不能远程增加路由。代价是要在管理员自己的电脑上用 `cloudflared tunnel login` 取得账户范围的证书来创建 Tunnel，步骤多；控制台创建的 Tunnel 会忽略本地配置（Cloudflare 维护者在 cloudflared issue #933、#633 中的答复），两种方式不能混用 |

选 A。能在控制台增加路由的人已经能改这个 Zone 的 DNS，B 防住的场景很小；A 的偏差由 FR-07 检查发现。重新评估的条件：FR-07 发现过非预期的路由，或者控制台不再自动创建 DNS 记录。

cloudflared 怎样安装和运行：

| 候选 | 评价 |
|---|---|
| A. GitHub Release 的程序文件 + 固定的 SHA-256 + 本仓库的服务单元（推荐） | 安装到固定路径，摘要写在本仓库中（发布说明中的摘要只用来交叉核对，FR-05）；服务单元由本仓库提供，带 `--no-autoupdate`、`--token-file`，metrics 固定在 `127.0.0.1:20241`，不安装更新定时器 |
| B. Release 中的 `.deb` | 文件归属清晰；服务单元仍要自己提供，相比 A 没有实质收益 |
| C. `cloudflared service install --no-update-service` | 服务单元由上游生成，内容随版本变化，main 分支 2026-10-29 刚改过更新定时器（已核实）；不能加下面的权限限制 |
| D. Cloudflare 的 apt 软件源 | 版本随 `apt upgrade` 变化，不满足 NFR-05；多信任一个软件源 |

A 的服务单元以 systemd 的动态用户运行 cloudflared，令牌文件仍是 root 所有、0600，由 systemd 的 `LoadCredential` 交给服务。cloudflared 只发起出站连接、转发到回环地址，不需要 root（推断，在 M3 中证实；不可行时先改用固定的非特权系统用户，再考虑 root，令牌文件的要求不变）。这一项超出 FR-05 的字面要求，理由是 cloudflared 是唯一直接接收外部请求内容的新组件，降权可以缩小它被攻破时的影响。

### 4.6 只读检查的数据来源（FR-07）

| 候选 | 评价 |
|---|---|
| A. 只读打开 SQLite，加上文件和本机接口（推荐） | 用 Debian 官方仓库的 `sqlite3` 以只读方式读数据库；cloudflared 的 `/ready`、`/config` 在回环地址上（已核实）。检查不持有可写的凭据，也不调用 `x-ui setting`：它每次都先初始化数据库，不是只读的（第 4.2 节） |
| B. 调用 3X-UI 的 API | 读入站和设置要 admin 范围的 token（monitor 范围只能读状态和指标，已核实），检查就要长期持有一个可写的凭据。不采用 |

### 4.7 备份、迁移、升级和回退（FR-09、FR-10）

| 候选 | 评价 |
|---|---|
| A. 文档步骤，迁移时部署脚本只做预检和安装（推荐） | 这些操作不频繁（一台主机，IP 基本固定，A-7），每一步简单；迁移用 `deploy --migrate`（FR-12）安装相同版本的 3X-UI 和 cloudflared、不写设置，其余按文档。与 v0.2 的评估一致：省下的时间主要在迁移上，数据库备份已省下大部分 |
| B. 全部做成子命令 | 每个都要实现和测试失败路径，收益小 |

重新评估的条件沿用需求第 11.1 节：迁移超过每月一次、检查多次发现同一种手工失误，或者节点超过两台。

### 4.8 发布与安装

沿用 vps-hardening 的做法：GitHub Release 资产附带 `SHA256SUMS`，固定版本的安装器逐个校验，安装时不执行部署。理由与它的方案设计第 4.5 节相同。

## 5. 方案比较

实现形态和写入方式是影响全局的两项，其余各项在第 4 节中已经逐项取舍。

| 维度 | Bash + API 写入（推荐） | Python + API 写入 | Bash + 直接写 SQLite |
|---|---|---|---|
| 功能覆盖 | FR-01～FR-12 都能实现 | 同左 | 同左，但入站和使用者的关联数据要自己维护 |
| 与 3X-UI 的耦合 | 公开的 API，CI 每次验证 | 同左 | 内部表结构，升级时最容易失配 |
| 目标机依赖 | `jq`、`sqlite3`（Debian 官方仓库） | python3、`sqlite3` | `sqlite3` |
| 安全面 | 部署时有一个 admin token，用完删除；检查不持有可写凭据 | 同左 | 不需要 token，但写数据库要停 x-ui 或承担并发写入的风险 |
| 单人维护 | 与另外两个仓库同栈 | 新增一套语言栈 | 同栈 |
| 演进 | 3X-UI 的 API 变化时只改写入模块 | 同左 | 表结构变化时写入和检查都要改 |
| 可验证性 | CI 中执行的就是实际使用的脚本（D12） | 同左 | 同左 |

结论：Bash + API 写入。退路：如果 JSON 处理在实现中出错多，可以把写入模块换成 Python，命令面不变。

## 6. 推荐方案

推荐组合：Bash 工具；经回环地址上的 3X-UI API 写入，安装 token 用完即删；安装前后两次核对 3X-UI 的文件；REALITY 的 target 指向 Xray 自己的本机转发入站，只放行 target 的 SNI；订阅只监听回环地址，经远程管理的 Cloudflare Tunnel 发布；cloudflared 用固定的程序文件和本仓库的服务单元，以动态用户运行；检查只读数据库和本机接口；备份、升级和回退用文档步骤。

**置信度：中。** 3X-UI v3.11.0 和 cloudflared 2026.10.5 的相关行为已经对照源码核实。以下几点还没有运行证据，要在 M2、M3 中证实：

- 转发入站按嗅探到的 SNI 改写目的地址并路由：别的 SNI、没有 SNI 的连接在外连侧没有转发，异权威探测得不到其他站点的内容；SNI 正确、ClientHello 拆开发送的连接仍被转发到 target（第 4.4 节）；
- 经 API 写入的设置在面板和订阅输出中与预期一致，包括节点名称和节点地址；
- cloudflared 以动态用户运行时能正常连接；
- 经 Cloudflare 拉取订阅时不被挑战拦住。

## 7. 架构设计

### 7.1 组件与边界

| 组件 | 监听 | 对外可达 | 说明 |
|---|---|---|---|
| Xray：VLESS + REALITY 入站 | 443/tcp（所有地址） | 是 | 唯一的代理入口（D3） |
| Xray：转发入站（`tunnel`） | 127.0.0.1 上的一个端口 | 否 | 只作 REALITY 的 target，只放行 target 的 SNI（第 7.4 节） |
| Xray：3X-UI 的 api 入站 | 127.0.0.1:62789（模板默认） | 否 | 3X-UI 自带，不改 |
| x-ui 面板 | 127.0.0.1:面板端口 | 否 | 只经 SSH 隧道访问 |
| x-ui 订阅服务 | 127.0.0.1:2096，HTTP | 否 | 只由 cloudflared 访问（第 7.5 节） |
| cloudflared | 不监听入站；metrics 在 127.0.0.1:20241 | 否 | 出站连接 Cloudflare 的 7844/TCP 和 UDP |
| UFW（vps-hardening） | — | — | 只放行 22/tcp 和 443/tcp |

数据流与信任边界：

- **使用者 → 443：** 经 GFW 所在的网络，REALITY 认证；认证失败或 SNI 不对的连接进入转发入站，只有 target 的 SNI 被转发到 target。
- **使用者 → 订阅：** 经 Cloudflare 边缘（HTTPS 在此终结，Cloudflare 看到明文，R-17）→ Tunnel → cloudflared → 127.0.0.1:2096。VPS 的公网地址上不出现订阅主机名和证书。
- **管理员 → 面板：** SSH 隧道到 127.0.0.1 上的面板端口。
- **部署脚本 → 面板 API：** 回环地址，Bearer token，只在部署期间存在。
- **客户端 → 规则集：** 经代理从 GitHub 下载（D13），与 VPS 无关。

### 7.2 命令面

命令名为 `vps-proxy-setup`。

| 子命令 | 作用 | 是否修改系统 | 需求 |
|---|---|---|---|
| `deploy` | 首次部署：预检、安装 3X-UI、写入设置、安装 cloudflared 并接入 Tunnel、执行检查 | 是 | FR-01～FR-05、FR-12 |
| `deploy --migrate` | 迁移：预检、安装 3X-UI 和 cloudflared，不写设置；之后按文档恢复数据库 | 是 | FR-09、FR-12 |
| `check` | 只读检查 | 否 | FR-07 |
| `target-check <主机名>` | 在本机核实一个候选 target，只连接给定的这个主机，结果写在本机 | 否（只写结果文件） | FR-02、需求第 11.5 节 |

输入（第 6 节需求）从 root 所有、权限 0600 的文件读取，或者交互输入：订阅主机名、节点 IP、伪装目标、入站备注、使用者代号、Tunnel 的令牌。面板端口从 vps-hardening 的记录读取。分流规则是本仓库的文本，随工具发布。`deploy` 必须在交互终端中运行，与 vps-hardening 的 `apply` 相同。

本工具在 VPS 上的文件都在 `/etc/vps-proxy-setup/`（root 所有，0700）：部署记录（版本、摘要、订阅主机名、节点 IP、target，供检查核对）、Tunnel 的令牌（0600）、交给管理员的文件（取走后删除）。target 写在 VPS 上，不进入仓库（NFR-02）。

### 7.3 首次部署流程（FR-12）

| 步骤 | 内容 | 失败时 |
|---|---|---|
| 1. 预检（只读） | root；Debian 13 amd64；`vps-hardening verify` 通过；没有 3X-UI 的程序、服务单元和数据库，没有 cloudflared；输入合法，秘密文件的属主和权限正确；能读到 vps-hardening 记录的面板端口 | 停止，主机不变 |
| 2. 预取并核对 3X-UI 的文件 | tag 指向 D10 固定的提交；发布包、`x-ui.sh`、服务单元文件与固定的摘要一致 | 停止，主机不变 |
| 3. 安装 3X-UI | 非交互运行固定摘要的 `install.sh`（第 4.3 节），输出不进日志 | 停止，按清理步骤处理 |
| 4. 安装后核对 | 所装的 `/usr/bin/x-ui`、程序文件、`x-ui.service` 与第 2 步一致；`x-ui setting -listenIP 127.0.0.1` 后重启 x-ui，面板只在回环地址上监听 | 同上 |
| 5. 写入前核对 | 没有入站和使用者，订阅设置是默认值；能用 `install-result.env` 中的 token 访问 API | 拒绝写入，数据库不变 |
| 6. 写入 | 订阅设置（第 7.5 节）、Xray 配置模板中的路由（第 7.4 节）、转发入站、REALITY 入站和使用者；REALITY 密钥对、UUID 和订阅 ID 由 3X-UI 的接口生成；v3.11.0 没有生成 shortId 的接口，shortId 由部署脚本在 VPS 上用密码学安全随机源生成（`openssl rand -hex 8`，需求 D28），再经接口写入 | 停止并报告，按清理步骤处理（不自动回滚，FR-12） |
| 7. 收尾 3X-UI | 重启面板使订阅服务改为回环监听；经 API 删除安装 token；把面板凭据、`webBasePath` 和每人的订阅地址写入交给管理员的文件；删除 `install-result.env` | 同上 |
| 8. 安装 cloudflared | 核对固定的摘要，安装程序文件、令牌文件和服务单元，启动并等待 `/ready` | 同上 |
| 9. 检查 | 执行 `check`；提示管理员执行 `vps-hardening ports --add 443/tcp` 并从新的 SSH 会话确认（FR-06，不在脚本中） | 报告不符合项 |

清理步骤（文档）：`x-ui uninstall` 之后恢复 vps-tuning 的 `90-proxy-vps.conf`（需求第 10.1 节）；停止并删除 cloudflared 的服务单元、程序文件和令牌文件；删除 `/etc/vps-proxy-setup/`。之后预检能通过。

### 7.4 REALITY 入站与转发限制（FR-02、FR-03）

REALITY 入站：

| 设置 | 取值 | 理由 |
|---|---|---|
| 协议、端口、监听 | VLESS，443，所有地址 | D3 |
| 传输方式 | RAW（TCP） | REALITY 的常规组合，Mihomo 支持 |
| flow | `xtls-rprx-vision`，每个使用者都设置 | 与 RAW + REALITY 的常规组合一致；3X-UI 生成的 Mihomo 配置带 `flow`（已核实） |
| target | `127.0.0.1:<转发端口>` | 第 4.4 节 |
| serverNames | 只有 target 的主机名 | FR-02 |
| shortIds | 一个随机值：8 字节，编码成 16 个十六进制字符，由部署脚本在 VPS 上生成（需求 D28） | 取允许的最大长度，减少可猜测的取值（推断）；面板的随机按钮一次生成 8 个不同长度的值，不用（需求第 10.1 节） |
| fingerprint | `chrome` | 3X-UI 文档推荐提供 ML-KEM 的值，Mihomo 的 `chrome` 在 uTLS v1.8.7 中提供（需求第 10.1 节）；3X-UI 把它写成 `client-fingerprint`（已核实） |
| 回落限速 | 首版不设 | 转发入站已经只放行 target；需要时作为附加措施（FR-02） |
| 分享地址 | `shareAddrStrategy=custom`，`shareAddr`=VPS 的公网 IPv4 | 不设时，3X-UI 依次用节点地址、监听地址、`subDomain`，最后是请求的主机名（已核实），会给出订阅主机名，REALITY 连不上 |
| 备注 | 部署输入，例如 `🇺🇸 LA-Reality` | D14 |

节点地址用 IPv4：VPS 有 IPv6 时 443 仍在两种地址上监听，订阅只给 IPv4 地址。多数使用者的网络是 IPv4（推断）；以后需要时可以在 3X-UI 的主机（Hosts）中加一个 IPv6 的地址。

转发入站：协议 `tunnel`，监听 127.0.0.1；目的地址是占位的 `127.0.0.1`，端口 443；嗅探 TLS，用嗅探到的域名改写目的地址（`destOverride` 只有 `tls`，不设 `routeOnly`，`metadataOnly` 关闭），端口不变（第 4.4 节）。Xray 配置模板中的路由规则放在最前面，两条相邻：

1. 来自转发入站、目的域名为 `full:<target 主机名>`（完全相等）→ `direct`。只有嗅探到 SNI、目的地址被改写的连接才有域名；
2. 来自转发入站的其余连接 → `blocked`：别的 SNI，以及没有 SNI 或不是 TLS、目的地址仍是占位 IP 的连接。

占位地址在回环网段：规则 2 万一缺失或顺序出错，仍是占位地址的连接还会被模板中的私有地址 → `blocked` 挡住；即使走到 `direct`，它的 `finalRules` 也屏蔽私有地址（已核实）。这两层只对占位地址有效；被改写成别的域名的连接只靠规则 2，因为模板的 `domainStrategy` 是 `AsIs`，IP 规则不匹配域名（已核实）。M2 中不带 SNI 的用例要确认转发入站的外连侧没有连接（落到规则 2），不只看客户端拿不到内容。

模板中原有的规则保留：私有地址 → `blocked`，BitTorrent → `blocked`（v3.11.0 的默认模板，已核实）。

屏蔽回国流量（OD-2，用户 2026-10-29 决定采用）：紧接转发入站的两条规则之后再加两条（仍在模板原有规则之前），都只限 REALITY 入站，不影响其他入站和 VPS 本机的进程：

3. 来自 REALITY 入站、目的域名命中 `geosite:cn` → `blocked`；
4. 来自 REALITY 入站、目的地址是命中 `geoip:cn` 的 IP → `blocked`。

依据是 REALITY README 的"配置加分项：禁回国流量"，它没有说明理由，也没有测量，所以本文不把它算作已证实的抗探测收益。客户端的规则已经让国内流量直连（D13），这两条只影响漏到代理上的国内流量。`domainStrategy` 保持 `AsIs`：Mihomo 发来的多是域名，`geoip:cn` 只匹配 IP 字面量，域名靠 `geosite:cn`；不在 `geosite:cn` 中、却解析到国内地址的域名不挡。改成 `IPOnDemand` 能补上这一块，代价是服务端要为经 REALITY 入站、带域名的每个连接做一次解析，不采用。域名解析到私有地址的情况已由 `direct` 的 `finalRules` 挡住，不依赖 `IPOnDemand`。

同一条加分项中的"TCP/80、UDP/443 也转发"（让 VPS 对外像端口转发）不做：D21 和 vps-hardening 的约定只开放 443/tcp。这是已知的偏离。

双栈的出站（FR-13，需求 D27、D29、D31）：机制已决定（OD-5，需求 D32），在 M2 实现，只在部署输入启用时写入模板。取值：是否启用由部署输入明确给出，未启用时不写入；目的域名有 IPv6 地址时只经 IPv6 出站，IPv6 不可用或连接失败时连接失败，不改走 IPv4；没有 IPv6 地址时走 IPv4；其余流量保持系统默认。

机制（A，需求 D32）：新增一个 freedom 出站，`finalRules` 与 `direct` 相同，`streamSettings.sockopt.domainStrategy` 设为 `ForceIPv6v4`，不设 `happyEyeballs`；在规则 4 之后、模板原有规则之前加一条：来自 REALITY 入站、目的域名命中 `geosite:openai` 或 `geosite:anthropic` → 这个出站。按 Xray v26.10.21 的源码（第 13 节）：`ForceIPv6v4` 先只查 AAAA，查到就只连 IPv6，连接失败不改走 IPv4（`tryDelayMs` 默认为 0，不竞速，地址也只有 IPv6）；查不到 AAAA 才查 A、走 IPv4；两者都查不到时连接失败，不交给系统解析。TCP 和 UDP 都按这个顺序。路由的 `domainStrategy` 仍是 `AsIs`，规则 3、4 的匹配不变。

用户提供的配置样例的做法（B，需求 U20）：路由的 `domainStrategy` 改为 `IPOnDemand`，规则同时要求域名命中这两个类别和 `ip: ::/0`，命中时走设了 `ForceIPv6` 的 IPv6 出站，不命中的落入默认规则、走 IPv4；出站还用 `sendThrough` 固定了源地址。B 对 FR-13 的选路效果与 A 相同（推断），但 `IPOnDemand` 会让规则 4 的 `geoip:cn` 也匹配解析到国内地址的域名，并为经 REALITY 入站、带域名的连接做解析，改变 D22 的取舍，不采用（需求 D32）。样例中把其余流量限定在 IPv4 出站、删除 `direct` 等设置，与需求 D29 的第 2 项（保持系统默认）不同，也不采用；其余流量仍走 `direct`。

不用 `sendThrough` 固定 IPv6 源地址，由内核选择源地址（需求 D32）。理由：A 的出站设了 IPv6 源地址后，只查 AAAA、不再回退查询 A（源码，第 13 节），没有 IPv6 地址的域名会连接失败，与 D31 不符，要固定就得拆成两个出站并在选路时判断 AAAA，也就是回到 B；固定还要多一个部署输入，地址变化时这个出站失败。主机只有一个全局 IPv6 地址时，内核总是选它，不固定出口也不变。代价是主机有多个全局 IPv6 地址或临时地址时，出口可能随目的地址或地址变化而变；这类主机由检查提示（详细设计 DO-14）。重新评估的条件：出现这类主机，并且需要固定出口。

实际行为在 M2 中验证；固定的发布包中的 `geosite.dat` 是否有这两个类别，在 M2 实现之前按 v3.11.0 核实（需求第 10.1 节），没有时回到用户决定。

使用者：每人一个客户端，email 是代号，UUID 和订阅 ID 由接口生成（FR-03）。停用之后 Xray 不再接受这个 UUID；订阅是否还列出这个节点，v3.11.0 的订阅代码没有按启用状态过滤客户端（推断，在 M2 中核实），FR-03 要求的是"不再返回可用的节点"，不可用的节点也满足。

### 7.5 订阅与 Tunnel（FR-04、FR-05）

订阅设置（经 `/panel/api/setting/update` 写入）：

| 设置 | 取值 | 说明 |
|---|---|---|
| `subEnable` | true | 默认值 |
| `subListen`、`subPort` | 127.0.0.1、2096 | D21 |
| `subCertFile`、`subKeyFile` | 空 | 以 HTTP 提供，HTTPS 在 Cloudflare 边缘 |
| `subDomain` | 订阅主机名 | Host 不符时返回 403（已核实） |
| `subClashEnable`、`subClashEnableRouting` | true、true | FR-04 |
| `subClashRules` | 本仓库的规则文本 | D13 |
| `subJsonEnable` | false | 默认值 |
| `subInfoNodeEnable` | false | 默认值。打开时会在节点列表前插入一个指向 127.0.0.1:1080 的占位节点（已核实），使用者选中时无法上网 |
| `subUpdates` | 12 | 保持默认：IP 基本固定（A-7），没有缩短的理由 |
| `subURI`、`subClashURI` | `https://<订阅主机名>/...` | 为空时面板显示 `http://<主机>:2096/...`（已核实）。值是否包含路径，在详细设计中按 v3.11.0 核实 |
| `remarkTemplate` | `{{INBOUND}}` | 默认模板是 `{{INBOUND}}-{{EMAIL}}\|📊{{TRAFFIC_LEFT}}\|⏳{{DAYS_LEFT}}D`（已核实）。改为只用入站备注，节点名称固定、包含完整的备注（FR-02 的验收）；名称中的剩余流量和天数在不设上限时没有意义（D7） |

v3.11.0 对带 `Accept: text/html` 或 `?html=1` 的请求返回信息页面，没有找到关闭它的设置（已核实）。访问它仍要知道订阅路径和订阅 ID，所以不需要关闭；使用者用浏览器打开订阅地址时看到的就是这个页面。

Tunnel：

- 管理员在 Cloudflare 控制台创建 Tunnel，添加一个公开主机名：订阅主机名 → `http://127.0.0.1:2096`，不设置 HTTP Host Header（需求 FR-04）。控制台创建的 Tunnel 的兜底规则是返回 404（推断，在 M3 中从 `/config` 证实）。
- 订阅主机名用一级子域名，由 Cloudflare 的边缘证书覆盖（覆盖范围在详细设计中按 Cloudflare 文档核实）；从未以 DNS only 指向节点 IP（FR-05）。
- 对这个主机名关闭会挑战非浏览器客户端的设置；具体是 Bot Fight Mode 还是用 WAF 跳过规则，在详细设计中按 Cloudflare 免费计划的现行界面核实。
- cloudflared：第 4.5 节的 A。metrics 固定在 `127.0.0.1:20241`，`check` 从这里读 `/ready` 和 `/config`。

### 7.6 只读检查（FR-07）

`check` 在 VPS 上以 root 执行，不改动任何文件、设置或服务。输出逐项 PASS/WARN/FAIL/SKIP，退出码与 vps-hardening 的 `verify` 相同：0 全部通过（可以有 WARN），1 有不符合项，2 用法错误，3 内部错误。

| 检查项 | 数据来源 | 需求 |
|---|---|---|
| 3X-UI 的版本、程序文件摘要，面板只在 127.0.0.1 上监听，没有 `3x-ipl` jail | 程序文件的 `-v` 输出（只打印版本，不打开数据库，已核实），文件摘要，`ss`，`fail2ban-client` | FR-01、FR-07 |
| 版本不是 v3.11.0 时，报告 FAIL 并跳过依赖数据格式的检查 | 同上 | FR-07 |
| 入站：只有 REALITY 入站和转发入站；REALITY 的设置和分享地址；转发入站只在回环地址上；路由规则的前四条（第 7.4 节） | 只读打开的 SQLite（入站和设置表） | FR-02 |
| 使用者：每人的 flow 正确；不输出 UUID 和订阅 ID，只输出数量和代号 | 同上 | FR-03 |
| 订阅设置：第 7.5 节表中的值；分流规则与本仓库的文本一致 | 同上 | FR-04 |
| 本机端口：订阅服务和转发入站只在回环地址上监听 | `ss` | FR-04、FR-06 |
| cloudflared：程序文件摘要，服务在运行，`/ready` 正常，没有更新定时器，令牌文件 root 所有、0600 | 文件、`systemctl`、本机接口 | FR-05 |
| Tunnel 的生效路由：只有订阅主机名一条，指向 `http://127.0.0.1:2096`，其余拒绝 | `127.0.0.1:20241/config` | FR-07（v1.3） |
| VPS 上没有 acme.sh 和 Cloudflare API Token | 文件 | D21 |
| `vps-hardening verify` 的结果 | 它的退出码 | NFR-04 |

秘密：输出中不出现 UUID、订阅 ID、订阅路径、REALITY 私钥、面板凭据、`webBasePath` 和 Tunnel 的令牌（NFR-01）。`/config` 的内容只取主机名和服务地址。

数据库以 `sqlite3` 的只读模式打开，不调用 `x-ui setting`（第 4.2 节）。检查不能改动数据库：不写入数据，不改表结构和文件权限，不新建或删除文件。v3.11.0 的 SQLite 默认是 WAL 模式（已核实），读取时 SQLite 会在 `-shm` 中记读标记，这是读取本身的行为，不算改动（推断）。这几点在 M1 中验证；读不了时报告原因，不为了读取而初始化或修复数据库。

`check` 全部通过只说明检查范围内的配置符合要求，不说明从中国大陆可达，也不说明伪装有效；可达性看客户端的实际连接（FR-11）。

从 VPS 之外的验证用文档步骤，不做成脚本：它在管理员自己的电脑上执行，平台不定（可能是 Windows）。步骤是：经订阅主机名取得订阅，核对证书和内容；扫描 VPS 的公网地址，确认只有 22 和 443、没有任何端口出示自己域名的证书（FR-06）；用三个客户端实际连接（FR-11）。

### 7.7 target 的选择与核实（FR-02、需求第 11.5 节）

`target-check <主机名>` 只连接给定的主机，不扫描网段（需求第 11.5 节第 4 条）。它记录：解析到的地址；TLS 版本、ALPN、证书是否有效并与主机名匹配；根路径是否跳转到别的主机名；握手耗时；异权威探测（用 target 的 SNI 建立 TLS，再请求一个不同的 Host 和 HTTP/2 `:authority`）的结果。结果写在 `/etc/vps-proxy-setup/` 下，不进入仓库。是否在共享 CDN 上、网络是否与 VPS 相近，要按地址查网络归属，由管理员按文档另行判断（这一步要访问外部的查询服务）。

target 的标准以需求第 11.5 节为准，不另加排除项；用户原来的参考方案不再使用（OD-4）。

### 7.8 备份、迁移、升级与回退（FR-09、FR-10）

- **备份：** 用 `sqlite3` 的在线备份命令生成数据库的一致副本，不必停止 x-ui；管理员取走后加密保管。Tunnel 的令牌也可以在 Cloudflare 上重新取得，不必备份。
- **迁移前提：** 先按需求 FR-09 确认不依赖受阻 TCP 链路的既有管理路径；旧机 SSH 不可达不等于旧 cloudflared 已停止。无法确认旧连接器已停止或隔离时，不启动新机连接器，不宣称完成迁移。默认沿用同一个 Tunnel 的令牌；怀疑旧机被入侵，或旧机无法管理、需要隔离旧连接器时，轮换令牌，新机用新令牌接入（需求 D26）。轮换令牌不能代替断开已有连接，具体顺序见详细设计第 16.3 节。
- **迁移：** 新机上执行 `deploy --migrate`（预检、安装 3X-UI 和 cloudflared），停止 x-ui、替换数据库、启动 x-ui，在面板中把分享地址改为新机的 IP；先停止旧机的 cloudflared 再接入新机；开放 443/tcp，执行 `check`（FR-09）。部署记录中的节点 IP 由 `--migrate` 的输入给出。
- **订阅恢复：** 保持主机名不变不等于无条件可更新；源站、Tunnel、Cloudflare 入口和客户端获取路径须满足需求 FR-09。节点不可用时取得新内容的验证复用验证计划第 5 节 M5，不增加第二常驻节点。
- **升级 3X-UI：** 按需求第 11.3 节的准则评估，备份，按新版本的固定摘要重新执行安装，执行 `check`。`install.sh` 在已有凭据时保留原来的凭据，只在 `webBasePath` 短于 4 个字符时重新生成（已核实）；部署时生成的 `webBasePath` 是 18 个字符，不受影响。
- **回退：** 原机回退按 FR-10 的顺序；新机回退按迁移。
- **升级 cloudflared：** 替换程序文件，更新本仓库中的固定摘要，重启服务，执行 `check`；失败时换回原来的程序文件。

### 7.9 秘密与安全设计

| 秘密 | 生成或来源 | 存放 | 生命周期 |
|---|---|---|---|
| 面板用户名、密码、`webBasePath` | `install.sh` 随机生成 | 3X-UI 数据库；交给管理员的文件 | 管理员取走后删除文件 |
| 安装时的 API token（admin 范围） | `install.sh` 生成 | 数据库中只有摘要；`install-result.env` | 部署结束时经 API 删除 token，删除文件 |
| REALITY 私钥、shortId | 私钥：3X-UI 的接口；shortId：部署脚本在 VPS 上用 `openssl rand -hex 8` 生成（需求 D28） | 数据库 | 换 target 或怀疑泄露时重新生成：私钥在面板中重新生成，shortId 用同一命令生成后写入，不用面板的随机按钮 |
| UUID、订阅 ID、订阅路径 | 3X-UI 的接口和初始化 | 数据库；交给管理员的文件中的订阅地址 | 单独重置（FR-03） |
| Tunnel 的令牌 | Cloudflare 控制台 | `/etc/vps-proxy-setup/` 下 root 所有、0600 的文件 | 迁移时默认沿用；怀疑泄露、旧机被入侵，或需要隔离无法管理的旧连接器时轮换（R-16，需求 D26） |

其他控制：

- 部署脚本不把秘密放在命令行参数中，向 3X-UI 发请求时 token 经文件或标准输入交给 `curl`；`install.sh` 的输出不进日志（第 4.3 节）。
- 只有本仓库发布的、校验过的文件以 root 运行；3X-UI 和 cloudflared 的文件都按固定的摘要核对。
- 测试时用测试秘密扫描输出和归档（NFR-01）。

## 8. 验证设计

具体的用例在验证计划中确定。

| 层次 | 环境 | 覆盖 |
|---|---|---|
| 静态 | CI | ShellCheck；规则文本是合法的 YAML；仓库中没有真实的 IP、域名和 target（NFR-02） |
| 虚拟机 | CI，QEMU，Debian 13 amd64，沿用 vps-hardening 的虚拟机生命周期 | 加固和调优之后执行 `deploy`：不接入 Tunnel，令牌用测试值，第 8 步等待 `/ready` 预期超时失败，核对报告的原因；cloudflared 只测安装、核对、服务单元和令牌文件。之后单独执行 `check`，除 cloudflared 就绪和 Tunnel 路由两项预期 FAIL 外，其余应通过；真实的就绪和订阅发布只在测试 VPS 上判定。Mihomo 经回环地址取得订阅并实际连接；FR-02 的三个负面用例，在转发入站的外连侧观测；SNI 正确的三个用例（ClientHello 拆成多个 TLS 记录、分段慢速到达、带 X25519MLKEM768 的大 ClientHello）应被转发到 target（第 4.4 节）；同一 target 直接访问与经 VPS 访问的握手、证书、ALPN 和响应对照，记录差异；回国流量的两条规则用 3X-UI 的路由测试接口和客户端实际连接各验证一次（第 7.4 节）；`check` 不改动数据库（第 7.6 节）；FR-07 每项注入一种偏差；FR-12 的预检拒绝、写入前核对拒绝和中途失败后的清理；迁移、升级和原机回退（FR-09、FR-10） |
| 测试 VPS | 用户的测试 VPS，执行之前另行征求授权 | 真实的 Tunnel、订阅主机名和证书，`/ready` 就绪；`/config` 的路由检查和路由偏差的注入；外部端口扫描；三个客户端的连接（FR-11）；cloudflared 以动态用户运行 |

## 9. 风险与缓解

| 编号 | 风险 | 缓解 |
|---|---|---|
| SR-1 | 3X-UI 的 API 或设置项在修复版中变化 | 版本固定（D10）；版本不符时 `deploy` 和 `check` 拒绝或报告不符合；CI 每次执行写入 |
| SR-2 | `install.sh` 的输出或 `install-result.env` 泄露凭据 | 输出不进日志；文件读取后删除；token 用完即删 |
| SR-3 | 转发入站的嗅探或路由不按预期工作：未认证的连接被转发到别处，或者 SNI 正确的连接因嗅探失败被关闭，与直接连 target 的表现不同 | M2 的三个负面用例和三个 SNI 正确的用例；`check` 核对路由规则；SNI 正确的用例失败时按第 4.4 节决定接受还是改用 B |
| SR-4 | 订阅主机名经控制台被加了别的路由 | `check` 读 `/config` 发现（FR-07） |
| SR-5 | Cloudflare 挑战非浏览器客户端，订阅更新失败 | 关闭相关设置；M3 和 FR-11 中用三个客户端验证 |
| SR-6 | `geosite:cn`、`geoip:cn` 规则误挡境外服务 | 只限 REALITY 入站；测试中记录被挡的请求；误挡时在面板中删去这两条规则 |
| SR-7 | cloudflared 的 `/config` 接口或 metrics 地址在新版本中变化 | 版本固定；升级 cloudflared 时复核这一项 |
| SR-8 | 以动态用户运行 cloudflared 不可行 | 先改用固定的非特权系统用户，再考虑 root；令牌文件的要求不变 |
| SR-9 | 两次核对之间上游发布文件被替换，被替换的 `x-ui` 在第二次核对之前已经以 root 运行 | 第二次核对发现后停止，不写设置；这台主机按被入侵处理，重装系统后再部署；tag 指向固定的提交、摘要固定，缩小这个窗口 |

需求中的风险（R-1～R-17）不在这里重复。

## 10. 里程碑

| 里程碑 | 内容 | 完成的标志 |
|---|---|---|
| M1 只读部分 | 工具骨架、安装器、`check` 和 `target-check`，预检 | CI 中 ShellCheck、只读检查的注入测试和 `check` 不改动数据库的测试通过 |
| M2 部署 | `deploy` 的第 1～7 步和 `--migrate`；规则文本；FR-13 的出站和路由（按部署输入启用） | CI 虚拟机中部署、Mihomo 连接、FR-02 负面用例、回国流量规则、FR-12 的失败用例通过；SNI 正确的用例通过，或者没通过时已按第 4.4 节接受并记入 SR-3、或改用 B 后通过；FR-13 的用例按验证计划 VO-8 确定后通过 |
| M3 Tunnel | `deploy` 的第 8 步；cloudflared 的服务单元 | CI 中 cloudflared 的安装和核对通过（测试令牌，不判定就绪）；测试 VPS 上 `/ready` 就绪，经 Tunnel 取得订阅，`/config` 检查和路由偏差注入通过 |
| M4 运维 | 备份、迁移、升级和回退的文档 | 虚拟机中迁移、升级、原机回退和新机回退各一次 |
| M5 验收 | 使用说明和客户端说明 | 测试 VPS 上按使用说明完成 SC1，三个客户端连接成功，外部扫描通过 |

## 11. 待决事项

| 编号 | 事项 | 建议或决定 |
|---|---|---|
| OD-1 | Tunnel 的路由在 Cloudflare 上管理，还是在 VPS 上的配置文件中管理 | 已决定（需求 D22）：在 Cloudflare 上管理（第 4.5 节），偏差由 `check` 发现 |
| OD-2 | 服务端是否屏蔽回国流量 | 已决定（需求 D22）：采用 `geosite:cn` 和 `geoip:cn` → `blocked`，只限 REALITY 入站，`domainStrategy` 保持 `AsIs`（第 7.4 节） |
| OD-3 | 以动态用户运行 cloudflared | 已决定（需求 D22）：采用；不可行时先改用固定的非特权系统用户，再考虑 root（SR-8） |
| OD-4 | 参考方案中 target 的其他排除项 | 已决定（需求 D22）：参考方案不再使用，不另加排除项，target 的标准以需求第 11.5 节为准（第 7.7 节） |
| OD-5 | FR-13 的机制（需求 D27） | 已决定（需求 D32）：新增一个 freedom 出站，`sockopt.domainStrategy` 为 `ForceIPv6v4`，不设 `happyEyeballs`，不设 `sendThrough`；路由按 `geosite:openai`、`geosite:anthropic` 只把 REALITY 入站的连接引到它，路由的 `domainStrategy` 保持 `AsIs`（第 7.4 节），不改变 OD-2 的取舍。不采用配置样例的 `IPOnDemand` 加 `ip: ::/0`、IPv4 出站和删除 `direct` |

## 12. 需求追踪

| 需求 | 本文 |
|---|---|
| FR-01 | 第 4.3 节，第 7.3 节第 2～4 步 |
| FR-02 | 第 4.4 节，第 7.4 节，第 7.7 节 |
| FR-03 | 第 7.4 节 |
| FR-04 | 第 7.5、7.8 节 |
| FR-05 | 第 4.5 节，第 7.5 节，第 7.3 节第 8 步 |
| FR-06 | 第 7.1 节，第 7.3 节第 9 步，第 7.6 节（外部验证） |
| FR-07 | 第 4.6 节，第 7.6 节 |
| FR-08、FR-11 | 第 10 节 M5 |
| FR-09、FR-10 | 第 4.7 节，第 7.8 节 |
| FR-12 | 第 4.2 节，第 7.2 节，第 7.3 节 |
| NFR-01 | 第 7.9 节 |
| NFR-03、NFR-04 | 第 3 节，第 8 节 |
| NFR-05 | 第 4.3 节，第 4.5 节 |
| NFR-06、NFR-07 | 第 7.6 节，第 8 节 |
| D21、R-15～R-17 | 第 7.1 节，第 7.5 节，第 7.9 节 |
| D24 | 第 7.8 节；研究与范围复核见需求第 11.5 节 |
| FR-13、D27、D29、D31、D32 | 第 7.4 节，第 10 节 M2，OD-5 |
| D26 | 第 7.8、7.9 节 |
| D28 | 第 7.3 节第 6 步，第 7.4、7.9 节 |

## 13. 本文新核实的事实（2026-10-29～31）

需求第 10.1 节已有的不再重复。

| 事实 | 来源 |
|---|---|
| `install.sh` 在标准输入不是终端或 `XUI_NONINTERACTIVE=1` 时以非交互方式运行；读取 `XUI_ENABLE_FAIL2BAN`（不是 `true` 时跳过 Fail2ban 的自动配置）、`XUI_PANEL_PORT`、`XUI_USERNAME`、`XUI_PASSWORD`、`XUI_WEB_BASE_PATH`、`XUI_DB_TYPE`（默认 SQLite）、`XUI_SSL_MODE`（非交互时默认 `none`）；向几个第三方服务查询公网 IPv4，只用于显示访问地址 | v3.11.0 `install.sh` |
| 全新安装时，`install.sh` 在标准输出打印用户名、密码、端口、`webBasePath`、访问地址和 API token，并写入 root 所有、0600 的 `/etc/x-ui/install-result.env`；已有凭据时保留原来的凭据，只在 `webBasePath` 短于 4 个字符时重新生成 | v3.11.0 `install.sh`（`write_install_result`、`config_after_install`） |
| `x-ui setting` 的选项：`-port`、`-username`、`-password`、`-webBasePath`、`-listenIP`、`-show`、`-getListen`、`-getCert`、`-getApiToken`（可带 `-tokenName`、`-tokenScope`）等 | v3.11.0 `main.go` |
| `x-ui setting` 除 `-reset` 外每次都先调用 `updateSetting()`，进而调用 `InitDB`：建数据目录，删除数据库目录下以 `.x-ui-backup-` 开头的目录，以读写方式打开，收紧文件权限，设置 journal 模式（默认 WAL），执行 AutoMigrate 和种子数据；`-v` 只打印版本 | v3.11.0 `main.go`（`setting` 分支、`updateSetting`），`internal/database/db.go`（`InitDB`、`cleanupSQLiteBackupDirs`、`sqliteJournalMode`） |
| 全新安装时 `install.sh` 用所装的 `x-ui setting` 设置凭据，并启动 x-ui 服务 | v3.11.0 `install.sh` |
| API token 分 admin、monitor、node-sync、node-admin 范围；只存 SHA-256 摘要，明文只在创建时返回一次；可以经 `/panel/api/setting/apiTokens/delete/{id}` 删除 | v3.11.0 `docs/content/docs/en/reference/api/api-tokens.mdx`、`frontend/public/openapi.json` |
| 写入接口：`/panel/api/inbounds/add`、`/panel/api/clients/add`、`/panel/api/setting/update`、`/panel/api/xray/update`、`/panel/api/setting/restartPanel`；另有 `/panel/api/xray/routeTest` | v3.11.0 `frontend/public/openapi.json` |
| 入站有 `shareAddrStrategy`（`node`、`listen`、`custom`）和 `shareAddr`；节点地址依次取 `custom` 时的分享地址、节点地址、监听地址、`subDomain`（再是面板域名），最后是请求的主机名 | v3.11.0 `internal/database/model/model.go`，`internal/sub/service.go`（`resolveInboundAddress`、`configuredPublicHost`） |
| Xray 的 TLS 嗅探在 ClientHello 不带 SNI 时返回错误，不改写目的地址；嗅探到域名且协议在 `destOverride` 中时改写目的地址（只改地址，端口不变），设了 `routeOnly` 时只改写路由用的目的地址；路由规则取域名时先看路由用的目的地址，再看实际的目的地址，是 IP 时没有域名 | Xray-core v26.10.21 `common/protocol/tls/sniff.go`（`ReadClientHello`）、`app/dispatcher/default.go`（`shouldOverride`、`Dispatch`）、`features/routing/session/context.go`（`GetTargetDomain`） |
| Xray 的 TLS 嗅探只解析第一个 TLS 记录：记录不完整时返回"没有结论"（`ErrNoClue`），ClientHello 的扩展长度与记录内的剩余长度不符时返回错误；嗅探得到两次"没有结论"或累计等满 200ms 就放弃 | Xray-core v26.10.21 `common/protocol/tls/sniff.go`（`SniffTLS`、`ReadClientHello`），`app/dispatcher/default.go`（`sniffer`） |
| freedom 出站连上之后按实际连接的地址核对 `finalRules`，目的地址是域名时也一样；没有配置时，对来自 VLESS 等入站的连接默认屏蔽私有地址 | Xray-core v26.10.21 `proxy/freedom/freedom.go`（`getDefaultFinalRule`） |
| 入站协议中 dokodemo-door 叫 `tunnel`；默认 Xray 模板的出站是 `direct`（freedom）和 `blocked`（blackhole），路由规则是 api、私有地址 → `blocked`、BitTorrent → `blocked`；`direct` 带 `finalRules`（私有地址屏蔽，其余放行）；路由的 `domainStrategy` 是 `AsIs` | v3.11.0 `internal/database/model/model.go`、`internal/web/service/config.json` |
| Mihomo 配置中的 VLESS 节点带客户端的 `flow`，`client-fingerprint` 取入站的 fingerprint | v3.11.0 `internal/sub/clash_service.go` |
| `remarkTemplate` 默认是 `{{INBOUND}}-{{EMAIL}}\|📊{{TRAFFIC_LEFT}}\|⏳{{DAYS_LEFT}}D`；`subInfoNodeEnable` 默认关闭，打开时在节点前插入指向 127.0.0.1:1080 的占位节点 | v3.11.0 `internal/web/service/setting.go`，`internal/sub/clash_service.go` |
| 订阅的信息页面在 `Accept` 含 `text/html`、`?html=1` 或 `?view=html` 时返回，没有找到关闭它的设置 | v3.11.0 `internal/sub/controller.go`（`maybeServeSubPage`） |
| vps-hardening 的检查结果分 PASS、WARN、FAIL、SKIP；退出码 0、1、2、3 分别是通过、不符合、用法错误、内部错误；没有 FAIL 时退出码为 0，WARN 不影响 | vps-hardening `v0.1.1` `lib/vps-hardening/common.sh`、`verify.sh` |
| 控制台创建的 Tunnel 使用 Cloudflare 下发的路由，忽略本地配置文件；要本地管理又用令牌运行，须用命令行创建 Tunnel | cloudflared issue #933、#633 中维护者的答复 |
| 任何持有 Tunnel 令牌的人都能运行这个 Tunnel；令牌可以轮换，轮换后旧令牌不能建立新连接 | Cloudflare 文档 Tunnel permissions |
| 设了 `sockopt.domainStrategy` 时，freedom 先按它解析域名以核对 `finalRules`，再以域名拨号，由拨号器按同一策略解析。`UseIPv6v4` 先只查 AAAA，查不到或出错才查 A；`UseIP` 同时查两者。拨号器在 `happyEyeballs` 的 `tryDelayMs`、`maxConcurrentTry` 都大于 0、地址至少两个、TCP、没有 `dialerProxy` 时竞速拨号（`prioritizeIPv6` 让 IPv6 排在前面；一个地址失败立即试下一个），否则在地址中随机选一个。`tryDelayMs` 默认为 0，即不竞速。`Force` 开头的取值在查不到地址时返回错误，不交给系统解析。设了 `sendThrough`（源地址）时，只查与源地址同一族的地址，不做回退查询。freedom 设置中的 `domainStrategy` 已弃用，构建配置时迁移到 `sockopt.domainStrategy`，行为不变 | Xray-core v26.10.21 `proxy/freedom/freedom.go`（`Process`）、`transport/internet/dialer.go`（`DialSystem`、`LookupForIP`）、`transport/internet/config.go`（`strategy`）、`transport/internet/happy_eyeballs.go`（`TcpRaceDial`、`sortIPs`）、`infra/conf/transport_sockopt.go`（`HappyEyeballsConfig`）、`infra/conf/xray.go`（freedom 的策略迁移），2026-10-31 |
