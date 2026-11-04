# TAG 适配与上游同步

本仓库是 [anyun-hy/claude-switcher](https://github.com/anyun-hy/claude-switcher)，基于原作者 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher) 维护。自己的 `main` 承接上游代码和少量本地适配；本次同步的上游基线是 [`187a8d69ec7c718a74c2d225f5ceea4543bd8d81`](https://github.com/YOURSJEYO/claude-switcher/commit/187a8d69ec7c718a74c2d225f5ceea4543bd8d81)。保留原作者署名、Git 历史和上游随代码提供的 [AGPL-3.0-only 许可证](../LICENSE)。

## TAG 适配范围

- 核心脚本支持 `tag` 客户端模式，按完整可执行文件路径识别 TAG 内核：`/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin`。其他客户端或任意包含 `mihomo` 的进程不能据此当成 TAG。
- 安装器、保镖模板和桌面界面支持同一客户端模式。安装器按实际客户端和出口写入配置，App 安装位置保留为「应用程序」文件夹。用户切换客户端后，root 保镖需要通过安装器同步其配置。
- 这些改动提供 TAG 的基础兼容。Fake-IP 响应及相关网卡、DNS 行为只能作为检查信号，不能证明请求实际走了预期代理节点，也不能证明规则已置顶；仍须在 TAG 中核对 TUN、代理规则和实际出口。
- 切换器不会自动重写 TAG 的规则文件。启动客户端、检查状态及等待隧道就绪后仍不满足要求时，应由用户在 TAG 中调整配置。

## 更新通道与安装范围

macOS 核心的更新源固定为 **`anyun-hy/claude-switcher` 的 `main`**，与当前是否选择 `tag` 模式无关。原作者的新提交先由维护者合入自己的仓库，通过验证后再进入这条更新通道。

| 入口 | 行为 |
|---|---|
| `update-check` / `update --check` | 下载自己仓库 `main` 的归档，使用归档内同一快照的 `SHA256SUMS` 校验后比较核心、`stun-probe.py`、界面与守护脚本。只检查，不替换已安装文件、不修改运行配置、不创建更新备份。 |
| 界面「立即更新」(`update --gui`) | 获取 `~/.claude-switcher/update.lock` 互斥锁并注册 `trap` 异常回滚（界面超时 600 秒），先更新核心脚本、`stun-probe.py` 并写入 `~/.claude-switcher/config.env`，**先执行 `checkdetail` 自检通过后**，再统一通过 `scripts/build-app.sh` 编译替换 `/Applications/Claude Switcher.app`、按需请求一次管理员权限同步 root 守护脚本（root 执行前二次校验临时文件 SHA256），完成后自动重启应用（失败或中断自动回滚）。 |
| `update` / `update --auto` | 命令行或 LaunchAgent 更新核心脚本与 `stun-probe.py`（命令行下若界面源码变化且目录可写也会在自检通过后同步重编 App）；`--auto` 供用户态 LaunchAgent 后台静默更新核心与探针，不弹窗、不中断运行中界面。 |
| 安装器 | 首次安装或手动完整重装核心、App、root 保镖与时区守护等组件，并将运行配置写入 `~/.claude-switcher/config.env`。 |

运行配置项 `PROXY_MODE`、`PROXY_GROUP`、`COUNTRY_TARGET`、`TZ_TARGET`、`LOCALE_TARGET` 持久化在 `~/.claude-switcher/config.env`（脚本头部保留默认兜底值以兼容老版本升级），使已安装的核心脚本保持与 `SHA256SUMS` 字节一致。归档内的 `SHA256SUMS` 用于防传输损坏与缺文件校验，信任根为 GitHub HTTPS 与自有仓库写权限；提权同步 root 守护与系统目录 App 时，会在 root 脚本内二次核验临时构建产物的 SHA-256 摘要。

修改仓库源码不会自动替换本机已经安装的核心、App 或系统守护；旧版本继续执行它原有的更新逻辑。首次迁移到本 fork 时应从自己的 `main` 运行安装器，之后核心更新才使用上述通道。原作者发布的安装包也不包含本 fork 的 TAG 适配。

## 后续接收上游更新

1. 确认工作区状态、远程地址和双方提交：`origin` 指向自己的仓库，`upstream` 指向原作者仓库。
2. 从自己的 `main` 建立 `anyun/` 前缀的临时集成分支，获取 `upstream/main` 并合并。保留上游历史，逐项处理冲突，保持 TAG 改动集中在客户端识别与模式接入处。
3. 核对核心、安装器、保镖与界面中的 TAG 支持，以及自己的更新仓库、分支和同一归档校验方式。上游新增功能沿用其实现，不把客户端适配扩展为整套实现的替换。
4. 执行隔离回归、Shell 语法检查和可用的构建检查，重新生成并验证 `SHA256SUMS`。`anyun/**` 推送与 `main` 一样触发现有 CI；macOS 专属行为以 macOS CI 和实际环境验证结果为准。
5. 验证通过后将集成结果并入自己的 `main`，记录本次采用的上游提交及保留的本地改动。需要更新 App 或 root 守护时，再通过安装器部署对应组件。
