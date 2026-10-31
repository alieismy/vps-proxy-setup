# VPS Proxy Setup 详细设计

| 项目 | 内容 |
|---|---|
| 状态 | v0.2 草案，待用户评审。保留 v0.1 的 M1 设计，修正命令、检查和注入契约；增加 API 与凭据、部署与恢复顺序、REALITY SNI 边界、Tunnel 服务和测试接缝（第 15～19 节）。本次补充 IPv4 订阅、监听与双栈出站的分层检查契约；核心修复评估为 DO-13，IPv6 出站策略为 DO-14，均未变更已批准基线。各节按 M1～M5 分阶段实现和验证，不把后续设计或真实环境验收设为 M1 的统一前置条件。没有批准、实现或运行验收记录 |
| 日期 | 2026-10-30 |
| 本次修订 | 2026-10-31，按需求 U16、D24 补充第 16.3 节的迁移管理前提和停止条件；按需求 v1.4（U17、D25～D28）同步上游：shortId 在 VPS 上生成，关闭 DO-12（第 15.1 节）；第 16.3 节分出默认沿用令牌和轮换两种情形，并补面板端口的核对；第 4.4 节和 DO-14 承接 FR-13；第 6.1 节列出 DO-13 的交付方式。按需求 v1.5（U19、D29、D30）：第 4.4 节和 DO-14 按已定的 FR-13 取值修改，DO-13 选定交付方式 A。按需求 v1.6（U20、D31）：第 4.4 节和 DO-14 改为 IPv6 失败时不改走 IPv4；按需求 U21、D32：方案设计 OD-5 已决定，第 4.4 节和 DO-14 据此收窄。按用户"请按你的意见接着做"冻结 DO-14 的检查细节：部署输入 `ipv6_ai_egress` 和部署记录（第 2.4、2.8 节），预检和检查项 `ipv6.egress`、`routing.ai-ipv6`（第 3、4.2 节），出站和规则的形态（第 4.4 节），写入顺序（第 16.1 节）；对应用例见验证计划 v1.2 的 VT-32～VT-34。用户 2026-10-31 批准验证计划 v1.2 和 DO-14 的取值（需求 U22、D33）。本文整体仍为 v0.2 草案，后续运行验收状态不变 |
| 上游 | [需求规格说明 v1.6](requirements.md)（已批准）、[方案设计 v1.4](solution-design.md)（已批准）、[验证计划 v1.2](verification-plan.md)（已批准）；[vps-hardening 详细设计](https://github.com/alieismy/vps-hardening/blob/master/docs/detailed-design.md)的形态和惯例 |
| 下游 | 实现和测试（从 M1 开始） |
| 深度 | 命令和 API 契约、数据来源、凭据与文件生命周期、写入及恢复顺序、服务边界、检查和测试接缝；不重复上游决策理由，不含实现代码和操作手册 |

**证据状态。** 本文只是设计，仓库中还没有实现，也没有运行证据。标"已核实"的，是 2026-10-30 对照上游源码或软件包数据核实的结果，本文新核实的见第 14 节；标"推断"的，要在指定的里程碑中证实，列在第 12 节。

## 1. 范围

v0.2 按方案设计第 10 节、验证计划第 7 节分阶段定义。以下内容沿用并修订 v0.1 的 M1 范围：

- 整体的命令契约（第 2 节）：子命令、退出码、输出格式、部署输入的格式和校验规则、本工具在 VPS 上的文件；
- `deploy`：只到预检为止（第 2.5、3 节）；
- `check`：第 4 节的检查目录和只读读取方式。M1 建立检查骨架并验证不依赖部署的项；依赖规则文本、完整入站或 Tunnel 的判据与注入在 M2、M3 补齐。后续项存在于目录中不表示已有运行验证；
- `target-check`（第 2.7、5 节）；
- 安装脚本（第 2.9 节）。发布和从公开地址的回验在 M4（VT-98）；
- 模块划分、实现约束和 M1 的测试框架（第 7～9 节）。

本版增加的跨阶段契约：

- 第 15、16 节：M2 的 API、凭据和写入契约；M3 的 Tunnel 接入与 M4 的恢复、迁移、回退顺序。`--migrate` 的命令分支按方案设计列入 M2，涉及 cloudflared 的部分随 M3，完整迁移演练在 M4；
- 第 17、18 节：REALITY SNI 的配置和观测边界、cloudflared 服务字段与动态用户；
- 第 19 节：复用现有 VT 用例的测试接缝，限定在隔离测试驱动中，不增加生产故障开关。

规则文本及其取舍（DO-9）、实际平台输出与固定摘要（DO-1～DO-3）、API 和服务运行行为、Cloudflare 账户设置及授权仍按第 12 节处理。DO-7、VO-5、VO-7 未获用户决定；DO-13 的交付方式已按需求 D30 选定；DO-14（FR-13 的检查细节）的取值已获用户批准（需求 D33），VO-8 已在验证计划 v1.2 中关闭。完整使用说明、客户端说明和操作命令不在本文件中，分别随 M4、M5 交付。2026-10-30 用户澄清：订阅使用节点 IPv4，双栈主要用于出站规则和路由，关注 `geosite:openai`、`geosite:anthropic`；随后明确选择先定义目标、检查和验证契约，将路由策略变更列为待决，保持已批准基线（第 4.4 节、DO-14）。该澄清 2026-10-31 补记为需求 U18；双栈的出站与路由已作为需求 FR-13 进入 M2（需求 D27），取值已按需求 D29、D31 确定，机制已按方案设计 OD-5 决定（需求 D32）。本文新增细节均为待评审设计，写明接口不等于授权执行接口。

## 2. 命令契约

### 2.1 调用与环境

- 入口为 `bin/vps-proxy-setup`，模块在 `lib/vps-proxy-setup/`，随工具发布的数据文件在 `share/vps-proxy-setup/`。入口用 `readlink -f` 定位自身，按上两级目录找这两个目录。安装后的位置是 `/usr/local/bin`、`/usr/local/lib/vps-proxy-setup` 和 `/usr/local/share/vps-proxy-setup`（第 2.9 节），与在仓库中运行时的相对布局相同。
- 入口固定 `PATH=/usr/sbin:/usr/bin:/sbin:/bin`、`LC_ALL=C` 和 `umask 077`，启用 `set -Eeuo pipefail`。`/usr/local/bin` 下的 `vps-hardening` 和 `cloudflared` 按绝对路径调用，不经过 `PATH` 查找。
- 输出中的说明文字为中文；检查项编号为英文，保持稳定，测试按编号判定。

| 子命令 | 参数 | 要求交互终端 | 是否修改系统 |
|---|---|---|---|
| `deploy` | `[--input <文件>] [--migrate]` | 是 | M1 中不修改（只预检）；M2 起按方案设计第 7.3 节 |
| `check` | 无 | 否 | 否 |
| `target-check` | `<主机名> [--probe-host <主机名>]` | 否 | 只写结果文件（第 2.7 节） |
| `--version`、`--help` | 无 | 否 | 否 |

三个子命令都要以 root 执行，由门槛检查项 `root` 判定（第 3 节）。`--version` 输出 `vps-proxy-setup <版本>`，版本是入口中的 `VPS_VERSION`。

**锁。** `deploy` 和安装脚本在读取输入之前，用 `flock -n` 取得 `/run/vps-proxy-setup.lock`；取不到时拒绝执行，退出码为 1，不等待。`check` 和 `target-check` 不取这个锁：部署进行中执行 `check`，得到的是中间状态。

### 2.2 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 命令达到自己的完成条件；检查没有不符合项（允许有警告和有明确原因的跳过） |
| 1 | 至少一项不符合，或者命令被拒绝 |
| 2 | 用法或输入错误 |
| 3 | 内部错误：命令意外失败，由 ERR 陷阱统一转换（第 8 节），避免被误读为"不符合" |

各命令的 0、1、2：

| 命令 | 0 | 1 | 2 |
|---|---|---|---|
| `deploy` | 完整首次部署完成且最终 `check` 为 0；`--migrate` 仅按第 16.3 节的安装准备条件返回 0，不表示迁移验收完成 | 不是 root；平台不符；锁被占用；预检失败；M1 预检完成但未实现写入；M2 尚未实现 Tunnel；管理员取消；某一步失败或写入结果无法确认；最终检查不符合 | 未知参数；标准输入不是终端；输入文件不合规；输入值不合法（第 2.4 节） |
| `check` | 没有不符合项 | 不是 root；至少一项不符合，包括数据库读不了（`xui.db`，VT-75） | 带了任何参数 |
| `target-check` | 没有不符合项且结果文件已发布 | 不是 root；至少一项不符合，包括解析不到地址；结果文件因权限、空间或 I/O 错误无法发布 | 缺少主机名；主机名或 `--probe-host` 不合法；未知参数 |
| 安装脚本 | 安装完成，或无需变更 | 拒绝或失败 | 未知参数、缺少取值、`--source-dir` 不是绝对路径 |

数据库读不了时退出码取 1（VT-75 交给本文确定）：这时检查范围内的配置无法确认，按不符合处理；原因写在 `xui.db` 一行中，检查不初始化或修复数据库。

外部请求超时、连接失败、数据库忙或不可读、API 明确拒绝均属预期操作失败，归入 1，不直接落入 ERR 陷阱。3 留给程序不变量破坏或未分类的意外错误。收到 SIGINT、SIGTERM 时，分别以 130、143 退出，清理私有临时文件并释放锁，不自动撤销已完成的部署步骤；SIGKILL 或掉电无法保证清理。测试驱动另记信号中断，不把它解释为部署成功。写请求响应丢失的处理见第 15.3 节。

M2 的阶段完成按 VT-70 的基线判定，工具仍返回 1 并说明 Tunnel 尚未完成；不为测试把 `cfd.* FAIL` 改为 PASS，也不增加生产用的跳过检查参数。完整 `deploy` 返回 0 仍不表示公网端口已开放或已完成客户端验收。

### 2.3 输出格式

与 vps-hardening 详细设计第 2.3 节相同：每个检查项一行，`[级别] 编号 说明`，编号左对齐占 30 列；级别为 `PASS`、`FAIL`、`WARN`、`SKIP`、`INFO`，只有 `FAIL` 使退出码为 1，`INFO` 不计数；最后一行汇总通过、不符合、警告和跳过的数量。用法错误和内部错误以 `[x]` 开头写到标准错误。

检查行与汇总写标准输出；交互提示、拒绝原因、未完成阶段和内部错误写标准错误。子进程的原始输出不直接透传。失败输出只包含步骤、稳定检查编号、已脱敏原因、是否已改动系统和人工接续位置；不回显请求体、认证头或原始 API 响应。`--help`、`--version` 写标准输出且不要求 root。`check` 说明不含运行时间和耗时，以满足 VT-76；`target-check` 的时间和耗时不受此限制。

输出中不出现以下秘密（FR-07、NFR-01）：UUID、订阅 ID、订阅路径、REALITY 私钥和 shortId、面板用户名和密码、`webBasePath`、API token、Tunnel 的令牌。shortId 不在 FR-07 的清单中，本文同样不输出：它与 UUID 一起构成客户端的连接参数，检查不需要显示它。可以输出的是：主机名、节点地址、端口、使用者代号和数量、版本、摘要不符的文件名、API token 的名称。

### 2.4 部署输入

**来源。** `--input <文件>` 给出的文件中没有的项，按下表的顺序交互读取。Tunnel 的令牌用 `read -rs` 读取，不回显；其余用 `read -r`。交互输入为空时按不合法处理。不给 `--input` 时全部交互读取。

**输入文件。**

- 必须是普通文件，不能是符号链接；属于 root（uid 0），权限正好是 0600（FR-12、VT-04），大小不超过 64 KiB。
- 文件只打开一次，属性在打开的文件描述符上核对，之后从同一个描述符读取，避免核对和读取之间文件被替换。
- 每行 `键=值`。值是第一个 `=` 之后的全部内容，原样使用，不去引号，不去空白。以 `#` 开头的行和空行忽略。
- 整个文件必须是合法的 UTF-8，不能有 CR（CRLF 换行的文件被拒绝）。未知的键和重复的键都被拒绝。
- 文件按数据解析，不执行（不用 `source`）。

**校验。**

| 键 | `deploy` | `--migrate` | 规则 |
|---|---|---|---|
| `sub_host` | 必须 | 必须 | 小写主机名：总长不超过 253；至少三个标签（订阅用子域名，方案设计第 7.5 节）；每个标签 1～63 个 `a-z0-9-`，不以 `-` 开头或结尾；不以点结尾，不是 IP 字面量 |
| `node_ip` | 必须 | 必须 | 点分十进制 IPv4（方案设计第 7.4 节），每段 0～255，没有前导零。拒绝：`0.0.0.0/8`、`10.0.0.0/8`、`100.64.0.0/10`、`127.0.0.0/8`、`169.254.0.0/16`、`172.16.0.0/12`、`192.0.0.0/24`、`192.168.0.0/16`、`198.18.0.0/15`、`224.0.0.0/4`、`240.0.0.0/4`。文档地址 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24` 接受，预检给出警告（验证计划第 3.3 节） |
| `target` | 必须 | 必须 | 规则同 `sub_host`，但至少两个标签；不能等于 `sub_host` |
| `remark` | 必须 | 不接受 | 合法的 UTF-8；以两个区域指示符（U+1F1E6～U+1F1FF）组成的国旗开头（D14）；编码后不超过 64 字节；没有控制字符（U+0000～U+001F、U+007F）；首尾不是空格 |
| `users` | 必须 | 不接受 | 以逗号分隔的代号，1～8 个（D2）；每个代号匹配 `^[a-z0-9][a-z0-9_-]{0,31}$`，所以不会是电子邮件地址（FR-03）；不能重复 |
| `ipv6_ai_egress` | 必须 | 必须 | `on` 或 `off`，是否启用 FR-13（需求 D29：由部署输入明确给出，不按探测结果自动启用，所以没有默认值）。`on` 时预检 `ipv6.egress` 必须通过（第 3 节）。`--migrate` 时填旧机部署记录中的值：恢复的数据库带着旧机的模板，填错时由 `routing.ai-ipv6` 发现 |
| `tunnel_token` | 必须 | 必须 | 标准 Base64；解码后是 JSON 对象：`a` 是非空字符串，`t` 是 UUID 格式的字符串，`s` 是标准 Base64 字符串、解码后至少 32 字节，`e` 可有可无（cloudflared 2026.10.5 的令牌格式，第 14 节） |

- 所有输入在主机检查之前校验。不合法时，每个不合法的键输出一行 `[x] 输入 <键>：<原因>`，不回显它的值，以退出码 2 结束，不做主机检查。
- `--migrate` 的输入文件中有 `remark` 或 `users` 时同样以退出码 2 拒绝：迁移不写设置（FR-09），这两项没有用处，出现说明拿错了文件。
- 输入文件的消费与删除见第 16.1 节。M1 只预检；输入错误、预检失败或管理员取消时不删除它。

### 2.5 `deploy`

M1 的流程：

1. 标准输入不是终端时，以退出码 2 结束（方案设计第 7.2 节）；
2. 解析参数，不合法时退出码 2；
3. 门槛检查项 `root`、`platform`（第 3 节），不满足时退出码 1；
4. 取得锁（第 2.1 节）；
5. 读取并校验输入（第 2.4 节）；
6. 预检的其余检查项（第 3 节），有不符合项时退出码 1；
7. 全部通过时，以 `[x]` 输出"预检通过；之后的步骤在 M2 实现，主机未改动"，退出码 1。

M2 在第 6 步之后加上变更计划和确认：管理员输入 `yes` 才继续，否则以退出码 1 结束、主机不变。VT-01 在此处取消以验证预检无副作用，不执行安装。之后的步骤见第 16.1 节，M2、M3 的完成条件分别见第 2.2 节。

### 2.6 `check`

不带参数，不要求交互终端，以 root 执行。检查项和数据来源见第 4 节。它不取锁，不写任何文件：数据库的快照、单元属性和接口的响应只保存在变量中。实现中确实需要临时文件时，只写在 `mktemp -d` 创建的私有目录中，退出时删除。

### 2.7 `target-check`

- **参数。** `<主机名>` 按第 2.4 节 `target` 的规则校验。`--probe-host <主机名>` 是异权威探测请求的 Host，规则相同，不能等于目标；默认是 `vps-proxy-setup-probe.invalid`（RFC 2606 保留的、不会被解析的名称）。默认值只能发现"按 Host 返回别的内容"的服务器；要检查同一网络或同一 CDN 上的某个具体站点，由管理员用这个参数给出（第 5 节）。
- **网络范围。** 只解析目标主机名，只连接它解析到的地址的 443/tcp。`--probe-host` 只作为 HTTP 的 Host 和 HTTP/2 的 `:authority` 发送，不解析、不连接（需求第 11.5 节第 4 条，VT-80）。
- **结果文件。** 写入 `/etc/vps-proxy-setup/target-check/<主机名>`（目录不存在时以 0700 创建，文件 0600），先写到同一目录下的临时文件，再改名替换。内容为键值行 `format=1`、`version=`（工具版本）、`time=`（UTC，ISO 8601）、`target=`、`probe_host=`，之后为第 5 节各检查项、汇总和末行 `result=PASS` 或 `result=FAIL`。完成的失败探测也覆盖旧结果，不能沿用旧 PASS；内部错误或信号中断不发布半成品，保留旧文件并在标准错误明确本次未更新。写文件失败不返回 0。
- **有效记录。** 文件必须是 root 所有的 0600 普通文件；格式可识别、必需键唯一且齐全、目标与输入一致、时间可解析且不晚于本机当前时间、检查项完整且计数与汇总一致。只有 `result=PASS` 且没有 FAIL 才可供预检使用。缺失、截断、错误类型或未知格式视为没有有效核实结果。WARN 保留供管理员判断，不把它提升为隔离证明。记录只作本机证据，不增加签名或主机身份绑定。

### 2.8 本工具在 VPS 上的文件和固定的端口

`/etc/vps-proxy-setup/` 属于 root，权限 0700（方案设计第 7.2 节），其中的文件都是 0600：

| 文件 | 写入者 | 读取者 | 内容与生命周期 |
|---|---|---|---|
| `target-check/<主机名>` | `target-check` | 预检的 `target.checked`；M2 起写入部署记录 | 第 2.7 节；新的一次覆盖旧的 |
| `deploy.conf` | `deploy`（M2 起） | `check` 的 `record.consistent` | 部署记录，键值行，按数据解析：`tool_version`、`xui_version`、`cloudflared_version`、`mode`（`deploy` 或 `migrate`）、`deployed_at`、`sub_host`、`node_ip`、`target`、`target_check_time`、`ipv6_ai_egress`。第 16 节规定发布时点；它记录预期配置，不证明整个部署或迁移已完成。部署之后不由本工具修改 |
| `tunnel-token` | `deploy` 第 8 步（M3） | systemd 经 `LoadCredential` 交给 cloudflared | 只有令牌一行；迁移时默认沿用，怀疑泄露、旧机被入侵或需要隔离无法管理的旧连接器时轮换（方案设计第 7.9 节，需求 D26） |
| `handoff` | `deploy` 第 7 步（M2） | 管理员 | 交给管理员的文件：面板凭据、`webBasePath`、每人的订阅地址；管理员取走后删除 |

随工具发布的数据文件（第 2.9 节）：`share/vps-proxy-setup/clash-rules.yaml`（规则文本，M2）、`share/vps-proxy-setup/vps-proxy-setup-cloudflared.service`（cloudflared 的服务单元，M3）。部署时服务单元被复制到 `/etc/systemd/system/`；单元名不用上游的 `cloudflared.service`，以免与 `cloudflared service install` 生成的单元相互覆盖。

固定的端口：

| 用途 | 地址 | 说明 |
|---|---|---|
| REALITY 入站 | 所有地址的 443/tcp | 方案设计第 7.4 节 |
| 转发入站 | 127.0.0.1:20443 | REALITY 的 target。不在 Linux 默认的临时端口范围（32768～60999）内，不会因为本机的出站连接先占用而绑定失败 |
| 订阅服务 | 127.0.0.1:2096 | 方案设计第 7.5 节 |
| cloudflared metrics | 127.0.0.1:20241 | 方案设计第 7.5 节 |
| 3X-UI 的 api 入站、Xray metrics | 127.0.0.1:62789、127.0.0.1:11111 | v3.11.0 模板的默认值，不改（已核实） |
| 面板 | 127.0.0.1:面板端口 | 取自 vps-hardening 的记录 |

### 2.9 安装脚本

仓库根目录的 `install.sh` 是发行版安装脚本，沿用 vps-hardening 详细设计第 2.12 节的做法：绑定发行版、只允许 HTTPS 下载、按 `SHA256SUMS` 逐个校验、先暂存再改名替换、未完成的替换由退出陷阱恢复为安装前的文件、`--source-dir` 用于发布前验证。它只放置文件，不执行 `deploy`、`check` 或 `target-check`。与 vps-hardening 不同的地方：

- **资产。** 入口、全部模块和 `share/vps-proxy-setup/` 下的数据文件。`tests/static.sh` 核对资产清单正好是这些文件，版本等于入口的 `VPS_VERSION`。
- **位置。** 入口在 `/usr/local/bin/vps-proxy-setup`（0755），模块在 `/usr/local/lib/vps-proxy-setup/`（目录 0755，文件 0644），数据文件在 `/usr/local/share/vps-proxy-setup/`（目录 0755，文件 0644），属主和属组都是 root。"未做变更"指这三处的文件与发行版逐字节相同、没有多余的文件，属主和权限也相同。
- **拒绝条件。** 不是 root；缺少所需的命令；锁被占用（第 2.1 节）。
- **结尾的提示。** 提示先用 `target-check` 核实候选的 target，再执行 `deploy`。

M1 实现安装脚本并用 `--source-dir` 在本地验证；发布和从公开地址的回验在 M4（VT-98）。

## 3. 预检检查项

`deploy` 和 `deploy --migrate` 使用同一组检查项。前两项是门槛：不满足时立即结束，后续检查不执行。之后的检查都只读，不改动主机（FR-12）。

| 编号 | 检查 | 不符合的条件 | 验证 |
|---|---|---|---|
| `root` | 运行权限 | 不是 root | VT-05 |
| `platform` | 平台 | `/etc/os-release`（按数据解析，不执行）中 `ID` 不是 `debian` 或 `VERSION_ID` 不是 `13`；`dpkg --print-architecture` 不是 `amd64`；PID 1 不是 systemd；运行在容器中（`systemd-detect-virt --container` 不是 `none`） | VT-05 |
| `inputs.*` | 输入摘要 | 不判定不符合：每项输入一行 `INFO`，回显已校验的值，令牌只显示"已提供"。`--migrate` 时没有 `remark` 和 `users` 两行。`inputs.node_ip` 在两种情况下为警告：节点地址在文档地址段中；节点地址不在本机任何接口上（可能是 1:1 NAT，也可能填错，由管理员核对） | VT-01、VT-03 |
| `deps` | 依赖的命令 | 缺少 `curl`、`jq`、`sqlite3`、`openssl`、`ss`、`ip`、`systemctl`、`sha256sum`、`base64`、`iconv`、`timeout`、`flock`、`getent`、`lslocks` 中的任何一个。说明中列出要安装的 Debian 软件包 | VT-01 |
| `apt.idle` | 包管理器 | dpkg、apt 或 unattended-upgrades 的锁被持有，或者 apt、dpkg 进程在运行。判定方法与 vps-hardening 相同（它的详细设计第 6 节）。3X-UI 的 `install.sh` 会调用包管理器（M2），所以在预检中先排除 | VT-01 |
| `hardening.state` | 加固状态 | `/var/lib/vps-hardening/state` 读不到，或其中第一行 `status=` 的值不是 `applied`（需求 A-1） | VT-05 |
| `hardening.version` | vps-hardening 的版本 | 不判定不符合：`/usr/local/bin/vps-hardening --version` 的版本在测试过的列表中时通过，否则为警告并显示版本。列表目前只有 `0.1.1`（需求 A-1、D9，第 12 节 DO-7） | VT-01 |
| `hardening.panel-port` | 面板端口 | 状态文件中第一行 `panel_port=` 读不到，或者不是 1～65535 的整数，或者是 22 或第 2.8 节中本工具使用的端口。通过时在说明中显示端口 | VT-05 |
| `hardening.verify` | 加固验证 | `vps-hardening verify` 的退出码不为 0（NFR-04）。说明中给出退出码；它的输出不转录，管理员另行执行查看 | VT-05 |
| `new-host.xui` | 存量判定 S1 | 存在 `/usr/local/x-ui`、`/usr/bin/x-ui`，systemd 能找到 `x-ui.service` 的单元文件，或者存在 `/etc/default/x-ui`、`/etc/conf.d/x-ui`、`/etc/sysconfig/x-ui` 中的任何一个 | VT-02 |
| `new-host.xui-db` | 存量判定 S2 | 存在 `/etc/x-ui` | VT-02 |
| `new-host.cloudflared` | 存量判定 S3 | 存在 `/usr/local/bin/cloudflared`；`PATH` 中有 `cloudflared`；dpkg 记录 `cloudflared` 已安装；systemd 能找到 `cloudflared.service`、`vps-proxy-setup-cloudflared.service` 或 `cloudflared-update.timer`；存在 `/etc/cloudflared` | VT-02 |
| `new-host.state` | 是否部署过 | 存在 `/etc/vps-proxy-setup`，但不是"属于 root、权限 0700、其中只有同样属于 root 且 0700 的 `target-check` 目录，目录中只有普通文件"。只有 `target-check` 的结果时仍算新机 | VT-02 |
| `ports.free` | 要用的端口 | 443、面板端口和第 2.8 节中 127.0.0.1 上的端口，任何一个已有 TCP 监听（不论地址）。说明中列出被占用的端口 | VT-01 |
| `tuning.dropin` | 调优的 drop-in | 不判定不符合：`/etc/systemd/system/x-ui.service.d/90-proxy-vps.conf` 不存在时为警告。之后 vps-tuning 的严格验证需要它（NFR-04，README 的执行顺序） | VT-01 |
| `target.checked` | target 的核实 | 没有第 2.7 节定义的有效 PASS 记录。结果早于 7 天时为警告：小站点容易改版或迁走（需求第 11.5 节）；记录中已有的警告应一并提示 | VT-01 |
| `ipv6.egress` | FR-13 的本机前提 | 输入 `ipv6_ai_egress=on` 时按第 4.2 节的同名项判定：没有可用的全局 IPv6 地址或 IPv6 默认路由时不符合，有多个可用地址时为警告。输入为 `off` 时为 `SKIP`。只有 IPv4 的主机填 `off` 即可照常部署（需求 D29） | VT-33 |

`target.checked` 来自 FR-02 的验收"部署记录中有 target 在部署所用的 VPS 上的核实结果"：没有核实过的 target 不进入部署。`--migrate` 同样要求，因为核实要在部署所用的 VPS 上进行。

## 4. check 检查项

### 4.1 数据来源与读取方式

**数据库。** 路径固定为 `/etc/x-ui/x-ui.db`。`xui.env` 和 `xui.unit` 确认 3X-UI 没有经环境变量改用别的位置：x-ui 每次启动都读取三个环境文件中第一个存在的那个，其中的 `XUI_DB_FOLDER`、`XUI_BIN_FOLDER` 等会改变数据库和程序的位置（已核实，第 14 节）。

打开方式按 SQLite 对只读 WAL 的规定选择，但 `mode=ro` 和预先检查侧文件并不单独保证不新建文件：目录可写时 SQLite 仍可创建侧文件。下表是候选读取策略，DO-1 在 M1 中核实稳定状态及状态切换；不在 `/etc/x-ui` 中新建或删除文件仍是 VT-72 的门禁，不能以返回 FAIL 抵消已经发生的写入。

| x-ui 状态与 `-wal`、`-shm` | `-journal` | 打开方式 |
|---|---|---|
| 服务稳定运行，侧文件都存在 | 不存在 | `file:/etc/x-ui/x-ui.db?mode=ro`；侧文件消失的竞态由 DO-1 验证 |
| 服务已停止、没有并行管理操作，侧文件都不存在 | 不存在 | `file:/etc/x-ui/x-ui.db?mode=ro&immutable=1`；不可变前提及启动竞态由 DO-1 验证 |
| 只有一个侧文件、服务处于启动/停止过渡，或状态无法确认 | — | 不读取，`xui.db` 不符合，不把侧文件存在与否当作服务状态证明 |
| 任意 | 存在 | 不读取，`xui.db` 不符合：不尝试恢复可能的热日志 |

- 命令为 `sqlite3 -readonly -safe -batch -bail -init /dev/null <URI> <SQL>`，设 5 秒的忙等待，整体 30 秒超时。`-safe` 禁止写文件的点命令和函数，作为额外的保险。
- 一次调用、一条语句、一个读事务，输出一个 JSON 文档作为快照，所有库项都在这份快照上判定，不会读到两个时刻的数据。
- 快照中没有秘密：语句只选需要的列，不用 `SELECT *`；`stream_settings` 去掉 REALITY 私钥之后输出，另加一个"私钥非空"的布尔值；shortId 只输出个数、长度和是否为十六进制；需要用到订阅路径的判定（`sub.uri`、`sub.paths`）在 SQL 中算成布尔值和长度，路径本身不离开 `sqlite3` 进程；使用者只选代号、启用状态、flow 和 `limit_ip`，不选 UUID 和订阅 ID；模板中的出站只取标签和协议。
- 设置表中没有某个键时，按 v3.11.0 的默认值判定（3X-UI 自己就是这样读取的，已核实）。被检查的键在设置表中有多行时，`xui.db` 判为不符合，不去猜 3X-UI 用哪一行。

读取前后确认受管理的 x-ui 状态；检测到变化时本次库项不作通过结论，报告 `xui.db FAIL`、依赖项 SKIP。前后检测只用于作废不可靠结果，不能证明已消除所有竞态。若 M1 实测发现源目录写入，须修订读取方法并重过 VT-72 后才能宣称只读通过；不预设新增 VFS、复制数据库、停服务或锁框架。`check` 不与面板或管理员维护操作组成事务，稳定状态下的一次 SQL 快照也不等于运行中的 Xray 配置。

**其他来源。** 文件的属性和 SHA-256；`systemctl show` 给出的单元的生效属性（合并了 drop-in 之后的值）；`ss -Hltn`（地址族核对时分别用 `-4`、`-6`，IPv6 socket 补充 `-e` 读取 `v6only`）；`ip` 的只读地址与路由输出；`fail2ban-client status`；`/usr/local/x-ui/x-ui -v`；`curl` 访问 `127.0.0.1:20241` 的 `/ready` 和 `/config`；`vps-hardening verify` 的退出码。

| 来源 | 负责的检查 | 证据上限及读取失败 |
|---|---|---|
| SQLite 单次脱敏快照；v3.11.0 默认设置 | 第 4.2 节标“库”的项，包括 `record.consistent` 的比较值 | 证明持久化配置；不证明已生成、加载或外部可达。读取失败由 `xui.db` 报告，依赖项 SKIP |
| 固定摘要、文件属性、安装记录；vps-hardening 的状态文件 | `xui.files`、`cfd.files`、`state.perms`、`cfd.token`、预检各记录项 | 证明所查文件，缺失/不可读按对应项 FAIL；不输出秘密内容 |
| systemd 管理器的属性；当前 MainPID 的必要进程属性 | `xui.unit`、服务状态、`cfd.unit`、`cfd.service`、`cfd.autoupdate` | 管理器配置和当前进程分开核对，见第 18.2 节；读取失败不能按默认通过 |
| `ss` 的地址族、监听地址、`v6only` 属性；`ip` 的本机地址与路由；Fail2ban 状态 | 各监听项、第 4.4 节的本机网络前提、`xui.ipl` | 只证明本机状态，不证明公网入站或出站连通性；所需属性或地址读取失败不能默认通过，也不能将未知状态当作 IPv4-only。IPv6 地址和默认路由存在不等于 IPv6 业务可用；Fail2ban 降级为文件检查时按已有规则注明 |
| cloudflared `/ready`、`/config` | `cfd.ready`、`cfd.routes` | 分别证明连接就绪和本机可见的生效路由，不证明边缘证书、挑战策略或客户端可用；超时/解析失败为 FAIL |
| `vps-hardening verify` 的退出码 | `hardening.verify` | 依赖组件的检查结果；不复制其实现，不转录原始输出 |

没有 `cert.pem` 只证明所列目录中未发现账户证书，不是全盘不存在 Cloudflare API Token 的证明。本工具不接收或生成该 API Token；部署路径与 VT-55 的文件核验共同覆盖本工具管理范围，任意管理员另存的凭据不靠全盘内容扫描证明不存在。

### 4.2 检查项

"库"表示依赖数据库快照：`xui.version` 或 `xui.db` 不符合时，这些项报告为 `SKIP`（FR-07，VT-73）。REALITY 入站或转发入站不存在时，依赖它的项同样报告为 `SKIP`，不符合由 `inbounds.set` 报告一次。"阶段"指这一项的注入用例最早在哪个里程碑（验证计划 VT-71，第 9.5 节）。

**门槛与 3X-UI 程序**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `root`、`platform`、`deps` | 同预检（第 3 节），不满足时立即结束。`deps` 只列 `check` 用到的命令：`sqlite3`、`jq`、`curl`、`ss`、`ip`、`systemctl`、`sha256sum`、`od`、`timeout`；没有 `fail2ban-client` 时 `xui.ipl` 只按文件判定 | FR-07 | M1 |
| `xui.version` | `/usr/local/x-ui/x-ui -v`（10 秒超时）不存在、失败，或者输出不是 `3.11.0`。`-v` 只读取环境文件、打印版本，不打开数据库（已核实）；这个程序本来就以 root 作为 x-ui 服务运行，检查执行它不扩大它的权限 | FR-01、FR-07 | M1 |
| `xui.files` | `/usr/local/x-ui/x-ui`、`/usr/local/x-ui/bin/xray-linux-amd64`、`/usr/bin/x-ui`、`/etc/systemd/system/x-ui.service` 中有与固定的摘要（第 6 节）不符的或不存在的。说明中列出文件名。Geo 数据文件不核对：面板可以更新它们 | FR-01、NFR-05 | M1 |
| `xui.unit` | `x-ui.service` 的生效属性不是：`ExecStart` 为 `/usr/local/x-ui/x-ui`、没有参数；`WorkingDirectory` 为 `/usr/local/x-ui`；`Environment` 只有 `XRAY_VMESS_AEAD_FORCED=false`；`EnvironmentFiles` 只有可缺省的 `/etc/default/x-ui`；`User` 为空或 `root`。drop-in 改动这些属性时同样发现 | FR-01 | M1 |
| `xui.env` | `/etc/default/x-ui`、`/etc/conf.d/x-ui`、`/etc/sysconfig/x-ui` 中有一个存在。部署不创建它们，SQLite 安装时 `install.sh` 也不创建（已核实） | FR-07 | M1 |
| `xui.service` | `x-ui.service` 不是 `enabled`，或者不是 `active` | FR-07 | M1 |
| `xui.ipl` | 存在 `/etc/fail2ban/filter.d/3x-ipl.conf`、`action.d/3x-ipl.conf` 或 `jail.d/3x-ipl.conf`；`fail2ban-client status` 的 jail 列表中有 `3x-ipl`。fail2ban 没有运行时只按文件判定，并在说明中注明 | FR-01、FR-07 | M1 |
| `xui.db` | 第 4.1 节的读取失败：文件不存在；侧文件或服务状态不满足读取前提；读取期间检测到状态变化；有 `-journal`；`sqlite3` 报错或快照无效；被检查的设置键有多行。说明中给出脱敏原因 | FR-07 | M1（VT-72、VT-75） |

**面板、入站与路由（库）**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `panel.listen` | `webListen` 不是 `127.0.0.1`；`webPort` 不等于 vps-hardening 记录的面板端口；面板端口没有监听，或者在回环地址之外也有监听（`ss`） | FR-01、FR-07 | M1 |
| `inbounds.set` | 入站不正好是两个：协议 `vless`、端口 443、监听为空（所有地址）；协议 `tunnel`、监听 `127.0.0.1`。两个都要启用，`node_id` 为空。其他任何入站都不符合，说明中只列出协议和端口 | FR-02 | M2 |
| `reality.settings` | REALITY 入站的 `stream_settings` 不是：`network` 为 `tcp`，`security` 为 `reality`；`realitySettings` 中 `target` 和 `dest` 恰有一个，值为 `127.0.0.1:<转发入站的端口>`；`serverNames` 正好一项，是合法的主机名；`shortIds` 正好一项，是 2～16 位、长度为偶数的十六进制；私钥非空；`settings.fingerprint` 为 `chrome`；`xver` 为 0 或不设。入站的 `settings.decryption` 为 `none`，`disable_flow` 为 0。`network` 必须是 `tcp`：不用 VLESS 加密时（`decryption` 为 `none`），3X-UI 只在 `tcp` 加 `reality` 或 `tls` 时允许 flow（已核实） | FR-02 | M2 |
| `reality.share` | `share_addr_strategy` 不是 `custom`；`share_addr` 不是 IPv4 字面量；`exclude_from_sub` 不为 0 | FR-02 | M2 |
| `reality.hosts` | REALITY 入站有未停用的主机（Hosts），其地址不是 IP 字面量，或者打开了 `mihomo_x25519`（R-11、R-15） | FR-02、FR-04 | M2 |
| `forwarder.settings` | 转发入站不是：端口等于 REALITY `target` 中的端口；`settings` 中 `rewriteAddress` 和旧名 `address` 恰有一个，值为 `127.0.0.1`，`rewritePort` 和旧名 `port` 恰有一个，值为 443，`allowedNetwork` 和旧名 `network` 至多一个，值为 `tcp`，`followRedirect` 为假或不设；`sniffing` 为启用，`destOverride` 正好是 `["tls"]`，`routeOnly` 和 `metadataOnly` 为假或不设；没有传输层安全。新旧两个名字同时出现时不符合：哪个生效取决于 Xray 的解析顺序，不作猜测 | FR-02 | M2 |
| `routing.rules` | 设置表中没有 `xrayTemplateConfig`（模板仍是默认值）；`routing.domainStrategy` 不是 `AsIs`（不设视同 `AsIs`）；按 3X-UI 生成配置时的做法去掉 `enabled` 为假的规则之后，前四条不依次是方案设计第 7.4 节的规则 1～4：转发入站且域名 `full:<serverNames 的那一项>` → `direct`；转发入站 → `blocked`；REALITY 入站且域名 `geosite:cn` → `blocked`；REALITY 入站且 IP `geoip:cn` → `blocked`。每条只能有这些字段，另外允许 `type` 为 `field` 和 `enabled` 为真；入站按标签匹配，标签取自入站表 | FR-02、D22 | M2 |
| `routing.outbounds` | 模板的出站中没有正好一个标签为 `direct`、协议为 `freedom` 的，或者没有正好一个标签为 `blocked`、协议为 `blackhole` 的。规则 1～4 的含义依赖这两个出站。`direct` 的 `finalRules` 不检查（方案设计第 7.6 节，验证计划第 3.6 节） | FR-02 | M2 |

**双栈出站（FR-13）**

两项都按部署记录的 `ipv6_ai_egress` 判定；记录缺失或这个值无效时两项为 `SKIP`，不符合由 `record.consistent` 报告。出站和规则的形态见第 4.4 节。

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `routing.ai-ipv6` | （库）记录为 `off`：模板中有标签为 `ai-ipv6` 的出站，或有 `outboundTag` 为 `ai-ipv6` 的规则；都没有时为 `SKIP`，说明未启用。记录为 `on`，有下列任一情形：① 标签为 `ai-ipv6` 的出站不正好一个，或者它不是：只有 `tag`、`protocol`、`settings`、`streamSettings` 四个字段；`protocol` 为 `freedom`；`settings` 只有 `finalRules`，与 `direct` 的 `finalRules` 按 JSON 值相同；`streamSettings` 只有 `sockopt`，`sockopt` 只有 `domainStrategy`，值为 `ForceIPv6v4`。所以 `sendThrough`、`happyEyeballs`、`dialerProxy`、旧名 `settings.domainStrategy` 都不符合（需求 D32）；② 出站列表的第一个不是 `direct`：没有命中规则的连接走第一个出站（第 14 节）；③ 按 `routing.rules` 的做法去掉停用的规则之后，第五条不是：REALITY 入站的标签，`domain` 正好是 `geosite:openai` 和 `geosite:anthropic`（顺序不限），`outboundTag` 为 `ai-ipv6`，字段的限制同 `routing.rules`；或者还有别的规则指向 `ai-ipv6`；④ 模板中有 `dns`：部署不写它，它的 `queryStrategy`、`hosts` 和服务器都会改变这个出站的解析结果，例如 `UseIPv4` 使有 AAAA 的域名也走 IPv4，`UseSystem` 使本机没有 IPv6 路由时改走 IPv4（第 14 节）。自带的 `geosite.dat` 缺少这两个类别时 Xray 拒绝加载配置（第 14 节），443 不再监听，由 `listen.reality` 发现，本项不另读 `geosite.dat` | FR-13、D29、D31、D32 | M2 |
| `ipv6.egress` | 记录为 `off` 时为 `SKIP`。记录为 `on`：`ip -j -6 addr show` 中没有可用的全局 IPv6 地址，或者 `ip -j -6 route show default` 为空。可用的地址指：所在接口为 UP，`scope` 为 `global`，不在 `fc00::/7` 中，没有 `tentative`、`dadfailed`、`deprecated` 标志；文档地址 `2001:db8::/32` 接受（验证计划第 3.3 节）。可用的地址多于一个（包括临时地址）时为警告：不固定源地址，出口可能随内核的源地址选择变化（需求 D32）。说明中只给地址数量和标志，不输出地址。只读本机配置，不发起连接，不证明 IPv6 业务可达（第 4.4 节）；`ip` 的 JSON 字段在 M2 随 DO-2 核实。预检中的同名项用同一判定（第 3 节） | FR-13、D29、D31、D32 | M2 |

**使用者（库）**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `clients.count` | 不判定不符合：`INFO` 输出关联到 REALITY 入站的使用者数量和代号，停用的注明；没有使用者时为警告 | FR-03 | M2 |
| `clients.flow` | 关联到 REALITY 入站的使用者中，有 flow 不是 `xtls-rprx-vision` 的，或者关联的 `flow_override` 不是空、也不是 `xtls-rprx-vision` 的。说明中列出代号 | FR-03 | M2 |
| `clients.limit-ip` | 有 `limit_ip` 不为 0 的使用者（IP Limit 不启用，FR-01）。没有使用者时通过 | FR-01、FR-07 | M2 |

**订阅（库）**

按方案设计第 7.5 节的表。设置表中没有的键按 v3.11.0 的默认值判定。

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `sub.enable` | `subEnable` 不为真 | FR-04 | M1 |
| `sub.listen` | `subListen` 不是 `127.0.0.1`，或 `subPort` 不是 2096 | FR-04、D21 | M2 |
| `sub.cert` | `subCertFile` 或 `subKeyFile` 不为空 | FR-04、D21 | M1 |
| `sub.domain` | `subDomain` 为空或不是合法的主机名 | FR-04 | M2 |
| `sub.uri` | `subURI` 不等于 `https://` 加 `subDomain` 加 `subPath`，或者 `subClashURI` 不等于 `https://` 加 `subDomain` 加 `subClashPath`。3X-UI 把这两个值与订阅 ID 直接拼成订阅地址，所以值中要有路径（已核实，第 14 节） | FR-04 | M2 |
| `sub.paths` | `subPath` 或 `subClashPath` 是默认值（`/sub/`、`/clash/`），或者两个斜杠之间少于 16 个字符。这一项只能排除默认值和过短的路径：设置表中看不出路径是不是初始化时随机生成的，16 个字符以上的自定义路径即使可以猜到也会通过，所以它不证明 FR-04"订阅路径用初始化时生成的随机值"已满足（第 11 节） | FR-04 | M1 |
| `sub.clash` | `subClashEnable` 或 `subClashEnableRouting` 不为真 | FR-04 | M2 |
| `sub.rules` | `subClashRules` 与 `share/vps-proxy-setup/clash-rules.yaml` 不是逐字节相同（两边都转成十六进制比较）。M1 中还没有规则文本，这一项为 `SKIP` | FR-04、D13 | M2 |
| `sub.json` | `subJsonEnable` 不为假 | FR-04 | M1 |
| `sub.info-node` | `subInfoNodeEnable` 不为假 | 方案设计第 7.5 节 | M1 |
| `sub.updates` | `subUpdates` 不是 12 | FR-04 | M1 |
| `sub.remark` | `remarkTemplate` 不是 `{{INBOUND}}` | FR-02 | M2 |

订阅的信息页面不设检查项：v3.11.0 没有关闭它的设置，方案设计第 7.5 节的结论是不需要关闭（FR-07"内置页面按 FR-04 中核实的结论检查"）。

**监听端口（`ss`）**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `listen.reality` | 443/tcp 没有可接受 IPv4 的通配监听；配置公网 IPv6 的主机还缺少 IPv6 通配监听。IPv4 通配 socket 和 IPv6 通配 socket 分别证明各自地址族的监听，两者均存在时不依赖 `v6only`。只有依靠 IPv6 通配 socket 满足 IPv4 要求时，才必须确认 `v6only=0`；此时为 1 或未知均 FAIL，未知须说明无法确认 IPv4 接收能力。所需地址族信息读取失败也为 FAIL；不要求两个独立 socket，不仅凭 `*` 或 `[::]` 字符串通过。分层边界见第 4.4 节 | FR-02、方案第 7.4 节 | M2 |
| `listen.forwarder` | 转发入站的端口（取自数据库中的转发入站；数据库读不了或没有转发入站时用 20443）没有监听，或者在回环地址之外也有监听 | FR-02、FR-06 | M2 |
| `listen.sub` | 2096 没有监听，或者在回环地址之外也有监听 | FR-04、FR-06 | M2 |
| `listen.api`、`listen.metrics` | 62789 或 11111 没有监听，或者在回环地址之外也有监听 | FR-06 | M2 |

"回环地址"指 `127.0.0.0/8` 和 `::1`。面板端口在 `panel.listen` 中检查，cloudflared 的 metrics 在 `cfd.metrics` 中检查。

**秘密、残留与部署记录**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `secrets.install-result` | 存在 `/etc/x-ui/install-result.env`：其中有面板凭据和 admin 范围的 API token（方案设计第 4.2 节） | NFR-01 | M2 |
| `secrets.api-tokens` | 不判定不符合（库）：有启用的 API token 时为警告，显示数量和名称。部署结束时会删除安装 token（方案设计第 7.3 节第 7 步），之后出现的可能是管理员自己建的 | NFR-01 | — |
| `secrets.handoff` | 不判定不符合：`/etc/vps-proxy-setup/handoff` 存在时为警告，提示取走后删除 | FR-12 | — |
| `absent.acme` | 存在 `/root/.acme.sh`，或者 `PATH` 中有 `acme.sh` | D21、FR-05 | M1 |
| `absent.cf-credentials` | cloudflared 的账户证书 `cert.pem` 出现在它的默认搜索目录中：`/root/.cloudflared`、`/root/.cloudflare-warp`、`/root/cloudflare-warp`、`/etc/cloudflared`、`/usr/local/etc/cloudflared`（已核实，第 14 节）。这份证书能管理整个账户的 Tunnel，VPS 上只应有令牌（方案设计第 4.5 节） | D21、FR-05 | M1 |
| `state.perms` | `/etc/vps-proxy-setup` 不属于 root 或权限不是 0700，或者其中有不属于 root、权限不是 0600 的文件（`target-check` 目录本身为 0700）。目录不存在时为 `SKIP`，部署记录的缺失由下一项报告 | NFR-01 | M2 |
| `record.consistent` | 没有 `deploy.conf` 或解析失败；`ipv6_ai_egress` 不是 `on` 或 `off`；记录的 `sub_host` 与 `subDomain`、`target` 与 `serverNames` 的那一项、`node_ip` 与 `share_addr` 有不一致的（库）。面板中有意修改了这些值时，部署记录随之按文档更新（M4 的文档） | FR-07 | M2 |

**cloudflared 与 Tunnel**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `cfd.files` | `/usr/local/bin/cloudflared` 不存在、与固定的摘要不符（第 6 节），或者不属于 root、权限不是 0755 | FR-05、NFR-05 | M3 |
| `cfd.unit` | 正式单元文件与发布文件不同；`FragmentPath` 不是正式路径；`DropInPaths` 非空；`NeedDaemonReload` 为真；管理器加载的完整 `ExecStart`、`DynamicUser`、`LoadCredential` 等必需字段与第 18.1 节不符。字段的 systemctl 表示在 M3 核实，不用磁盘摘要代替加载状态 | FR-05 | M3 |
| `cfd.service` | 单元不是 `enabled` 或 `active`；MainPID 无效、进程消失、有效 UID 为 0，或当前进程参数不符合第 18.2 节。只报告判定，不输出原始命令行 | FR-05 | M3 |
| `cfd.autoupdate` | 单元的生效 `ExecStart` 中没有 `--no-autoupdate`；`cloudflared-update.timer` 或 `cloudflared-update.service` 已加载并启用。单元不存在时同样不符合（FR-05 要求"服务带 `--no-autoupdate` 运行"） | FR-05 | M3 |
| `cfd.token` | `/etc/vps-proxy-setup/tunnel-token` 不是普通文件、不属于 root、权限不是 0600，或者为空。检查不读取它的内容 | FR-05、NFR-01 | M3 |
| `cfd.metrics` | 20241 没有监听，或者在回环地址之外也有监听 | FR-05、FR-06 | M3 |
| `cfd.ready` | `GET http://127.0.0.1:20241/ready`（5 秒超时）不是 200，或者 `readyConnections` 不大于 0 | FR-05 | M3（测试 VPS） |
| `cfd.routes` | `GET http://127.0.0.1:20241/config`（5 秒超时）失败或结构无效；`config.ingress` 不正好是两条：第一条 `hostname` 等于 `subDomain`（数据库读不了时用有效部署记录的 `sub_host`），`service` 为 `http://127.0.0.1:2096`，`path` 为 null，`originRequest.httpHostHeader` 为空字符串；第二条 `hostname` 为空字符串、`path` 为 null、`service` 为 `http_status:` 加一个 4xx 状态码。这里“未设置”不指 JSON 属性不存在；固定版本的必需字段缺失或类型不符时不能默认为通过。没有可核对的订阅主机名时同样 FAIL。只输出经校验的主机名和服务地址，不转录原始响应。真实兜底及非 ingress 路由的边界仍由 DO-4 核实 | FR-05、FR-07 | M3（测试 VPS） |

**加固**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `hardening.verify` | `vps-hardening verify`（120 秒超时）的退出码不为 0。说明中给出退出码 | NFR-04 | M1 |

### 4.3 与验证计划的对应

- **VT-70 的 M2 基线。** 部署第 1～7 步之后、还没有 cloudflared 时，`cfd.*` 各项都不符合（`cfd.autoupdate` 因为单元不存在而不符合），其余项通过；`secrets.handoff` 在管理员删除那个文件之前为警告，不影响判定。这与验证计划 VT-70 的"cloudflared 和 Tunnel 的各项 FAIL，其余全部 PASS"一致。`routing.ai-ipv6`、`ipv6.egress` 在主配置（不启用）上为 `SKIP`，在启用 FR-13 的覆盖层上为 PASS（验证计划 VT-32、VT-33）。
- **VT-70、VT-53 的 M3 基线。** 测试令牌下只有 `cfd.ready`、`cfd.routes` 不符合。
- **一种偏差对应几项。** 有的偏差同时由数据库和监听端口两处发现，例如订阅改为监听 `0.0.0.0` 并重启之后，`sub.listen` 和 `listen.sub` 都不符合。VT-71 中"对应的项"指本节为这种偏差列出的全部项，第 9.5 节逐一列出 M1 的注入和预期。

### 4.4 IPv4 订阅与双栈出站的检查契约

**效力与范围。** 需求 v1.4 已把双栈的出站与路由列为 FR-13（P1，M2，需求 D27），取值已按需求 D29、D31 确定，机制已按方案设计 OD-5 决定（需求 D32）；本节的出站部分是 FR-13 的检查和验证契约，检查细节已冻结（DO-14，需求 D33）。用户已明确订阅仍使用公网 IPv4，IPv6 的主要用途是服务端对特定目的域名选择出站；这不要求客户端具备 IPv6，也不把 IPv6 入站当作 IPv6 出站可用的证明。本次按用户答复保留已批准 `AsIs`、`direct`、前四条安全路由及模板原规则，不创建 `IPv6-OUT`/`IPv4-OUT`，不删除 `direct`，不改全局 DNS、内核路由或防火墙。方案第 7.4 节原有“双栈主机同时监听”的约束仍有效，但只由 `listen.reality` 检查，不代表已实现 AI 域名的 IPv6 出站。

| 层次 | 输入和数据来源 | 判定、输出与证据边界 |
|---|---|---|
| 订阅入口 | 输入 `node_ip`；数据库 `share_addr`；隔离测试取得的最终订阅 | 两类主机均发布同一公网 IPv4 字面量；沿用 `reality.share` 与 VT-22。不能因发现 IPv6 而自动把订阅改为 IPv6 |
| 本机监听 | 按地址族读取 `ss`；IPv6 socket 的 `v6only`；本机已配置的公网 IPv6 地址 | 按 `listen.reality` 判定。只有回环/链路本地 IPv6 不算公网双栈；IPv4-only 主机不因缺 IPv6 监听失败；已配置公网 IPv6 但没有默认路由不能当作 IPv4-only 来豁免监听。检查不发起新的 TCP 探测，不以全局 `bindv6only` 默认值代替现有 socket 的属性 |
| 出站本机前提 | `ip` 的地址、接口状态和 IPv6 路由；部署输入和部署记录的 `ipv6_ai_egress` | 由 `ipv6.egress` 判定（第 3、4.2 节），只能描述“具备本机配置前提”或“前提缺失”，不能标为业务可达。IPv4-only 是受支持场景：按需求 D29 不启用 FR-13（输入 `off`），部署照常，不因缺少 IPv6 地址/路由拒绝部署。是否启用由部署输入明确给出，不按探测结果自动启用；未启用时两项报告 SKIP 并说明原因。启用后目的域名有 IPv6 地址、但 IPv6 不可用或连接失败时，连接失败，不改走 IPv4（D31）；所以输入 `on` 而本机没有可用的 IPv6 时预检拒绝，部署之后失去 IPv6 时检查报告 FAIL，因为这时有 IPv6 地址的目的域名全部连接失败。按需求 D32 不固定 IPv6 源地址：可用的全局地址多于一个（包括临时地址）时出口可能变化，检查报告 WARN。部署和检查都不自动改写配置 |
| 出站配置与顺序 | 第 4.1 节一次数据库快照中的模板、真实入站 tag；部署时用自带 Xray 核验类别（第 16.1 节）；测试侧最终生成配置 | 由 `routing.ai-ipv6` 判定出站协议、地址族策略、域名集合、规则先后及 REALITY tag 限定；不把类别名当作永久固定的域名清单，类别存在由部署前的核验和 Xray 加载配置保证。错误 tag、漏规则、错误策略或被前置规则遮蔽都不能通过。新增 Freedom 出站的 `finalRules` 与 `direct` 相同，保留私有地址保护；旧名 `settings.domainStrategy` 会被核心迁移到 `sockopt`（第 14 节），检查只接受新位置，最终生效表示由隔离测试核对（第 17 节）。安全规则优先，转发入站仍只到 `direct` 或 `blocked`，不能落入 AI 分流。只有记录为启用时，这两项才进入 PASS 基线（第 4.3 节） |
| 实际出站 | 隔离 DNS/双栈替身、客户端结果、两种地址族的外连观测与替身记录 | 必须观察实际目的/源地址族及响应；路由测试返回出站 tag、出现 AAAA、存在默认路由、监听 `[::]` 均不足以证明 IPv6 出站成功。生产 `check` 不访问 OpenAI/Anthropic 来作探测，真实服务可用性留给获授权的测试 VPS 验收 |

**出站和规则的形态（DO-14）。** 输入为 `on` 时，第 16.1 节第 6 步在写前四条规则的同一次模板写入中加上：

| 对象 | 内容与位置 |
|---|---|
| 出站 | `tag` 为 `ai-ipv6`（本工具的固定值），`protocol` 为 `freedom`；`settings` 只有 `finalRules`，值与 `direct` 的相同；`streamSettings.sockopt` 只有 `domainStrategy`，值为 `ForceIPv6v4`。追加在出站列表末尾，`direct` 仍是第一个 |
| 规则 | `type` 为 `field`，`inboundTag` 为 REALITY 入站的标签，`domain` 为 `geosite:openai`、`geosite:anthropic`，`outboundTag` 为 `ai-ipv6`。放在规则 4 之后、模板原有规则之前，即第五条 |

目的为 IP 字面量的连接不匹配这条规则，按其余规则处理，大多走 `direct`；转发入站的连接先由规则 1、2 处理，到不了这条规则。输入为 `off` 时模板中没有这个出站和这条规则。

**参考材料及不可直接迁移的部分。** 用户提供的本地配置记录“3X-UI-Xray设置”以 `geosite:openai`、`geosite:anthropic` 与 `ip=::/0`、REALITY tag 联合匹配到 `IPv6-OUT`；出站使用 `ForceIPv6`，其后有 IPv4 兜底，整体路由为 `IPOnDemand`。公开文档只记录这些规则语义，不复制原文件的路径、主机标识、真实地址、凭据或历史例外清单。该记录是设计参考，不是本仓库的运行证据；需求 D27 只把它作为 FR-13 的参考，D22 对其余参考设置的退役不变。需求 U20 指定的本地配置样例中，双栈路由和出站的语义与此一致，另用 `sendThrough` 固定两个出站的源地址，并把其余流量限定在 IPv4 出站；按需求 D31 只参考其中的双栈路由和出站设置，同样不复制原文件的地址和标识。

固定核心的源码语义见第 14 节：同条规则的域名和 IP 条件同时满足才匹配；`IPOnDemand` 让 IP 条件按需解析域名，不检测 IPv6 连通性。它也会扩大当前 `geoip:cn` 对域名的匹配范围，改变 D22 已批准的取舍。在候选 `IPOnDemand` 下，域名没有可匹配的 AAAA 时可能不命中 IPv6 规则、继续走后面的 IPv4 规则；这是选路阶段的兜底。`ForceIPv6` 无 IPv4 自动回退；命中该出站后连接失败，不会继续尝试下一条 IPv4 路由。`UseIPv4` 与 `sendThrough=0.0.0.0` 也不能单独保证“所有其他请求强制 IPv4”，尤其要核对直接携带 IPv6 字面量和解析失败的路径。因此 IPv4-only 行为、无 AAAA、IPv6 路由缺失/中断、字面量目的地址、例外集合及回退条件一起列入 DO-14，不从参考记录推定答案。需求 D29、D31 已确定：只有 IPv4 的主机不启用；目的域名有 IPv6 地址时只走 IPv6，失败不改走 IPv4，没有 IPv6 地址时走 IPv4，与参考记录的选路效果相同。方案设计 v1.4 的 OD-5 据此决定（需求 D32）：新增出站的 `sockopt` 用 `domainStrategy: ForceIPv6v4`，不固定源地址，路由保持 `AsIs`，不改变 `geoip:cn` 的匹配范围；实际行为在 M2 验证。

**分阶段验证。** M1 仍只完成既定骨架及不依赖部署的项；`ss` 地址族和 `v6only` 的真实输出在 M2 核实。M2 的 VT-71 覆盖 IPv4-only、双栈但缺一族监听、单个双栈 socket，以及 IPv4/IPv6 通配 socket 各自存在但 `v6only` 缺失的情况（仍通过）；只有依靠 IPv6 socket 满足 IPv4 要求时，`v6only=1` 或未知才据此 FAIL，配合 VT-60～VT-62；M5 保留已有双地址族外部扫描。出站矩阵已写入验证计划 v1.2 的 VT-32～VT-34：IPv4-only（主配置）、A-only、AAAA-only、A+AAAA、解析失败、IPv6 不可用、IPv6 拒绝或丢弃、直接 IPv4/IPv6 字面量、AI/非 AI 域名、AAAA 为私有地址及转发入站隔离。解析到国内地址的 AI 域名按 D22 的取舍不挡，不单列用例。条件由客体的 `/etc/hosts`、双栈替身和外连隔离控制，不新增平台矩阵、不依赖真实 AI 账户；两个检查项随 VT-32、VT-33 和 VT-71 验证。不能直接套用参考材料的历史连通结论。

## 5. target-check 检查项

| 编号 | 检查 | 判定 |
|---|---|---|
| `root`、`deps` | 运行权限和依赖的命令 | 不是 root，或者缺少 `curl`、`openssl`、`getent`、`sha256sum`、`timeout` 中的任何一个时不符合，后续不执行 |
| `resolve` | 解析 | `getent ahosts <目标>`。解析不到地址时不符合，后续为 `SKIP`；否则 `INFO` 列出地址，供管理员按文档查询网络归属（是否在共享 CDN 上、是否与 VPS 在同一网络，方案设计第 7.7 节） |
| `tls.handshake` | 可达性和握手耗时 | 连续 5 次 TLS 握手（每次 15 秒超时）。全部失败时不符合，后续为 `SKIP`；部分失败时为警告；说明中给出握手耗时的最小值、中位数和最大值（"从部署所用的 VPS 稳定可达"，需求第 11.5 节第 1 条） |
| `tls.version` | TLS 版本 | 协商的不是 TLS 1.3 时不符合 |
| `tls.alpn` | ALPN | 提供 `h2,http/1.1` 时协商的不是 `h2`，不符合 |
| `tls.cert` | 证书 | 按系统的 CA 存储验证证书链失败，或者与目标主机名不匹配，不符合；说明中给出签发者和到期时间。证书无效时，后续的 HTTP 请求照常进行（不验证证书），使其余各项仍有结果 |
| `tls.group` | 密钥交换组 | 只输出 `INFO`：提供 X25519MLKEM768 时协商到的组。target 不必支持 X25519MLKEM768（需求第 11.5 节第 1 条），不判定 |
| `http.root` | 根路径 | 经 h2 请求 `/`，不跟随跳转。2xx 通过；3xx 跳转到同一主机名（或相对地址）通过，说明中给出路径；跳转到别的主机名不符合；4xx 和 5xx 为警告，显示状态码 |
| `probe.host` | 异权威探测（HTTP/1.1） | 以目标的 SNI 建立 TLS，请求 `/`，Host 为探测主机名。基准是同样的连接、Host 为目标的两次请求 |
| `probe.authority` | 异权威探测（HTTP/2） | 同上，用 HTTP/2，`:authority` 为探测主机名 |

两项异权威探测的判定：

- 探测请求的响应不是 2xx（例如 421、403、404），或者是 2xx 且内容与基准相同：通过；
- 探测请求的响应是 2xx、两次基准的内容相同、探测的内容与基准不同：不符合，说明"按 Host 返回了别的内容，可能交叉路由"；
- 探测请求的响应是 2xx，但两次基准的内容不同（动态页面）：警告，说明无法按内容比较。

内容按响应体的 SHA-256 比较，响应体最多读 4 MiB，只保存在私有临时目录中，退出时删除。通过的说明中注明"只能发现交叉路由，结果干净不证明隔离"（FR-02）。

不检查的：是否在中国大陆之外被封锁，是否在共享 CDN 上。前者从 VPS 上测不到，后者要查网络归属（需要访问外部的查询服务），都由管理员按文档判断（方案设计第 7.7 节）。

## 6. 固定的版本和摘要

固定的值写在 `lib/vps-proxy-setup/pins.sh` 中，是唯一的来源；`deploy`（M2、M3）和 `check` 都从这里读取，测试按它核对（VT-99）。

| 项目 | 值 | 来源 |
|---|---|---|
| 3X-UI 版本和提交 | `3.11.0`，tag `v3.11.0` 指向 `c621ba9014a6aa21fd7c9ecf45655e44e24ebf13` | 需求 D10 |
| `install.sh` | SHA-256 `9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d` | 需求第 2.2、10.1 节（继承的约定） |
| `x-ui-linux-amd64.tar.gz` | 82728788 字节，SHA-256 `0ddfa4702f595442e2962acd81addc768fdacaa4ff2672c971a0463dae744916` | 验证计划第 3.5 节 |
| `/usr/bin/x-ui`（tag 路径上的 `x-ui.sh`） | SHA-256 `26c229d5fb3b184e81581b4b223b801582ca7cf5908aaedeb8d1c7c70ad4cc25` | 需求第 10.1 节 |
| `/etc/systemd/system/x-ui.service` | tag 路径上的 `x-ui.service.debian` 为 SHA-256 `95cb6e39499601148404cadf3b4d75b0489301ff7e7ab565cd9db21d23be957c`（第 14 节）；安装后的文件来自发布包还是 tag 路径、是否与它相同，在 M1 核对 | VO-1 |
| `/usr/local/x-ui/x-ui`、`/usr/local/x-ui/bin/xray-linux-amd64` | 从固定的发布包中取得 | VO-1（M1） |
| cloudflared | `2026.10.5`，`cloudflared-linux-amd64` 40263303 字节，SHA-256 `e1bc0cf084fd9e590554fe769a86b1db46701c3f847a43d902f7b974a4e16298` | 验证计划第 3.5 节 |
| vps-hardening 测试过的版本 | `0.1.1` | 需求 A-1、D9；第 12 节 DO-7 |

### 6.1 核心修复评估（DO-13）

3X-UI 仍固定 v3.11.0；当前发布包的 Xray 基线仍为 v26.10.21，不因存在新版本而自动替换。2026-10-29 发布的 v26.10.29 包含 #7238：修复 VLESS 等 `DispatchLink` 入站在 Freedom 的 `finalRules` 拒绝连接时，未能按 `blockDelay` 结束连接的问题。已认证 VLESS 请求一个未先被其他规则拦截、随后被 Freedom 解析为私有地址的域名，可以进入这条路径；Vision 分支仍使用 `DispatchLink`。风险是拒绝连接持续占用资源，不是私有地址放行、未认证 SNI 绕过或已发生资源耗尽（第 14 节）。

包含该修复的核心列为候选，当前候选为 v26.10.29，未批准采用。评估 3X-UI 的修复版时（需求 D30），设计/测试用本项目 REALITY + Vision 验证拒绝连接确实结束、客户端保持发送/不关闭的情况、正常公网转发和重启恢复；复用现有 VM 与连接观察接缝，计时判据明确到适用的 `blockDelay` 和容差，不以“closed”日志代替 socket 结束。核对候选的配置/API 兼容、发布资产与摘要；如果变更版本，先同步需求相关约束、方案、验证计划第 3.5 节、本节和 VO-1 的文件摘要，再运行受影响的 VT-16、VT-20～VT-29、VT-71、VT-92。新增的拒绝连接回收用例随 DO-13 评审纳入验证计划，不虚构已有 VT 编号。

决定采用候选核心时，交付方式有三种（用户 2026-10-31 选定 A，需求 D30）：

| 方式 | 做法 | 影响 | 建议 |
|---|---|---|---|
| A. 等 3X-UI 的修复版 | 3X-UI 发布自带 v26.10.29 或之后核心的版本后，按需求第 11.3 节评估，改固定版本、提交和摘要 | 仍按固定的发布包安装，不偏离 FR-01、NFR-05；发布时间不可控，截至 2026-10-31 最新仍是 v3.11.0 | 采用。等待期间按上文评估风险和验证要求，不阻塞 M1 |
| B. 面板的"切换 Xray 版本" | 管理员在面板中下载并替换核心 | 下载的文件不在本仓库固定的摘要之内，`xui.files` 的核对随之失效；需求第 10.1 节记录了 v3.11.0 上这项功能的缺陷报告 | 不采用 |
| C. 部署脚本替换自带的核心 | 部署脚本按本仓库固定的摘要下载候选核心，替换发布包中的 Xray | 偏离 FR-01、NFR-05 按固定发布包安装的约束，要先由用户批准需求变更；重装或升级 3X-UI 时会被发布包的核心覆盖（推断）；`xui.files` 的摘要、VO-1 和升级流程都要改 | 只在风险被证实需要立即处理、又等不到 A 时考虑 |

**已决定（需求 D30）：采用 A。** M1、M2 按固定的 v3.11.0 及其自带的 v26.10.21 实现和验证，不用 B，不做 C，也不宣称已解决 #7238 所述的问题。3X-UI 发布自带修复核心的版本后，按需求第 11.3 节和 FR-10 评估，上文的验证要求在那时执行；改版本时同步需求及下游，相关摘要与核心行为证据按新版本重取。

## 7. 模块划分

| 文件 | 职责 |
|---|---|
| `bin/vps-proxy-setup` | 环境、加载模块、ERR 陷阱、子命令分派、帮助和版本 |
| `lib/vps-proxy-setup/common.sh` | 第 2.8 节的常量、退出码、`report` 和汇总、私有临时目录、拒绝（`refuse`）、通用小函数 |
| `lib/vps-proxy-setup/pins.sh` | 第 6 节的固定值，只有数据 |
| `lib/vps-proxy-setup/platform.sh` | 解析 `/etc/os-release`（按数据解析，不执行）、平台判定 |
| `lib/vps-proxy-setup/inputs.sh` | 输入文件的核对和读取、交互读取、各输入项的校验（第 2.4 节）；`target-check` 也用其中的主机名校验 |
| `lib/vps-proxy-setup/probe.sh` | 只读探测：监听端口、单元的生效属性、文件属性和摘要、vps-hardening 的记录和 `verify`、包管理器的锁 |
| `lib/vps-proxy-setup/xuidb.sh` | 选择打开方式、执行快照查询、在快照上取值（第 4.1 节） |
| `lib/vps-proxy-setup/preflight.sh` | 第 3 节的检查项 |
| `lib/vps-proxy-setup/check.sh` | 第 4 节的检查项 |
| `lib/vps-proxy-setup/target.sh` | `target-check`（第 2.7、5 节） |
| `lib/vps-proxy-setup/deploy.sh` | `deploy`。M1 中只有预检和结束提示，M2、M3 增加各步骤 |
| `install.sh` | 发行版安装脚本，独立运行，不加载上面的模块（第 2.9 节） |

## 8. 实现约束

- **只读。** 预检、`check` 和 `target-check`（结果文件除外）只调用读取类的命令。测试在每个用例前后比较状态摘要（第 9.4 节）。
- **秘密的传递。** 只读检查时，数据库中的秘密留在 `sqlite3` 进程中（第 4.1 节）。输入校验时 Tunnel token 只在 `inputs.sh` 的变量中，不写入临时文件、不出现在命令行参数中；用内建的 `printf` 经管道交给 `base64` 和 `jq`。不用 here-string 传秘密：Bash 在内容超过管道缓冲区时可能把它写成临时文件。M2、M3 中的 API 请求和 token 落盘遵循第 15.2 节，秘密不能经 `jq --arg` 等进程参数传递，应经标准输入或私有文件读取（方案设计第 7.9 节）。
- **JSON。** 用 `jq` 解析，M2 中也用 `jq` 构造请求体，不拼接字符串（方案设计第 4.1 节）。
- **按数据解析。** 输入文件、部署记录、`target-check` 的结果、`/etc/os-release` 和 vps-hardening 的状态文件都逐行解析，从不 `source`。vps-hardening 的状态文件取每个键的第一行，与它自己的 `state_get` 相同（第 14 节）。
- **有界。** 外部命令都有超时：`sqlite3` 30 秒；`vps-hardening verify` 120 秒；`x-ui -v` 10 秒；`systemctl`、`ss`、`fail2ban-client` 30 秒；访问 `127.0.0.1:20241` 的 `curl` 5 秒；`target-check` 的每次连接 15 秒。
- **UTF-8。** `LC_ALL=C` 下按字节处理。合法性用 `iconv -f UTF-8 -t UTF-8` 判断；国旗按两个区域指示符的字节序列判断（每个是 `F0 9F 87 A6`～`F0 9F 87 BF`）；长度按字节计。
- **写入。** `target-check` 的结果先写临时文件再改名替换（第 2.7 节）。
- **沿用 vps-hardening 的经验（它的详细设计第 6 节）：**
  - 管道的读取端不提前退出（不用 `head`、`grep -q` 截断），已取得的文本用 here-string 匹配，否则写入端会因 SIGPIPE 失败，在 `pipefail` 下被误判；
  - ERR 陷阱只在主 shell 中把意外失败转换为退出码 3；要检查的 `$(...)` 先赋给单独声明的变量再检查，不与 `local` 写在同一行；
  - awk 程序中不用正则区间（`{n}`、`{m,n}`）；
  - 判定不确定时宁可误报不符合，不误放行，例如 `forwarder.settings` 中新旧两个字段名同时出现。

## 9. 测试框架（M1）

### 9.1 组成

沿用 vps-hardening 的测试框架，改动之处在下表中注明。

| 文件 | 作用 |
|---|---|
| `tests/vm.py` | 运行器侧：下载并校验官方云镜像，生成 cloud-init 种子，启动 QEMU，按阶段在客体中执行，收集证据，扫描泄露。改编自 vps-hardening 的 `tests/vm.py`；套件正常结束而证据收集失败时，测试失败（验证计划第 6 节） |
| `tests/guest/m1.sh` | 客体侧：主配置和存量主机的准备、两个命名空间和替身、M1 的用例和判定 |
| `tests/guest/standin.py` | target 替身（第 9.2 节） |
| `tests/platform-images.json` | 镜像 URL 和摘要，与 vps-hardening、vps-tuning 同源；只有 Debian 13 amd64（NFR-03） |
| `tests/static.sh` | 不需要虚拟机的检查：shell 和 Python 语法、安装脚本的资产清单和版本、LF 行尾、泄露和隐私扫描（VT-97）；M2 起加上规则文本的 YAML 解析（VT-96） |
| `.github/workflows/static.yml` | 运行 `tests/static.sh` 和 ShellCheck 0.11.0（固定的容器镜像），列出全部模块和 `install.sh` |
| `.github/workflows/vm.yml` | M1 的两组作业 `m1-preflight`、`m1-check`；证据作为构件保存 14 天 |

**隐私扫描（VT-97）。** 扫描仓库中所有文件：

- 示例 IPv4 只允许 `0.0.0.0`、`127.0.0.0/8`、`10.0.0.0/8`（QEMU 用户网络）和三个文档地址段；IPv6 只允许 `::`、`::1` 和 `2001:db8::/32`。另将第 2.4 节地址校验所需的公开标准 CIDR 常量按准确文本及使用位置列为有限例外；它们不是部署地址，不能据此放行同网段内任意真实地址。域名及地址的公开来源例外不改变 NFR-02 对真实基础设施标识的禁止；
- 不允许 UUID 格式的字符串；
- 域名只允许 `example`、`example.com`、`example.net`、`example.org`、`.test`、`.invalid` 和 `tests/privacy-allow.txt` 中列出的公开站点（例如 GitHub、Debian、Cloudflare 的文档地址）；
- 不允许本地路径（盘符路径、`/home/`、`/Users/`）。

服务商名称和生产使用的 target 不能列在仓库里（列出来就泄露了），所以 CI 查不到它们。它们由管理员在推送前用仓库外的私有清单在本地扫描（`tests/privacy-local.sh <私有清单>`），这是已知的限制（第 11 节）。

### 9.2 客体与网络

- **主配置**（验证计划第 3.2 节）：cloud-init 写入测试密钥；按 vps-tuning 的固定版本（VO-6）应用调优，重启，验证；按 vps-hardening `v0.1.1` 加固，经伪终端执行 `apply`、从新的 SSH 会话 `confirm`，UFW 只放行 22/tcp。准备好的磁盘作为只读的基础镜像，每个会破坏状态的用例在自己的 qcow2 覆盖层上运行。
- **存量主机：**
  - S1：核对 `install.sh` 的摘要之后，按部署会用的环境变量运行它：`XUI_NONINTERACTIVE=1`、`XUI_PANEL_PORT=<面板端口>`、`XUI_ENABLE_FAIL2BAN=false`、`XUI_DB_TYPE=sqlite`、`XUI_SSL_MODE=none`，版本参数 `v3.11.0`（方案设计第 4.3 节）；
  - S2：只建 `/etc/x-ui/x-ui.db`（用 `sqlite3` 建一个空数据库）；
  - S3：核对摘要之后，把固定版本的 cloudflared 放到 `/usr/local/bin/cloudflared`。
- **两个命名空间**（验证计划第 3.3 节）：`vpsns-client` 经 veth 连到客体，客体一侧为 `192.0.2.1/24`（这就是部署输入中的节点地址），命名空间一侧为 `192.0.2.2/24`；`vpsns-standin` 同样连接，客体一侧为 `198.51.100.1/24`，替身为 `198.51.100.2/24`。客体的 `/etc/hosts` 把 `target.example`、`other.example` 和 `probe.example` 解析到 `198.51.100.2`。M1 用到替身；客户端命名空间在 M1 只核对它能到达客体的节点地址，Mihomo 从 M2 开始。
- **替身**（验证计划第 3.6 节）：Python 标准库的 `ssl` 加 Debian 的 `python3-h2`，监听 `198.51.100.2:443`，支持 TLS 1.3、h2 和 HTTP/1.1；证书由每次运行生成的测试 CA 签发，覆盖 `target.example` 和 `other.example`，两个虚拟主机返回固定、可区分的内容。路由方式由启动参数选择：严格按 SNI（忽略 Host）或按 Host 交叉路由。替身把每个 TCP 连接和 SNI 记入日志，作为证据之一。`probe.example` 的 HTTP 和 HTTPS 服务从 M2 开始需要（经代理访问）。
- **测试 CA 的信任。** 信任时放入 `/usr/local/share/ca-certificates` 并执行 `update-ca-certificates`，不信任时删除并再次执行。

### 9.3 用例的实现

| 用例 | 作业 | 实现 |
|---|---|---|
| VT-80、VT-81 | `m1-preflight` | 在主配置上对 `target.example` 执行 `target-check`，分别在信任和不信任测试 CA 时；替身切换两种路由方式，交叉路由时 `--probe-host other.example`。在客体上用 `tcpdump` 记录测试期间的出站连接，判定只有到 `198.51.100.2:443` 的连接（`/etc/hosts` 解析，没有 DNS 查询）；只保留地址、端口、时间和 SNI。VT-81 的结果同时检验测试驱动本身（验证计划 VR-9） |
| VT-01 | `m1-preflight` | 先在信任测试 CA 时执行 `target-check target.example`，再采集"执行前"的状态摘要。输入文件含全部六项，令牌为每次运行生成的测试令牌（验证计划第 3.4 节）。经伪终端执行 `deploy --input`，判定各项预检通过（`inputs.node_ip` 因文档地址为警告）、标准错误中是"之后的步骤在 M2 实现"、退出码 1、前后状态摘要一致；再以标准输入不是终端的方式执行一次，判定退出码 2、状态不变 |
| VT-02 | `m1-preflight` | S1、S2、S3 各一个覆盖层，分别判定 `new-host.xui`、`new-host.xui-db`、`new-host.cloudflared` 不符合，退出码 1，状态不变 |
| VT-03 | `m1-preflight` | 一张表：每个输入项至少一个不合法的值，其中包括节点地址为主机名、使用者代号重复、备注没有国旗、令牌不是 Base64、令牌的 `t` 不是 UUID、`--migrate` 时出现 `remark`；另有含国旗的合法 UTF-8 备注。判定退出码 2、标准错误中有对应的键、没有回显令牌，合法备注被接受 |
| VT-04 | `m1-preflight` | 输入文件属于非 root 用户；权限为 0644、0640、0400；是符号链接。判定退出码 2，状态不变 |
| VT-05 | `m1-preflight` | 以非特权用户经伪终端执行，判定 `root` 不符合；在私有挂载命名空间中把 `/etc/os-release` 绑定为另一个发行版的内容，判定 `platform` 不符合；加一条 UFW 规则使 `vps-hardening verify` 不通过（独立的覆盖层）；在私有挂载命名空间中把状态文件绑定为没有 `panel_port` 的副本。都判定退出码 1、预检停止并说明原因、状态不变（注入本身的改动不计入） |
| VT-71（M1）、VT-72～VT-76 | `m1-check` | 在第 9.5 节的 M1 基线上执行 |
| VT-96、VT-97 | `static.yml` | 第 9.1 节 |

VT-72 的实现：在 `/etc/x-ui` 中建 `.x-ui-backup-vt72` 目录；x-ui 稳定运行时和稳定停止后各执行一次 `check`，核对目录、文件列表（含侧文件）、属主、权限、表结构和各表摘要不变（运行时按第 9.4 节确定排除项）；停止时还判定数据库摘要不变、侧文件仍不存在。DO-1 同时验证读取期间启动/停止的情形：测试驱动自身造成的文件变化用对照运行区分，不能把检查新建/删除侧文件算进排除项。作废不可靠结论与证明不写文件是两个判据。具体协调方法在 M1 实现中确定，门禁通过前必须有证据，不另建测试矩阵。

VT-73：在私有挂载命名空间中把 `/usr/local/x-ui/x-ui` 绑定为一个打印 `9.9.9` 的脚本，判定 `xui.version`、`xui.files` 不符合，库项为 `SKIP`。

VT-75：带一个参数执行，判定退出码 2；x-ui 停止后在 `/etc/x-ui` 中放一个空的 `x-ui.db-wal`（没有 `-shm`），判定 `xui.db` 不符合并说明原因、退出码 1、数据库文件和那个文件的摘要都不变。

VT-74：用验证计划第 3.4 节的清单扫描 `check` 的输出。M1 中清单来自 S1 的 `install-result.env`（用户名、密码、`webBasePath`、API token）和只读打开的数据库（订阅路径、订阅 ID 等）。

VT-76：在同一个状态下连续执行三次，输出逐字节相同。说明中不含时间和耗时，所以可以逐字节比较。

### 9.4 状态摘要

每个用例前后各采集一次（验证计划第 4 节）：

- `/etc` 下每个文件的路径、类型、属主、权限和 SHA-256。排除：`/etc/resolv.conf`、`/etc/adjtime`；`/etc/x-ui` 下的数据库文件改由下面的数据库摘要比较；用例本身注入的文件。
- `ufw status verbose` 和 `nft list ruleset`；相关单元（`x-ui`、`fail2ban`、`ufw`、cloudflared 的单元）的启用和运行状态；`ss -Hltnu`；`dpkg-query -W` 的软件包列表。
- 3X-UI 的数据库：表结构（`sqlite_master`）和每个表按主键排序导出的摘要，读取方式与第 4.1 节相同。x-ui 运行时它自己会写数据库（例如流量统计）：同一时间段内不执行 `check`、连续采集两次，出现差异的表和列就是 x-ui 自己的写入，作为排除项；执行 `check` 的那一次不能出现排除项以外的差异。排除清单在 M1 中这样确定，并写入本文（验证计划第 4 节）。

### 9.5 M1 的基线与注入（VT-71）

**基线。** S1 之后，测试驱动执行部署第 4 步中与面板有关的部分：`x-ui setting -listenIP 127.0.0.1`，然后重启 x-ui。执行一次 `check` 作为基线并归档。按第 4 节的判定，预期（推断，以 M1 的实际基线为准）：

- 通过：`root`、`platform`、`xui.*`（`xui.files` 要在 VO-1 取得摘要之后）、`panel.listen`、`routing.outbounds`（有效默认模板已有 direct/freedom 和 blocked/blackhole）、`clients.limit-ip`、`sub.enable`、`sub.cert`、`sub.paths`、`sub.json`、`sub.info-node`、`sub.updates`、`listen.api`、`listen.metrics`、`secrets.handoff`、`absent.*`、`hardening.verify`；
- 不符合：`inbounds.set`、`sub.listen`、`sub.domain`、`sub.uri`、`sub.clash`、`sub.remark`、`listen.reality`、`listen.forwarder`、`listen.sub`、`secrets.install-result`、`record.consistent`、`cfd.*`；
- 跳过：依赖 REALITY 入站或转发入站的项（`reality.*`、`forwarder.settings`、`routing.rules`、`clients.count`、`clients.flow`），`sub.rules`（还没有规则文本），`state.perms`；
- 警告：`secrets.api-tokens`（安装 token 仍在）。

**注入。** 每种偏差在自己的覆盖层上注入，与基线比较，只有下表中对应的项由通过变为不符合：

| 注入 | 由通过变为不符合的项 |
|---|---|
| 程序文件换成报告其他版本的替身（同 VT-73） | `xui.version`、`xui.files`；库项变为 `SKIP` |
| `/usr/bin/x-ui` 改动一个字节 | `xui.files` |
| 加一个 drop-in，设置 `Environment=XUI_DB_FOLDER=/var/tmp`，执行 `systemctl daemon-reload`，不重启 x-ui | `xui.unit` |
| 创建空的 `/etc/default/x-ui` | `xui.env` |
| `systemctl disable x-ui`（不停止） | `xui.service` |
| `x-ui setting -listenIP 0.0.0.0`，重启 x-ui | `panel.listen` |
| 放置 `/etc/fail2ban/jail.d/3x-ipl.conf` | `xui.ipl` |
| 经面板接口打开 `subJsonEnable` | `sub.json` |
| 经面板接口打开 `subInfoNodeEnable` | `sub.info-node` |
| 经面板接口把 `subUpdates` 改为 6 | `sub.updates` |
| 经设置接口把 `subEnable` 设为 false；只改持久化设置，不主动重启服务 | `sub.enable`；若接口产生连带变化，逐项列出实际对应项 |
| 经设置接口设置测试证书和密钥路径，测试文件只属于客体夹具 | `sub.cert`；不向外发布证书，失败或连带变化须记录 |
| 经设置接口把 `subPath` 或 `subClashPath` 设为默认值或过短值 | `sub.paths`；如 API 拒绝该测试值，用隔离测试夹具核验读取判据，记录不能由 API 生成该状态的事实 |
| 放置 `/root/.acme.sh/acme.sh` | `absent.acme` |
| 放置 `/root/.cloudflared/cert.pem` | `absent.cf-credentials` |
| 加一条 UFW 规则使 `vps-hardening verify` 不通过 | `hardening.verify` |

经面板接口的注入用 `install-result.env` 中的 API token（M1 中还没有 handoff），调用完整设置读取和更新的契约见第 15 节。`sub.enable`、`sub.cert`、`sub.paths` 不再笼统延期；具体 API 可接受值和连带项在 M1 核实，测试夹具不作为生产写入路径。`clients.limit-ip` 需要使用者，仍在 M2；`listen.api`、`listen.metrics` 的偏差涉及 Xray 运行配置，随 M2 的配置和重启注入。一个偏差影响多项时列明全部对应项，不能以此省略不依赖部署结果的 M1 注入。基线/注入可随实测纠正，不能把未执行的项计为通过。

## 10. 运行证据

还没有。M1 实现之后增补，包括第 9.4 节的排除清单、第 9.5 节的实际基线、VO-1 取得的摘要和第 12 节各项的核实结果。

## 11. 已知限制

- **只读读取与并发。** `immutable` 不检查锁和变化；检查期间启动写者可能使结果不可靠。`mode=ro` 路径也有侧文件检查后被删除的窗口。第 4.1 节的状态检测不能被称为消除了竞态，DO-1 在 M1 验收前核实；本次结论无效时不保证重跑一次必然正确。此限制不授权修改数据库或停止服务。
- **结论的范围。** `check` 全部通过只说明检查范围内的配置符合要求，不说明从中国大陆可达，也不说明伪装有效（方案设计第 7.6 节）。
- **Tunnel 的路由。** `cfd.routes` 只能看到 `/config` 中有的内容。私有网络路由等不在 ingress 中的配置能否从这里看到，在 M3 中核实（DO-4）；看不到时这里记录为限制。
- **订阅路径的随机性。** `sub.paths` 只排除默认值和过短的路径，不能证明路径是初始化时随机生成的。部署不改订阅路径（`deploy` 只用 3X-UI 初始化时生成的值），之后在面板中改成可猜的值，检查发现不了。
- **异权威探测。** 结果干净不证明隔离；默认的探测主机名只能发现"按 Host 返回别的内容"的服务器（第 2.7、5 节）。
- **隐私扫描。** 服务商名称和生产使用的 target 只能在本地用私有清单扫描（第 9.1 节）。
- **执行所装的程序。** `xui.version` 执行 `/usr/local/x-ui/x-ui -v`。即使这个文件已被替换，它本来就以 root 作为服务运行，检查执行它不扩大它的权限；摘要不符由 `xui.files` 报告。

## 12. 待决事项

| 编号 | 事项 | 处理 | 负责与时间 | 关闭条件与影响 |
|---|---|---|---|---|
| DO-1 | Debian 13 SQLite 的只读模式、`-safe`、URI、忙等待与侧文件行为；服务状态变化时的竞态 | 第 4.1、9.3 节，VT-72、VT-75；如观察到检查新建/删除侧文件，必须修订读取方式，不预选复杂框架 | 实现，M1 | M1 验收前有静止及变化状态证据；未核实不阻止编写实现，不得宣称只读门禁通过 |
| DO-2 | systemd 257 的属性输出规范化、Fail2ban jail 列表格式；`ss` 的地址族与 `v6only` 输出 | M1 基线核实 x-ui 属性和列表；监听属性在 M2 核实；cloudflared 的凭据/进程属性在 M3 核实 | 实现，M1/M2/M3 | 相应解析器和偏差测试通过；内核未提供所需 socket 属性时不得猜测通过 |
| DO-3 | VO-1：安装后文件和单元摘要、服务单元实际来源 | 从固定发布包/提交取得，写入第 6 节与实现的固定值 | 测试实现，M1 | 相关摘要检查能运行前关闭；未取得不编造摘要 |
| DO-4 | 控制台实际兜底；私有网络路由在 `/config` 中的可见范围 | 空字段的固定源码表示已在第 4.2、18.3 节明确；真实配置仍需测试 VPS 核实 | 实现，M3，依赖 VO-7 | M3 真实路由验收前明确覆盖与限制；不计为 M1 阻塞 |
| DO-5 | 经面板再次保存路由的字段和表示 | 在 VM 中比较模板及最终生成配置，校正检查允许字段 | 实现，M2 | VT-16、VT-71 的相关项通过 |
| DO-6 | 订阅证书的实际覆盖与挑战功能配置 | 官方产品限制已核实（第 18.3 节）；Zone 边界、有效证书、当前开关及调整影响由管理员确认 | 设计与管理员，M3 前 | 外部证书和非浏览器拉取验证；不擅自关闭 Zone 范围功能 |
| DO-7 | hardening `v0.1.2` 与已批准 A-1、D9 的 `v0.1.1` 不同 | 保持批准基线；升级须用户决定并同步需求与验证计划。未升级时预检按既定版本差异给 WARN，不自行改白名单 | 用户，升级前 | 待定；M1 可沿用 `v0.1.1`，不由本文批准升级 |
| DO-8 | curl 的 HTTP/2 Host → `:authority` 实际行为 | VT-81 由替身记录收到的权威字段，不只看客户端参数 | 实现，M1 | HTTP/1.1 和 HTTP/2 探测均经已知交叉路由对象自检 |
| DO-9 | Apple、微软等服务的直连取舍；国内 IP 的 `no-resolve`；规则名称与顺序 | 随 M2 规则文本提交评审，保持 D13 选型；本文不把未写的 YAML 计为完成 | 设计，M2 | 规则定稿并满足 VT-42、VT-44、VT-96；不阻塞 M1 |
| DO-10 | 安装后摘要偏差的注入实现 | 第 19 节已定义阶段接缝，不需要生产故障开关 | 测试实现，M2 | 设计待本草案评审；VT-12 的真实测试仍未执行 |
| DO-11 | 路由测试和新增 API 契约的运行核实 | 第 15、19 节按固定源码规定；核对实际 JSON 表示、部分写入、撤销结果和核心选路 | 实现，M2 | VT-15～VT-18、VT-30、VT-31；源码不等于运行通过 |
| DO-12 | shortId 生成来源与已批准上游不一致 | 已关闭（需求 D28，2026-10-31）：部署脚本在 VPS 上用 `openssl rand -hex 8` 生成，经 API 写入；方案设计第 7.3、7.4、7.9 节和 VT-16 已同步（第 15.1 节） | 用户，2026-10-31 已决定 | 不再阻塞；生成和传递的运行证据随 VT-16 在 M2 取得 |
| DO-13 | Xray v26.10.21 的相关修复与核心版本选择 | 已决定（需求 D30，2026-10-31）：采用 A，等 3X-UI 的修复版；M1、M2 保持 v3.11.0 自带的 v26.10.21（第 6.1 节） | 用户，2026-10-31 已决定；修复版的评估随 FR-10 | 不阻塞 M1、M2。修复版出现后按需求第 11.3 节评估，替换时同步上游、摘要和受影响验证；拒绝连接回收、正常转发与重启证据未取得，不宣称修复通过 |
| DO-14 | IPv4 订阅下的 IPv6 出站策略及检查契约冻结（需求 FR-13） | 已决定（需求 D33，2026-10-31）：部署输入 `ipv6_ai_egress`（`on`/`off`，必须给出）及部署记录（第 2.4、2.8 节）；输入 `on` 而没有可用的 IPv6 时预检拒绝，部署之后为 FAIL，可用地址多于一个时为 WARN（`ipv6.egress`）；出站与规则的形态和检查（第 4.4 节、`routing.ai-ipv6`）；写入前用自带 Xray 核验类别（第 16.1 节）；字面量不匹配规则（第 4.4 节）。用例见验证计划 v1.2 的 VT-32～VT-34（VO-8 关闭） | 用户，2026-10-31 已批准 | 不阻塞 M1。`ip -j` 的字段、`run -test` 的类别核验和实际出站行为在 M2 随 VT-32～VT-34 取得运行证据；旧基线通过不能算 IPv6 分流完成 |

验证计划中仍待用户决定的 VO-5（FR-11 三个客户端的平台）和 VO-7（测试 VPS 的时间、主机和授权范围）都在 M3 之前，不影响 M1。VO-2、VO-3、VO-4、VO-6 继续由验证计划拥有，本文引用，不代为关闭。以上“已核实”仅指证据，“待评审设计”不等于用户批准；没有把任何 DO 或 VO 记为运行通过。

## 13. 需求追踪

下表追踪的是设计和验证责任，不是完成报告；所有运行用例仍未执行。

| 需求或上游约束 | 本文设计位置 | 验证及阶段/待定 |
|---|---|---|
| FR-01 | 第 3、4.2、6、16.1 节，安装前后摘要与回环面板 | VT-10～VT-13；M2，摘要先在 M1 取得（DO-3） |
| FR-02 | 第 2.4、2.7、4.4、5、15.1、17 节；`reality.*`、`forwarder.settings`、`routing.*` | VT-16、VT-20～VT-29、VT-80、VT-81；M1 target、M2 流量；真实 target 在 M5 |
| FR-03 | 第 2.4 节 `users`、第 4.2 节 `clients.*`、第 15 节 | VT-35～VT-38；M2；停用/重置/删除的业务结果不由数量检查替代 |
| FR-04 | 第 4.2 节 `sub.*`、第 15.1、15.2、18.3 节 | VT-40～VT-44；M2，规则文本待 DO-9，真实拉取在 M3 |
| FR-05 | 第 2.4、2.8、4.2、18 节；token 生命周期 | VT-50～VT-55；M2 残留、M3 服务与真实 Tunnel；DO-4、DO-6、VO-7 |
| FR-06 | 第 2.8、4.2、16.1、17 节；开放端口仍为管理员操作 | VT-60～VT-62，M2；验证计划第 5 节外部扫描，M5 |
| FR-07 | 第 2.2、2.3、2.6、4、18.2 节；数据来源分层 | VT-70～VT-76；M1～M3 按基线分阶段，不把 SKIP 或静态证据当业务验收 |
| FR-08 | 第 2、16、18 节提供使用说明的契约输入 | 完整操作手册及 SC1～SC7 在 M4、M5；验证计划第 5 节 M5，本文不代交手册 |
| FR-09 | 第 16.2、16.3 节；同版本备份、恢复和单连接器切换，默认沿用令牌、必要时轮换（需求 D26） | VT-85、VT-86，M4；真实 Tunnel 切换需 VO-7 授权 |
| FR-10 | 第 16.3 节；原机回退的两次停止和旧备份 | VT-87～VT-90，M4；版本沿用 VO-4，不在此升级 |
| FR-11 | 第 18.3 节的拉取/客户端边界 | 验证计划第 5 节 M3、M5；客户端说明在 M5，平台 VO-5 待定 |
| FR-12 | 第 2.4、2.5、3、15、16.1、19 节 | VT-01～VT-05、VT-15～VT-18；M1 预检、M2 写入，无自动回滚 |
| FR-13 | 第 2.4、2.8、3、4.2、4.4、16.1 节，DO-14；取值按需求 D29、D31，机制按需求 D32，检查细节按需求 D33 | VT-32～VT-34、VT-71 的 FR-13 部分（验证计划 v1.2）；M2 |
| NFR-01 | 第 2.3、4.1、8、15.2、18.1、19 节 | VT-13、VT-17、VT-52、VT-74 及全部归档扫描；M1～M3 |
| NFR-02 | 第 9.1、19 节；公开常量有限例外与私有清单 | VT-97；各次提交前；本地清单不入库 |
| NFR-03 | 第 3 节 `platform`、第 9.1、9.2 节 | Debian 13 amd64，M1 起；不扩 Debian 12/Ubuntu 矩阵 |
| NFR-04 | 第 3、4.2、16.1～16.3 节；保留 tuning drop-in | VT-05、VT-18、VT-62、VT-94；M1/M2，hardening 版本 DO-7 |
| NFR-05 | 第 6、16.1、18.1 节；固定提交、摘要、禁自动更新 | VT-11、VT-12、VT-50、VT-51、VT-98、VT-99；M2～M4；核心候选及受影响验证见 DO-13 |
| NFR-06 | 第 16.1、18.1 节；服务解耦与独立业务中断判据 | VT-54、VT-92、VT-93；M2/M3，操作等待上限不放宽 10 秒判据 |
| NFR-07 | 第 4.1、9.3、9.4 节；一次快照、状态变化和确定性 | VT-72、VT-75、VT-76；M1，DO-1 关闭前不宣称只读保证 |
| D21、D22/OD-1～OD-4 | 第 17、18 节；回环订阅、远程 Tunnel、SNI 与回国规则、动态用户 | 沿用批准选择，不重新选型；SR-3、SR-8 例外仍需原决定流程 |
| 方案第 7.5 节“值是否包含路径” | 第 4.2 节 `sub.uri`、第 14、15.2 节 | 已核实拼接源码；VT-43 在 M2 验证 |
| VT-75 退出码；验证计划第 3.3 节文档地址 | 第 2.2、2.4 节 | M1；不因测试保留地址放宽私有/非公网地址的其他拒绝规则 |
| 验证计划第 4 节排除清单、VT-71 同阶段基线 | 第 9.4、9.5、19 节 | M1 实测清单；不把检查造成的写入列为排除 |
| VT-12、VT-30 交给详细设计的接口 | 第 19 节、DO-10、DO-11 | 接缝和 API 设计已写，执行验证在 M2 |
| 2026-10-30 用户澄清（需求 U18、D27）：IPv4 订阅、双栈用于出站；先保留基线 | 第 1、4.4 节、DO-14 | 现行监听偏差沿用 VT-71/M2，公网扫描在 M5；IPv6 出站用例见验证计划 v1.2 的 VT-32～VT-34 |
| 需求 D24、D26、D28 | 第 2.8、15.1、15.2、16.1、16.3 节 | VT-16、VT-86；令牌轮换分支是文档步骤，不在虚拟机中演练 |
| 需求 D30 | 第 6.1 节、DO-13 | M1、M2 沿用固定核心；修复版出现后按 FR-10 和验证计划 VO-4 评估 |

## 14. 本文新核实的事实（2026-10-30）

需求第 10.1 节、方案设计第 13 节和验证计划第 11 节已有的不再重复。

| 事实 | 来源 |
|---|---|
| 订阅地址由 `subURI`（Mihomo 格式用 `subClashURI`）与订阅 ID 直接拼成，以 `/` 连接；值为空时用 `BuildSubURIBase` 生成的 `http(s)://<主机>[:端口]` 加订阅路径。所以这两个值要包含路径 | v3.11.0 `internal/sub/service.go`（`BuildURLs`、`buildSingleURL`、`joinPathWithID`），`internal/web/service/setting.go`（`BuildSubURIBase`、`GetDefaultSettings`） |
| 设置表中没有某个键时，按内置的默认值返回 | v3.11.0 `internal/web/service/setting.go`（`getString`） |
| 保存设置时，路由规则（含 `subClashRules`）只在是远程地址时被改写为规范形式，本地的规则文本原样保存 | v3.11.0 `internal/web/service/setting.go`（`validateRemoteRoutingURLSetting`） |
| VLESS 的 flow 在 `network` 为 `tcp`、`security` 为 `tls` 或 `reality` 时允许，另外在启用 VLESS 加密时允许（`xdrive` 传输除外）；订阅和生成 Xray 配置用同一判定 | v3.11.0 `internal/sub/service.go`（`vlessFlowAllowed`，注释说明与 `internal/web/service` 的 `inboundCanEnableTlsFlow` 一致） |
| cloudflared 在 `~/.cloudflared`、`~/.cloudflare-warp`、`~/cloudflare-warp`、`/etc/cloudflared`、`/usr/local/etc/cloudflared` 中依次查找配置文件和账户证书 `cert.pem` | cloudflared 2026.10.5 `config/configuration.go`（`DefaultConfigSearchDirectories`），`credentials/origin_cert.go`（`FindDefaultOriginCertPath`） |
| x-ui 的每次调用（包括 `-v`）都先读取 `/etc/default/x-ui`、`/etc/conf.d/x-ui`、`/etc/sysconfig/x-ui` 中第一个存在的文件（godotenv），再解析参数；`-v` 打印版本后返回，不打开数据库 | v3.11.0 `main.go`（`loadServiceEnvFile`、`main`），`internal/config/config.go`（`GetEnvFilePaths`） |
| 改变位置和数据库的环境变量有 `XUI_DB_FOLDER`、`XUI_BIN_FOLDER`、`XUI_LOG_FOLDER`、`XUI_DB_TYPE`、`XUI_DB_DSN`、`XUI_DB_JOURNAL_MODE`、`XUI_DB_SYNCHRONOUS` 等 | v3.11.0 `internal/config/config.go`、`internal/database/db.go` |
| `install.sh` 只在选择 PostgreSQL 时写 `/etc/default/x-ui`；每次安装都重新生成 `x-ui.service.d/10-xui-sandbox.conf`，其中的可写目录按环境文件中的 `XUI_*` 变量求得 | v3.11.0 `install.sh`（数据库选择、`_xui_service_write_paths_dropin`） |
| tag 路径上的 `x-ui.service.debian` 的 SHA-256 为 `95cb6e39499601148404cadf3b4d75b0489301ff7e7ab565cd9db21d23be957c`；单元中 `EnvironmentFile=-/etc/default/x-ui`，`Environment="XRAY_VMESS_AEAD_FORCED=false"`，`WorkingDirectory=/usr/local/x-ui/`，`ExecStart=/usr/local/x-ui/x-ui` | 提交 `c621ba9` 的 `x-ui.service.debian` |
| Tunnel 的令牌是标准 Base64 编码的 JSON：`a`（账户标签）、`s`（密钥，`[]byte`，在 JSON 中是 Base64 字符串）、`t`（Tunnel ID，UUID）、可选的 `e`。令牌文件的内容去掉首尾空白后使用；`--token`（`TUNNEL_TOKEN`）优先于 `--token-file`；新建 Tunnel 时密钥至少 32 字节 | cloudflared 2026.10.5 `connection/connection.go`（`TunnelToken`），`cmd/cloudflared/tunnel/subcommands.go`（`ParseToken`、令牌文件的读取），`cmd/cloudflared/tunnel/subcommand_context.go` |
| 只读打开 WAL 数据库时，要么 `-shm` 和 `-wal` 已存在，要么目录可写以便创建它们，要么以 `immutable` 打开 | SQLite 文档 `wal.html`（Read-Only Databases） |
| Debian 13 的软件包版本：`sqlite3` 3.46.1-7+deb13u2，`jq` 1.7.1-6+deb13u4，`curl` 8.14.1-2+deb13u7，`openssl` 3.5.7-1~deb13u3，`iproute2` 6.15.0-1 | packages.debian.org（trixie），2026-10-30 |
| vps-hardening 的状态文件是 `键=值` 行，`state_get` 取第一行；`--version` 输出 `vps-hardening <版本>`；默认分支的版本已是 `0.1.2` | vps-hardening `lib/vps-hardening/state.sh`、`bin/vps-hardening` |
| `setting/update` 先保留遮蔽秘密，再按完整 `AllSetting` 遍历保存；不能当 PATCH 使用 | 固定提交的 [setting.go：UpdateAllSetting](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/service/setting.go#L1669-L1745)、[设置视图控制器](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/controller/setting.go#L100-L109) |
| POST `/xray/` 对旧包装模板有自愈写入，返回的 `obj` 为 JSON 字符串；`xray/update` 接收表单，省略测试 URL 会复位默认值，保存与核心更新并非一个事务 | 固定提交的 [xray_setting.go：读取与写入](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/controller/xray_setting.go#L77-L164)；与 [OpenAPI](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/frontend/public/openapi.json) 的读取示例有表示差异 |
| 安装 token 的元数据不含明文；删除接口要求 `expectedScope`，不能只给 ID；安装结果用 `%q` 写出 | [token 服务](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/service/panel/api_token.go#L19-L120)、[删除控制器](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/controller/setting.go#L281-L292)、[install.sh](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/install.sh#L148-L168) |
| shortId 由前端的 `randomShortIds` 生成；固定版本 OpenAPI 和 server 路由未提供 shortId 生成接口，与上游“接口生成”的文字不一致 | [前端调用](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/frontend/src/pages/inbounds/form/useSecurityActions.ts#L176-L184)、[随机值实现](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/frontend/src/utils/index.ts#L204-L232)、[server 路由](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/controller/server.go#L45-L87)；DO-12（已按需求 D28 关闭） |
| 新增使用者和路由测试的请求格式；routeTest 调核心的选路测试，不发送业务请求 | [客户端控制器](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/controller/client.go)、[OpenAPI](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/frontend/public/openapi.json) 的 `/clients/add`、`/xray/routeTest`；第 19 节不以该接口替代 VT-31 |
| cloudflared 的 tunnel/run 参数归属，token 环境变量优先于 token 文件；有效 ingress 序列化保留空 Host 字段和 path | cloudflared 2026.10.5 [cmd.go](https://github.com/cloudflare/cloudflared/blob/2026.10.5/cmd/cloudflared/tunnel/cmd.go)、[subcommands.go](https://github.com/cloudflare/cloudflared/blob/2026.10.5/cmd/cloudflared/tunnel/subcommands.go#L714-L786)、[rule.go](https://github.com/cloudflare/cloudflared/blob/2026.10.5/ingress/rule.go#L13-L32)、[config.go](https://github.com/cloudflare/cloudflared/blob/2026.10.5/ingress/config.go#L305-L306)、[有效配置导出](https://github.com/cloudflare/cloudflared/blob/2026.10.5/orchestration/orchestrator.go#L255-L278) |
| `LoadCredential` 把凭据置于服务可读的只读目录，ExecStart 可用 `CREDENTIALS_DIRECTORY` 引用；支持动态用户并不证明本项目已运行成功 | systemd v257 [systemd.exec.xml：Credentials](https://github.com/systemd/systemd/blob/v257/man/systemd.exec.xml#L3448-L3539)；运行验证在 M3 |
| Xray v26.10.29 包含 #7238；v26.10.21 的 Freedom block 延时依赖中断 reader，VLESS/Vision 的 `DispatchLink` 路径可能未按时结束。私有地址保护仍在，项目运行影响尚未实测 | [v26.10.29 发布](https://github.com/XTLS/Xray-core/releases/tag/v26.10.29)、[修复 PR #7238](https://github.com/XTLS/Xray-core/pull/7238)、[旧 block 实现](https://github.com/XTLS/Xray-core/blob/v26.10.21/proxy/freedom/freedom.go#L216-L246)、[解析与私有地址检查](https://github.com/XTLS/Xray-core/blob/v26.10.21/proxy/freedom/freedom.go#L294-L358)、[Vision/DispatchLink](https://github.com/XTLS/Xray-core/blob/v26.10.21/proxy/vless/inbound/inbound.go#L604-L628)；DO-13 |
| `IPOnDemand` 按需向路由上下文提供 DNS；同条规则各字段取 AND，首条匹配即返回。选择出站不等于连接成功，也不提供连接失败后的跨出站回退 | [固定核心路由器](https://github.com/XTLS/Xray-core/blob/v26.10.21/app/router/router.go#L201-L228)、[条件组合与 IP 匹配](https://github.com/XTLS/Xray-core/blob/v26.10.21/app/router/condition.go#L35-L109)；DO-14 |
| 地址族解析策略处理域名目标，`Force` 解析失败直接报错；`Use` 可进入底层系统拨号。`sendThrough=0.0.0.0` 在系统拨号器中表示不指定本地源地址，不能证明强制 IPv4。旧 `freedom.domainStrategy` 在该核心仍接受，但会兼容迁移到 `sockopt.domainStrategy` | [解析/拨号条件](https://github.com/XTLS/Xray-core/blob/v26.10.21/transport/internet/dialer.go#L251-L264)、[源地址处理](https://github.com/XTLS/Xray-core/blob/v26.10.21/transport/internet/system_dialer.go#L31-L46)、[兼容迁移](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/xray.go#L416-L430)；DO-14 |
| iproute2 6.15 的 `ss -e` 可输出内核提供的 IPv6 socket `v6only`；缺少内核属性时不输出，不能凭缺失值判为 0。命令在 Debian 13 上的真实输出与解析仍待 M2 核实 | [ss.c：读取与输出](https://github.com/iproute2/iproute2/blob/v6.15.0/misc/ss.c#L3752-L3785)、[选项处理](https://github.com/iproute2/iproute2/blob/v6.15.0/misc/ss.c#L5961-L5964)；DO-2、第 4.4 节 |
| 2026-10-31：3X-UI v3.11.0 的默认模板没有 `dns`。没有 `dns` 时核心用本机解析器（`localdns`），一次取两种地址再按地址族筛选，不按本机路由过滤 AAAA；`dns.queryStrategy` 为 `UseSystem` 时才按本机路由筛选，`UseIPv4`、`UseIPv6` 只保留一种地址族，无法识别的值按 `UseIP` 处理 | [默认模板](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/web/service/config.json)、[默认解析器](https://github.com/XTLS/Xray-core/blob/v26.10.21/core/xray.go)、[localdns](https://github.com/XTLS/Xray-core/blob/v26.10.21/features/dns/localdns/client.go)、[DNS 模块](https://github.com/XTLS/Xray-core/blob/v26.10.21/app/dns/dns.go)、[取值解析](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/dns.go#L398-L411)；`routing.ai-ipv6`、验证计划 VT-34 |
| 2026-10-31：没有命中路由规则的连接走第一个出站，出站管理器把第一个加入的出站设为默认 | [outbound.go](https://github.com/XTLS/Xray-core/blob/v26.10.21/app/proxyman/outbound/outbound.go#L109-L111)；`routing.ai-ipv6` |
| 2026-10-31：路由规则中的 `geosite:` 类别在解析配置时核对，`geosite.dat` 中没有这个类别时配置加载失败；`run -test` 只测试配置、不启动服务，同样经过这一步。资产文件先从 `XRAY_LOCATION_ASSET` 指定的目录、没有时从程序所在的目录查找 | [rule_parser.go](https://github.com/XTLS/Xray-core/blob/v26.10.21/common/geodata/rule_parser.go#L193-L224)、[geodat_loader.go](https://github.com/XTLS/Xray-core/blob/v26.10.21/common/geodata/geodat_loader.go#L19-L29)、[run.go](https://github.com/XTLS/Xray-core/blob/v26.10.21/main/run.go#L83-L93)、[platform.go](https://github.com/XTLS/Xray-core/blob/v26.10.21/common/platform/platform.go#L16-L35)；第 16.1 节、`routing.ai-ipv6` |

## 15. 3X-UI API 与凭据（M2）

### 15.1 请求和响应契约

以下路径相对于 `http://127.0.0.1:<面板端口>/<webBasePath>`；拼接时确保路径之间只有一个 `/`。`webBasePath` 从安装结果读取，属于秘密，不显示完整 URL。只连接回环地址，不使用代理环境变量，不跟随重定向，不降级到另一认证方式。认证为安装生成的 admin 范围 Bearer token；不登录浏览器会话，不使用 Cookie，也不长期创建检查专用 token。

所有请求设置连接超时 5 秒、单次总超时 30 秒；这是本草案选择的操作上限，不是已测性能指标。HTTP 200 还须满足 JSON 的 `success` 为布尔值 true、`obj` 满足该接口的结构，才算接口成功。HTTP 200 加 `success=false` 仍失败，不按可能本地化的 `msg` 判断成功。超时、认证失败、非预期状态码、结构缺失均停止该步骤；写操作的结果分类见第 15.3 节。原始响应、`msg`、响应头和请求体都不直接输出。

| 用途 | 方法和路径 | 输入、输出和限制 |
|---|---|---|
| 读取完整设置 | POST `/panel/api/setting/all` | 无业务请求体；`obj` 为设置视图对象。秘密被遮蔽，`has*` 是只读视图元数据；此接口用于部署，不用于 `check` |
| 写订阅设置 | POST `/panel/api/setting/update`，JSON | **全量设置更新，不是 PATCH**。由完整读取结果构造固定版本 `AllSetting` 的全部字段，去掉视图元数据，只修改方案设计第 7.5 节指定的订阅键；其余字段保持原值。空的遮蔽秘密按上游 `preserveRedactedSecrets` 保留，不发送清除秘密的控制字段。写后重新读取并逐字段核对，不能只发送几项而让其他字段落为零值 |
| 读取 Xray 模板 | POST `/panel/api/xray/` | 固定源码的 `obj` 是 JSON 编码的字符串，解析一次得到含 `xraySetting`、`outboundTestUrl` 等字段的对象；其中 `xraySetting` 是模板对象。OpenAPI 示例与此存在表示差异，按固定源码并在 M2 实测。读取还可能修复旧的嵌套模板并写库，所以只能在写入前核对通过后用于部署，不能用于预检、拒绝分支或 `check` |
| 写 Xray 模板 | POST `/panel/api/xray/update`，表单编码 | `xraySetting` 为完整模板的 JSON 字符串；`outboundTestUrl` 显式保留读取值，不能省略或传空，否则上游恢复默认值。只添加第 17 节四条路由，保留其余模板。保存、设置测试 URL、应用到核心不是一个整体事务；响应失败也可能已经保存 |
| 读取入站 | GET `/panel/api/inbounds/list` | `obj` 为数组。入站的 `settings`、`streamSettings`、`sniffing` 按固定版本为对象；读取返回的 `id`、`tag`，不凭端口猜 tag |
| 新增入站 | POST `/panel/api/inbounds/add`，JSON | 一次一个入站，传 `enable`、`protocol`、`port`、`listen`、`remark`、`settings`、`streamSettings`、`sniffing`。本地入站 `nodeId=null`；`expiryTime=0`、`total=0`。配置字段统一传对象，不混用旧的 JSON 字符串形式。REALITY 另设 `shareAddrStrategy=custom`、`shareAddr=node_ip`、`excludeFromSub=false`、`disableFlow=false`。响应和重新读取必须能唯一定位刚建的入站 |
| 新增使用者 | POST `/panel/api/clients/add`，JSON | `client` 对象含代号 `email`、`enable=true`、`flow=xtls-rprx-vision`、`limitIp=0`、`totalGB=0`、`expiryTime=0`、`tgId=0`，`inboundIds` 数组只含 REALITY 入站的数值 ID；省略 UUID 的输入字段 `client.id` 和 `client.subId`，由服务端生成。不在入站的嵌套客户端和全局客户端接口中重复添加同一人 |
| 读取使用者 | GET `/panel/api/clients/get/<email>` | email 作为单一路径段编码；读取 `obj.client` 与 `obj.inboundIds`，核对代号、`obj.client.uuid`、`obj.client.subId`、flow、启用状态和所属入站。此处 `obj.client.id` 是数值数据库主键，不是 UUID。唯一性在进程内比较，只输出代号及计数；各人的 UUID 和订阅 ID 均应互异 |
| 生成 REALITY 密钥对 | GET `/panel/api/server/getNewX25519Cert` | `obj.privateKey`、`obj.publicKey`；校验字段、编码和解码后的 32 字节长度，只用于本次入站请求和核对，私钥不写入 handoff。生成接口使用已安装的 Xray，仍须先完成安装核对 |
| 列出安装 token | GET `/panel/api/setting/apiTokens` | `obj` 数组只含元数据。全新安装应能唯一定位名为 `install`、启用、admin 范围的记录；保留其数值 ID。异常数量或身份不符时停止，不批量删除其他 token |
| 撤销安装 token | POST `/panel/api/setting/apiTokens/delete/<id>`，JSON | 必须传 `expectedScope=admin`；删除指定 ID。之后用原 token 访问此前成功的固定路径，应为 HTTP 401，并通过第 4.1 节只读数据库方式确认该 ID 已不存在。404、超时或服务停止不能证明撤销 |
| 重启面板 | POST `/panel/api/setting/restartPanel` | 无业务请求体；成功只说明已调度重启。固定源码延迟约 3 秒触发重启，随后观察 systemd、API 可用性和 `ss`；不能收到 200 就认为新监听已生效 |

**shortId 的生成（需求 D28，DO-12 已关闭）。** 固定 v3.11.0 的服务端路由和 OpenAPI 有 UUID、X25519 生成接口，没有 shortId 生成接口；前端的随机按钮在浏览器中一次生成 8 个不同长度的值（需求第 10.1 节），不符合 `reality.settings` 只有一项的要求。第 6 步由部署脚本执行 `openssl rand -hex 8`：OpenSSL 的密码学安全随机源，8 字节，输出 16 个小写十六进制字符。去掉行尾换行后按 `^[0-9a-f]{16}$` 校验；命令失败或输出不符时停止该步骤，不退化为固定值，也不改用其他随机源。该值只在部署进程的内存中，按第 8 节经标准输入交给 `jq` 构造入站请求，不出现在 argv、日志、错误输出和 handoff 中；写入后按 `reality.settings` 读回核对。之后重新生成也用同一命令，再写入入站，不用面板的随机按钮。`openssl` 已在预检的 `deps` 中（第 3 节）。

### 15.2 秘密的来源、存放与删除

| 对象 | 允许的存放与传递 | 正常完成点与失败时处理 |
|---|---|---|
| 部署输入文件、交互输入 | 第 2.4 节的文件或进程内存；不导出到子进程环境 | 预检拒绝或取消保留输入文件。首次部署完成第 7 步导入后删除输入文件，内存中的 Tunnel token 留到第 8 步落入专用文件；`--migrate` 在安装准备与 token 文件写入确认后删除。删除前确认路径仍对应原打开文件，替换过则不删除替代文件并报告未完成清理 |
| `/etc/x-ui/install-result.env` | root、0600、普通文件，从同一已核对描述符读取；不 `source`、不 `eval` | 上游以 Bash `printf %q` 编码，不能当第 2.4 节的原始值文件盲读。本工具清除继承覆盖并走全新安装分支后，只接受所需字段的未转义格式：用户名/密码各 10 个、路径标签 18 个 ASCII 字母数字，API token 为 48 个字母数字，端口为数字；不用 `XUI_ACCESS_URL`。所需字段含引号、反斜杠或其他形式时停止并保留受保护原文件，不执行 shell 解码。M2 核实实际格式 |
| 面板凭据和 `webBasePath` | 进程内存、3X-UI 数据库、root 0600 的 `handoff` | handoff 原子发布并核对后才删除安装结果；管理员取走后删除 handoff。脚本不代为发送，不把内容作为成功摘要 |
| 安装 admin token | 内存、安装结果；向 `curl` 传入的头配置用受保护文件或标准输入 | 写入、订阅核对及所有需要认证的读回完成后撤销；证实撤销后删除安装结果和认证临时文件。若撤销结果未知，不宣布完成，明确仍需人工核对，不能以删掉明文文件代替撤销 |
| REALITY 私钥、shortId、客户端 UUID、订阅 ID 和路径 | 仅部署内存及数据库；由 3X-UI 生成订阅。shortId 由 `openssl rand -hex 8` 在部署进程中生成（第 15.1 节） | 临时请求/响应退出时删除；不进入日志。handoff 仅含订阅 URL 所必需的路径和订阅 ID，不另列私钥、UUID 或 shortId |
| Tunnel token | 内存与 `/etc/vps-proxy-setup/tunnel-token`；运行时由 systemd 的凭据目录提供 | token 文件同目录暂存、核对属主权限后改名；不把 token 放进 argv、Environment、单元内容或 journal。失败不自动删除已安装的持久文件；迁移时默认沿用；疑似泄露、旧机被入侵或需要隔离无法管理的旧连接器时由管理员轮换（需求 D26，第 16.3 节），运行中的服务需重启才能读取新凭据 |
| 安装日志、API 请求和响应临时文件 | `mktemp -d` 的 root 0700 私有目录，文件 0600，禁止 xtrace 和 curl verbose/trace | 正常退出、ERR、INT、TERM 清理；掉电/SIGKILL 后须按失败说明检查残留。任何诊断摘录先删除已知秘密及敏感字段；无法可靠脱敏时只报告步骤、退出状态和原因类别 |

`handoff` 采用 UTF-8 JSON：`format=1`、`panel`（`username`、`password`、`webBasePath`、`port`）、`users` 数组（每项 `email`、`subscriptionUrl`、`mihomoUrl`）。两个地址分别用当前 `subPath`、`subClashPath` 和该人的 `subId` 构造：`https://<sub_host>/<路径>/<subId>`，路径连接规则按第 14 节，不重生成订阅路径。文件只显示交付位置，内容不输出。写在目标目录的临时文件，完成解析回验、数量和权限核对后原子改名；异常停止，保留仍需要的原始凭据来源。

启动安装器时只显式传入方案规定的 `XUI_*`；清除继承的用户名、密码、路径、数据库位置和数据库类型覆盖，防止旧环境变量改变新装假设。这个限制与上游 `%q` 格式一起在 M2 测试，不增加通用 shell 文件解释器。

### 15.3 写入结果、重试与并发

- 只读 `check` 不使用上述 API。`deploy` 的读取也不能统称无副作用，例如 `/xray/` 的自愈行为；第 5 步拒绝写入所需的事实优先用第 4.1 节只读快照核对。
- 写前重新确认目标尚未有业务配置；本工具的锁只排斥另一个本工具进程，不锁住管理员、面板或 3X-UI。部署期间要求没有并行面板操作；检测到读回与预期不符立即停止，不覆盖第三方改动。首次部署 API 跨请求没有整体事务，这个窗口不承诺消除。
- 每个新增和更新请求只发送一次。收到明确失败、结构错误，或请求发出后断开/超时，均停止后续写入。后两种记为“结果未知”，不能解释为没写入，也不使用 `curl --retry` 重放写操作。
- 结果未知时可重新读取相应入站、客户端或设置，并在受保护内存中比较自然键、返回 ID 和目标值，供人工判断当前状态；不因此继续后续步骤或自动回滚。即使单个接口采用事务，也不能推断它与核心重载一起原子完成。
- token 删除是特殊收尾：响应丢失后只有“原 token 在既定路径被拒绝，且数据库中该 ID 不存在”两项均成立，才可判为撤销完成；否则停止并保留恢复提示。不会为查证而生成第二个 admin token。
- 读请求在连接失败时至多重试一次，前提是已确认该路径在当前数据状态下没有写入副作用；面板重启后的等待按第 16.1 节轮询。401、字段不符、业务拒绝不通过重试掩盖。

## 16. 写入、备份与恢复顺序

### 16.1 首次部署的状态与边界（M2、M3）

本节细化方案设计第 7.3 节的 1～9 步，不新增恢复子命令。下载和核对用私有临时目录；“主机不变”指持久配置、服务、数据库和包不变，临时下载与锁的生命周期不算部署写入。每步结束报告非秘密的阶段和结果。

| 上游步骤 | 必须完成的动作及顺序 | 完成证据与失败后的可见状态 |
|---|---|---|
| 1 预检 | 第 2.5、3 节；显示变更摘要并确认。再次确认服务、文件和端口没有改变 | 未确认不安装；输入文件保留 |
| 2 预取核对 | 固定提交、安装器、发布包、`x-ui.sh` 和单元逐一校验；不运行未核对的文件 | 任一不符即停，持久主机状态不变（VT-11） |
| 3 安装 | 保存 `90-proxy-vps.conf` 的路径、权限和摘要供后续核对；非交互运行已核对安装器，输出受保护 | 安装器可能已启动服务或写库；失败属于部分安装，不假称未改动 |
| 4 安装后核对 | 先核对所装文件，再执行 `x-ui setting -listenIP 127.0.0.1` 并重启；验证面板只监听回环、tuning drop-in 保持、无 `3x-ipl` | 安装后摘要不符走 SR-9：停止，不写业务设置，提示按潜在入侵处理并重装；不把普通卸载清理当作消除了该风险（VT-12） |
| 5 写入前核对 | 确认版本、无入站/使用者、有效订阅设置为新装默认；只读比较通过后，读取安装结果并验证安装 token。检查所选 target 的有效记录；所有输入仍在内存中 | 已有业务配置则拒绝。拒绝路径不调用可能自愈写库的 `/xray/`，不删除输入或安装结果（VT-15） |
| 6 写业务配置 | 获取完整设置和模板；按第 15 节生成密钥（shortId 按第 15.1 节在本机生成）。保留订阅路径，写订阅设置；创建回环转发入站和 REALITY 入站，取得真实 ID/tag 后写模板前四条路由。输入 `ipv6_ai_egress=on` 时，同一次模板写入加上第 4.4 节的 `ai-ipv6` 出站和第五条规则；写入之前用 3X-UI 自带的 Xray 以 `run -test` 加载一份只含这个出站和这条规则的临时配置，确认自带的 `geosite.dat` 有这两个类别，不通过则停止、不写模板（第 14 节）。之后逐人创建客户端并读回。初始化时公网 443 尚未开放，最终路由确认前不把节点交给使用者 | 每次写入后核对本项。取得 tag 后才写路由是对上游写入步骤内部的细化，不猜 tag。失败停止且保留已完成部分，不自动恢复数据库（VT-16、VT-18；FR-13 见 VT-32、VT-33） |
| 7 收尾 3X-UI | 重启面板，等待服务/API 恢复并核对订阅监听及本机订阅；准备并原子发布 handoff；撤销并证实安装 token 失效；发布 `deploy.conf`；删除 `install-result.env` 和原输入文件，清除不再需要的秘密 | 订阅读回在撤销 token 前完成；handoff 写失败不能先删唯一凭据来源。成功后 token、安装结果和输入文件均不残留（VT-17）；部署记录不等于 Tunnel 已就绪 |
| 8 Tunnel | 固定摘要核对 cloudflared，安装二进制、root 0600 token、服务单元；`daemon-reload` 后核对已加载属性；启用并启动，按第 18 节等 `/ready` 和有效路由 | M3 的真实连接验证独立；假 token 超时必须返回 1，保留部署后状态供只读检查和清理，不回滚 3X-UI（VT-53） |
| 9 检查 | 执行完整 `check`，报告其退出码；0 时提示管理员按 FR-06 开放 443/tcp、从新 SSH 会话确认并做外部验收 | 脚本不调用 `vps-hardening ports`、不改 UFW。最终检查失败返回 1，配置仍在 |

面板重启等待上限 60 秒，轮询间隔 2 秒，每次请求有独立超时且不超过剩余总期限；这些是本草案的操作上限。观察超时不等于服务已恢复，也不自动重复重启。后续 NFR-06 的业务中断仍按 VT-92 的 10 秒判据，不能拿 60 秒等待上限放宽它。

M2 的开发阶段执行到第 7 步后以 1 报告 Tunnel 尚未实现，符合 VT-70 的阶段基线；输入已按 VT-17 消费，尚未落盘的 Tunnel token 随进程退出丢弃。这个阶段版本不能用于完整首次部署，不提供从中间步骤恢复执行的承诺。完整 M3 流程在同一次调用中继续把内存 token 写入第 8 步的专用文件。

失败提示至少说明：最后确认完成的步骤、当前失败步骤、是否已安装/写入、写入结果已知或未知、仍保留哪些受保护文件、适用清理或恢复路径。第 3 步之后普通失败沿用上游的人工清理：保留或恢复 tuning drop-in，卸载 x-ui，停止并清理本工具的 cloudflared 文件和 token，再清理部署目录；确认预检可通过且 tuning 严格验证通过后重新部署。此流程在 M2 验证；本文没有执行清理，也不授权将其用于已有业务主机。

### 16.2 备份与原机恢复（M4）

**备份契约。** 输入是当前固定版本、数据库路径和管理员指定的 root 0700 私有输出目录。使用 SQLite 在线备份接口（`.backup`）取得一致副本，不直接复制正在写入的主数据库文件，也不把一组不同时点的 DB/WAL/SHM 当作备份。备份文件暂以 0600 创建，备份成功后只读运行 `PRAGMA integrity_check`，必须只返回 `ok`；记录版本、时间、大小、SHA-256 和属主权限，再改名为最终文件。失败保留原主库，不发布标为成功的副本。

备份包含面板密码相关数据、密钥、UUID、订阅 ID 等，不能进入测试归档或仓库；由管理员取到 VPS 外加密保存。Tunnel token 单独保管或重新取得，不把它、handoff 和数据库打进普通诊断包。VT-85 的逐表摘要比较须针对一致的逻辑时点：测试期间冻结夹具的业务变更，单独记录已知后台流量计数变化；不能拿备份完成后的任意活库摘要证明或否定快照一致性。具体对照方法随 M4 补齐，不能仅凭 `integrity_check=ok` 宣称业务数据完整。

**恢复顺序。**

1. 核对备份版本、摘要、完整性、来源和权限；版本不匹配时停止，不能靠启动新版程序迁移后再声称恢复原样。
2. 停止 cloudflared，避免恢复期间对外提供旧/中间订阅；停止 x-ui，确认其管理的 Xray 及其他写者均已退出，防止重启或自动入口同时写库。
3. 在数据库目录之外的管理员私有恢复目录保存当前 DB、存在的 `-wal`、`-shm` 和必要文件元数据；不放在 x-ui 会清理的 `.x-ui-backup-*` 目录。保存现状用于失败分析，不把这组文件标为已经验证的在线备份。
4. 确认没有写者后移走原 DB 及其侧文件；不能把旧 `-wal`、`-shm` 留给新数据库。把经过验证的备份以临时文件放到目标文件系统，设置 root 所有、0600，目录权限按第 4 节；验证后同文件系统改名为 `x-ui.db`，在没有旧侧文件的条件下再次只读核验完整性。失败保持服务停止，原现场仍在受保护恢复目录。
5. 启动 x-ui，核对版本、文件摘要、回环监听、入站/使用者和订阅内容，再执行 `check`。此时未启动 Tunnel 的项预期失败并逐项列出，不能把它们改成 PASS。局部恢复验证通过后启动 cloudflared，再运行完整检查与客户端验证。

恢复是文档操作，没有自动回滚承诺。任何失败都先确认写者已停止，再由管理员选择重试恢复或使用保留的现场；不把旧 WAL 拼回已经启动过的新主库。文件替换成功不代表服务和业务恢复成功。

### 16.3 迁移、升级和回退（M2 分支；M3、M4 完成）

`deploy --migrate` 复用第 1～4 步的预检、版本和安装核对，但不执行第 6、7 步的业务写入、不调用设置/入站/客户端 API、不生成业务密钥和 handoff。安装器本身会初始化空库并启动 x-ui，这是安装行为；核对后停止并禁用新机 x-ui，在数据库恢复前不让它因重启继续运行。它不通过 `setting -listenIP` 修改待替换的空库；恢复后的面板监听按备份和检查核对。

cloudflared 的二进制、token 和单元安装到位，执行 `daemon-reload`，但**不启用、不启动新机连接器**。发布 `mode=migrate` 的部署记录，保存新 `node_ip`，确认 token 文件后删除输入文件；新装临时 `install-result.env` 在服务停止后删除，其空库将在恢复时整体移走。安装准备返回 0 的条件是两种固定版本文件、权限、单元及部署记录符合，两个服务均保持停止且新机连接器未启用；不运行完整 `check` 的通过条件来冒充已迁移。M3 以前未完成 cloudflared 安装的阶段版本仍返回 1。

后续由管理员按文档执行。开始切换前按需求 FR-09 确认既有管理路径：大陆到旧节点全部 TCP 不可达时，不能依赖同一路径的 SSH。使用服务商控制台或已有可信管理路径确认旧连接器状态；无法管理旧机时，须通过已授权的 Cloudflare 管理操作确认旧连接器已隔离。具体操作在使用说明中核实，不由 `deploy --migrate` 自动调用 Cloudflare API，也不新增公网管理入口：

1. 在新机复用第 16.2 节的备份核对、停写者、移走旧库及侧文件、替换和完整性检查，以及 x-ui 的恢复验证；**不执行该节原机恢复的 cloudflared 启动**。保留原订阅路径、订阅 ID 和使用者；启用并启动 x-ui，在面板把分享地址改为新机 IPv4，核对回环订阅及部署记录。恢复的数据库带着旧机的面板端口（`webPort`）：与新机 vps-hardening 记录的面板端口不同时，在同一步中经 SSH 隧道连到恢复后的端口，在面板中改为新机的值并重启面板，按第 15.1 节观察新监听，否则 `panel.listen` 不通过。恢复/改地址未成功不得切换 Tunnel，切换只在下一步执行。
2. 切换 Tunnel 的连接器，始终只保留一个，避免同一订阅随机返回新旧节点地址；用同一个 Tunnel，订阅主机名和 DNS 不因此更改。分两种情形（需求 D26）：
   - **默认：沿用同一个令牌。** 旧机可以管理时，**先停止并禁用旧机 cloudflared，再启用并启动新机 cloudflared**；新机用 `--migrate` 写入的令牌文件。
   - **轮换：怀疑旧机被入侵，或旧机无法管理、需要隔离旧连接器。** 强制断开只断开已建立的连接，旧连接器持有有效令牌就能重新接入，所以要轮换。在授权范围内依次：① 在 Cloudflare 上轮换令牌；② 把新令牌写入新机的令牌文件，沿用第 2.8、15.2 节的暂存、核对属主权限、改名，不经 argv；③ 在 VPS 之外用管理员持有的 API Token 强制断开该 Tunnel 的已有连接（需求 A-2、第 10.1 节）；④ 在 Cloudflare 上确认该 Tunnel 没有连接器在线；⑤ 启用并启动新机 cloudflared。不能只保存新文件就认为旧连接已断。替换令牌文件是使用说明中的文档步骤，不新增子命令；具体接口和命令在使用说明中对照届时的 Cloudflare 文档核实。

   无法确认旧连接器已停止或隔离时，停止切换，新机连接器继续保持未启用、未启动，不把新机准备完成报告为迁移成功。
3. 按 FR-06 开放新机 443/tcp 并确认，执行完整 `check`、经 Tunnel 的订阅和客户端验证；订阅获取须满足需求 FR-09 的前提，不能把 `check` 通过代替客户端取得新内容。节点不可用场景复用验证计划第 5 节 M5。失败时保持单一连接器，是否切回旧机由管理员决定，先检查旧机是否仍可信。

3X-UI 升级和回退不运行 `deploy` 绕过“全新安装”检查。升级先做第 16.2 节备份、按 FR-10 评估新版本并固定相应摘要。**原机回退必须依次停止 x-ui → 按旧版固定摘要重装（安装器可能自动启动）→ 再停止 x-ui → 恢复旧备份并处理侧文件 → 启动 → 检查**，不能省掉第二次停止；Tunnel 在恢复期间停止，验证后再接入。新机回退沿用迁移流程。cloudflared 升级只替换已核对的二进制并重启本服务，失败换回原版本并重新检查，不改 x-ui 或 REALITY。起止版本沿用验证计划 VO-4；此处没有批准新的版本。

## 17. REALITY 的 SNI 转发边界（M2）

第 4.2 节的字段检查是静态配置证据；本节规定实际流量应当跨过哪条边界，不以静态 PASS 代替 VT-20～VT-29。

| 位置 | 固定契约 | 必须观察的结果 |
|---|---|---|
| REALITY 入站 | VLESS、443/tcp、RAW/TCP、Vision，订阅给节点 IPv4；`serverNames` 仅 target；REALITY 的 `target` 为 `127.0.0.1:20443` | 已认证客户端的代理请求不受“只能到 target”限制，仍按 REALITY 入站的业务路由处理 |
| 回环转发入站 | 协议 `tunnel`，仅监听 `127.0.0.1:20443`；原目的地址为占位 IP `127.0.0.1`、端口 443；嗅探启用，`destOverride` 仅 `tls`，`routeOnly=false`、`metadataOnly=false` | 只有解析到 SNI 才以该域名替换目的地址；不得把原目的地址写成 target 域名或加入 HTTP 嗅探 |
| 模板规则 1、2 | 第一条仅匹配转发 tag 和 `full:<target>` → `direct`；紧邻第二条兜住该 tag 的所有其他连接 → `blocked` | 错误 SNI、无 SNI、非 TLS 的连接不穿过转发入站的外连边界；HTTP `Host: target` 不能使明文请求放行 |
| 模板规则 3、4 | 仅 REALITY tag 的 `geosite:cn`、`geoip:cn` → `blocked`，随后保留模板原规则；`domainStrategy=AsIs` | 域名规则不等于解析后的 IP 分类；`geoip:cn` 对域名不补做解析，不修改这一已批准取舍 |
| direct 出站 | 保留固定模板的私有地址 `finalRules` | 占位 IP 的兜底防护仍在；它不能替代规则 2 对其他域名的拦截 |

配置模板、数据库入站和 **3X-UI 最终生成并应用的 Xray 配置**分别核对：实际 tag、规则次序、监听、sniffing、REALITY target 和出站均一致。生产 `check` 的来源不扩展为保存一份含私钥的生成配置；读取生成配置及完整比对由隔离测试驱动执行，秘密不进入归档。

验收的三处证据沿用验证计划第 4.4 节：转发到替身方向的抓包连接摘要、Xray 访问日志、替身的连接记录；同时记录客户端结果。负面用例不能只凭 TLS 失败或客户端没有内容通过。正面用例证明流量确实到达 target，包含大 ClientHello、跨 TLS 记录及慢速分段；VT-27 每种 20 次，产品偶发失败不以重跑覆盖。失败时沿用方案 SR-3 的决定流程，由用户接受代价或评审替代方案，不自动引入 nginx。

该边界只根据 ClientHello 的 SNI 控制去向，不解密 TLS，不检查内层 Host、HTTP/2 `:authority` 或 URL。target 若按内层权威交叉路由，仍可能返回别的站点；`target-check` 和 VT-28 能发现样本中的交叉路由，干净结果不能证明隔离，也不能代替管理员按需求第 11.5 节核实站点归属与共享 CDN 情况。只放行域名不等于固定目标 IP，target 的 DNS 地址可变化；本文不增加 DNS 固定、地址轮换或抗封锁收益承诺。

## 18. Tunnel 服务与生效状态（M3）

### 18.1 单元、凭据和监听

本仓库单元名为 `vps-proxy-setup-cloudflared.service`，安装位置见第 2.8 节。以下是待实现的单元字段契约，不是本次已安装的配置：

| 字段 | 取值与理由 |
|---|---|
| `Type` | `simple`；进程启动与 Tunnel 就绪分开判定，服务 active 不等于 `/ready` 通过 |
| `Wants`、`After` | `network-online.target`；不设置与 x-ui 的 `BindsTo`、`PartOf` 或共同重启关系，Tunnel 停止不影响 REALITY |
| `DynamicUser` | `yes`；不固定 UID，不以 root 运行，也不使源 token 文件对动态 UID 可读 |
| `LoadCredential` | `tunnel-token:/etc/vps-proxy-setup/tunnel-token`；由 systemd 以服务身份可读的只读凭据副本提供，源文件仍为 root 0600 |
| `ExecStart` | `/usr/local/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file ${CREDENTIALS_DIRECTORY}/tunnel-token`；只有凭据路径进入 argv，不传 token 值、不传 Tunnel ID |
| `Restart`、`RestartSec` | `on-failure`、`5s`；重启策略不改变 deploy 的就绪期限或退出码 |
| `WantedBy` | `multi-user.target`；首次部署启用，迁移准备不启用 |

不提供 `EnvironmentFile`，不通过环境传入 `TUNNEL_TOKEN`、配置文件路径或 metrics 覆盖。固定 cloudflared 的 `TUNNEL_TOKEN` 优先于 `--token-file`，因此实际环境不能含该值；检查只判定是否存在，不输出内容。`CREDENTIALS_DIRECTORY` 是 systemd 提供的路径，不是令牌。也不运行 `cloudflared service install`，不创建更新 timer 或账户证书。DynamicUser 的实际权限和服务行为在 M3 验证，不因 systemd 文档支持就记为运行通过。

### 18.2 三层检查与就绪

| 层次 | 数据来源 | 判据及不能替代的层次 |
|---|---|---|
| 磁盘配置 | 单元文件摘要、drop-in 路径/内容、程序摘要、token 文件属性 | 文件符合只是下一次加载的输入；本仓库单元不允许未识别的有效覆盖 |
| systemd 已加载配置 | `systemctl show` 的 `FragmentPath`、`DropInPaths`、`NeedDaemonReload`、`ExecStart`、`DynamicUser`、`LoadCredential`、`Environment`、`EnvironmentFiles` | 必须为本仓库单元和预期字段，`NeedDaemonReload=no`。只执行 `daemon-reload` 不能证明当前进程换用了新命令 |
| 当前进程与运行接口 | `MainPID`、对应 `/proc/<pid>/exe`、`cmdline`、UID、必要环境变量的存在性，`ss`，`/ready`、`/config` | PID 非零且读取前后仍属于该单元，实际程序、完整参数、非零 UID 和凭据路径符合；UID 不跨运行固定。metrics 只监听回环且归属该进程。竞争、读不到或状态变化时不能给 PASS，不打印原始 argv/env |

`cfd.unit` 报告前两层的偏差；`cfd.service` 报告停止、禁用、PID/身份/参数偏差；监听、就绪、路由仍分别报告。M3 注入覆盖“磁盘改了但未 reload”“reload 后没有 restart、旧 PID 仍运行”“实际参数或身份不符”，不能只测试当前磁盘文本。动态凭据的路径要与该 PID 的 systemd 凭据目录对应；不读取 token 内容来做健康检查。Token 轮换由服务重启加载，静态文件正确不能证明活跃连接已使用新 token。

首次启动后，`deploy` 最多等 120 秒，每 2 秒查询一次 `/ready`，单次上限 5 秒且服从剩余期限；这是设计上限，不是服务保证。就绪要求 HTTP 200 且 `readyConnections` 大于 0，之后读取 `/config` 按第 4.2 节核对有效路由。超时返回 1、原因归为 Tunnel 未就绪；服务仍按既定策略运行，配置保留供检查。测试 token 不能连到真实 Tunnel，VT-53 预期 `cfd.ready`、`cfd.routes` 为 FAIL，其他项仍按实际判定；不模拟接口来声称真实就绪。

### 18.3 远程路由、边缘证书与待定事项

唯一公开路由是 `sub_host` → `http://127.0.0.1:2096`，没有 path 限制和 Host 重写，后接拒绝兜底。`/config` 是 cloudflared 返回的有效配置；固定源码会显式输出空 `hostname`、空 `httpHostHeader` 和空 path，所以检查按类型和值判断，不要求这些字段缺席。具体判据以第 4.2 节 `cfd.routes` 为准，真实控制台兜底及私有网络路由的可见范围仍为 DO-4。

Cloudflare 的 Universal SSL 在完整接入 Zone 时覆盖域名本身和一级子域名，不由“输入有三个标签”单独证明；部署输入也不知道 Zone 的实际边界。管理员须在 VPS 外核实该订阅主机名的证书覆盖和生效证书，M3 从外部核验证书链及主机名（[Universal SSL 限制](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/#full-setup)，2026-10-30 核对）。Cloudflare 免费版 Bot Fight Mode 不能用 WAF Skip 对单个主机名绕过；不能把“配置 Skip”写成它的解决步骤（[Bot Fight Mode 限制](https://developers.cloudflare.com/bots/get-started/bot-fight-mode/#limitations)，同日核对）。实际启用的挑战功能、对其他主机名的影响和所需调整由管理员在账户中确认，归 DO-6；本设计不替用户选择 Zone 范围的开关，也不要求向 VPS 提供 Cloudflare API Token。

VO-7 未确定前不操作 Cloudflare 路由、DNS、证书或测试 VPS；VO-5 的三个客户端平台仍待用户决定。CI 的假 token、模拟 `/config` 解析以及本机订阅测试分别只证明相应层次，不能关闭这两个待决事项。

## 19. 测试接口与注入接缝

沿用第 7 节模块和第 9 节运行器，不新增生产故障参数、环境变量后门、通用插件系统或持久化部署状态机。接缝只隔离确实需要观察/替换的进程、文件、API 和服务边界；正常入口固定路径和版本，测试运行于自己的 VM 覆盖层。

| 边界 | 最小接口契约与注入方式 | 用例及阶段 |
|---|---|---|
| 安装器调用与安装后核对 | 安装动作返回退出状态和受保护日志位置；文件核对是独立的下一步。测试驱动加载模块，真实运行安装动作，返回后替换一个已装文件，再调用原核对动作；不把跳过校验的开关放进 `deploy`。另有不注入的完整入口测试，防止测试专用路径替代产品流程 | VT-12、VT-13，M2；DO-10 的接缝在此定义，运行实现仍待核实 |
| 第 4 步与第 5 步之间 | 相邻阶段函数可由隔离客体驱动顺序调用；驱动在边界用真实 API 增加入站/用户或改变订阅，之后运行真实只读 fresh 检查，前后逐表摘要比较 | VT-15，M2；驱动的修改与被测拒绝路径的修改分别记录 |
| API 传输与业务操作 | 部署模块的请求函数接受方法、固定相对路径、请求体的私有输入和响应的私有输出，返回传输状态、HTTP 状态、解析状态；业务函数决定语义，不读原始 stderr 判成败。测试中替换函数使第二个新增失败、请求提交后丢失响应、token 删除响应丢失；生产不接受外部 API base URL | VT-16～VT-18、VT-17 撤销核对，M2；实际 API 正常流程另用固定版本验证 |
| 设置读取与判定 | 第 4.1 节一次只读快照转为不含秘密的固定字段；纯判定逻辑只接受这些值。测试可传入畸形/缺字段快照，但不能代替真实 SQLite 的 VT-72、VT-75 | VT-71～VT-76，M1 起；服务状态变化和侧文件竞态纳入 DO-1 |
| target 与 HTTP 权威 | 用第 9.2 节替身切换按 SNI/Host 路由、证书信任及分段行为，记录传入 SNI 与 Host/authority；不改变产品的连接目的地址限制 | VT-80、VT-81，M1；VT-23～VT-29，M2 |
| Xray 路由测试 | POST `/panel/api/xray/routeTest`，表单字段 `domain` 或 `ip`（二者择一）、`port=443`、`network=tcp`、`inboundTag=<实际 tag>`；不依赖协议或用户规则时省略 `protocol`、`email`。在撤销安装 admin token 前执行，之后仍须按 VT-17 撤销，不为生产 `check` 保留它。回国屏蔽须 `success=true`、`obj.matched=true`、`obj.outboundTag=blocked`；转发 target 应命中 `direct`。对照域名允许未命中规则（`matched=false`、空 tag），此时须另核对最终生成配置的首个默认出站确为 `direct`。接口只测试核心选路，不发送业务流量 | VT-30 加收尾后 VT-31 的真实客户端请求，M2；[响应语义源码](https://github.com/MHSanaei/3x-ui/blob/c621ba9014a6aa21fd7c9ecf45655e44e24ebf13/internal/xray/api.go#L369-L378)，运行结果待 DO-11 |
| 双栈监听与出站（DO-14） | 监听解析接受按地址族归一化的 socket 地址及可用的 `v6only`，按 `listen.reality` 判断；两种通配监听各自存在时无需 `v6only`，仅在依靠 IPv6 socket 证明 IPv4 接收能力时要求该值为 0。真实 VM 验证独立监听和单个双栈 socket 的上述预期。出站测试用客体的 `/etc/hosts`、双栈替身、外连隔离、真实客户端和外连观测；分别控制解析结果与 IPv6 路由，观察实际连接，不把 routeTest 的 tag 当连通证明。生产侧只有部署输入 `ipv6_ai_egress`，不新增测试开关；IPv6 地址、路由和替身的拒绝/丢弃由测试驱动在客体和替身命名空间中改变 | 监听沿用 VT-71，M2；出站见验证计划 VT-32～VT-34，M2；M5 的外部扫描不变 |
| 核心拒绝连接回收（DO-13） | 使用已认证 REALITY + Vision 客户端，使请求进入 Freedom 的私有地址 block 分支并保持连接；测试驱动观察客户端及服务端连接结束，不输出秘密。另跑正常转发和重启对照；不修改生产配置来绕过私有地址屏蔽 | 第 6.1 节，评估 3X-UI 修复版时执行（需求 D30）；专用用例随该评估纳入验证计划，运行尚未执行 |
| systemd、进程与 `/config` | 解析函数接受脱敏结构化数据，隔离单测覆盖空值/缺字段；真实 VM 通过单元/drop-in、reload/restart 的不同顺序注入。真实 Tunnel 路由偏差只在 VO-7 授权的 VPS 进行 | VT-51～VT-53、VT-71，M3；模拟响应不能计为 `/ready` 或 Cloudflare 验收 |
| 备份与恢复 | 管理员文档步骤是测试入口，驱动用隔离副本模拟坏摘要、完整性失败、残留侧文件和重装后服务自动启动；不在产品加入 restore 子命令 | VT-85～VT-90，M4；观察点见第 16.2、16.3 节 |

测试程序可以在客体内读取测试秘密生成泄露清单，但只归档脱敏判据、摘要、属主权限和连接摘要；主库、备份、请求响应、token、handoff 不归档。证据收集失败即作业失败，不能拿测试命令退出 0 抵消。VT-71 仍只把同阶段基线中 PASS 的项计入注入覆盖；每项最早里程碑见第 4.2、9.5 节，实际多项连带变化必须记录。所有本节接缝都是设计，仓库当前没有对应函数、夹具或测试执行结果。
