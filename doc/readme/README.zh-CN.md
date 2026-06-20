# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../../LICENSE)
[![codecov](https://codecov.io/gh/ycpss91255-docker/github_runner/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/github_runner)

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## 目录

- [TL;DR](#tldr)
- [概览](#概览)
- [目录结构](#目录结构)
- [Scripts](#scripts)
- [配置](#配置)
- [测试](#测试)
- [安全性说明](#安全性说明)
- [先决条件](#先决条件)
- [快速开始](#快速开始)
- [验证 runner](#验证-runner)
- [升级 runner 二进制](#升级-runner-二进制)
- [卸载](#卸载)
- [重建 SOP](#重建-sop)
- [疑难排解](#疑难排解)
- [参考资料](#参考资料)
- [授权](#授权)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # 若尚未登录

./script/init.sh <your-org>             # 准备 host + 注册第一个 runner
./script/add-runner.sh org <other-org>  # (可选) 为另一个 org 注册 runner
./script/status.sh                      # 本地 + GitHub 端状态
```

`<your-org>` 是**你自己的 GitHub organization**(账号名称,例如 `my-company`)
——不是 repo,也不是本项目名称。你需要一个你具有 **admin/owner** 权限的 GitHub
org。若你没有 org(个人账号),改为注册 repo-scoped runner —— 见[快速开始](#快速开始)。

有两件事要先设好,否则第一次跑会中断 / job 会卡住:

- **核准闸门**——org runner 请先开启 *Settings → Actions → General →
  「Require approval for all outside collaborators」*,否则 `add-runner.sh org`
  会拒绝注册(可加 `--force` 略过)。详见安全性说明。
- **标签**——默认标签是 `gpu`。非 GPU 主机请先设标签
  (`./script/configure.sh --labels <label>`),否则 `runs-on` 没指定 `gpu` 的
  job 会无声卡在 `queued`。

Runner state 预设安装在 `<repo_root>/runners/`;要改位置用 `RUNNER_HOME=...`。

## 概览

部署、管理与拆除 self-hosted GitHub Actions runner 的工具:注册 / 移除
org-level 或 repo-level runner、安装成 systemd service、cache 与升级 runner
binary、回报本地与 GitHub 端状态、清理自动升级残料。一份 clone 拥有
`<repo_root>/runners/` 底下所有 runner state,所有 script 均为 idempotent。

这些 script 是通用的 — 任何 org 或 repo 都能传入。`ycpss91255-research` 与
`ycpss91255-docker` 两个 org 在全文只是具体范例(作者自己跑的 org),并未写死绑定。

## 目录结构

预设所有 runner state 都住在 `<repo_root>/runners/`（跟此 checkout 同位，
已 gitignored）。一份 clone 拥有所有状态，不需要额外的 `~/github_runner`
目录：

```
<repo_root>/runners/                                   # 预设 RUNNER_HOME
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # 缓存的 tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` 代表「该 org 的 org-level runner」。Repo-level runner 会放在
`<org>/<repo>/`。

要改安装位置，在跑任一 script 前 export `RUNNER_HOME`（例如
`RUNNER_HOME=/var/lib/gh-runners ./script/init.sh ...`）。

## Scripts

| Script | 用途 |
|---|---|
| `script/install-deps.sh` | 在 apt/Ubuntu host 上安装 CLI 先决条件（`gh`、`jq`、`curl`、`sudo`）并跑 `gh auth login`。`-y` 接受所有安装提示;`--dry-run` 只报告缺什么。Docker 与 NVIDIA Container Toolkit 假设已安装。幂等 |
| `script/init.sh` | 检查 host 先决条件；透过 GitHub API 解析 actions/runner 最新 release（当 gh 缺失 / 未认证 / 离线时退回内建 pinned 版本），下载并缓存至 `<repo_root>/runners/.bin/`（即 `$RUNNER_HOME/.bin/`）。可用 `RUNNER_VERSION=...` 覆盖。若带 scope 参数，会原封不动转交给 `add-runner.sh` 并注册第一个 runner：`org <org>`、`repo <owner> <repo>`，或只给 org 名称作为 `org` 形式的简写 |
| `script/add-runner.sh` | 注册新 runner。用法：`[--force] org <org>` 或 `repo <owner> <repo>`。labels 取自 `setup.conf`（默认 `gpu`，详见配置）。`org` scope 会先验证外部贡献者 approval gate,再把 Default runner group 的 `allows_public_repositories=true` 打开让 public repo workflow 能 dispatch；gate 未设时会**拒绝**,除非加 `--force`(详见下方安全性说明） |
| `script/configure.sh` | 生成／更新 `${RUNNER_HOME}/setup.conf`。`--labels <csv>` 设定新注册 runner 的 labels；无参数则打印当前生效的配置 |
| `script/set-labels.sh` | 通过 GitHub API 即时改既有 runner 的 labels（免 remove + 重新注册）。用法：`org <org> <csv>` 或 `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | 取消注册 + uninstall systemd service + 删目录 |
| `script/status.sh` | 列出所有 registered runner 的本地与 GitHub 端状态，以及当前的 labels。`-w`/`--watch` 持续刷新（`-i`/`--interval` 设定间隔，默认 5 秒），以行为单位高亮差异；`--no-color` 关闭颜色 |
| `script/update.sh` | 解析 actions/runner 最新 release（或 `RUNNER_VERSION=...` 指定，与 init 相同的 fallback），cache 不存在则下载，再把新版的 versioned runner 文件 seed 到各 runner 目录（既有文件保留原状）；runner 会在下次连线时透过正常的 self-update 接手新版本。保留 config |
| `script/uninstall.sh` | `script/init.sh` 的对等：把此 checkout 注册过的 runner 全部拆掉 + 删 tarball cache。预设 prompt 确认，`--yes` 跳过，`--dry-run` 预览。**不**动 org runner-group flag、**不**删 checkout 本身（详见 #11） |
| `script/cleanup.sh` | 清掉 GitHub 自动升级循环留下的占空间残料：陈旧 `bin.X` / `externals.X` 版本目录、`${RUNNER_HOME}/.bin/` 内的旧版 tarball、`_work/_update*` 残留、过期的 `_diag/*.log`。可安全排程，**不**动 registration state、进行中的 job 目录。预设 prompt 确认,`--yes` 跳过,`--dry-run` 预览。可选 `--work-caches` 会额外修剪**闲置** runner 的 `_work/_tool` / `_work/_actions` 旧 cache 项目(正在跑 job 的 runner 会跳过;需要 `pgrep`) |
| `script/schedule-cleanup.sh` | 安装／移除 user crontab 内的排程，定时自动跑 `cleanup.sh`（daily / weekly / monthly 可选；时段、星期几互动选择）。不带参数进互动模式，也可用 `--every` / `--at` / `--day` 一行带完。`--status` 看目前排程，`--uninstall` 移除。输出 append 到 `${RUNNER_HOME}/.cleanup.log`，`flock` 防并发重跑 |

所有 script 均为 idempotent。

## 配置

Runner 注册时会读取可选的配置文件 `${RUNNER_HOME}/setup.conf`（`KEY=value`，可被 shell source）。用 `script/configure.sh` 生成或更新：

```bash
./script/configure.sh --labels gpu,cuda12   # 新注册 runner 的 labels
./script/configure.sh                         # 打印当前生效的配置
```

`LABELS`（默认 `gpu`）会在注册当下成为 runner 的 custom labels；系统 label `self-hosted` / `Linux` / `X64` 由 GitHub 一律保留。labels 是 `runs-on` 的路由 key：只有 job 的 `runs-on` labels 是某 runner labels 的子集，job 才会落到该 runner。

`setup.conf` 只影响写入之后才注册的 runner。要即时改既有 runner 的 label（免 remove + 重新注册），用 `script/set-labels.sh`：

```bash
./script/set-labels.sh org ycpss91255-docker gpu,cuda12
./script/set-labels.sh repo <owner> <repo> gpu,cuda12
```

`script/status.sh` 会在 `LABELS` 列显示每个 runner 当前的 labels。

## 测试

测试在 `ghcr.io/ycpss91255-docker/test-tools` image 内执行（alpine +
bats + shellcheck + hadolint，跟 `ycpss91255-docker/base` 用同一个 image），
覆盖率在 `kcov/kcov` 内跑（Debian，内含 `kcov`；`bats` runtime apt 装）。
本机跟 CI 共用相同 image。

Makefile 改名 `Makefile.ci`（无 top-level `Makefile`）对齐 base repo 惯例 —
都用 `-f Makefile.ci` 调用：

```bash
make -f Makefile.ci pull       # 拉 test-tools + kcov image（首次）
make -f Makefile.ci lint       # shellcheck（在 docker 内）
make -f Makefile.ci test       # bats smoke tests（在 docker 内）
make -f Makefile.ci check      # lint + test（不含 coverage）
make -f Makefile.ci coverage   # bats + kcov 覆盖率 → ./coverage/
make -f Makefile.ci help       # 列 targets
```

若想直接在 host 跑（需本机已装 `shellcheck` / `bats`）：

```bash
make -f Makefile.ci lint-host
make -f Makefile.ci test-host
```

CI 每次 push / PR 跑 `lint` + `test`，**push 到 main 才跑 `coverage`**
（kcov 比纯 bats 慢 2-5×，留给 release-quality signal 用），Codecov
上传走 `CODECOV_TOKEN` repo secret。

## 安全性说明

Public repo 的 workflow 在 self-hosted runner 上 dispatch，GitHub 有两个
开关需同时对齐：

1. **外部贡献者 approval gate**（org Settings → Actions → General →
   「Require approval for all outside collaborators」）。依 ADR-0011 Public
   repo security 设定。挡住 fork PR 在 runner 上任意执行 code，直到
   maintainer 按「Approve and run」。
2. **Runner group `allows_public_repositories` flag**（各 org 的 Default
   group）。GitHub 2024 起预设 `false`，会把 public repo 的 workflow
   永远卡在 queued 状态 — runner 显示 `online` + idle 但实际不接 job。
   `script/add-runner.sh org <org>` 会把它打开成 `true`，maintainer 触发的
   dispatch 才会通。

两个保护同时开 = 跟 GitHub 预设保护等价：外部贡献者没被 approve 不能跑，
maintainer 跟受信任 collaborator 可跑。只关一个的话：knob 2 关
→ public repo 工作再次卡死；knob 1 关 → fork PR 漏洞再开。原始分析详见
#6。

由于 knob 2 会降低 GitHub 的安全预设,`add-runner.sh org` 会**先验证 knob 1**:
读取该 org 的 approval gate,若未设为「对所有外部贡献者要求核准」就**拒绝注册**,
让工具不会只降低一边。要照样继续可加 `--force`(代表你接受 fork-PR 风险,
例如纯内部 org)。

`script/status.sh` 提供 `PUBLIC-DISPATCH` 栏(knob 2)**与 `APPROVAL-GATE` 栏
(knob 1)**,让单边设定一眼可见、不会静默偏移。

回报安全漏洞请见 [SECURITY.md](../../SECURITY.md)(使用 GitHub 私密漏洞回报,
勿开公开 issue)。

### Runner-user 权限

Workflow job 直接以 runner service user 在 host 上执行，而该 user 属于
`docker` group —— 这**等同 root**（`docker run -v /:/host …` 即可触及整台主机）。
对单租户、自管的 GPU 主机而言这是刻意接受的取舍:真正的安全边界是**哪些
workflow 被允许执行**(由上述两个 knob 把关，只有维护者与已批准的 PR 能
dispatch)，而**不是** runner user 的本机权限。由此衍生、且刻意**不**在 repo 内
追的后果:短效的 registration token 会出现在 runner `config.sh` 的命令行上
(其他本机 user 可透过 `ps` 看到 —— 单租户下非问题)，且 `sudo ./svc.sh` 信任
runner 树。若这台主机未来要跑不可信的 workflow 或变成多租户,升级路径是
**rootless Docker 或 rootless Podman**(不需 `docker` group，daemon 以非特权执行)
—— 可行,但有 GPU + docker-in-docker 的摩擦,届时再单独评估。

专用 CI user **本身不构成边界**。因为 runner user 在 `docker` group(如上,等同
root),另开一个登录账号、清空 home、或 `chmod 600 ~/.ssh` 都只是装饰:任何跑起来
的 job 都能 `docker run -v /:/host …` 读走 operator 的 SSH key、cloud 凭证与
token,与文件所有者无关。专用 CI user 只有在搭配 **rootless**(user 不再是 root)
**或** **host 无机密**(root 没东西可偷)时才会变成真正的边界 —— 缺一不可。实际
操作步骤见 [host hardening runbook](../runbook/HOST-HARDENING.md)。

repo 内**有**做的加固:下载的 actions/runner tarball 在解压前会比对 GitHub 为该
release asset 公布的 SHA-256(供应链检查,与上述正交)。

## 先决条件

**主机 / 硬件**

- Linux x64（测试过 Ubuntu 22.04）
- NVIDIA GPU —— **可选**。有卡时:host 上 `nvidia-smi` 可执行、
  `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` 须能成功,
  且 runner 默认挂 `gpu` 标签。无卡时:`script/init.sh` 会自动检测（无 `nvidia-smi`）、
  跳过 GPU 检查,并提醒你设非 gpu 标签（`./script/configure.sh --labels <label>`）。
- Docker（用 GPU 时并需 NVIDIA Container Toolkit）
- 当前使用者在 `docker` group 内（注意:这等同 root —— 见 [Security model](#security-model)）

**CLI 工具**

- `gh`、`jq`、`curl`、`sudo`

**存取 / 网络**

- 一个你具有 **admin/owner 权限的 GitHub organization** ——org-scoped 流程
  (`init.sh <org>` / `add-runner.sh org <org>`)是默认。个人账号请改注册
  repo-scoped runner(`init.sh repo <owner> <repo>`,或 `add-runner.sh repo <owner> <repo>`)。
- `gh` 已登入且 token 含 `admin:org` scope（`gh auth login --scopes admin:org`）
- 对 `github.com`、`api.github.com`、`cli.github.com`、`objects.githubusercontent.com` 的对外 HTTPS（runner 下载 + 注册）
- `sudo` 权限（runner 以 systemd service 安装）

**安装先决条件**

Docker 与 NVIDIA Container Toolkit 须先自行安装（牵涉 kernel driver / repo，本工具刻意不碰），
照 Docker 与 NVIDIA 官方文件即可。之后 `script/install-deps.sh` 会在 apt/Ubuntu host 上
装好其余 CLI 工具（`gh`、`jq`、`curl`、`sudo`）并带你跑 `gh auth login`:

```bash
./script/install-deps.sh            # 每项安装前先询问,再做 auth
./script/install-deps.sh -y         # 接受所有安装提示（apt -y）;auth 仍为交互式
./script/install-deps.sh --dry-run  # 只报告缺什么,不安装
```

`script/init.sh` 接着会重新检查以上全部,任何一项失败即 exit non-zero（并列出每个缺项）。

## 快速开始

`script/init.sh <your-org>` 会准备好 host 并同时注册第一个 runner。下面的
`<your-org>` / `<other-org>` 请换成**你自己的 GitHub organization** 名称
——它们是占位符,不是字面值。其他 runner 用 `script/add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                # 装 gh/jq/curl/sudo + gh auth login
                                        # （已设定好可略过;Docker+NVIDIA 须先存在）

./script/init.sh <your-org>             # 准备 + 为你的 org 注册第一个 runner
./script/add-runner.sh org <other-org>  # (可选) 为另一个 org 注册 runner
./script/status.sh
```

若只想准备环境、暂不注册（例如 CI lint，或之后再注册）：

```bash
./script/init.sh   # 不带 org 参数 = 只 bootstrap
```

org vs repo scope：org runner 服务该 org 下所有 repo;repo runner 只绑定单一 repo。
`script/init.sh` 两种 scope 都接,所以 repo-level runner 也能一步到位 —— 带上
`repo <owner> <repo>`,它会准备 host 并注册该 runner(转交给 `script/add-runner.sh`)。
没有 org 的个人账号就走这条路:

```bash
./script/init.sh repo <owner> <repo>  # 准备 host + runner 绑定 <owner>/<repo>
```

(上面 org 示例里的 `init.sh <your-org>` 只是 `init.sh org <your-org>` 的简写。)

`./script/status.sh` 预期输出(`APPROVAL-GATE` 栏为 knob 1、`PUBLIC-DISPATCH`
为 knob 2,详见安全性说明):

```
NAME                               SCOPE  LOCAL-SVC  GITHUB   PUBLIC-DISPATCH   APPROVAL-GATE   LABELS
<hostname>-<your-org>-org          org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
<hostname>-<other-org>-org         org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
```

## 验证 runner

End-to-end 验证需要一个 canary workflow 放在跟 runner 同 org 的 repo 内
（GitHub org-level runner 只接受同 org 的 workflow）。立即的健康检查：`./script/status.sh`
显示 GitHub 端的 `online` flag，且在 GPU 主机上 `script/init.sh` 已验证过
`docker run --gpus all nvidia-smi` 在 host 上能跑（检测不到 GPU 时会跳过）。

## 升级 runner 二进制

```bash
RUNNER_VERSION=<new-version> ./script/update.sh
```

把新版的 versioned runner 文件 seed 到各 runner 目录（既有文件保留原状）；runner 会在下次连线时透过正常的 self-update 接手新版本。config 跟 credentials 保留。

## 卸载

移除**单一** runner(deregister + 卸载 systemd service + 删目录):

```bash
./script/remove-runner.sh org <your-org>          # org runner
./script/remove-runner.sh repo <owner> <repo>     # repo runner
```

拆除这个 checkout 注册过的**全部** runner + 删 tarball cache(默认会 prompt,
先预览再确认):

```bash
./script/uninstall.sh --dry-run   # 显示会移除什么
./script/uninstall.sh --yes       # 实际移除(非 TTY 必须加)
```

`uninstall.sh` 刻意**不**做:重设 org 的 `allows_public_repositories` runner-group
旗标(可能被其他主机共用)、或删除这个 checkout。主机消失后 GitHub 端残留的
`offline` runner 请到 UI 移除(Settings → Actions → Runners → Remove)。卡住的
状态见[疑难排解](#疑难排解)。

## 重建 SOP

机器遗失 / 重装后：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh <your-org>
./script/add-runner.sh org <other-org>
```

没有未记录的机器状态。注册 token 透过 `gh api` 重新申请，旧机器上的 runner
entry 若无法回收，需在 GitHub UI 手动移除（Settings → Actions → Runners →
Remove offline runners）。注意 labels 存在 gitignored 的 `setup.conf`,主机重装
后不会留存——用 `./script/configure.sh --labels ...` 重新设定(见疑难排解)。

## 疑难排解

on-call 对照表:把 `status.sh` 的每个状态(`offline` / `not-found` / `n/a` /
`stopped` / `public-BLOCKED`),以及 job 卡 queued、磁盘满、`gh` auth 过期、
重装后标签漂移等情境,对应到成因、第一步诊断指令与修法:
**[doc/runbook/TROUBLESHOOTING.md](../runbook/TROUBLESHOOTING.md)**。

## 参考资料

- [ADR-0011] — 原始 CI 架构（已修订）
- [ADR-0012] — research org 切分 + dual org-level runner（本 repo 实作其
  tooling 部分）
- GitHub docs：[Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs：[Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## 授权

[Apache-2.0](../../LICENSE) — 与 [ycpss91255-docker/base] 以及 org 内其他
repo 一致。

[ADR-0011]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0011-ci-architecture-with-self-hosted-gpu-runner.md
[ADR-0012]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0012-research-org-split-dual-org-runners.md
[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
