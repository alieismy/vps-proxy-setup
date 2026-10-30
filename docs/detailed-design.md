# VPS Proxy Setup 详细设计

| 项目 | 内容 |
|---|---|
| 状态 | v0.1 草案：覆盖里程碑 M1，即整体的命令契约、部署输入、预检、`check` 的全部检查项、`target-check`、安装脚本、模块划分、实现约束和 M1 的测试框架。`deploy` 预检之后的步骤、规则文本、交给管理员的文件和 cloudflared 的服务单元，在 M2、M3 的版本中增补。按 CodeRabbit 对草案的意见，写明 `sub.paths` 不能证明订阅路径是随机生成的（第 4.2、11 节）。待用户评审 |
| 日期 | 2026-10-30 |
| 上游 | [需求规格说明 v1.3](requirements.md)（已批准）、[方案设计 v1.0](solution-design.md)（已批准）、[验证计划 v1.0](verification-plan.md)（已批准）；[vps-hardening 详细设计](https://github.com/alieismy/vps-hardening/blob/master/docs/detailed-design.md)的形态和惯例 |
| 下游 | 实现和测试（从 M1 开始） |
| 深度 | 命令契约、检查项目录、文件格式、模块划分、实现约束和测试框架；不重复上游已有的决策理由，不含代码和操作手册 |

**证据状态。** 本文只是设计，仓库中还没有实现，也没有运行证据。标"已核实"的，是 2026-10-30 对照上游源码或软件包数据核实的结果，本文新核实的见第 14 节；标"推断"的，要在指定的里程碑中证实，列在第 12 节。

## 1. 范围

v0.1 覆盖 M1（方案设计第 10 节，验证计划第 7 节）：

- 整体的命令契约（第 2 节）：子命令、退出码、输出格式、部署输入的格式和校验规则、本工具在 VPS 上的文件；
- `deploy`：只到预检为止（第 2.5、3 节）；
- `check`：第 4 节的全部检查项。依赖部署结果和 cloudflared 的检查项也在 M1 中实现，但只能在 M2、M3 中对部署之后的主机验证（验证计划第 7 节）；那时发现要修改的，随 M2、M3 的版本修改本文；
- `target-check`（第 2.7、5 节）；
- 安装脚本（第 2.9 节）。发布和从公开地址的回验在 M4（VT-98）；
- 模块划分、实现约束和 M1 的测试框架（第 7～9 节）。

不在 v0.1 中：

- `deploy` 的第 2～9 步（方案设计第 7.3 节，M2、M3），`--migrate` 在预检之后的步骤（M4）；
- 规则文本（M2）、交给管理员的文件的内容（M2）、cloudflared 服务单元的内容（M3）；
- 上游交给详细设计、属于 M2 的三项：规则集的两处取舍（需求第 11.2 节）、VT-12 的注入方法、VT-30 所用的路由测试接口（第 12 节 DO-9～DO-11）；
- 方案设计第 7.5 节交给详细设计的两项 Cloudflare 设置：边缘证书的覆盖范围，对非浏览器客户端的挑战设置。它们属于 M3，在 M3 的版本中按 Cloudflare 的现行文档核实（第 12 节 DO-6）。

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
| 0 | 完成，检查没有不符合项（可以有警告和跳过） |
| 1 | 至少一项不符合，或者命令被拒绝 |
| 2 | 用法或输入错误 |
| 3 | 内部错误：命令意外失败，由 ERR 陷阱统一转换（第 8 节），避免被误读为"不符合" |

各命令的 0、1、2：

| 命令 | 0 | 1 | 2 |
|---|---|---|---|
| `deploy` | M2 起：部署完成，随后的 `check` 全部通过 | 不是 root；平台不符；锁被占用；预检有不符合项；M1 中预检全部通过之后（后续步骤还没有实现，主机未改动）；M2 起还有：管理员没有输入 `yes`，某一步失败 | 未知参数；标准输入不是终端；输入文件不合规；输入值不合法（第 2.4 节） |
| `check` | 没有不符合项 | 不是 root；至少一项不符合，包括数据库读不了（`xui.db`，VT-75） | 带了任何参数 |
| `target-check` | 没有不符合项 | 不是 root；至少一项不符合，包括解析不到地址 | 缺少主机名；主机名或 `--probe-host` 不合法；未知参数 |
| 安装脚本 | 安装完成，或无需变更 | 拒绝或失败 | 未知参数、缺少取值、`--source-dir` 不是绝对路径 |

数据库读不了时退出码取 1（VT-75 交给本文确定）：这时检查范围内的配置无法确认，按不符合处理；原因写在 `xui.db` 一行中，检查不初始化或修复数据库。

### 2.3 输出格式

与 vps-hardening 详细设计第 2.3 节相同：每个检查项一行，`[级别] 编号 说明`，编号左对齐占 30 列；级别为 `PASS`、`FAIL`、`WARN`、`SKIP`、`INFO`，只有 `FAIL` 使退出码为 1，`INFO` 不计数；最后一行汇总通过、不符合、警告和跳过的数量。用法错误和内部错误以 `[x]` 开头写到标准错误。

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
| `tunnel_token` | 必须 | 必须 | 标准 Base64；解码后是 JSON 对象：`a` 是非空字符串，`t` 是 UUID 格式的字符串，`s` 是标准 Base64 字符串、解码后至少 32 字节，`e` 可有可无（cloudflared 2026.10.5 的令牌格式，第 14 节） |

- 所有输入在主机检查之前校验。不合法时，每个不合法的键输出一行 `[x] 输入 <键>：<原因>`，不回显它的值，以退出码 2 结束，不做主机检查。
- `--migrate` 的输入文件中有 `remark` 或 `users` 时同样以退出码 2 拒绝：迁移不写设置（FR-09），这两项没有用处，出现说明拿错了文件。
- 输入文件何时删除（FR-12"导入之后删除"）属于 M2 的契约。M1 中 `deploy` 不删除它。

### 2.5 `deploy`

M1 的流程：

1. 标准输入不是终端时，以退出码 2 结束（方案设计第 7.2 节）；
2. 解析参数，不合法时退出码 2；
3. 门槛检查项 `root`、`platform`（第 3 节），不满足时退出码 1；
4. 取得锁（第 2.1 节）；
5. 读取并校验输入（第 2.4 节）；
6. 预检的其余检查项（第 3 节），有不符合项时退出码 1；
7. 全部通过时，以 `[x]` 输出"预检通过；之后的步骤在 M2 实现，主机未改动"，退出码 1。

M2 在第 6 步之后加上变更计划和确认：管理员输入 `yes` 才继续，否则以退出码 1 结束、主机不变。这样 VT-01 在 M1 和 M2 中都按"预检通过、主机不变"判定。之后的步骤按方案设计第 7.3 节，契约在 v0.2 中增补。

### 2.6 `check`

不带参数，不要求交互终端，以 root 执行。检查项和数据来源见第 4 节。它不取锁，不写任何文件：数据库的快照、单元属性和接口的响应只保存在变量中。实现中确实需要临时文件时，只写在 `mktemp -d` 创建的私有目录中，退出时删除。

### 2.7 `target-check`

- **参数。** `<主机名>` 按第 2.4 节 `target` 的规则校验。`--probe-host <主机名>` 是异权威探测请求的 Host，规则相同，不能等于目标；默认是 `vps-proxy-setup-probe.invalid`（RFC 2606 保留的、不会被解析的名称）。默认值只能发现"按 Host 返回别的内容"的服务器；要检查同一网络或同一 CDN 上的某个具体站点，由管理员用这个参数给出（第 5 节）。
- **网络范围。** 只解析目标主机名，只连接它解析到的地址的 443/tcp。`--probe-host` 只作为 HTTP 的 Host 和 HTTP/2 的 `:authority` 发送，不解析、不连接（需求第 11.5 节第 4 条，VT-80）。
- **结果文件。** 写入 `/etc/vps-proxy-setup/target-check/<主机名>`（目录不存在时以 0700 创建，文件 0600），先写到同一目录下的临时文件，再改名替换，所以同一个目标只保留最新的一次。内容为键值行 `version=`（工具版本）、`time=`（UTC，ISO 8601）、`target=`、`probe_host=`，然后是与终端输出相同的检查项行和汇总行。预检的 `target.checked` 读取这个文件（第 3 节）。

### 2.8 本工具在 VPS 上的文件和固定的端口

`/etc/vps-proxy-setup/` 属于 root，权限 0700（方案设计第 7.2 节），其中的文件都是 0600：

| 文件 | 写入者 | 读取者 | 内容与生命周期 |
|---|---|---|---|
| `target-check/<主机名>` | `target-check` | 预检的 `target.checked`；M2 起写入部署记录 | 第 2.7 节；新的一次覆盖旧的 |
| `deploy.conf` | `deploy`（M2 起） | `check` 的 `record.consistent` | 部署记录，键值行，按数据解析：`tool_version`、`xui_version`、`cloudflared_version`、`mode`（`deploy` 或 `migrate`）、`deployed_at`、`sub_host`、`node_ip`、`target`、`target_check_time`。部署之后不由本工具修改 |
| `tunnel-token` | `deploy` 第 8 步（M3） | systemd 经 `LoadCredential` 交给 cloudflared | 只有令牌一行；迁移或怀疑泄露时轮换（方案设计第 7.9 节） |
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
| `target.checked` | target 的核实 | 没有这个 target 的 `target-check` 结果（第 2.7 节），或者结果中有 `FAIL` 行。结果早于 7 天时为警告：小站点容易改版或迁走（需求第 11.5 节） | VT-01 |

`target.checked` 来自 FR-02 的验收"部署记录中有 target 在部署所用的 VPS 上的核实结果"：没有核实过的 target 不进入部署。`--migrate` 同样要求，因为核实要在部署所用的 VPS 上进行。

## 4. check 检查项

### 4.1 数据来源与读取方式

**数据库。** 路径固定为 `/etc/x-ui/x-ui.db`。`xui.env` 和 `xui.unit` 确认 3X-UI 没有经环境变量改用别的位置：x-ui 每次启动都读取三个环境文件中第一个存在的那个，其中的 `XUI_DB_FOLDER`、`XUI_BIN_FOLDER` 等会改变数据库和程序的位置（已核实，第 14 节）。

打开方式按 SQLite 对只读打开 WAL 数据库的规定选择：`-wal` 和 `-shm` 都存在时可以只读打开；都不存在时，只读连接要在目录中创建它们，除非以 `immutable` 打开（已核实，第 14 节）。检查不能在 `/etc/x-ui` 中新建文件（VT-72），所以：

| `-wal` 和 `-shm` | `-journal` | 打开方式 |
|---|---|---|
| 都存在（x-ui 在运行） | 不存在 | `file:/etc/x-ui/x-ui.db?mode=ro` |
| 都不存在（x-ui 已停止） | 不存在 | `file:/etc/x-ui/x-ui.db?mode=ro&immutable=1` |
| 只有一个 | — | 不读取，`xui.db` 不符合 |
| — | 存在 | 不读取，`xui.db` 不符合：读取一个热日志的数据库要先回滚，那是写入 |

- 命令为 `sqlite3 -readonly -safe -batch -bail -init /dev/null <URI> <SQL>`，设 5 秒的忙等待，整体 30 秒超时。`-safe` 禁止写文件的点命令和函数，作为额外的保险。
- 一次调用、一条语句、一个读事务，输出一个 JSON 文档作为快照，所有库项都在这份快照上判定，不会读到两个时刻的数据。
- 快照中没有秘密：语句只选需要的列，不用 `SELECT *`；`stream_settings` 去掉 REALITY 私钥之后输出，另加一个"私钥非空"的布尔值；shortId 只输出个数、长度和是否为十六进制；需要用到订阅路径的判定（`sub.uri`、`sub.paths`）在 SQL 中算成布尔值和长度，路径本身不离开 `sqlite3` 进程；使用者只选代号、启用状态、flow 和 `limit_ip`，不选 UUID 和订阅 ID；模板中的出站只取标签和协议。
- 设置表中没有某个键时，按 v3.11.0 的默认值判定（3X-UI 自己就是这样读取的，已核实）。被检查的键在设置表中有多行时，`xui.db` 判为不符合，不去猜 3X-UI 用哪一行。

**其他来源。** 文件的属性和 SHA-256；`systemctl show` 给出的单元的生效属性（合并了 drop-in 之后的值）；`ss -Hltn`；`fail2ban-client status`；`/usr/local/x-ui/x-ui -v`；`curl` 访问 `127.0.0.1:20241` 的 `/ready` 和 `/config`；`vps-hardening verify` 的退出码。

### 4.2 检查项

"库"表示依赖数据库快照：`xui.version` 或 `xui.db` 不符合时，这些项报告为 `SKIP`（FR-07，VT-73）。REALITY 入站或转发入站不存在时，依赖它的项同样报告为 `SKIP`，不符合由 `inbounds.set` 报告一次。"阶段"指这一项的注入用例最早在哪个里程碑（验证计划 VT-71，第 9.5 节）。

**门槛与 3X-UI 程序**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `root`、`platform`、`deps` | 同预检（第 3 节），不满足时立即结束。`deps` 只列 `check` 用到的命令：`sqlite3`、`jq`、`curl`、`ss`、`systemctl`、`sha256sum`、`od`、`timeout`；没有 `fail2ban-client` 时 `xui.ipl` 只按文件判定 | FR-07 | M1 |
| `xui.version` | `/usr/local/x-ui/x-ui -v`（10 秒超时）不存在、失败，或者输出不是 `3.11.0`。`-v` 只读取环境文件、打印版本，不打开数据库（已核实）；这个程序本来就以 root 作为 x-ui 服务运行，检查执行它不扩大它的权限 | FR-01、FR-07 | M1 |
| `xui.files` | `/usr/local/x-ui/x-ui`、`/usr/local/x-ui/bin/xray-linux-amd64`、`/usr/bin/x-ui`、`/etc/systemd/system/x-ui.service` 中有与固定的摘要（第 6 节）不符的或不存在的。说明中列出文件名。Geo 数据文件不核对：面板可以更新它们 | FR-01、NFR-05 | M1 |
| `xui.unit` | `x-ui.service` 的生效属性不是：`ExecStart` 为 `/usr/local/x-ui/x-ui`、没有参数；`WorkingDirectory` 为 `/usr/local/x-ui`；`Environment` 只有 `XRAY_VMESS_AEAD_FORCED=false`；`EnvironmentFiles` 只有可缺省的 `/etc/default/x-ui`；`User` 为空或 `root`。drop-in 改动这些属性时同样发现 | FR-01 | M1 |
| `xui.env` | `/etc/default/x-ui`、`/etc/conf.d/x-ui`、`/etc/sysconfig/x-ui` 中有一个存在。部署不创建它们，SQLite 安装时 `install.sh` 也不创建（已核实） | FR-07 | M1 |
| `xui.service` | `x-ui.service` 不是 `enabled`，或者不是 `active` | FR-07 | M1 |
| `xui.ipl` | 存在 `/etc/fail2ban/filter.d/3x-ipl.conf`、`action.d/3x-ipl.conf` 或 `jail.d/3x-ipl.conf`；`fail2ban-client status` 的 jail 列表中有 `3x-ipl`。fail2ban 没有运行时只按文件判定，并在说明中注明 | FR-01、FR-07 | M1 |
| `xui.db` | 第 4.1 节的读取失败：文件不存在；`-wal`、`-shm` 只有一个；有 `-journal`；`sqlite3` 报错（例如表结构与 v3.11.0 不同）；被检查的设置键有多行。说明中给出原因 | FR-07 | M1（VT-75） |

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
| `listen.reality` | 443/tcp 没有在通配地址（`0.0.0.0`、`[::]` 或 `*`）上监听 | FR-02 | M2 |
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
| `record.consistent` | 没有 `deploy.conf` 或解析失败；记录的 `sub_host` 与 `subDomain`、`target` 与 `serverNames` 的那一项、`node_ip` 与 `share_addr` 有不一致的（库）。面板中有意修改了这些值时，部署记录随之按文档更新（M4 的文档） | FR-07 | M2 |

**cloudflared 与 Tunnel**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `cfd.files` | `/usr/local/bin/cloudflared` 不存在、与固定的摘要不符（第 6 节），或者不属于 root、权限不是 0755 | FR-05、NFR-05 | M3 |
| `cfd.unit` | `/etc/systemd/system/vps-proxy-setup-cloudflared.service` 与随工具发布的那一份不是逐字节相同，或者它有 drop-in（`DropInPaths` 不为空） | FR-05 | M3 |
| `cfd.service` | 这个单元不是 `enabled`，或者不是 `active` | FR-05 | M3 |
| `cfd.autoupdate` | 单元的生效 `ExecStart` 中没有 `--no-autoupdate`；`cloudflared-update.timer` 或 `cloudflared-update.service` 已加载并启用。单元不存在时同样不符合（FR-05 要求"服务带 `--no-autoupdate` 运行"） | FR-05 | M3 |
| `cfd.token` | `/etc/vps-proxy-setup/tunnel-token` 不是普通文件、不属于 root、权限不是 0600，或者为空。检查不读取它的内容 | FR-05、NFR-01 | M3 |
| `cfd.metrics` | 20241 没有监听，或者在回环地址之外也有监听 | FR-05、FR-06 | M3 |
| `cfd.ready` | `GET http://127.0.0.1:20241/ready`（5 秒超时）不是 200，或者 `readyConnections` 不大于 0 | FR-05 | M3（测试 VPS） |
| `cfd.routes` | `GET http://127.0.0.1:20241/config`（5 秒超时）失败或不是 JSON；`config.ingress` 不正好是两条：第一条的主机名等于 `subDomain`（数据库读不了时用部署记录的 `sub_host`），`service` 为 `http://127.0.0.1:2096`，没有 `path`，`originRequest` 中没有 `httpHostHeader`；第二条没有主机名和 `path`，`service` 为 `http_status:` 加一个 4xx 的状态码。说明中只输出主机名和服务地址（方案设计第 7.6 节）。兜底规则的具体写法是推断，私有网络路由能否从这里看到也没有核实（第 12 节 DO-4） | FR-05、FR-07 | M3（测试 VPS） |

**加固**

| 编号 | 不符合的条件 | 需求 | 阶段 |
|---|---|---|---|
| `hardening.verify` | `vps-hardening verify`（120 秒超时）的退出码不为 0。说明中给出退出码 | NFR-04 | M1 |

### 4.3 与验证计划的对应

- **VT-70 的 M2 基线。** 部署第 1～7 步之后、还没有 cloudflared 时，`cfd.*` 各项都不符合（`cfd.autoupdate` 因为单元不存在而不符合），其余项通过；`secrets.handoff` 在管理员删除那个文件之前为警告，不影响判定。这与验证计划 VT-70 的"cloudflared 和 Tunnel 的各项 FAIL，其余全部 PASS"一致。
- **VT-70、VT-53 的 M3 基线。** 测试令牌下只有 `cfd.ready`、`cfd.routes` 不符合。
- **一种偏差对应几项。** 有的偏差同时由数据库和监听端口两处发现，例如订阅改为监听 `0.0.0.0` 并重启之后，`sub.listen` 和 `listen.sub` 都不符合。VT-71 中"对应的项"指本节为这种偏差列出的全部项，第 9.5 节逐一列出 M1 的注入和预期。

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
- **秘密不离开来源。** 数据库中的秘密留在 `sqlite3` 进程中（第 4.1 节）。令牌只在 `inputs.sh` 的变量中，不写入临时文件，不出现在命令行参数中；校验时用内建的 `printf` 经管道交给 `base64` 和 `jq`。不用 here-string：Bash 在内容超过管道缓冲区时把 here-string 写成临时文件（Bash 5.1 起的行为）。M2、M3 中向 3X-UI 的 API 发请求时，token 经文件或标准输入交给 `curl`（方案设计第 7.9 节）。
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

- IPv4 字面量只允许 `0.0.0.0`、`127.0.0.0/8`、`10.0.0.0/8`（QEMU 用户网络）和三个文档地址段；IPv6 字面量只允许 `::`、`::1` 和 `2001:db8::/32`；
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

VT-72 的实现：在 `/etc/x-ui` 中建 `.x-ui-backup-vt72` 目录；x-ui 运行时和停止后各执行一次 `check`，判定那个目录仍在、文件列表（含 `-wal`、`-shm` 是否存在）、属主和权限不变、表结构不变、各表的摘要不变（运行时按第 9.4 节的对照运行确定排除项）；停止时还判定数据库文件的摘要不变、`-wal` 和 `-shm` 仍不存在。

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

- 通过：`root`、`platform`、`xui.*`（`xui.files` 要在 VO-1 取得摘要之后）、`panel.listen`、`clients.limit-ip`、`sub.enable`、`sub.cert`、`sub.paths`、`sub.json`、`sub.info-node`、`sub.updates`、`listen.api`、`listen.metrics`、`secrets.handoff`、`absent.*`、`hardening.verify`；
- 不符合：`inbounds.set`、`routing.outbounds`（模板仍是默认值）、`sub.listen`、`sub.domain`、`sub.uri`、`sub.clash`、`sub.remark`、`listen.reality`、`listen.forwarder`、`listen.sub`、`secrets.install-result`、`record.consistent`、`cfd.*`；
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
| 放置 `/root/.acme.sh/acme.sh` | `absent.acme` |
| 放置 `/root/.cloudflared/cert.pem` | `absent.cf-credentials` |
| 加一条 UFW 规则使 `vps-hardening verify` 不通过 | `hardening.verify` |

经面板接口的注入用 `install-result.env` 中的 API token（M1 中还没有交给管理员的文件）。`sub.enable`、`sub.cert`、`sub.paths`、`clients.limit-ip`、`listen.api`、`listen.metrics` 在 M1 基线中通过，但注入要么会使订阅服务或 Xray 无法正常运行、连带改变其他项，要么需要使用者，所以和其余各项一起在 M2 中注入，注入方法在 v0.2 中确定。

## 10. 运行证据

还没有。M1 实现之后增补，包括第 9.4 节的排除清单、第 9.5 节的实际基线、VO-1 取得的摘要和第 12 节各项的核实结果。

## 11. 已知限制

- **x-ui 停止时的读取。** 这时以 `immutable` 打开数据库，SQLite 不检查锁。如果 x-ui 恰好在检查期间启动并写入，快照可能不一致，检查结果可能有误，但不会改动数据库；重新执行一次即可。
- **结论的范围。** `check` 全部通过只说明检查范围内的配置符合要求，不说明从中国大陆可达，也不说明伪装有效（方案设计第 7.6 节）。
- **Tunnel 的路由。** `cfd.routes` 只能看到 `/config` 中有的内容。私有网络路由等不在 ingress 中的配置能否从这里看到，在 M3 中核实（DO-4）；看不到时这里记录为限制。
- **订阅路径的随机性。** `sub.paths` 只排除默认值和过短的路径，不能证明路径是初始化时随机生成的。部署不改订阅路径（`deploy` 只用 3X-UI 初始化时生成的值），之后在面板中改成可猜的值，检查发现不了。
- **异权威探测。** 结果干净不证明隔离；默认的探测主机名只能发现"按 Host 返回别的内容"的服务器（第 2.7、5 节）。
- **隐私扫描。** 服务商名称和生产使用的 target 只能在本地用私有清单扫描（第 9.1 节）。
- **执行所装的程序。** `xui.version` 执行 `/usr/local/x-ui/x-ui -v`。即使这个文件已被替换，它本来就以 root 作为服务运行，检查执行它不扩大它的权限；摘要不符由 `xui.files` 报告。

## 12. 待决事项

| 编号 | 事项 | 处理 | 负责与时间 | 是否阻塞 v0.1 |
|---|---|---|---|---|
| DO-1 | Debian 13 的 `sqlite3`（3.46.1）对 `-safe`、URI 文件名、`immutable=1` 和忙等待的实际行为；`mode=ro` 的读取除 `-shm` 的读标记外不改动文件 | VT-72、VT-75 | 实现，M1 | 否 |
| DO-2 | systemd 257 下 `systemctl show` 的 `ExecStart`、`WorkingDirectory`（是否去掉末尾的斜杠）、`Environment`、`EnvironmentFiles` 的输出格式；`fail2ban-client status` 中 jail 列表的格式 | M1 基线 | 实现，M1 | 否 |
| DO-3 | VO-1：安装后的程序文件和服务单元的摘要；`x-ui.service` 来自发布包还是 tag 路径 | 从固定的发布包和固定提交取得，写入第 6 节和 `pins.sh` | 测试实现，M1 | 否 |
| DO-4 | `/config` 中兜底规则的写法（推断为 `http_status:404`）；私有网络路由能否从 `/config` 看到 | 测试 VPS 上核实，按结果修改 `cfd.routes` | 实现，M3（需要授权，VO-7） | 否 |
| DO-5 | 在面板中重新保存路由之后，规则中是否出现 `routing.rules` 允许之外的字段 | 在虚拟机中经面板接口重新保存一次，比较前后的模板 | 实现，M2 | 否 |
| DO-6 | 方案设计第 7.5 节交给详细设计的两项：Cloudflare 边缘证书的覆盖范围；对非浏览器客户端的挑战，具体是 Bot Fight Mode 还是用 WAF 跳过规则处理 | 按 Cloudflare 免费计划的现行文档核实，写入 M3 的版本和使用说明 | 设计，M3 之前 | 否 |
| DO-7 | vps-hardening 已发布 `v0.1.2`（修复版），需求 A-1 和 D9 固定的是 `v0.1.1` | 改用 `v0.1.2` 要改需求 A-1、验证计划第 3.2 节和 `hardening.version` 的列表，由用户决定；不改时 `v0.1.2` 的主机预检给出警告、不阻止 | 用户 | 否 |
| DO-8 | `curl` 在 HTTP/2 中是否把自定义的 Host 用作 `:authority` | VT-81 的 HTTP/2 部分 | 实现，M1 | 否 |
| DO-9 | 需求第 11.2 节交给详细设计的规则集取舍：Apple、微软等在国内有节点的服务是否单独直连；国内 IP 规则是否加 `no-resolve`；规则的名称、顺序和取舍 | 随规则文本在 v0.2 中确定 | 设计，M2 | 否 |
| DO-10 | VT-12 的注入方法：`install.sh` 运行之后、安装后核对之前替换一个所装的文件（验证计划第 4.2 节） | 在 v0.2 中随部署第 3、4 步的契约确定 | 设计，M2 | 否 |
| DO-11 | VT-30 所用的 3X-UI 路由测试接口（`/panel/api/xray/routeTest`）的路径和参数（验证计划第 4.5 节） | 按 v3.11.0 的源码和 OpenAPI 文档核实，写入 v0.2 | 设计，M2 | 否 |

验证计划中仍待用户决定的 VO-5（FR-11 三个客户端的平台）和 VO-7（测试 VPS 的时间、主机和授权范围）都在 M3 之前，不影响 M1。

## 13. 需求追踪

| 需求或设计 | 本文 |
|---|---|
| FR-01 | 第 3 节 `new-host.*`；第 4.2 节 `xui.*`；第 6 节 |
| FR-02 | 第 2.4 节 `target`；第 2.7、5 节；第 3 节 `target.checked`；第 4.2 节 `inbounds.set`、`reality.*`、`forwarder.settings`、`routing.*` |
| FR-03 | 第 2.4 节 `users`；第 4.2 节 `clients.*` |
| FR-04 | 第 4.2 节 `sub.*`、`listen.sub`、`reality.hosts` |
| FR-05 | 第 2.4 节 `tunnel_token`；第 2.8 节；第 4.2 节 `cfd.*`、`absent.*` |
| FR-06 | 第 2.8 节的端口；第 4.2 节 `listen.*` |
| FR-07 | 第 2.6 节；第 4 节 |
| FR-12 | 第 2.4、2.5 节；第 3 节 |
| NFR-01 | 第 2.3 节；第 4.1 节"快照中没有秘密"；第 8 节；第 9.3 节 VT-74 |
| NFR-02 | 第 9.1 节的隐私扫描 |
| NFR-03 | 第 3 节 `platform`；第 9.1 节 |
| NFR-04 | 第 3 节 `hardening.*`、`tuning.dropin`；第 4.2 节 `hardening.verify` |
| NFR-05 | 第 6 节 |
| NFR-07 | 第 4.1 节；第 9.3 节 VT-72、VT-76 |
| D21 | 第 4.2 节 `sub.listen`、`sub.cert`、`absent.*` |
| D22（OD-2） | 第 4.2 节 `routing.rules` 的规则 3、4 |
| 方案设计第 7.5 节"值是否包含路径" | 第 4.2 节 `sub.uri`，第 14 节 |
| 验证计划 VT-75"退出码取值" | 第 2.2 节 |
| 验证计划第 3.3 节"接受文档地址" | 第 2.4 节 `node_ip` |
| 验证计划第 4 节"排除清单在 M1 中确定" | 第 9.4 节 |

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
