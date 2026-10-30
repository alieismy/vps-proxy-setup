# VPS Proxy Setup 需求规格说明

| 项目 | 内容 |
|---|---|
| 状态 | v1.3 已批准（之后只增加 U12～U15、D22、D23，记录方案设计 v1.0 和验证计划 v1.0 的评审和批准，需求条目不变）：按用户 2026-10-29 确认的方案（U11、D21）关闭 OQ-2。3X-UI 的订阅服务只监听回环地址，经 Cloudflare Tunnel 以 HTTPS 发布在订阅主机名上，HTTPS 由 Cloudflare 边缘提供；节点地址显式用 VPS 的公网 IP；2096/tcp 不开放；VPS 上不签发证书、不保存 Cloudflare API Token，只保存 Tunnel 的令牌；cloudflared 固定版本、不自动更新。用户接受 Cloudflare 看到订阅的明文内容，VPS 的 IP 基本固定（A-7）。FR-05 由证书改为订阅的发布（Tunnel）。修改第 1～3、4（FR-01、FR-02、FR-04～FR-10、FR-12）、5～13 节，新增 A-7、R-16、R-17 和第 11.6 节；README 同步。U11 按 U9 的先例理解为确认并批准。按 CodeRabbit 对 v1.3 的意见，FR-07 增加 Tunnel 生效路由的检查，经 cloudflared 本机的 `/config` 接口读取，不需要 API Token。v1.2 已批准：按用户 2026-10-28 的决定（U10、D18、D19），一并纳入两件事。一、处理订阅与节点同址削弱伪装的问题（U10 的研究提问）：只定原则——节点地址优先用纯 IP、不挂证书；订阅服务不与节点共用同一公网 IP 暴露自己的域名或真实证书；重开 OQ-2，具体机制在方案设计中按证据选定（改 D6、FR-02、FR-04、R-10，新增 R-15）。二、按 CodeRabbit 对 v1.1 的三条意见（D19）：第 1 节的范围只排除非本项目首次部署的现网主机，本项目部署的机器之后的检查（FR-07）、备份与迁移（FR-09）、升级与回退（FR-10）仍在范围内；第 11.5 节和 FR-02 默认排除共享 CDN 上的 target——SNI 白名单挡不住内层 HTTP Host 或 HTTP/2 `:authority` 在 CDN 边缘的交叉路由，除非能证明该监听只按 SNI 路由到 target，并加一个异权威探测用例（只能发现交叉路由，不能反证隔离）；FR-02 验收补不带 SNI 的 ClientHello 用例，并在到 target 的外连边界观测。修改第 1、2、4、6、10、11、13 节，新增 R-15。按 CodeRabbit 对 v1.2 的意见，把 OQ-2 重开传导到 FR-05、FR-06、FR-09 和 D6（以"在本 VPS 上提供公开订阅服务"这一机制为前提），修正追踪矩阵中过时的"OQ-2 已关闭"，并把 README 的节点地址措辞改为"优先"。2026-10-28 批准（U10、D20）。v1.1 已批准：按用户 2026-10-28 的决定（U9、D17），按 CodeRabbit 对 v1.0 的意见修改三处：D15 和第 11.5 节中的"自己运营"改为"由站点自己托管、不在共享 CDN 上"，含义不变；FR-02 无论 target 在哪里都只转发 serverNames 中的 SNI，回落限速只作附加措施（R-13 同步修改）；FR-10 规定原机回退的顺序，并以新机迁移作为另一种回退方式。修改第 2、4、10、11、13 节。v1.0 已批准：用户于 2026-10-28 评审通过 v0.4 草案（U8、D16），内容与 v0.4 相同，只补记 U8、D16、第 13 节的一行和本行。v0.4 草案：按用户 2026-10-28 的答复（U7）：VLESS REALITY 入站的备注以国旗开头（D14）；伪装目标仍用第三方站点，在部署所用的 VPS 上按第 11.5 节的标准选择，未认证的连接只能到达伪装目标本身，生产使用的伪装目标不写入仓库（D15）；评估网上关于伪装目标的四级说法（第 11.5 节）。修改第 2、4～6、10、11、13 节，新增 R-13、R-14 和第 11.5 节。按 CodeRabbit 对 v0.3 的意见：FR-01 核对 `install.sh` 另行下载的文件；FR-09、FR-10 恢复数据库之前先停止 x-ui；FR-12 规定清理之后的状态，其中保留 vps-tuning 的 drop-in；分流规则以本仓库的文本为准（D12、FR-04）。待用户评审。v0.3 草案：按用户 2026-10-28 的答复（U6），v0.2 的其余内容无异议；3X-UI 改用 v3.11.0（D10）；先调优再安装 3X-UI，顺序不变（D11）；交付形态改为首次部署脚本加只读检查（D12，关闭 OQ-1）；分流规则以 Loyalsoldier/clash-rules 的白名单模式为基础改造，规则集用 MetaCubeX/meta-rules-dat 的 mrs 格式（D13，关闭 OQ-5）。修改第 1～4、6～13 节，新增 FR-12、R-11、R-12 和第 11.2～11.4 节；FR-04、FR-07 中"内置订阅页面已关闭"改为待核实（第 10.1 节）。按 CodeRabbit 的意见：REALITY 的原始链接也带 ML-KEM 的提示，更正 FR-04 和 R-5；FR-02 约束 REALITY 的 fingerprint；FR-12 先做只读预检，并限制秘密文件的属主和权限；第 11.2 节写明规则文本的来源和许可证。待用户评审。v0.2 草案：按用户 2026-10-26 的答复（U4）关闭 OQ-2～OQ-4（D6～D8）：订阅主机名首版不开启 Cloudflare 代理；首版不设流量上限和到期时间；分流规则在 3X-UI 中统一配置，规则的内容待定（OQ-5）。修改第 2、3 节，FR-02～FR-05、FR-07、FR-09、FR-11 和第 9～11、13 节。按 CodeRabbit 对拉取请求 #1 的意见：第 10.1 节只保留核实过的事实，客户端内核版本的推断移到 A-4，FR-11 记录客户端显示的内核版本；迁移时订阅主机名和节点地址都要改为指向新机（SC5、FR-02、FR-09）；新增 R-10（证书透明度日志公开订阅主机名）；A-1 改为 vps-hardening 的正式版 `v0.1.1`（D9）。交付形态（OQ-1）仍待用户确认。待用户评审。v0.1 草案：按用户 2026-10-26 对五个需求问题的答复（U2）起草 |
| 日期 | 2026-10-29（v0.3～v1.2 为 2026-10-28，v0.2 为 2026-10-27，v0.1 为 2026-10-26） |
| 上游依据 | 第 2 节的用户原话；[vps-hardening 需求规格说明](https://github.com/alieismy/vps-hardening/blob/master/docs/requirements.md) v1.10 第 7.2 节（已批准）中与本仓库的约定 |
| 下游 | [方案设计](solution-design.md)（v1.0 已批准，D22）；[验证计划](verification-plan.md)（v1.0 已批准，D23）；[详细设计](detailed-design.md)（v0.1 草案，覆盖 M1） |

优先级：**P0** 必须，缺少则首版不成立；**P1** 应有，可以放到下一迭代；**P2** 可选；**P3** 明确不做。

**证据状态。** 本文是需求，仓库里还没有实现，也没有运行证据。第 10.1 节标"已核实"的，是 2026-10-26～29 对照 3X-UI v3.10.2 和 v3.11.0、Xray、Mihomo、客户端、vps-tuning、vps-hardening、cloudflared、Cloudflare 文档和规则仓库的上游源码或文档核实的结果，以及 2026-10-28 对候选伪装目标的连接测试；标"推断"的，要在方案设计和测试中证实。

## 1. 目的与范围

在已经用 vps-hardening 加固并确认、按 vps-tuning 调优的新 VPS 上，用 3X-UI v3.11.0（D10）搭建一个 VLESS + REALITY 代理节点，供 5～8 人使用；通过 HTTPS 订阅（经 Cloudflare Tunnel 发布，D21），把每个人的配置分发到基于 Mihomo 内核的客户端（Sparkle、FlClash、Clash Verge Rev）。

范围内：

- 按固定版本安装 3X-UI，面板只监听回环地址，只经 SSH 隧道访问；
- 首次部署脚本：在全新安装的 3X-UI 上写入入站、使用者、订阅设置和分流规则；之后的变更在面板中进行（D12）；
- 一个 VLESS + REALITY 入站（443/tcp）；
- 每个使用者的客户端（UUID 和订阅 ID），以及停用和撤销；
- 订阅服务：3X-UI 的订阅只监听回环地址（2096/tcp，不对外开放），经 Cloudflare Tunnel 以 HTTPS 发布在订阅主机名上，输出 Mihomo 配置（D21）；
- Cloudflare Tunnel 的连接器 cloudflared：固定版本安装，作为服务运行，不自动更新（D21）；
- 备份、恢复与迁移，3X-UI 的升级与回退；
- 只读检查和验收方法。

首次部署只在新机上进行：本仓库不在用户既有的现网 3X-UI 主机（非本项目首次部署的机器）上安装或做首次写入，这些机器不受本仓库任何步骤的影响。对本项目在新机上部署的节点，之后的只读检查（FR-07）、备份与恢复、迁移（FR-09）、升级与回退（FR-10）在范围内。重装 3X-UI 的具体步骤不在本节规定，也不在本节验证。范围外的事项见第 8 节。

## 2. 需求来源与已确认决定

### 2.1 用户原话

U1～U5 是在 vps-hardening 的对话中给出的，也记录在它的需求第 2.1 节，这里只摘录与本仓库有关的条目；U6 起是本仓库的工作中给出的。原文不改，只有 U7、U12 中的本地路径、参考文档的文件名（含服务商名称）和测试中的伪装目标，按 NFR-02 和 D15 换成方括号中的说明。

| 编号 | 日期 | 原话 |
|---|---|---|
| U1 | 2026-10-25 | 3. 授权创建vps-proxy-setup仓库，你认为可以创建了就开始创建，公开，用MIT（vps-hardening U33 第 3 项。指：创建本仓库，公开，使用 MIT 许可证，创建时间按评估确定） |
| U2 | 2026-10-26 | 3. a.大约5-8人使用，一般情况下5人使用，b.只用 VLESS + REALITY（443） c.有托管在 Cloudflare 的域名，订阅端口 2096 要配证书 d.客户端主要使用Sparkle(Mihomo)和FlClash以及Clash Verge，需要订阅 e.脚本加验证，还是只要文档加检查脚本，请你评估哪种方式最佳（vps-hardening U35 第 3 项。依次答复此前提出的五个问题：用途和规模、入站协议、域名和证书、客户端和订阅、交付形态） |
| U3 | 2026-10-26 | 2.M5 通过后，目前生产只用Debian13，Ubuntu 24.04和Debian12 用虚拟机测试结果即可 ，确认发布正式版（vps-hardening U35 第 2 项。这一项是对 vps-hardening 正式版的决定；本仓库只引用其中"生产 VPS 目前只用 Debian 13"这一事实） |
| U4 | 2026-10-26 | 2. 先发布vps-hardening后，确认vps-hardening无问题后，我们切换到vps-proxy-setup仓库再开始任务，单可以提前授权你对vps-proxy-setup进行合并、提交和推送 3.首版不开，只做DNS解析 4.首版不设置 5.在 3X-UI 里统一配置规则，但是这个任务等下切换到vps-proxy-setup仓库进行，先把vps-hardening所有任务完成和收尾。（vps-hardening U36 第 2～5 项。依次指：vps-hardening 收尾、确认没有问题之后再开始本仓库的工作，同时预先授权在本仓库中合并、提交和推送，原文的"单"按"但"理解；第 3～5 项依次答复 v0.1 草案的 OQ-2～OQ-4） |
| U5 | 2026-10-27 | 2. 你评估 vps-hardening 没有问题之后就切换到vps-proxy-setup（vps-hardening U39 第 2 项。vps-hardening 的收尾评估见它的需求 D58） |
| U6 | 2026-10-28 | 1. 3X-UI 版本是用3.10.2还是最新版3.11.0，请你分析3X-UI Releases后评估确定，用 vps-hardening 加固后是先做vps-tuning 优化还是先做vps-proxy-setup，请你评估哪种方式最优，其它需求无异议。 2.3X-UI 的设置 是按说明在面板里完成、检查 还是 由脚本写入设置再检查，请你评估，选取最优的方式  3.分流规则请联网搜索github 相关的仓库，选取一个最优的通用分流规则来进行改造（对 v0.2 草案的答复。第 1 项：3X-UI 的版本和执行顺序交由评估确定，v0.2 的其余内容没有意见；第 2 项答复 OQ-1；第 3 项答复 OQ-5） |
| U7 | 2026-10-28 | 3X-UI 对REALITY Target 选择、 VLESS REALITY 入站、客户端、出站与路由的详细设置你可以参考目录[本地目录]下的[双栈的配置方案]（针对IPv4和IPv6双栈）、[单栈的配置方案] （IPv4单栈），只参考，需求以目前需求文档v0.3 草案为准，VLESS REALITY 入站中备注要带国家字符，比如"🇺🇸 LA-Reality"，Target目前测试选择的是[一个大厂站点]，请你评估，从不被GFW发现的情况下，选择哪个Target更合适？因为我看到有人说：[网上的四级说法，原文见第 11.5 节]，不知道对不对？（两份参考文档是用户现有的 3X-UI 配置方案，分别针对双栈和 IPv4 单栈的 VPS，只作方案设计的参考，不改变本文；"国家字符"按国旗 Emoji 理解（D14）；伪装目标的评估见第 11.5 节（D15）） |
| U8 | 2026-10-28 | 1. 评审通过 v0.4 2. 生成新的测试密钥（第 1 项：v0.4 草案评审通过；第 2 项是为测试 VPS 生成新的测试密钥，与本文的内容无关） |
| U9 | 2026-10-28 | 1. 按建议修改，改后记为 v1.1 2.授权你执行（对 CodeRabbit 关于 v1.0 的三条意见及其处理建议的答复。第 1 项：按建议修改，记为 v1.1；第 2 项授权删除测试 VPS 上旧的测试公钥，与本文的内容无关） |
| U10 | 2026-10-28 | 订阅服务和 REALITY 用的是同一个 IP，探测者可能同时看到你自己的域名和大厂域名，这会削弱伪装目标的作用。请搜索记忆，联网搜索相关资料，研究有没有更好的方案。（对同址削弱伪装的研究提问，以及随后三项决定：一并做 v1.2 后再合并；订阅去同址在需求层面只定原则、机制留到方案设计；共享 CDN 上的 target 默认排除。评估和处理见第 11.5 节、FR-02、FR-04、R-15 和 OQ-2） |
| U11 | 2026-10-29 | 确认你的推荐方案，请按照你的方案实施，VPS一般是固定IP，基本上不会换IP，接受 Cloudflare 看到订阅内容（对一份网上关于订阅与节点同址问题的分析做评审之后，给出的推荐方案的答复。推荐方案：订阅只监听回环地址，经 Cloudflare Tunnel 发布；节点地址显式用纯 IP；不开放 2096；VPS 上不再签发证书。"按照你的方案实施"在本仓库目前的阶段理解为：按方案修订需求、记为 v1.3 并批准，与 U9 的先例相同；实际部署在方案设计和实现之后进行。后两句是方案评估的输入：VPS 的 IP 基本固定（A-7），接受 Cloudflare 看到订阅的明文内容（R-17）。评估见第 11.6 节，D21） |
| U12 | 2026-10-29 | 1. 按上表修订 PR #3 2.采用修正后的规则 3.参考文档在目录[本地目录]下的[参考文档] （对方案设计草案的一份外部评审做过分析之后的答复。第 1 项：按分析中列出的九处修订改方案设计；第 2 项：OD-2 采用修正后的规则，即 `geosite:cn` 和 `geoip:cn` → `blocked`；第 3 项给出 OD-4 所需参考文档的位置，随后由 U13 取代。D22） |
| U13 | 2026-10-29 | 参考文档为之前的，后期不再参考使用，请用你的方案来修复"不带 SNI 的连接会被放行"漏洞（OD-4：参考方案不再使用，不另加排除项；转发入站沿用方案设计的做法，目的地址是占位的回环 IP，只用嗅探到的 TLS SNI 改写。D22） |
| U14 | 2026-10-29 | 批准方案设计（OD-1、OD-3 按方案设计的建议决定。D22） |
| U15 | 2026-10-30 | 批准验证计划,继续执行未完成任务和下一阶段任务（批准验证计划 v1.0 草案，含按 CodeRabbit 意见对 VT-71 的修改；"未完成任务"指合并验证计划，"下一阶段"是详细设计。验证计划的 VO-5、VO-7 没有在这里答复，仍待决定。D23） |

### 2.2 已确认决定

| 编号 | 决定 | 日期 | 依据 |
|---|---|---|---|
| D1 | 创建本仓库：公开，使用 MIT 许可证。按评估，在 vps-hardening 的 D47 修复在测试 VPS 上复核之后创建（vps-hardening D49） | 2026-10-25 | U1 |
| D2 | 规模：5～8 人，一般为 5 人 | 2026-10-26 | U2 a |
| D3 | 只用 VLESS + REALITY，入站端口为 443/tcp，不提供其他协议 | 2026-10-26 | U2 b |
| D4 | 订阅端口 2096/tcp 使用证书（HTTPS）。域名托管在 Cloudflare；证书走 DNS-01，80/tcp 不开放，与 vps-hardening D14 一致。（D21 改变：订阅经 Cloudflare Tunnel 发布，HTTPS 由 Cloudflare 边缘的证书提供；2096 只在回环地址上以 HTTP 监听，不对外开放；VPS 上不签发证书。使用者得到的仍是 HTTPS 订阅；80/tcp 仍不开放） | 2026-10-26 | U2 c（D21 改变） |
| D5 | 客户端是 Sparkle、FlClash 和 Clash Verge，三者都使用 Mihomo 内核；配置通过订阅分发。Clash Verge 按维护中的 Clash Verge Rev 理解（A-3） | 2026-10-26 | U2 d |
| D6 | 订阅主机名在 Cloudflare 上首版不开启代理，只做 DNS 解析（DNS only）。证书由 VPS 上签发的证书提供（FR-05）。IP 被封时订阅也无法更新，靠迁移恢复（FR-09）。（OQ-2 已由 D18 重开，D21 关闭并取代本行：订阅主机名改为 Cloudflare Tunnel 的公开主机名，经 Cloudflare 代理；节点 IP 被封时订阅仍可经 Cloudflare 更新） | 2026-10-26 | U4 第 3 项（OQ-2，D18 重开，D21 取代） |
| D7 | 首版不给使用者设流量上限和到期时间，只记录用量 | 2026-10-26 | U4 第 4 项（OQ-3） |
| D8 | 分流规则在 3X-UI 中统一配置，所有使用者从订阅得到同样的规则，只在一处维护；不沿用默认的全部走代理。规则的内容待定（OQ-5） | 2026-10-26 | U4 第 5 项（OQ-4） |
| D9 | vps-hardening 收尾之后开始本仓库的工作（vps-hardening D58）。加固以它的正式版 `v0.1.1` 为准（A-1）；在本仓库中合并、提交和推送已预先授权 | 2026-10-27 | U4 第 2 项，U5 |
| D10 | 3X-UI 用 v3.11.0（tag 指向 `c621ba9014a6aa21fd7c9ecf45655e44e24ebf13`），不用 v3.10.2。v3.10.2 自带的 Xray v26.10.10 已被 Xray 撤版，v3.11.0 自带替代它的 v26.10.21；两版的 `install.sh` 相同，`x-ui.sh` 只有两处结果相同的写法改动，vps-hardening 第 7.2 节的行为表仍然适用。评估见第 11.3 节。实现开始时如果已有 v3.11.x 的修复版，按第 11.3 节的准则评估之后再固定 | 2026-10-28 | U6 第 1 项 |
| D11 | 执行顺序不变：加固并确认之后，先按 vps-tuning 调优（应用、重启、验证），再安装和配置 3X-UI，之后做 vps-tuning 的严格验证并重启复核（README）。评估见第 11.4 节 | 2026-10-28 | U6 第 1 项 |
| D12 | 交付形态：首次部署脚本加只读检查（FR-12、FR-07）。脚本只在全新安装的 3X-UI 上写入入站、使用者、订阅设置和分流规则；之后 3X-UI 的数据库是唯一的配置来源，日常变更在面板中进行，变更后执行检查；分流规则例外，修改时先改本仓库的文本，再在面板中替换（FR-04）。这改变了 v0.2 的建议，评估见第 11.1 节 | 2026-10-28 | U6 第 2 项（OQ-1） |
| D13 | 分流规则以 Loyalsoldier/clash-rules 的白名单模式为基础改造：局域网和私有地址、中国大陆的域名和 IP 直连，其余走代理；规则集换成 MetaCubeX/meta-rules-dat 的 mrs 格式，经代理下载；首版不做广告拦截。规则文本保存在本仓库，由部署脚本写入 `subClashRules`。评估和改造内容见第 11.2 节 | 2026-10-28 | U6 第 3 项（OQ-5） |
| D14 | VLESS REALITY 入站的备注以国旗 Emoji 开头，后接地区和协议，例如 `🇺🇸 LA-Reality`（用户给出的格式）。值是部署输入（第 6 节） | 2026-10-28 | U7 |
| D15 | 伪装目标仍选用第三方站点，在部署所用的 VPS 上按第 11.5 节的标准选择和核实。优先选同一网络中由站点自己托管、不在共享 CDN 上的合格站点；共享 CDN 上的站点（含用户目前测试的那一个，在 Akamai 上）默认排除，除非能证明该监听只按 SNI 路由到 target（D19、第 11.5 节）。未认证的连接只能到达伪装目标本身（FR-02、R-13）。不改为以自己的域名为目标。生产使用的伪装目标不写入仓库（NFR-02）。评估见第 11.5 节 | 2026-10-28 | U7 |
| D16 | 需求规格说明 v1.0 批准，内容与 v0.4 草案相同；下一步是方案设计 | 2026-10-28 | U8 第 1 项 |
| D17 | 按 CodeRabbit 对 v1.0 的三条意见修改，记为 v1.1：D15 和第 11.5 节的措辞；FR-02 的 SNI 白名单无论 target 在哪里都必须有，回落限速只作附加措施；FR-10 规定原机回退的顺序，新机迁移作为另一种回退方式 | 2026-10-28 | U9 第 1 项 |
| D18 | 订阅与节点同用一个公网 IP、且订阅挂着自己域名的真实证书时，扫描者可按 IP 把借用的大厂证书（443）和你自己的证书（订阅端口）关联起来，削弱 REALITY 的伪装并把节点关联到你（R-15）。只定原则：节点地址优先用纯 IP、不挂证书（REALITY 本不需要自己的证书）；订阅服务不与节点共用同一公网 IP 暴露自己的域名或真实证书。重开 OQ-2，具体机制（如经 Cloudflare 代理、改用一次性下发或放在另一主机）在方案设计中按证据选定。改 D6、FR-02、FR-04、R-10。（机制已由 D21 选定，OQ-2 关闭） | 2026-10-28 | U10 |
| D19 | 按 CodeRabbit 对 v1.1 的三条意见修改，并入 v1.2：第 1 节的范围只排除非本项目首次部署的现网主机，本项目部署的机器之后的 FR-07、FR-09、FR-10 仍在范围内；第 11.5 节和 FR-02 默认排除共享 CDN 上的 target（内层 HTTP Host 或 `:authority` 在 CDN 边缘可交叉路由，SNI 白名单挡不住），除非能证明只按 SNI 路由到 target，并加异权威探测用例；FR-02 验收补不带 SNI 的 ClientHello 用例，在到 target 的外连边界观测 | 2026-10-28 | U10 |
| D20 | 需求规格说明 v1.2 批准，下一步是方案设计；v1.2 的内容是 v1.1 加 U10（D18、D19）的改动，以及 CodeRabbit 对 v1.2 的一致性修改 | 2026-10-28 | U10 |
| D21 | 关闭 OQ-2，按 D18 的原则选定机制：3X-UI 的订阅服务只监听 127.0.0.1（`subListen`），以 HTTP 提供、不配证书；经 Cloudflare Tunnel（VPS 上的连接器 cloudflared 只向 Cloudflare 发起出站连接，不需要入站端口）以 HTTPS 发布在订阅主机名上，HTTPS 由 Cloudflare 边缘提供。节点地址显式用 VPS 的公网 IP，不用主机名（FR-02）。2096/tcp 不开放，VPS 的公网地址上只有 22 和 443；VPS 上不签发证书，不安装 acme.sh，不保存 Cloudflare API Token，只保存 Tunnel 的令牌。cloudflared 固定版本、校验摘要、不自动更新。用户接受 Cloudflare 看到订阅的明文内容（R-17）；VPS 的 IP 基本固定（A-7）。不用"源站只放行 Cloudflare 网段"，因为 `vps-hardening ports` 不能限制来源地址；不用一次性下发，因为它与 U2 d 的"需要订阅"和 D8 冲突。改 D4、D6、D18，第 1 节、第 2.2 节继承的约定、第 3、5～9 节、第 10.1 节、第 12 节，FR-01、FR-02、FR-04～FR-10、FR-12，R-2、R-3、R-8～R-10、R-15，新增 A-7、R-16、R-17。评估见第 11.6 节。记为 v1.3 并批准 | 2026-10-29 | U11 |
| D22 | 方案设计 v1.0 批准。批准前按 U12 修订：检查不调用 `x-ui setting`；转发入站只嗅探 TLS，写明嗅探失败的代价和用例；写明安装核对的残余风险、虚拟机与真实 Tunnel 的判定边界、`check` 结论的范围。OD-1：Tunnel 的路由在 Cloudflare 上管理，偏差由 `check` 发现；OD-2：屏蔽回国流量，`geosite:cn` 和 `geoip:cn` → `blocked`，只限 REALITY 入站；OD-3：cloudflared 以动态用户运行，不可行时先改用固定的非特权系统用户，再考虑 root；OD-4：用户原来的参考方案不再使用，不另加 target 的排除项，转发入站用方案设计的做法。需求条目不变 | 2026-10-29 | U12、U13、U14 |
| D23 | 验证计划 v1.0 批准，内容是草案加按 CodeRabbit 意见的一处修改（VT-71 与同一阶段未注入时的基线比较）。VO-5（FR-11 三个客户端的平台）和 VO-7（测试 VPS 的时间、主机和授权范围）仍待用户决定，都在 M3 之前；其余待决事项在测试实现中处理。下一步是详细设计。需求条目不变 | 2026-10-30 | U15 |

**从 vps-hardening 继承的约定**（它的需求第 7.2 节，D14、D16、D32；本仓库的需求以这些为前提，不重复理由。3X-UI 的版本按 D10 改变；公开端口和证书按 D21 收窄，仍在约定的范围之内；其余不变）：

- 安装 3X-UI 时带版本参数。vps-hardening 约定的是 `v3.10.2`，本仓库按 D10 改为 `v3.11.0`。运行前按固定的摘要校验 `install.sh`：v3.11.0 的 `install.sh` 与 v3.10.2 的相同，摘要就是 vps-hardening 需求第 10.1 节记录的值；
- 设 `XUI_ENABLE_FAIL2BAN=false`，不启用 IP Limit，Fail2ban 由 vps-hardening 管理；
- 用 `XUI_PANEL_PORT` 传入加固时记录的面板端口（默认 2053）。面板只监听 127.0.0.1（`x-ui setting -listenIP 127.0.0.1`），只经 SSH 隧道访问；
- 公开端口由管理员用 `vps-hardening ports --add` 开放，并从新的 SSH 会话确认。不使用 3X-UI 的防火墙菜单和 BBR 菜单；
- 80/tcp 不开放；Cloudflare API Token 保存在 VPS 上，只授予签发证书所需的最小权限。按 D21，本仓库不在 VPS 上签发证书，也不保存 API Token；公开端口只有 443/tcp；
- REALITY 回落等本机端口只监听 127.0.0.1；
- Xray 从 v26.9.8 起只接受提供 X25519MLKEM768 的 REALITY 客户端（v3.10.2 自带 v26.10.10，v3.11.0 自带 v26.10.21），Mihomo 要设 `support-x25519mlkem768: true`。

## 3. 角色与场景

| 角色 | 说明 |
|---|---|
| 管理员 | 用户本人。以 root 用密钥登录 VPS，经 SSH 隧道使用面板，在 Cloudflare 上创建 Tunnel，保管 Tunnel 的令牌和备份 |
| 使用者 | 5～8 人，在自己的设备上用 Mihomo 内核的客户端导入订阅 |
| Cloudflare | 托管域名的 DNS；经 Cloudflare Tunnel 发布订阅，在边缘终结 HTTPS，所以能看到订阅的明文内容（D21、R-17） |
| 证书颁发机构 | D21 之后 VPS 上不签发证书；订阅主机名的边缘证书由 Cloudflare 签发和续期 |

| 场景 | 内容 |
|---|---|
| SC1 新建 | 在加固并调优后的 Debian 13 上（D11），用首次部署脚本安装 3X-UI，配置入站、使用者和订阅（D12），安装 cloudflared 并接入 Tunnel（D21），开放 443/tcp，检查通过 |
| SC2 分发 | 管理员把每人自己的订阅地址发给本人；使用者在客户端导入，客户端定期更新 |
| SC3 使用者变动 | 新增、停用、删除使用者；某人的订阅地址泄露时，只重置这个人 |
| SC4 日常运行 | 查看用量；定期或变更后执行检查。订阅的边缘证书由 Cloudflare 续期，VPS 上没有证书要续期（D21） |
| SC5 迁移 | IP 被封或更换 VPS 时，在另一台新机上恢复配置，用同一个 Tunnel 令牌接入，订阅主机名随之到达新机，不改 DNS；在面板中把节点地址改为新机的 IP（D21）。使用者经 Cloudflare 更新订阅后得到新的节点地址 |
| SC6 升级 | 3X-UI 发布新版本后，评估、备份、升级，失败时回退 |
| SC7 排查 | 连接失败时，按检查结果区分服务端、Tunnel、订阅和客户端的问题 |

## 4. 功能需求

### FR-01 安装 3X-UI（P0）

- 由首次部署脚本（FR-12）按第 2.2 节继承的约定安装 v3.11.0（D10）。
- 继承的约定只固定了 `install.sh` 的摘要。`install.sh` 另行下载的文件也要按固定的值核对：发布包（含 3X-UI 和 Xray 的程序）、从 tag 路径下载的 `x-ui.sh`，以及发布包中没有时从同一路径下载的服务单元文件；发布包按同一 Release 中的 `.sha256` 校验，只防下载损坏（第 10.1 节）。tag 也要核对仍指向 D10 固定的提交。核对的方式在方案设计中确定，例如安装之前预取比对、安装之后核对所装的文件，或者由脚本自己下载、校验之后交给安装；要说明核对与实际下载之间的时间窗口。
- 面板的用户名、密码和 `webBasePath` 都是随机值，由管理员保存。
- 2096/tcp 始终不开放（D21）：3X-UI 的订阅服务默认启用，对所有地址以 HTTP 提供（第 10.1 节），部署脚本把 `subListen` 设为 127.0.0.1（FR-04）。vps-hardening 加固后 UFW 只放行 22/tcp，改为回环监听之前 2096 也不对外可达，所以这一条只要求不对 2096 执行 `ports --add`。

验收：3X-UI 的版本为 v3.11.0；面板端口只在 127.0.0.1 上监听；没有 `3x-ipl` jail；`vps-hardening verify` 通过；所装的 `/usr/bin/x-ui`、程序文件和 `x-ui.service` 与固定的值一致，注入一个不符的文件时部署脚本停止（虚拟机测试）。

### FR-02 VLESS + REALITY 入站（P0）

- 只有一个入站：VLESS，443/tcp，安全层为 REALITY。传输方式和 flow 在方案设计中确定。
- REALITY 的密钥对和 shortId 在 VPS 上生成，私钥只保存在 3X-UI 的数据库中。
- REALITY 的 fingerprint 选用在 Mihomo 中提供 ML-KEM 的值，或者不设置（3X-UI 在 Mihomo 配置中写入 `chrome`）。启用 `support-x25519mlkem768` 不能改变旧的 fingerprint（第 10.1 节）。取值在方案设计中核实。
- 入站的备注以国旗 Emoji 开头，例如 `🇺🇸 LA-Reality`（D14），值是部署输入（第 6 节）。备注在数据库和订阅输出中保持原样（UTF-8）；3X-UI 怎样把备注和使用者代号等组合成 Mihomo 中的节点名称，在方案设计中按 v3.11.0 核实。
- 伪装目标（target 和 serverNames）选用第三方站点，在部署所用的 VPS 上按第 11.5 节的标准选择和核实（D15）；共享 CDN 上的站点默认排除，除非能证明该监听只按 SNI 路由到 target（D19，第 11.5 节）。serverNames 只有一项，就是 target 的主机名。核实的具体方法在方案设计中确定。
- 未认证的连接只能到达伪装目标本身。REALITY 把 SNI 不在 serverNames 中的连接原样转发到 target（第 10.1 节）：target 在共享 CDN 上时，别人可以借此经 VPS 访问同一 CDN 上的其他站点（R-13）；不在 CDN 上时，也能到达同一台服务器上的其他站点。所以无论 target 在哪里，都只转发 serverNames 中的 SNI，例如 target 指向回环地址上的转发入站，按 SNI 分流，其余连接不转发；具体做法在方案设计中确定。还要注意：SNI 白名单只作用在 TLS 层——target 在共享 CDN 上时，攻击者可用 target 的 SNI 过白名单、在内层 HTTP 里换 Host 或 HTTP/2 `:authority`，由 CDN 边缘按 Host 路由到同 CDN 的别的源站，VPS 只转发裸字节挡不住，所以共享 CDN 的 target 默认排除（D19，第 11.5 节）。REALITY 的回落限速（`limitFallbackUpload`、`limitFallbackDownload`）只限制带宽，不能代替 SNI 白名单，只作附加措施。
- 订阅中的节点地址显式设为 VPS 的公网 IP，不用主机名（D21）：REALITY 不需要自己的证书，节点 IP 上不出现你的域名或证书（D18、R-15）。必须显式设置：3X-UI 在入站没有指定分享地址时，用请求订阅时的主机名作为节点地址（第 10.1 节），经 Tunnel 时那是订阅主机名，即开启了 Cloudflare 代理的地址，而 REALITY 不能经 Cloudflare 代理（R-6）。迁移之后要在面板中改为新机的地址（FR-09）。VPS 有 IPv4 和 IPv6 时用哪一个，在方案设计中确定。

验收：
- 生成的 Mihomo 配置中，`client-fingerprint` 是方案设计选定的值；
- 开启 ML-KEM 的 Mihomo 客户端，经订阅中的节点访问测试地址成功；
- 不开启 ML-KEM 时握手失败（按上游的行为，作为负面用例）；
- 订阅中的节点地址是 VPS 的公网 IP，不是主机名；
- Mihomo 配置中的节点名称包含完整的入站备注，国旗没有损坏；
- 用 serverNames 之外的 SNI（例如与 target 在同一 CDN 上的另一个站点）连接 443/tcp，得不到那个站点的内容；在到 target 的外连边界观测（而不是只看客户端拿到什么，target 可能拒绝握手造成假通过）：没有转发到外部 target 或其他虚拟主机，若用回环转发器则在其外连侧确认；
- 不带 SNI 的 ClientHello（例如 `openssl s_client -noservername`）连接 443/tcp，同样得不到 target 或其他站点的内容，在到 target 的外连边界观测没有转发；
- 异权威探测：用 target 的 SNI 建立 TLS、再请求一个不同的 Host 或 HTTP/2 `:authority`，得不到别的站点的内容（这条只能发现交叉路由，结果干净不作为隔离的证明）；
- 部署记录中有 target 在部署所用的 VPS 上的核实结果（第 11.5 节），这份记录不进入仓库。

### FR-03 使用者（P0）

- 每个使用者对应一个 3X-UI 客户端，UUID 和订阅 ID 各自独立。本草案建议按人分配：同一个人的多台设备共用一个订阅。IP Limit 不启用，所以不限制设备数。
- 客户端名称（3X-UI 的 email 字段）使用代号，不用真实姓名或联系方式。
- 能停用、删除使用者；能单独重置某个人的 UUID 和订阅 ID。
- 首版不设流量上限和到期时间，只记录用量（D7）。
- 首次部署时由部署脚本按输入的代号创建（FR-12）；之后的新增、停用、删除和重置在面板中进行（D12）。

验收：
- 停用之后，这个使用者的连接失败，订阅不再返回可用的节点；
- 重置之后，旧的订阅地址和 UUID 失效，其他人不受影响。

停用之后订阅具体返回什么，在方案设计中按 v3.11.0 的行为核实。

### FR-04 订阅（P0）

- 订阅服务只监听 127.0.0.1（`subListen`），端口 2096，以 HTTP 提供，不配证书；经 Cloudflare Tunnel 以 HTTPS 发布在订阅主机名上（FR-05，D21）。2096/tcp 不对外开放，VPS 的公网地址上不出现你的域名或证书（D18、R-15）。
- 设置 `subDomain` 为订阅主机名，只应答这个主机名：3X-UI 按请求的 Host 比对，不符时返回 403；cloudflared 在没有设置 `httpHostHeader` 时原样转发原始的 Host（第 10.1 节）。
- 发给使用者的订阅地址是 `https://<订阅主机名>/<Mihomo 路径>`，走 Cloudflare 的 443 端口。3X-UI 在 `subURI`、`subClashURI` 为空时，按 `subDomain`、是否配证书和订阅端口生成面板中显示的地址（第 10.1 节），在本方案下会是 `http://<订阅主机名>:2096/...`，与实际地址不符；是显式设置这两项，还是由部署脚本按订阅主机名生成（FR-12），在方案设计中确定。
- 启用 Mihomo 格式（`subClashEnable`）。发给使用者的是 Mihomo 格式的地址（`/mihomo/<订阅 ID>` 或 `subClashPath`）。v3.11.0 生成的 Mihomo 配置会为 REALITY 写入 `support-x25519mlkem768: true`，与 v3.10.2 相同（第 10.1 节）。主机（Hosts）的"Mihomo X25519"开关保持关闭：v3.11.0 起它会去掉这个设置，握手随之失败（R-11）。
- 原始链接格式在订阅启用时总是可用。REALITY 的原始链接带 `support-x25519mlkem768=true`，但要客户端支持这个 URI 扩展才生效（第 10.1 节）；导入原始链接也得不到分流规则。所以发给使用者的只有 Mihomo 地址（FR-11）。
- JSON 格式保持关闭（默认值）。v3.11.0 对原始链接路径上的浏览器请求（`Accept: text/html` 或 `?html=1`）返回信息页面（第 10.1 节）；它能否关闭、是否需要关闭，在方案设计中核实。
- 订阅路径用 3X-UI 初始化时生成的随机值。
- 保留 `Subscription-Userinfo` 等响应头，客户端据此显示用量和到期时间。
- 分流规则在 3X-UI 中统一配置（`subClashEnableRouting`、`subClashRules`，第 10.1 节），写入每个人的 Mihomo 配置（D8）。规则的内容按 D13（第 11.2 节）。规则文本保存在本仓库，由部署脚本以本地 YAML 写入 `subClashRules`，不用远程地址。规则以本仓库的文本为准：要修改，先改本仓库，再在面板中把这项设置换成新的文本；只在面板中修改、不改仓库时，FR-07 报告不符合。
- 更新间隔默认 12 小时（`subUpdates`），是否调整在方案设计中确定。迁移之后，客户端最迟在一个间隔之后取得新的节点地址，使用者也可以手动更新。

验收：
- 从 VPS 之外经订阅主机名取得订阅：证书链有效，主机名匹配；三个客户端拉取订阅时不被 Cloudflare 的挑战或拦截挡住；
- 返回的 YAML 能被 Mihomo 解析，只包含这个使用者的节点，REALITY 带 `support-x25519mlkem768: true`，并包含配置的分流规则；
- Mihomo 加载这份配置之后，规则集下载成功；私有地址、国内和国外的测试地址分别命中直连、直连和代理；
- 订阅服务只在 127.0.0.1 上监听；在 VPS 上用其他 Host 请求 `127.0.0.1:2096` 时返回 403；不存在的订阅 ID 不返回节点。

### FR-05 订阅的发布：Cloudflare Tunnel（P0）

v1.2 及以前，本节是用 acme.sh 经 DNS-01 签发订阅证书。D21 之后 VPS 上不签发证书，本节改为订阅经 Cloudflare Tunnel 的发布。

- 管理员在 Cloudflare 上创建 Tunnel，把订阅主机名作为它的公开主机名，指向 `http://127.0.0.1:2096`（FR-04）。Tunnel 只发布这一个主机名，其余请求一律拒绝；面板仍只经 SSH 隧道访问，不经 Tunnel 发布。Tunnel 的路由放在 Cloudflare 上管理（远程管理），还是放在 VPS 上的配置文件中，在方案设计中确定。
- 订阅主机名用一个从未以 DNS only 方式指向任何节点 IP 的新主机名：被动 DNS 会保留历史解析（R-15）。它要被 Cloudflare 边缘证书覆盖，覆盖范围（例如只覆盖一级子域名）在方案设计中按 Cloudflare 文档核实。
- 不为这个主机名设置 `httpHostHeader`（FR-04）。会挑战或拦截非浏览器客户端的 Cloudflare 设置（例如 Bot Fight Mode），对这个主机名保持关闭，具体的设置项在方案设计中核实。
- VPS 上只保存 Tunnel 的令牌，不安装 acme.sh，不保存 Cloudflare API Token。令牌存放在只有 root 可读（0600）的文件中，cloudflared 用 `--token-file` 读取，令牌不出现在命令行参数、服务单元文件、输出和日志中（R-16）。
- cloudflared 使用固定版本，安装前按固定的 SHA-256 校验。发布说明中列出的摘要与程序来自同一个 Release，只防下载损坏，与 FR-01 相同（第 10.1 节）。
- cloudflared 不自动更新。2026.10.5 在 systemd 上执行 `service install` 时，除非带 `--no-update-service`，会安装并启动 `cloudflared-update.timer`，每天执行一次 `cloudflared update`（第 10.1 节）；服务本身带 `--no-autoupdate`。是用这个参数，还是用自己的服务单元，在方案设计中确定。升级按 FR-10。
- cloudflared 只向 Cloudflare 发起出站连接（7844/TCP 和 UDP），不需要入站端口；vps-hardening 的出站默认放行（第 10.1 节）。

验收：
- 从 VPS 之外经订阅主机名取得订阅（FR-04 的验收）；
- cloudflared 的版本和程序文件与固定的值一致，注入一个不符的文件时部署脚本停止（虚拟机测试）；
- 没有启用的自动更新：没有 `cloudflared-update.timer`，或者它没有启用；服务带 `--no-autoupdate` 运行；
- 令牌文件属于 root、权限为 0600；令牌不出现在进程的命令行、服务单元文件、输出和日志中；
- Tunnel 中只有订阅主机名一条路由，经 Tunnel 访问不到面板或其他本机服务；
- 停止 cloudflared 时订阅不可取，REALITY 节点不受影响；启动后订阅恢复（NFR-06 记录时长）；
- VPS 上没有 acme.sh 和 Cloudflare API Token。

### FR-06 端口（P0）

- FR-04 和 FR-05 完成之后，执行 `vps-hardening ports --add 443/tcp`，并从新的 SSH 会话确认。这一步由管理员执行，不在部署脚本中：确认要从新的 SSH 会话进行。
- 2096/tcp、面板端口和 80/tcp 不开放（D21）：订阅经 Tunnel 发布，不需要入站端口。

验收：从 VPS 之外探测，22、443 可达，2096、面板端口和 80 被拦截；扫描 VPS 的公网地址（有 IPv6 时两种地址都扫），没有任何端口出示含你自己域名的证书（R-15）；`vps-hardening verify` 通过。

### FR-07 只读检查（P0）

- 在 VPS 上以 root 执行，不改动任何文件、设置或服务。
- 检查项至少包括：
  - 3X-UI 的版本，面板的监听地址，Fail2ban 和 IP Limit 没有由 3X-UI 启用；
  - 入站的协议、端口、REALITY 设置（包括 FR-02 的转发限制）和节点地址，本机端口的监听地址；
  - 订阅：只监听 127.0.0.1、不配证书（D21），`subDomain` 已设置，Mihomo 格式和分流规则已启用，分流规则与本仓库的规则文本一致，JSON 格式已关闭；内置页面按 FR-04 中核实的结论检查；
  - cloudflared：版本和程序文件与固定的值一致，服务在运行，没有启用的自动更新（含 `cloudflared-update.timer`），令牌文件的属主和权限（FR-05）；
  - Tunnel 的生效路由：只有订阅主机名一条，指向 `http://127.0.0.1:2096`，其余请求拒绝，没有其他公开主机名（FR-05）。从 cloudflared 在本机回环地址上提供的 `/config` 接口读取生效的配置，不需要在 VPS 上放 Cloudflare API Token；路由在 Cloudflare 上还是在 VPS 上管理都适用（第 10.1 节）；
  - VPS 上没有 acme.sh 和 Cloudflare API Token（D21）；
  - `vps-hardening verify` 的结果。
- 输出中不出现秘密：UUID、订阅 ID、订阅路径、REALITY 私钥、面板凭据、`webBasePath` 和 Tunnel 的令牌。
- 3X-UI 的版本不是检查所针对的版本时，报告不符合，不再执行依赖它的数据格式的检查。
- 结果的分级和退出码与 vps-hardening 的 `verify` 保持一致，在方案设计中确定。
- 从 VPS 之外的验证：经订阅主机名取得订阅并核对证书和内容，扫描 VPS 的公网地址（FR-06），再用实际的客户端连接。用脚本还是手工步骤，在方案设计中确定。

验收：在符合本文的主机上全部通过；对每个检查项各注入一种偏差，检查都能发现（虚拟机测试；Tunnel 路由的偏差，例如多加一个指向面板的公开主机名，在测试 VPS 上注入，因为 CI 不接入真实的 Tunnel，第 12 节）。

### FR-08 使用说明（P0）

- 覆盖 SC1～SC7：部署脚本的输入和每一步的命令，日常变更在面板中的取值，预期结果和核对方法。
- 在 shell 中输入 Tunnel 的令牌等秘密的方式，不会把秘密留在命令历史中（例如 `read -rs`）。
- 在 Cloudflare 上创建 Tunnel、设置订阅主机名的步骤，以及要保持关闭的设置（FR-05）。
- 只用文档保留的示例值（`example.com`、`192.0.2.x` 等），不出现真实的 IP、域名、订阅地址、UUID 和服务商名称。

验收：在测试 VPS 上按使用说明从新机完成 SC1，检查全部通过。

### FR-09 备份、恢复与迁移（P1）

- 备份 3X-UI 的数据库。数据库包含全部秘密，备份保存在 VPS 之外，由管理员加密保管。
- 在另一台按 vps-hardening 加固的新机上恢复：用部署脚本安装相同版本的 3X-UI 和 cloudflared（FR-05），然后停止 x-ui、替换数据库、再启动 x-ui，不执行首次部署的写入（FR-12）；在面板中把节点地址改为新机的 IP（FR-02）；用同一个 Tunnel 的令牌接入，订阅主机名随之到达新机，不改 DNS；然后开放 443/tcp，执行检查。
- 旧机还在运行时，先停止旧机的 cloudflared，再接入新机：同一个 Tunnel 有多个连接器时，请求可能落到旧机，返回旧的节点地址（推断，在方案设计中核实）。怀疑旧机已被入侵时，迁移时轮换 Tunnel 的令牌（R-16）。
- Tunnel 的令牌由管理员在 VPS 之外保管，或者在 Cloudflare 上重新取得。
- 订阅主机名不变，使用者不需要重新导入；节点 IP 被封时，客户端仍能经 Cloudflare 更新订阅（D21）。

验收：在两台虚拟机之间完成一次迁移，使用者的订阅地址不变；节点地址是新机的 IP，订阅主机名经 Tunnel 到达新机，更新订阅后连接成功。

### FR-10 升级与回退（P1）

- 3X-UI 的新版本先评估再升级：对照 vps-hardening 需求第 7.2 节的行为表、本文的检查项和第 11.3 节的准则。部署脚本的写入也要在新版本上重新验证（FR-12）。
- 升级前备份数据库。回退有两种方式，由脚本还是文档步骤执行，在方案设计中确定：
  - 原机回退：停止 x-ui，按原版本的固定摘要重新安装（FR-01 的核对；不经过 FR-12，它的预检在已安装 3X-UI 的主机上停止），再停止 x-ui、恢复备份、启动 x-ui，然后执行检查（FR-07）。在已安装的主机上重新安装的方式，在方案设计中按 v3.11.0 的 `install.sh` 核实；
  - 新机回退：按 FR-09 迁移到另一台新机，安装原来的版本。
- cloudflared 的升级同样先评估、再升级（FR-05）；失败时换回原版本的程序文件，再重启服务。

验收：在虚拟机中完成一次升级，以及原机回退和新机回退各一次，之后检查都通过，使用者和入站与备份一致。

### FR-11 客户端说明（P1）

- 为 Sparkle、FlClash、Clash Verge Rev 写明导入订阅的步骤和最低版本：内核须支持 REALITY 的 `support-x25519mlkem768`，即 Mihomo v1.19.10 及以后（第 10.1 节）。
- 写明只导入 Mihomo 格式的订阅地址。

验收：三个客户端各在一个平台上导入订阅并连接成功，记录客户端显示的内核版本；平台在验证计划中确定。

### FR-12 首次部署脚本（P0）

- 在 VPS 上以 root 执行：先做只读预检，再按 FR-01 安装 3X-UI，经回环地址上的 3X-UI API 写入入站（FR-02）、使用者（FR-03）、订阅设置和分流规则（FR-04），然后按 FR-05 安装固定版本的 cloudflared，用 Tunnel 的令牌接入。
- 只用于全新安装。预检在任何改动之前执行：主机上已经安装 3X-UI，或者已有它的数据库时停止，不改动主机。写入设置之前再核对一次：已有入站或使用者，或者订阅设置不是默认值时拒绝写入。所以它不会改动正在使用的配置，也不提供重复执行时的合并。
- 迁移时只执行预检、安装 3X-UI 和 cloudflared，不写入设置，之后恢复数据库（FR-09）。
- 3X-UI 的版本不是脚本所针对的版本时拒绝执行（D10）。
- 输入（第 6 节）从文件或交互读取；Token 等秘密不出现在命令行参数、输出和日志中。从文件读取秘密时，文件须属于 root、权限为 0600，否则拒绝；导入之后删除这份文件，Tunnel 的令牌按 FR-05 保存。
- 生成的秘密只写入 3X-UI 的数据库，以及一份只有 root 可读的文件（面板凭据和每个人的订阅地址，地址按订阅主机名生成，FR-04）。管理员取走之后删除这份文件。
- 写入失败时停止并报告，不提供自动回滚。这时还没有使用者，按清理步骤处理之后重新执行。清理之后的状态：没有 3X-UI 的程序、服务单元和数据库，预检能通过；vps-tuning 预置的 `90-proxy-vps.conf` 仍在（`x-ui uninstall` 删除整个 `x-ui.service.d`，第 10.1 节，所以清理步骤要保留或恢复它）。cloudflared 和它的令牌文件是否保留并复用，以及清理的具体步骤，在方案设计中确定。
- 不执行 FR-06。

验收：
- 在虚拟机中从新机执行之后，FR-07 的检查全部通过；
- 对已安装 3X-UI 的主机执行时，在任何改动之前停止，主机状态不变；
- 写入之前的核对发现已有配置时拒绝写入，数据库不变（注入测试）；
- 写入中途失败（注入）之后按清理步骤处理，再次执行部署成功，vps-tuning 的严格验证通过；
- 秘密文件的属主或权限不符时拒绝；
- 输出、日志和归档中没有秘密（NFR-01）。

## 5. 非功能需求

| 编号 | 优先级 | 需求 | 验收 |
|---|---|---|---|
| NFR-01 | P0 | 安全：面板不对外开放。订阅地址视同凭据：持有者能取得节点的全部参数，所以每人一个、可以单独撤销。秘密不进入日志、检查输出和仓库 | 测试中用测试秘密扫描输出和归档，命中即失败 |
| NFR-02 | P0 | 隐私：仓库中没有真实的 IP、域名、订阅地址、UUID、服务商名称、本地路径和生产使用的伪装目标（D15） | 每次推送前扫描 |
| NFR-03 | P0 | 平台：Debian 13 x86_64，与生产 VPS 一致（U3，本草案的建议）。Debian 12 和 Ubuntu 24.04 为 P2 | 虚拟机测试，测试 VPS |
| NFR-04 | P0 | 与另外两个仓库兼容：完成 SC1 之后，`vps-hardening verify` 和 vps-tuning 的严格验证仍然通过 | 虚拟机测试 |
| NFR-05 | P0 | 固定版本：3X-UI 和 cloudflared 都使用固定版本，并校验摘要（3X-UI 包括 `install.sh` 另行下载的文件，FR-01；cloudflared 见 FR-05）；升级按 FR-10。D21 之前这一条约束的是 3X-UI 和 acme.sh | 检查 |
| NFR-06 | P1 | 中断：重启 x-ui 造成的连接中断在秒级；重启 cloudflared 只中断订阅，不影响节点（D21 之后 VPS 上没有证书续期） | 测试中记录时长 |
| NFR-07 | P0 | 检查只读、可以重复执行，结果只取决于主机的状态 | 测试中执行前后的状态摘要一致 |

## 6. 输入数据

| 输入 | 来源 | 说明 |
|---|---|---|
| 订阅主机名 | 管理员 | Cloudflare 上的完整域名，作为 Tunnel 的公开主机名；从未以 DNS only 方式指向节点 IP（FR-05） |
| 节点地址 | 管理员 | VPS 的公网 IP（FR-02，D21） |
| Tunnel 的令牌 | 管理员 | 在 Cloudflare 上创建 Tunnel 时取得（FR-05）；D21 之前这一行是 Cloudflare API Token 和 Zone ID |
| REALITY 伪装目标 | 管理员 | 在部署所用的 VPS 上按第 11.5 节的标准选择；不写入仓库（D15） |
| 入站备注 | 管理员 | 国旗 Emoji 加地区，例如 `🇺🇸 LA-Reality`（D14） |
| 使用者代号 | 管理员 | 5～8 个（D2） |
| 面板端口 | vps-hardening 的记录 | 默认 2053 |
| 分流规则 | 本仓库 | 按 D13 编写的规则文本 |

以上输入在首次部署时交给部署脚本（FR-12）。在 VPS 上生成：面板凭据、`webBasePath`、REALITY 密钥对、shortId、UUID、订阅 ID 和订阅路径。

## 7. 与其他仓库的约定

- **vps-hardening：** 按第 2.2 节继承的约定。本仓库不改动 sshd、UFW 规则、Fail2ban 和自动更新的配置；公开端口只经 `vps-hardening ports` 开放。3X-UI 的版本按 D10 改为 v3.11.0；vps-hardening 自己的 CI 仍用 v3.10.2 测试共存，v3.11.0 下的共存由本仓库的测试复核（FR-01、NFR-04）。按 D21 只开放 443/tcp，VPS 上不保存 Cloudflare API Token，都在它第 7.2 节约定的范围之内，不需要修改 vps-hardening。`vps-hardening ports` 只接受端口和协议，不能限制来源地址（第 10.1 节），所以本仓库不用"源站只放行 Cloudflare 网段"的做法。cloudflared 依赖它的出站默认放行；它改变出站策略时，要复核 FR-05。
- **vps-tuning：** 不使用 3X-UI 的 BBR 菜单；调优在安装 3X-UI 之前完成（D11）。vps-tuning 记录的业务验证基线是 3X-UI v3.4.2（第 10.1 节），v3.11.0 下的严格验证由本仓库的测试覆盖（NFR-04）。
- **执行顺序：** 见 [README](../README.md)。

## 8. 范围外（P3）

- 其他协议和传输：VMess、Trojan、Shadowsocks、Hysteria2 等 UDP 协议、XHTTP、经 CDN 中转（D3；指节点的流量，订阅经 Cloudflare Tunnel 发布见 D21）；
- 多个节点、3X-UI 的节点管理和订阅负载均衡；
- 面板对外开放，面板证书；
- IP Limit 和 3X-UI 自带的 Fail2ban；
- 3X-UI 的防火墙菜单和 BBR 菜单；
- 分流规则中的广告拦截（D13）；
- 在已运行 3X-UI 的现网主机上执行任何步骤；
- 客户端本身的安装和更新。

## 9. 假设

| 编号 | 假设 |
|---|---|
| A-1 | VPS 已经按 vps-hardening `v0.1.1` 加固并确认，并按 vps-tuning 调优（顺序见 README） |
| A-2 | 管理员能在 Cloudflare 上创建 Tunnel 并设置它的公开主机名（D21 之前是添加 DNS 记录、创建 API Token） |
| A-3 | "Clash Verge"指维护中的 Clash Verge Rev。原来的 Clash Verge 仓库已归档，最后一个版本是 2023-10-30 的 v1.3.8（第 10.1 节），它带的内核早于 `support-x25519mlkem768`，推断连不上 v3.11.0 的节点（Xray v26.9.8 起要求 ML-KEM） |
| A-4 | 使用者的客户端是近期版本，内核支持 `support-x25519mlkem768`。Clash Verge Rev v2.5.8 和 Sparkle 1.26.9 在构建时下载 mihomo 当时的最新正式版（第 10.1 节），据此推断两者自带的内核是 v1.19.31 或之后的版本。置信度中高：构建脚本说明的是构建的输入，不能直接证明已发布的安装包中的内核版本，要在测试中按客户端显示的内核版本证实（FR-11） |
| A-5 | 同一时间只有一个节点（一台 VPS） |
| A-6 | 管理员经可信的渠道把订阅地址发给本人 |
| A-7 | VPS 的公网 IP 基本固定，不主动更换（U11）；IP 被封时仍按 FR-09 迁移 |

## 10. 证据与风险

### 10.1 已核实的事实（2026-10-26～29）

| 事实 | 来源 |
|---|---|
| v3.10.2 的订阅有三种格式，按路径区分：原始链接（`subPath`，订阅启用时总是可用）、JSON（`subJsonEnable`）、Clash/Mihomo（`subClashEnable`，另有 `/mihomo/` 别名）。Mihomo 格式是完整的配置文件。v3.11.0 的文档相同，另列出只给 Clash for Windows 用的 `/clash-legacy/`；对原始链接路径带 `Accept: text/html` 或 `?html=1` 的请求返回可读的信息页面 | 3X-UI v3.10.2 和 v3.11.0 的 `docs/content/docs/en/config/subscription.mdx` |
| 默认值：订阅服务启用，监听所有地址，端口 2096，没有证书时以 HTTP 提供；Mihomo 格式和 JSON 格式关闭；订阅路径和 Mihomo 路径在初始化时随机生成。v3.11.0 相同 | v3.10.2 和 v3.11.0 的 `internal/web/service/setting.go` |
| Mihomo 配置中，REALITY 节点带 `support-x25519mlkem768: true`（源码注释：Xray 26.9.8 起拒绝没有 ML-KEM 密钥交换的 REALITY 握手）。v3.11.0 相同；v3.11.0 起主机的"Mihomo X25519"开关生效，打开时写入 `false`。`client-fingerprint` 在入站没有设置 fingerprint 时为 `chrome`，设置了则沿用；文档说明启用这个选项不能改变旧的 fingerprint，要选用提供 ML-KEM 的值（例如 Mihomo 的 uTLS v1.8.7 中的 `chrome`）。REALITY 的原始 `vless://` 链接带 `support-x25519mlkem768=true`（v3.10.2 和 v3.11.0），支持这个 URI 扩展的客户端导入时生效 | v3.10.2 和 v3.11.0 的 `internal/sub/clash_service.go`、`internal/sub/service.go`；v3.11.0 的 `docs/content/docs/en/config/reality.mdx`，3X-UI PR #6803 |
| 默认的 Mihomo 配置只有一个 `PROXY` 组和 `MATCH,PROXY` 规则。`subClashRules` 可以是本地的 YAML（规则列表，或者带 `rules`、`rule-providers` 等键的映射），也可以是远程地址；自定义规则中有 `MATCH` 时替换默认规则，否则放在默认规则之前。远程地址只取 `proxy-groups`、`rule-providers` 和 `rules`（v3.11.0 起可选再取 `dns`、`sniffer`），缓存 10 分钟 | v3.11.0 的 `internal/sub/clash_service.go`（`mergeClashRulesYAML`、`mergeRemoteClashRules`、`mergeClashRules`）和 `remote_routing.go`；v3.10.2 有同名的函数 |
| 节点地址的取值顺序：入站指定的分享地址、节点地址、入站的监听地址、配置的公开主机名，最后是请求订阅时的主机名。v3.11.0 相同（`ShareAddrStrategy` 为 `custom` 时分享地址优先） | v3.10.2 和 v3.11.0 的 `internal/sub/service.go`（`resolveInboundAddress`） |
| 菜单中的 Cloudflare 证书：可以用 API Token 或 Global API Key；acme.sh 没有安装时执行 `curl -s https://get.acme.sh \| sh`；签发主域名加通配符；默认续期后执行 `x-ui restart`；开启 acme.sh 的 `--auto-upgrade`；只提示把证书用于面板，不设置订阅服务。v3.11.0 的这些函数相同 | v3.10.2 的 `x-ui.sh`（`ssl_cert_issue_CF`、`install_acme`），文件摘要与 vps-hardening 需求第 10.1 节记录的相同；v3.11.0 的 `x-ui.sh`（见下文的比较） |
| 面板提供 REST API，可以用 Bearer token 认证；v3.10.2 的 token 具有完全的管理权限。v3.11.0 的 token 分权限范围：`admin` 可以使用全部接口，`monitor` 只读状态和指标。写入入站、使用者和设置的接口（`/panel/api/inbounds/add`、`/panel/api/clients/add`、`/panel/api/setting/update`），以及生成 X25519 密钥和 UUID 的接口，都在 OpenAPI 文档中 | v3.10.2 的 `docs/content/docs/en/reference/api/index.mdx`；v3.11.0 的 `docs/content/docs/en/reference/api/`（`api-tokens.mdx`、`inbounds.mdx`、`clients.mdx`、`settings.mdx`、`server.mdx`） |
| Mihomo 的 REALITY 选项 `support-x25519mlkem768` 于 2025-05-15 加入，v1.19.10 起包含；最新版本为 v1.19.33（2026-10-21） | MetaCubeX/mihomo 的提交 `5cf0f18`，`adapter/outbound/reality.go` |
| FlClash v0.9.2（2026-10-24）所带的内核包含这个选项 | FlClash 的子模块 `core/Clash.Meta` 在该版本指向的提交 |
| Clash Verge Rev 的最新版本为 v2.5.8（2026-10-09），Sparkle 为 1.26.9（2026-09-30）。两者都不固定内核版本：构建时下载 MetaCubeX/mihomo 当时的最新正式版和 Prerelease-Alpha（2026-10-27 核实）。这两个日期上，mihomo 的最新正式版是 v1.19.31（2026-09-14）或 v1.19.32（2026-09-30） | 两个项目的 GitHub Releases；Clash Verge Rev v2.5.8 的 `scripts/prebuild.mjs`，Sparkle 1.26.9 的 `scripts/prepare.ts`；mihomo 的 GitHub Releases |
| 原来的 Clash Verge 仓库已归档，最后一个版本是 v1.3.8（2023-10-30） | zzzgydi/clash-verge 的 GitHub 页面 |
| 3X-UI v3.11.0 的 tag 指向 `c621ba9014a6aa21fd7c9ecf45655e44e24ebf13`，Release 发布于 2026-10-25T19:09:16Z；到 2026-10-28T06:49Z 仍是最新的正式版，main 分支在它之后没有新提交。`install.sh` 的 SHA-256 与 v3.10.2 相同（`9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d`）；`x-ui.sh` 的 SHA-256 为 `26c229d5fb3b184e81581b4b223b801582ca7cf5908aaedeb8d1c7c70ad4cc25`，与 v3.10.2 相比只有两处 `[[ $# > n ]]` 改为 `[[ $# -gt n ]]`，对任何参数个数结果都相同 | GitHub API；两个 tag 的文件 |
| 3X-UI 的发布流程固定 Xray 的版本：v3.10.2 为 v26.10.10，v3.11.0 为 v26.10.21 | 两个 tag 的 `.github/workflows/release.yml`；两版的发布说明 |
| Xray v26.10.10 已撤版，Release 和 tag 都已删除。v26.10.21 的发布说明：印度的八张中间证书因私钥过于简单而被破解，这一版内置的根证书库移除了三张根证书（v26.10.10、v26.10.17 内置这些证书，已撤版），并用 Go 1.27.3 编译，即使操作系统的证书库没有更新也会过滤这些证书；用户应尽快升级 | XTLS/Xray-core 的 Releases，PR #7212（更新 `golang.org/x/crypto/x509roots/fallback`） |
| Xray 的 TLS 客户端默认使用系统证书库，只在系统证书库不可用或配置为不用系统证书时，才用内置的根证书库 | Xray v26.10.21 的 `transport/internet/tls/config.go`（`systemCertPool`、`loadCA`） |
| v3.11.0 中与本仓库有关的改动：所有订阅响应带 `Cache-Control: no-store`；新数据库的第一个面板用户随机生成；关闭 Fail2ban 时仍记录客户端 IP；主机的"Mihomo X25519"开关生效 | v3.11.0 的发布说明 |
| v3.11.0 发布后到 2026-10-28T06:49Z 有 18 个新 issue。报告 v3.11.0 缺陷的涉及 Telegram 机器人、TUIC、Hysteria2、AmneziaWG、Trojan 出站、节点、Cloudflare 后面的面板和面板中切换 Xray 版本，本仓库都不使用。"更新后 `webBasePath` 被重置"只在路径短于 4 个字符时发生，v3.10.2 也有；"三台节点夜间断连"的回复指向客户端的 Xray 太旧（v26.9.8 起要求 ML-KEM），v3.10.2 的内核同样要求 | 3X-UI 的 issue #6937～#6984 |
| 某些网络的 DPI 会丢弃带 ML-KEM 的 ClientHello（约 1.8 KB，两个 TCP 分段）的第二个分段。报告者在两台服务器上用 tcpdump 复现：Mihomo 1.19.32 不带 ML-KEM 时 20 次成功 20 次，带 ML-KEM 时 20 次成功 3 次。没有说明是哪个地区的网络 | 3X-UI PR #6803 |
| 3X-UI 的 `install.sh` 每次安装和更新只重写自己的 drop-in `x-ui.service.d/10-xui-sandbox.conf`，注释说明其他 drop-in 不受影响；`x-ui.service.debian` 中没有 `LimitNOFILE` | v3.11.0 的 `install.sh`、`x-ui.service.debian` |
| v3.11.0 的 `install.sh` 从 `raw.githubusercontent.com/MHSanaei/3x-ui/<tag>/x-ui.sh` 下载 `x-ui.sh`；服务单元文件只在发布包中没有时从同一路径下载；发布包只按同一 Release 中的 `.sha256` 校验 | v3.11.0 的 `install.sh`（`install_x-ui`、`require_repo_files`、`verify_release_checksum`、`_install_xui_service_unit`） |
| `x-ui uninstall` 停止并删除服务，删除整个 `x-ui.service.d` 目录（注释说明管理员添加的 drop-in 也一起删除），然后删除 `/etc/x-ui/` 和程序目录。vps-tuning 预置的 `90-proxy-vps.conf` 也在这个目录中 | v3.11.0 的 `x-ui.sh`（`uninstall`） |
| vps-tuning 在安装 3X-UI 之前应用时，预先创建 `x-ui.service` 的 drop-in（`90-proxy-vps.conf`，`LimitNOFILE=65536`），这时 `verify` 把代理服务未安装视为正常。它的操作指南要求先完成调优和重启验证，再安装 3X-UI，安装后做严格验证，并重启后再验证一次；`apply` 时 x-ui 已在运行的，要重启服务或主机之后再做严格验证。记录的业务验证基线是 3X-UI v3.4.2、Xray v26.6.27，其他版本要单独验证 | vps-tuning 的 README 和 `docs/usage.md`（v0.2.0-rc.4） |
| Mihomo v1.19.10 的规则集支持 `type`、`behavior`、`path`、`url`、`proxy`（经指定的代理下载）、`format`（包括 `mrs`）、`interval`、`size-limit` 和 `payload`；默认的地理数据（`geox-url`）从 MetaCubeX/meta-rules-dat 下载 | MetaCubeX/mihomo v1.19.10 的 `rules/provider/parse.go`、`constant/provider/interface.go`、`config/config.go` |
| Loyalsoldier/clash-rules：每天北京时间 6:30 自动构建，最近一次为 2026-10-27T22:35Z；规则集是文本格式，`direct.txt` 2,278,993 字节、`proxy.txt` 622,438 字节、`reject.txt` 5,605,483 字节、`cncidr.txt` 219,337 字节；README 推荐白名单模式（没有命中规则的流量都走代理） | 它的 README 和 `release` 分支 |
| MetaCubeX/meta-rules-dat：`meta` 分支提供 Mihomo 的 mrs 规则集，最近一次构建为 2026-10-28T01:34Z。`geo/geosite/cn.mrs` 532,882 字节、`geo/geosite/geolocation-!cn.mrs` 198,802 字节、`geo/geosite/private.mrs` 781 字节、`geo/geoip/cn.mrs` 38,553 字节、`geo/geoip/private.mrs` 236 字节。`geosite:cn` 的来源换成 blackmatrix7/ios_rule_script 的 ChinaMax；geoip 与 Loyalsoldier/v2ray-rules-dat 相同 | 它的 README 和 `meta` 分支 |
| 第 11.2 节候选仓库的星标数、最后推送日期和许可证 | GitHub API（2026-10-28） |
| Cloudflare 代理的 HTTPS 端口为 443、2053、2083、2087、2096、8443；除 443 外默认不缓存 | Cloudflare 文档 Network ports |
| REALITY 服务端只对 SNI 在 `serverNames` 中、带 X25519MLKEM768 的 TLS 1.3 ClientHello 尝试认证，其余连接原样转发到 target。认证成功时沿用 target 的 ServerHello 中的密码套件和密钥交换组，所以 target 不必支持 X25519MLKEM768 | XTLS/REALITY `83f62178`（Xray v26.10.21 的 `go.mod` 固定的版本）：`tls.go` 的 `Server`，`handshake_server_tls13.go` 的 [REALITY] SECTION |
| REALITY README 对 target 的要求：国外网站，支持 TLSv1.3 与 H2，域名不是用于跳转的；加分项：IP 相近（更像，且延迟低），Server Hello 之后的握手消息一起加密，有 OCSP Stapling；配置加分项：禁回国流量，TCP/80、UDP/443 也转发 | XTLS/REALITY README |
| 3X-UI 文档：target 必须是真实、可达、在所在地区没有被封锁、支持 TLS 1.3 和 HTTP/2 的站点；建议选不属于自己、流量大的站点 | 3X-UI v3.11.0 `docs/content/docs/en/config/reality.mdx` |
| 3X-UI v3.11.0 的 REALITY 表单提供回落限速 `limitFallbackUpload`、`limitFallbackDownload`（`afterBytes`、`bytesPerSec`、`burstBytesPerSec`），Xray 支持这两项 | 3X-UI v3.11.0 `frontend/src/pages/inbounds/form/security/reality.tsx`；Xray-core `infra/conf/transport_security.go` |
| XTLS 维护者的意见：只按 DNS 解析比对 SNI 和 IP，要么误伤多，要么遗漏多；没有 SNI 白名单时，区分 REALITY 和 TLS 意义不大，因为可以改为以自己的域名为目标（#2230）；target 是自己的站点没有风险（#3148） | Xray-core issues #2230、#3148 |
| target 使用 AWS 的 s2n-tls 时（例如 aws.amazon.com、CloudFront），重放探测能区分 REALITY 和 target；维护者答复：大多数站点用 OpenSSL 或 BoringSSL，REALITY 与之一致。这个 issue 仍未关闭，到 `83f62178` 为止的 REALITY 提交说明中没有看到针对它的改动 | Xray-core issue #6121；XTLS/REALITY 的提交记录（2026-10-28） |
| 声称"REALITY 已被完全攻破"的 #6091 以 not planned 关闭，RPRX 反驳；它的探测利用的是 REALITY 与 target 在处理畸形记录上的差异 | Xray-core issue #6091 |
| 2026-10-28 的检索没有找到 GFW 按 SNI 与 IP 不符识别 REALITY 的权威测量或论文，找到的是社区讨论和厂商博客 | 网络检索（2026-10-28） |
| 测试 12 个大厂站点（包括用户目前测试的那一个）：都支持 TLS 1.3、h2 和 X25519MLKEM768；除 dl.google.com 在 Google（AS15169）上之外，其余 11 个都在 Akamai（AS16625 或 AS20940）上。用户目前测试的目标：证书有效，有 OCSP Stapling，根路径 301 到同一主机名下的语言页。连接它所在的 Akamai 边缘地址、SNI 换成另外三个大厂站点时，分别得到这三个站点各自的证书 | 2026-10-28 从本地经现有代理测试：openssl 3.5.5 `s_client`，Google 公共 DNS 的 DoH，RIPEstat。出口是代理节点，结果只说明站点本身的特性；从部署所用 VPS 测得的延迟和网络位置要另行核实 |
| 3X-UI v3.11.0 的订阅服务：`subListen` 默认为空（监听所有地址），`subPort` 默认 2096；证书和私钥文件都设置且能加载时以 HTTPS 提供，否则以 HTTP 提供。`subDomain` 不为空时按请求的 Host（去掉端口）比对，不符时返回 403。`subURI`、`subClashURI` 为空时，面板中显示的订阅地址按 `subDomain`（为空时用请求的主机）、是否配证书和 `subPort` 生成，没有证书、端口不是 80 时为 `http://<主机>:<端口>` | v3.11.0 的 `internal/web/service/setting.go`（默认值、`BuildSubURIBase`）、`internal/sub/sub.go`（`Start`）、`internal/web/middleware/domainValidator.go` |
| cloudflared 的最新版本为 2026.10.5（2026-10-27）。Tunnel 不需要源站的入站监听，由 cloudflared 向 Cloudflare 发起出站连接，端口 7844（TCP 用于 http2，UDP 用于 quic）。没有设置 `httpHostHeader` 时，转发给本机服务的请求保留原始的 Host；设置时改写 Host，原值放进 `X-Forwarded-Host`。`service install <令牌>` 把令牌写入权限为 0600 的文件，服务用 `--token-file` 读取；在 systemd 上服务带 `--no-autoupdate`，但除非带 `--no-update-service`，还会安装并启动每天执行 `cloudflared update` 的 `cloudflared-update.timer`。发布说明列出各程序的 SHA-256。main 分支在 2026-10-29（2026.10.5 之后）又改动了这个 timer。cloudflared 的 metrics 服务默认只监听本机（依次尝试 `localhost:20241`～`20245`），其中 `/config` 返回当前生效的路由配置和版本号：路由在 Cloudflare 上管理时，这里反映 Cloudflare 下发的配置 | cloudflared 2026.10.5 的 `ingress/origin_proxy.go`、`cmd/cloudflared/linux_service.go`、`cmd/cloudflared/common_service.go`、`metrics/metrics.go`、`orchestration/orchestrator.go` 和发布说明，main 的提交 `53ba4e5`；Cloudflare 文档 Cloudflare Tunnel、Tunnel with firewall |
| vps-hardening `v0.1.1`：`ports` 的端口参数只接受"端口/协议"，可加 `/ipv4`、`/ipv6` 或 `/both`，不能限制来源地址；UFW 的出站默认放行 | vps-hardening `v0.1.1` 的 `lib/vps-hardening/inputs.sh`、`lib/vps-hardening/apply.sh` |
| Cloudflare 在 2021 年宣布 Tunnel 对所有账户免费，可选的 Argo Smart Routing 另行收费 | Cloudflare 博客 "A Boring Announcement: Free Tunnels for Everyone" |
| 按证书反查 Cloudflare 后面的源站有现成的工具：用全网扫描数据找出出示该域名证书的 IPv4 地址（CloudFlair，使用 Censys 的数据），针对的是公开暴露、没有把访问限制在 CDN 网段的源站 | CloudFlair 的 README |

### 10.2 风险

| 编号 | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R-1 | 订阅地址泄露 | 持有者能取得节点的全部参数，可以长期使用 | 每人一个订阅 ID，可以单独重置；只用 HTTPS；设置 `subDomain`；检查输出中不出现订阅地址 |
| R-2 | VPS 被攻破，Cloudflare API Token 泄露 | 攻击者能修改这个 Zone 的 DNS 记录 | D21 之后 VPS 上不保存 API Token，这一项不再适用；Tunnel 的令牌泄露见 R-16。原缓解：Token 只限一个 Zone、只给签发所需的权限；可以在 Cloudflare 上随时撤销 |
| R-3 | cloudflared 自动更新（D21 之前是 acme.sh 自动升级） | 以 root 运行未经固定的上游代码 | 固定版本，不启用自动更新，包括 `service install` 默认安装的 `cloudflared-update.timer`（FR-05）；FR-07 检查 |
| R-4 | 客户端内核太旧 | REALITY 握手失败 | 写明最低版本（FR-11）；排查时先核对客户端版本 |
| R-5 | 使用者导入了原始链接 | 得不到分流规则；客户端不支持 `support-x25519mlkem768` 这个 URI 扩展时握手失败 | 只发 Mihomo 地址（FR-04、FR-11） |
| R-6 | 节点地址指向开启了 Cloudflare 代理的主机名 | 连接失败 | 显式设置节点地址，检查核对它的解析结果（FR-02、FR-07） |
| R-7 | 3X-UI 升级后行为或数据格式变化 | 检查失效，或者升级后的默认值与本文不符 | 固定版本；先评估再升级；版本不符时检查报告不符合（FR-07、FR-10） |
| R-8 | 订阅服务默认以 HTTP 监听所有地址 | 端口一旦开放，订阅内容会以明文传输 | 2096/tcp 始终不开放，部署脚本把 `subListen` 设为 127.0.0.1（FR-01、FR-04、FR-06，D21） |
| R-9 | IP 被封 | 节点不可用 | 迁移（FR-09）；订阅主机名不变时，使用者只需更新订阅。订阅经 Cloudflare 发布，节点 IP 被封时客户端仍能更新订阅（D21） |
| R-10 | 公开签发的证书都记入证书透明度日志，任何人都能查到订阅主机名；订阅主机名若直接解析到 VPS（不经代理），解析结果就是 VPS 的地址 | 主机名和 VPS 的地址对应起来，可以被扫描或用于封锁（推断，置信度中） | D21 之后：VPS 上不签发证书；订阅主机名的边缘证书由 Cloudflare 公开签发，同样记入透明度日志（是否单独列出订阅主机名取决于证书的覆盖方式，FR-05），但主机名解析到 Cloudflare 的地址，不指向 VPS（R-15）。仍保留：主机名不与使用者的身份相关；`subDomain` 和随机的订阅路径。D21 之前的缓解：评估只用通配符证书，日志中只出现 `*.<域名>`；这只防止从日志中列出主机名，不能防止知道或猜到主机名的人解析它，也不能防止对 VPS 地址的扫描 |
| R-11 | 某些网络丢弃带 ML-KEM 的较大 ClientHello（第 10.1 节，3X-UI PR #6803） | 这些网络中的使用者连接失败或时断时续。是否影响本仓库的使用者不知道：只有一个报告者，没有说明地区 | 测试和试用中记录失败所在的网络。v3.11.0 起主机的"Mihomo X25519"开关可以去掉 ML-KEM，但 Xray v26.9.8 起服务端不接受这样的握手，要换用更早的 Xray，与 D10 的理由冲突。出现时另行评估 |
| R-12 | 规则集来自第三方，客户端按间隔自动更新（D13） | 规则数据出错或被篡改时，流量走错路径，例如应走代理的流量直连。规则集只是数据，不能执行代码 | 只用 MetaCubeX/meta-rules-dat：Mihomo 默认的地理数据也来自这个仓库（第 10.1 节），不多信任一方。需要时可以改为固定到某个提交 |
| R-13 | 伪装目标在共享 CDN 上，REALITY 把未认证的连接原样转发（第 10.1 节） | 别人可以把 VPS 当作访问同一 CDN 上任意站点的中转，消耗 VPS 的流量；中转的内容不受控制，可能引来滥用投诉（推断） | FR-02：只转发 serverNames 中的 SNI，回落限速只作附加措施；优先选不在共享 CDN 上的 target（第 11.5 节） |
| R-14 | GFW 借伪装目标识别 REALITY，例如比对 SNI 与 IP 所属的网络，或者利用 target 的 TLS 实现与 REALITY 的差异 | IP 被封 | 按第 11.5 节的标准选择，避开已知可以区分的 TLS 实现（#6121）；被封时按 FR-09 迁移，并换用新的 target。GFW 实际用什么方法，没有权威的公开测量（第 10.1 节），这些措施的效果无法事先验证（推断，置信度低） |
| R-15 | 订阅与 REALITY 节点同用一个公网 IP，且订阅挂着自己域名的真实证书：全网扫描器按 IP 对每个端口抓证书，能把 443 上借用的大厂证书和订阅端口上你自己的证书关联到同一个 IP，削弱 REALITY 的伪装，并把节点关联到你（第 10.1 节的扫描原理，推断，置信度中） | 节点匿名性被削弱，节点可被定位并关联到使用者本人 | 原则（D18）：节点地址优先用纯 IP、不挂证书；订阅不与节点共用同一公网 IP 暴露自己的域名或真实证书。机制（D21）：订阅只监听回环地址，经 Cloudflare Tunnel 发布，VPS 的公网地址上只有 22 和 443；节点地址用纯 IP；订阅主机名从未指向节点 IP（FR-02、FR-04～FR-06）。残留：443 上 SNI 与 IP 所属网络不一致的信号仍在（R-14），这一项无权威证据；Cloudflare 知道 Tunnel 的源站（R-17）；同一客户端先拉订阅、再连节点的时间关联在理论上存在（推断，信号弱） |
| R-16 | Tunnel 的令牌泄露（D21） | 持有者能为这个 Tunnel 运行连接器，在订阅主机名上下发伪造的订阅，例如把使用者的流量引到他的节点上 | 令牌只存放在只有 root 可读的文件中，不出现在命令行、输出和日志中（FR-05）；怀疑泄露或旧机被入侵时，在 Cloudflare 上轮换令牌（FR-09）。VPS 被攻破时攻击者本来就能控制 3X-UI，令牌泄露的额外影响是在重建之后仍然有效，所以重建时要轮换 |
| R-17 | Cloudflare 在边缘终结 HTTPS，能看到订阅的明文内容：节点 IP、UUID、REALITY 公钥和 shortId；订阅依赖 Cloudflare 的可用性，以及从中国大陆访问它的质量 | Cloudflare 或能取得它数据的一方，能得到节点的全部参数；Cloudflare 不可用时订阅无法更新，已导入的节点不受影响 | 用户接受 Cloudflare 看到订阅内容（U11）。3X-UI v3.11.0 的订阅响应带 `Cache-Control: no-store`（第 10.1 节），推断边缘不缓存，在测试中核实。订阅小、更新频率低；已导入之后，客户端可以经代理更新订阅（推断，在测试中核实）。Cloudflare 的服务条款是否限制这种用途，没有核实 |

## 11. 待决事项

| 编号 | 事项 | 建议 |
|---|---|---|
| OQ-1 | 交付形态：脚本加验证，还是文档加检查脚本（U2 e） | 已决定（D12）：首次部署脚本加只读检查，评估见第 11.1 节。v0.2 的建议：文档加只读检查脚本 |
| OQ-2 | 订阅服务怎样避免与 REALITY 节点同址、不在节点 IP 上暴露自己的域名或证书（原问题：订阅主机名在 Cloudflare 上是否开启代理） | 已决定（D21）：订阅只监听回环地址，经 Cloudflare Tunnel 以 HTTPS 发布；节点地址用纯 IP；2096 不开放，VPS 上不签发证书、不保存 API Token。评估见第 11.6 节。重开时（D18）的建议：原 D6 定首版不开启代理（DNS only）；U10 的研究指出订阅与节点同址会削弱伪装（R-15），故只定原则——节点优先用纯 IP、不挂证书，订阅不与节点共用同一公网 IP。具体机制在方案设计中按证据选定：(a) 经 Cloudflare 橙云代理（源站限 CF 网段 + CF Origin 证书，不进公开 CT），好处是 IP 被封时订阅仍可经 CF 更新、2096 是 CF 支持代理的 HTTPS 端口之一（第 10.1 节），代价是 CF 能看到订阅内容；(b) 不开公开订阅、一次性加密下发，最干净，代价是换 IP 要手动重发；(c) 放在另一主机。各方案的取舍见 R-10、R-15 |
| OQ-3 | 每人是否设流量上限和到期时间 | 已决定（D7）：首版不设，只记录用量。v0.1 的建议：首版不设，只记录用量；客户端会显示用量 |
| OQ-4 | 分流规则：沿用 3X-UI 默认的全部走代理（`MATCH,PROXY`），还是在 3X-UI 中统一配置规则（例如国内直连） | 已决定（D8）：在 3X-UI 中统一配置；规则的内容另见 OQ-5。v0.1 的建议：在 3X-UI 中统一配置，所有人得到同样的规则，只在一处维护；规则内容请你提供，或沿用你现有的配置文档 |
| OQ-5 | 分流规则的内容（D8） | 已决定（D13）：以 Loyalsoldier/clash-rules 的白名单模式为基础，规则集用 MetaCubeX/meta-rules-dat 的 mrs 格式，评估见第 11.2 节。v0.2 的建议：请你提供规则，或者确认一份基线：局域网和私有地址直连，中国大陆的域名和 IP 直连，其余走代理。基线用 Mihomo 内置的 GEOSITE、GEOIP 数据，还是外部规则集，在方案设计中按 3X-UI v3.10.2 `subClashRules` 支持的写法确定 |

### 11.1 OQ-1 评估：交付形态

**v0.3 的结论：首次部署脚本加只读检查（D12）。** 置信度：中。用户要求在"按说明在面板里完成、检查"和"由脚本写入设置再检查"之间选取最优的方式（U6 第 2 项）。重新评估时把脚本写入分成两种：可以重复执行、以脚本为准的声明式写入，和只在全新安装上执行一次的首次部署写入。

| 方面 | 面板中手工设置加检查（v0.2 的建议） | 首次部署脚本加检查（D12） | 声明式脚本加检查 |
|---|---|---|---|
| 配置的来源 | 只有 3X-UI 的数据库 | 部署之后只有数据库 | 脚本的声明和面板中的修改并存 |
| 改坏正在使用的配置 | 不会 | 不会：已有配置时拒绝写入 | 会：每次执行都可能覆盖 |
| 首次部署的人为失误 | 会有，由检查发现后手工修改 | 少：取值固定，CI 每次都验证 | 少 |
| 测试覆盖的路径 | CI 用 API 布置，是替代的路径；实际的面板操作只由检查事后核对 | CI 执行的就是实际使用的脚本 | 同左 |
| 3X-UI 升级 | 面板操作的说明可能随版本变化 | 写入代码要在新版本上重新验证（FR-10） | 同左，还要处理合并 |
| 开发和测试成本 | 中 | 中高：多出版本检查、全新安装的判断和秘密的输出；写入代码与 CI 布置的代码是同一份 | 高 |

理由：

1. v0.2 反对脚本写入的两条主要理由，针对的是可以重复执行、以脚本为准的写法：形成两个配置来源（下文理由 1），以及写入出错会改坏正在使用的配置（下文理由 3）。只在全新安装上写入一次、之后不再写入，这两条都不成立。
2. 首次部署要填的值多：入站和 REALITY 约十项，每个使用者几项，订阅约十项，还有一段分流规则的 YAML。手工输入的失误要等检查发现再改；脚本写入的值固定，并且每次 CI 都验证。
3. CI 本来就要用 API 布置 3X-UI（第 12 节）。把这部分代码做成首次部署脚本，测试覆盖的就是实际使用的路径；手工设置时，CI 验证的是替代的路径。
4. v0.2 的理由 2（变更不频繁）和理由 4（不需要 vps-hardening 那样的确认和自动恢复）仍然成立：省下的时间不是主要收益，脚本也不需要自动回滚（FR-12）。

**最强的反对理由：** 多一份要随 3X-UI 版本维护的写入代码，接口变化时要重新验证；脚本要处理生成的秘密。缓解：版本固定，版本不符时拒绝执行（D10、FR-12）；CI 每次都验证写入；秘密只写入数据库和只有 root 可读的文件（FR-12）。

以下是 v0.2 的评估，保留原文。

两种形态都要有检查。区别在于 3X-UI 中的设置由谁写入：

| 方面 | 脚本加验证（脚本写入设置） | 文档加只读检查脚本 |
|---|---|---|
| 写入方式 | 经 3X-UI 的 REST API（token 具有完全管理权限）或直接写数据库，写入入站、使用者和订阅设置 | 管理员按使用说明在面板中设置，shell 中的步骤照文档执行；脚本只读 |
| 配置的来源 | 脚本的声明和面板中的修改并存，要决定以谁为准：覆盖面板的修改，或者合并 | 只有 3X-UI 的数据库 |
| 日常操作 | 增减使用者要么经过脚本，要么造成偏差 | 照常在面板中操作，之后执行检查 |
| 3X-UI 升级 | 写入路径随接口和行为变化，每次升级都要重新验证写入和回滚 | 读取可能失效；失效时报告不符合，不会改坏配置 |
| 秘密 | 脚本要生成、传递或保存面板凭据、API token、REALITY 私钥、UUID 和订阅 ID | 秘密只在面板和数据库中，检查输出要遮蔽 |
| 新建和迁移的耗时 | 几分钟 | 新建约 30～60 分钟；迁移以恢复数据库为主，约 15～30 分钟（都是推断） |
| 人为失误 | 少 | 会有，由检查发现 |
| 开发和测试成本 | 高：幂等、输入校验、失败恢复和回滚都要实现和测试 | 中：检查项和注入偏差的测试。CI 中仍要用 API 布置测试用的 3X-UI，但只在测试中使用 |

**建议：文档加只读检查脚本。** 置信度：中高。3X-UI 的行为已对照源码核实；耗时和成本是推断，没有实测。理由：

1. 3X-UI 本身就是管理工具，它的数据库是配置的唯一来源。脚本再声明一份配置，就会和面板中的修改形成两个来源。
2. 变更不频繁：一台主机，5～8 个使用者，人员很少变动。自动化省下的时间主要在迁移上，而备份和恢复数据库（FR-09）已经能省下其中的大部分。
3. 失败时的后果不对称：只读检查最坏是报告错误；写入脚本出错则会改坏正在使用的配置。
4. vps-hardening 需要完整的应用、确认和自动恢复，是因为改错 SSH 和 UFW 会把管理员锁在外面。这里的操作不影响 SSH，不需要同样的机制。

**最强的反对理由：** 如果 IP 经常被封，迁移就会频繁发生；而且测试本来就要用 API 布置 3X-UI，写入脚本的一部分代码已经有了。

**重新评估的条件：** 出现以下任一情况时，先把 shell 中的步骤（安装、证书、恢复）改为脚本，面板中的设置仍保持手工：
- 新建或迁移超过每月一次；
- 检查多次发现同一种手工失误；
- 节点超过两台。

### 11.2 OQ-5 评估：分流规则

**结论：以 Loyalsoldier/clash-rules 的白名单模式为基础，规则集换成 MetaCubeX/meta-rules-dat 的 mrs 格式（D13）。** 置信度：中高。白名单模式就是 v0.2 提出的基线：局域网和私有地址、中国大陆的域名和 IP 直连，没有命中规则的流量都走代理。

候选仓库（2026-10-28 的 GitHub API；"内容"取自仓库的说明）：

| 仓库 | 星标 | 最后推送 | 许可证 | 内容 | 结论 |
|---|---|---|---|---|---|
| Loyalsoldier/clash-rules | 29,007 | 2026-10-27 | GPL-3.0 | 文本格式的规则集，以及白名单、黑名单两种规则模板；每天构建 | 选为改造的基础：使用最广，结构清楚，推荐的白名单模式与基线一致 |
| MetaCubeX/meta-rules-dat | 5,414 | 2026-10-28 | GPL-3.0 | Mihomo 项目的地理数据，以及 mrs、yaml、list 格式的规则集 | 用作规则集的来源 |
| blackmatrix7/ios_rule_script | 28,425 | 2026-10-27 | GPL-2.0 | 分流规则、重写规则和脚本，按应用和服务划分 | 不选：分得过细，作为通用基线维护成本高（判断） |
| ACL4SSR/ACL4SSR | 6,863 | 2026-10-25 | CC-BY-SA-4.0 | Clash 规则碎片，订阅转换用的配置 | 不选：面向订阅转换模板（判断） |
| Aethersailor/Custom_OpenClash_Rules | 6,695 | 2026-10-28 | CC-BY-SA-4.0 | 面向 OpenClash 的配置、订阅转换模板和规则 | 不选：面向路由器上的 OpenClash |
| SukkaW/Surge | 4,605 | 2026-10-26 | AGPL-3.0 | 面向 Surge、Mihomo、Clash Premium、sing-box 的规则 | 不选：多信任一个数据来源（R-12） |
| DustinWin/ruleset_geodata | 1,438 | 2026-10-27 | GPL-3.0 | 为 Clash、Mihomo、sing-box 定制的规则集和地理数据 | 不选：同上 |

改造的内容：

1. **规则集换成 MetaCubeX/meta-rules-dat 的 mrs 格式**：域名用 `private`、`geolocation-!cn`、`cn`，IP 用 `private`、`cn`。理由：mrs 是 Mihomo 原生的二进制格式，体积小得多（`cn.mrs` 约 0.5 MB，Loyalsoldier 的 `direct.txt` 约 2.3 MB；两者的数据来源不同，只作量级参考），对手机客户端更合适；Mihomo 默认的地理数据也来自这个仓库，不多信任一方（R-12）；Mihomo v1.19.10 起支持，与最低版本一致（第 10.1 节）。
2. **去掉与通用分流无关的部分**：`applications`（按进程名匹配，只对桌面客户端有效）、两条面板网址的 `DOMAIN` 规则、`reject`（广告拦截：误拦时排查成本高，首版不做，第 8 节）。Apple、微软等在国内有节点的服务是否单独直连，在详细设计中按规则集的内容确定。
3. **规则集经代理下载**（`proxy: PROXY`，更新间隔 86400 秒）：中国大陆常常无法直接访问 `raw.githubusercontent.com`（推断；Loyalsoldier 的 README 也提示了这种情况）。节点不可用时规则集无法首次下载，这时本来也无法代理；已下载的规则集保留在客户端（推断，在测试中核实）。
4. **IP 规则**：私有地址加 `no-resolve`。国内 IP 规则是否加 `no-resolve`，在详细设计中权衡：加上时，没有列入域名规则的国内网站会走代理；不加时，这些域名会先在本地解析，查询发给本地的 DNS。
5. **规则文本保存在本仓库**，由部署脚本以本地 YAML 写入 `subClashRules`，不用远程地址：不依赖面板访问 GitHub，规则的版本随仓库发布；检查核对它与仓库中的文本一致（FR-07），所以修改规则时先改仓库，再在面板中替换（FR-04）。仓库中只保存为本仓库编写的规则文本（规则集的名称、地址和规则的顺序），按本仓库的 MIT 许可证发布，不复制上游的规则数据和文本；规则集的数据由客户端从 MetaCubeX/meta-rules-dat 下载，不存入本仓库，仍按它自己的许可证（GPL-3.0）。规则的结构参照 Loyalsoldier/clash-rules 的白名单模式，在使用说明中注明出处。
6. **沿用 3X-UI 生成的 `PROXY` 组**，规则以 `MATCH,PROXY` 结尾：自定义规则中有 `MATCH` 时，3X-UI 用它替换默认规则（第 10.1 节）。
7. **规则集跟随 `meta` 分支的最新构建**，不固定提交（R-12）。

改造之后的形式（示意，名称、顺序和取舍以详细设计为准）：

```yaml
rule-providers:
  private-domain:
    type: http
    behavior: domain
    format: mrs
    proxy: PROXY
    interval: 86400
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs
  # non-cn-domain：geo/geosite/geolocation-!cn.mrs；cn-domain：geo/geosite/cn.mrs
  # private-ip、cn-ip：behavior: ipcidr，geo/geoip/private.mrs、geo/geoip/cn.mrs
rules:
  - RULE-SET,private-domain,DIRECT
  - RULE-SET,non-cn-domain,PROXY
  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,private-ip,DIRECT,no-resolve
  - RULE-SET,cn-ip,DIRECT
  - MATCH,PROXY
```

### 11.3 3X-UI 版本评估：v3.10.2 还是 v3.11.0

**结论：v3.11.0（D10）。** 置信度：中高。用户要求分析 3X-UI 的 Releases 后评估确定（U6 第 1 项）。证据见第 10.1 节。

| 方面 | v3.10.2 | v3.11.0 |
|---|---|---|
| 自带的 Xray | v26.10.10，已撤版 | v26.10.21，Xray 要求尽快升级到的版本 |
| `install.sh` 和 `x-ui.sh` | vps-hardening 核实过的基线 | `install.sh` 相同；`x-ui.sh` 两处写法改动，结果相同 |
| 与本仓库有关的改动 | 无 | 订阅响应带 `Cache-Control: no-store`；第一个面板用户随机生成；"Mihomo X25519"开关生效（R-11） |
| 已报告的缺陷 | 没有逐一核查 | 发布之后报告的缺陷都在本仓库不使用的功能上 |
| 发布至今 | 14 天 | 约 2.5 天，main 分支在它之后没有新提交 |
| 与 vps-hardening 的约定 | 一致 | 版本号不同；共存由本仓库的测试复核（第 7 节） |

理由：

1. 被撤版的内核不应作为新部署的固定版本。撤版的原因在 Xray 的 TLS 客户端：默认使用系统证书库，只有系统证书库不可用或被禁用时才用内置的根证书库（第 10.1 节）。所以对本仓库的实际影响可能很小（推断，置信度中）；但上游已撤下这个版本并要求升级，继续固定它就要自己承担这个判断。
2. 与 vps-hardening 的约定有关的脚本没有变化：`install.sh` 的摘要相同，`x-ui.sh` 中 vps-hardening 第 7.2 节涉及的函数没有变化。
3. v3.11.0 的改动多在本仓库不使用的功能上（AmneziaWG、Telegram 机器人、节点、主机的新功能）；VLESS + REALITY 和 Mihomo 订阅的行为在第 10.1 节核实过的范围内没有变化。

**最强的反对理由：** v3.11.0 发布不久、改动大。此前 v3.10.0 两天后出了 v3.10.2，v3.8.0 两天后出了 v3.8.5，v3.11.0 之后也可能很快有修复版。所以 D10 规定：实现开始时如果已有 v3.11.x 的修复版，按以下准则评估之后再固定：

- 自带的 Xray 没有被撤版；
- `install.sh` 和 `x-ui.sh` 与 vps-hardening 第 7.2 节的行为表一致；
- 已报告的缺陷不涉及本仓库使用的功能；
- 本文第 10.1 节核实过的订阅和接口行为不变。

### 11.4 执行顺序评估：先调优，还是先安装 3X-UI

**结论：先调优，再安装 3X-UI，维持 README 的顺序（D11）。** 置信度：中高。用户要求评估加固之后先做 vps-tuning 还是先做本仓库（U6 第 1 项）。

| 方面 | 先调优（现行） | 先安装 3X-UI |
|---|---|---|
| 代理的验收 | 在最终的内核网络参数下做一次 | 调优改变网络参数之后，要再做一遍检查和连接验收 |
| x-ui 的 NOFILE | 调优预置的 drop-in 在 x-ui 第一次启动时就生效 | `apply` 之后要重启 x-ui 或主机，才能做严格验证 |
| 出问题时的排查 | 调优时还没有代理服务，两者分开排查 | 调优出问题时要同时排除代理的影响 |
| 重启次数（加固之后） | 两次：调优之后，安装 3X-UI 之后复核 | 一次：调优之后的重启兼作复核 |
| 上游的说明 | vps-tuning 操作指南写明的顺序；vps-hardening D27、D41、D42 | vps-tuning 支持，但要额外重启 x-ui 或主机 |

理由：先调优的唯一代价是多一次重启（约一到两分钟，推断）；先安装 3X-UI 省下这次重启，却要在调优之后重做代理的验收。3X-UI 的 `install.sh` 只重写自己的 drop-in，不影响调优预置的 `90-proxy-vps.conf`（第 10.1 节），所以先调优没有冲突。

### 11.5 伪装目标评估：选哪个 target，网上的四级说法对不对

**结论：伪装目标仍用第三方站点（D15）。在部署所用的 VPS 上，优先选同一网络中由站点自己托管、不在共享 CDN 上的合格站点；共享 CDN 上的站点（含用户目前测试的那一个）默认排除，除非能证明该监听只按 SNI 路由到 target、不按内层 Host 交叉路由（D19）。不改为以自己的域名为目标。** 置信度：中低。能核实的是 REALITY 的实现、上游的选择标准和候选站点本身的特性（第 10.1 节）；GFW 实际用什么方法识别 REALITY，没有找到权威的公开测量。所以哪一种 target "不被发现"无法事先证明，只能去掉已知可以区分的地方。

用户引用的说法（U7，原文）：

> 1、青铜：偷大厂域名 + 高位端口\
> 一键脚本标准产物，SNI 是大厂，但端口挂个 54321，主动探测一扫一个准，纯属掩耳盗铃。
>
> 2、白银：偷大厂域名 + 443 端口\
> 知道端口伪装了，但跨 ASN 偷大厂，IP 与证书机构严重割裂，大流量下难逃风控审查。
>
> 3、黄金：偷邻居域名 + 443 端口\
> 同机房、同 C 段甚至同 ASN 抓原生网站，支持 TLS 1.3 + H2，路由与证书天衣无缝，老鸟基操。
>
> 4、王者：偷自己域名 / 自建回落反代 + 443\
> 域名自己的，真静态网页回落兜底，外部探针探测返回正常内容，查无可查。

| 说法 | 对的部分 | 不对或没有证据的部分 |
|---|---|---|
| 1. 大厂域名 + 高位端口 | 应该用 443。REALITY 对外表现为把连接转发到 target 的 443 端口，大厂站点出现在 54321 这样的端口上本身就不寻常 | "主动探测一扫一个准"没有证据：在任何端口上，未认证的探测得到的都是 target 的真实证书和内容，探测本身区分不了；要区分，仍要靠第 2 条的比对 |
| 2. 大厂域名 + 443 | SNI 是大厂、IP 却在主机商的网络中，这个差异确实存在；本次测试的 12 个大厂站点中 11 个在 Akamai 上（第 10.1 节），网络归属可以查到 | XTLS 维护者认为只按解析比对误伤多、遗漏多（#2230）；没有找到 GFW 据此封锁 REALITY 的权威测量。"大流量下难逃风控"说的是流量大小，与选哪个 target 无关，四种做法都一样 |
| 3. 邻居域名 + 443 | 与 REALITY README 的加分项"IP 相近（更像，且延迟低）"一致；邻居站点的地址在同一网络中，不在共享 CDN 上，R-13 的中转问题也小 | 解析邻居的域名得到的是邻居的 IP，不是 VPS 的 IP，只是网络和网段相符，谈不上"天衣无缝"；小站点更容易改版、迁走或停止服务，要定期复核；它的 TLS 实现也要核实（#6121）。找邻居要扫描同网段的地址，会连接第三方主机 |
| 4. 自己的域名 / 自建回落 + 443 | SNI 与 IP 一致，没有第 2 条的差异；探测得到的是自己的真实网站；XTLS 维护者也说 target 是自己的站点没有风险（#3148） | "查无可查"不成立：与 target 无关的识别方法（流量大小、连接模式等）照样适用；证书进入透明度日志，域名和 IP 一一对应，可以被找到（R-10）；封锁自己的域名没有附带损伤，封一次就要连域名一起换（推断）；要另外运行和维护网站与证书，超出第 1 节的范围。3X-UI 文档也建议选不属于自己、流量大的站点（第 10.1 节） |

总的看法：方向大致对，用 443，target 离 VPS 越近越像；但这个排名把可以核实的差异和没有证据的推测混在一起，而且漏掉了已知、可以核实的问题：target 的 TLS 实现（#6121）、共享 CDN 上的中转（R-13），以及共享 CDN 上即便按 SNI 白名单转发、内层 HTTP Host 或 `:authority` 仍可在 CDN 边缘被交叉路由（D19，这也是把共享 CDN 的 target 默认排除的原因）。

选择标准（FR-02，D15）：

1. 必须满足：支持 TLS 1.3 和 h2；证书有效，与主机名匹配；根路径不跳转到别的主机名（同一主机名下的路径跳转可以）；在中国大陆之外，没有被封锁；从部署所用的 VPS 稳定可达。target 不必支持 X25519MLKEM768（第 10.1 节）。
2. 排除：共享 CDN 上的站点默认排除（含 Akamai、Cloudflare、AWS CloudFront 等）。原因有两层：一是未认证的连接会被原样转发到 target，共享 CDN 上可中转到同 CDN 的其他站点（R-13）；二是即便按 SNI 白名单只转发 target 的 SNI，攻击者仍可用 target 的 SNI 过白名单、在内层 HTTP 里换 Host 或 HTTP/2 `:authority`，由 CDN 边缘按 Host 路由到同 CDN 的别的源站——VPS 只转发裸字节，挡不住（D19）。只有能用配置证据或上游契约证明"该监听只按 SNI 路由到 target、不按内层 Host 交叉路由"时，才可用共享 CDN 的 target。AWS（含 CloudFront）的 TLS 实现差异单独排除（#6121）。参考方案中的其他排除项，例如 Apple 和 iCloud、登录、支付和政府站点，在方案设计中逐项核实理由。
3. 优先：与 VPS 在同一网络或相邻网段、由站点自己托管（不在共享 CDN 上）的第三方站点，支持 TLS 1.3 + h2、证书有效、根路径不跳转到别的主机名。不再把共享 CDN 上的大厂站点作为次选（见第 2 条）。
4. 核实：在部署所用的 VPS 上，用 Xray 的 `tls ping` 或 openssl 记录 TLS 版本、ALPN、证书、跳转和握手耗时；对候选 target 做一次异权威探测（用 target 的 SNI 建立 TLS，再请求一个不同的 Host 或 HTTP/2 `:authority`），观察是否被交叉路由到别的站点——探测只能发现交叉路由，结果干净不能反证隔离。扫描邻居网段会连接第三方主机，由管理员决定是否执行；本仓库的脚本不自动扫描。

用户目前测试的目标满足第 1 条，但它在 Akamai 的共享 CDN 上（第 10.1 节），按第 2 条默认排除：除非能证明该监听只按 SNI 路由到 target、不按内层 Host 交叉路由，否则不作为 target。本次测试的大厂站点大多也在 Akamai 上，在这一类之间更换没有可以核实的好处；应按第 3 条找同网络、自托管、不在共享 CDN 上的站点。

**最强的反对理由：** 如果 GFW 开始按 SNI 与 IP 比对封锁，以第三方站点为 target 的节点会成批失效，以自己的域名为 target 是少数不受影响的做法，RPRX 也这样说过（#2230）。**重新评估的条件：** 出现 GFW 按 SNI 与 IP 比对封锁 REALITY 的可靠证据（论文、测量报告，或者 XTLS 维护者确认）；或者本仓库的节点换了 target 之后仍然反复被封，而流量和使用方式没有变化。那时再评估以自己的域名为 target；它需要网站和证书，扩大了范围，先征求用户同意。

**参考方案中的其他设置。** 两份参考方案中入站、出站和路由的详细设置，例如经回环地址的转发入站按 SNI 分流，服务端屏蔽私有地址、回国流量和 BT，作为方案设计的输入，逐项按本文和 3X-UI v3.11.0 核实之后采用，或者说明不采用（U7）。本文只把与 U7 的问题直接相关的转发限制写成需求（FR-02）。

### 11.6 OQ-2 评估：订阅怎样与节点去同址

**结论：订阅仍放在同一台 VPS 上，但不在公网监听。3X-UI 的订阅只监听 127.0.0.1，经 Cloudflare Tunnel 以 HTTPS 发布；节点地址显式用纯 IP；2096/tcp 不开放（D21）。** 置信度：中。"按 IP 关联证书"这个威胁是推断（R-15），没有权威测量；这个方案用可以核实的方式去掉这条关联（FR-06 的扫描验收），同时简化证书、端口和迁移。

2026-10-29 评审了一份网上关于这个问题的分析。它的方向与 D18 一致：不在节点 IP 上暴露自己的域名或证书，节点地址填 IP。它的三个方案和评审意见：

| 原文的方案 | 评审意见 |
|---|---|
| A. 订阅主机名开启 Cloudflare 代理，"审查者根本看不到 VPS 的真实 IP" | 只开代理不够：源站的 2096 仍在公网监听，出示 SAN 中带你主机名的证书，按证书反查源站是已知的手法（第 10.1 节，CloudFlair）。补救是源站只放行 Cloudflare 网段，但 `vps-hardening ports` 不能限制来源地址（第 10.1 节），本仓库又不直接改 UFW（第 7 节）。它还漏掉了 3X-UI 默认用请求的主机名作节点地址（FR-02、R-6） |
| B. 订阅和节点分放两台 VPS，节点地址可以用"另一个落地域名" | 原理成立，但与 3X-UI 内置订阅的结构不合（订阅由节点上的数据库生成），多一台主机，超出 A-5 和第 8 节的范围。用域名作节点地址，会经 DNS 和被动 DNS 把域名与节点 IP 绑定，与 D18 相反 |
| C. 不在公网提供订阅，本地配置 | 最干净，但每次改规则、增减使用者、迁移都要人工给每个人重发，也得不到 `Subscription-Userinfo` 的用量显示；与 U2 d 的"需要订阅"和 D8 的"规则只在一处维护、经订阅下发"冲突 |

另外两条补充意见：它举例的 target 是共享 CDN 上的大厂站点，与 D15、D19 冲突。"用自己的域名作 target 就退化成传统 TLS"不对（第 11.5 节，#3148）。

| 方面 | 只开 Cloudflare 代理 | 代理 + 源站只放行 Cloudflare 网段 | Tunnel（D21） | 一次性下发 |
|---|---|---|---|---|
| 节点 IP 上有没有你的域名或证书 | 有（2096） | 没有 | 没有，订阅也不在公网监听 | 没有 |
| 在本仓库的约束下能否实现 | 能 | 不能（`ports` 不支持来源地址） | 能 | 能 |
| 节点 IP 被封后客户端能否更新 | 能 | 能 | 能 | 不能 |
| VPS 上的秘密 | API Token | API Token 或 Origin 证书 | Tunnel 的令牌（R-16） | 无 |
| 新增组件 | acme.sh | acme.sh | cloudflared | 无 |
| 谁能看到订阅明文 | Cloudflare | Cloudflare | Cloudflare（R-17） | 管理员和分发渠道 |

理由：

1. 只有 Tunnel 在本仓库现有的约束下，让 VPS 的公网地址上不出现你的域名或证书，同时保留订阅。代理加网段限制做不到，一次性下发放弃了订阅。
2. 附带的简化：不再需要 2096 的公网端口（R-8）、VPS 上的 acme.sh、DNS-01 和 API Token（R-2、R-3 原来的对象）、证书续期造成的中断（NFR-06）；迁移不改 DNS（FR-09）。
3. 用户接受 Cloudflare 看到订阅内容（U11，R-17）。这是 Cloudflare 类方案共同的代价，Tunnel 没有比单纯开代理增加。

**IP 基本固定（A-7）之后的复核。** 评审时设过一个重新评估的条件：换 IP 很少时改选一次性下发。U11 说明 IP 基本固定，这个条件满足了，所以重新比较。比较的结果仍是 Tunnel：一次性下发的主要代价不只在迁移上，规则修改（D8、D13）、使用者变动（SC3）和用量显示都依赖订阅，它与 U2 d、D8 冲突。当时的条件只考虑了迁移，是不完整的。IP 固定只是让 Tunnel 的迁移优势变得次要。

**最强的反对理由：** 为 5～8 人多运行一个常驻组件，并把订阅交给 Cloudflare 看。缓解：cloudflared 固定版本、不自动更新、令牌只有 root 可读（FR-05、R-16）；它只承载订阅，停止时节点不受影响（FR-05 的验收）。

**重新评估的条件：** Cloudflare 从中国大陆持续无法访问，导致使用者无法首次导入订阅；Cloudflare 的条款或政策禁止这种用途；cloudflared 出现无法通过固定版本规避的安全问题；或者用户不再接受 Cloudflare 看到订阅内容。那时在一次性下发和另一主机之间重新选择。

## 12. 验证方法

沿用 vps-hardening 的做法，具体内容在验证计划中确定：

- **CI 虚拟机：** Debian 13 amd64。用首次部署脚本（FR-12）布置 3X-UI，与实际使用的路径相同；并在虚拟机中运行 Mihomo 实际连接。订阅在回环地址上取得；cloudflared 只测安装、校验、服务和令牌文件的处理，不接入真实的 Tunnel，不使用真实的令牌和域名。
- **测试 VPS：** 真实的 Tunnel、订阅和客户端连接要用你的域名和 Tunnel 的令牌，执行之前另行征求你的授权。
- **判定：** 按归档的证据逐项判定，不以 CI 显示通过为准。

## 13. 追踪矩阵

| 来源 | 需求 |
|---|---|
| U1、D1 | 仓库本身 |
| U2 a、D2 | FR-03 |
| U2 b、D3 | FR-02，第 8 节 |
| U2 c、D4 | FR-04～FR-06（D21 改变，见 U11、D21 行） |
| U2 d、D5 | FR-04，FR-11，A-3、A-4 |
| U2 e | 第 11.1 节，OQ-1（已关闭，见 D12） |
| U3 | NFR-03 |
| U4、D6 | FR-04，FR-09，R-10（OQ-2 由 D18 重开，D21 关闭，见 U10、D18 行和 U11、D21 行） |
| U4、D7 | FR-03（OQ-3 已关闭） |
| U4、D8 | FR-04、FR-07，OQ-5（OQ-4 已关闭） |
| U4、U5、D9 | A-1，本仓库的工作顺序和授权 |
| U6 第 1 项、D10 | 第 1 节，第 2.2 节继承的约定，FR-01、FR-03、FR-04、FR-10、FR-12，A-3，第 7 节，R-11，第 11.3 节 |
| U6 第 1 项、D11 | 第 1 节，SC1，第 7 节，第 11.4 节，README 的执行顺序 |
| U6 第 2 项、D12 | 第 1 节，SC1，FR-01、FR-03～FR-06、FR-08、FR-09、FR-12，第 6 节，第 12 节，第 11.1 节（OQ-1 已关闭） |
| U6 第 3 项、D13 | FR-04、FR-07，第 6 节，第 8 节，R-12，第 11.2 节（OQ-5 已关闭） |
| U7、D14 | FR-02，第 6 节 |
| U7、D15 | FR-02、FR-07，NFR-02，第 6 节，R-13、R-14，第 11.5 节 |
| U8、D16 | 本文的状态（v1.0 已批准） |
| U9、D17 | D15，FR-02，FR-10，R-13，第 11.5 节，本文的状态（v1.1 已批准） |
| U10、D18 | FR-02，FR-04，R-10、R-15，OQ-2（重开，D21 关闭），本文的状态（v1.2 已批准） |
| U10、D19 | 第 1 节，D15、FR-02，第 11.5 节，R-13，本文的状态（v1.2 已批准） |
| U10、D20 | 本文的状态（v1.2 已批准） |
| U11、D21 | D4、D6、D18，第 1 节，第 2.2 节继承的约定，第 3 节（角色，SC1、SC4、SC5、SC7），FR-01、FR-02、FR-04～FR-10、FR-12，NFR-05、NFR-06，第 6～9 节（A-2、A-7），第 10.1 节，R-2、R-3、R-8～R-10、R-15～R-17，OQ-2（已关闭），第 11.6 节，第 12 节，README，本文的状态（v1.3 已批准） |
| U12～U14、D22 | 方案设计 v1.0 的状态和第 11 节（OD-1～OD-4），本文的状态 |
| U15、D23 | 验证计划 v1.0 的状态，本文的状态 |
| vps-hardening 需求第 7.2 节 | 第 2.2 节继承的约定，FR-01，FR-05，FR-06 |
