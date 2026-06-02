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
- [重建 SOP](#重建-sop)
- [参考资料](#参考资料)
- [授权](#授权)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # 若尚未登录

./script/init.sh ycpss91255-docker             # 准备 host + 注册第一个 runner
./script/add-runner.sh org ycpss91255-research # 注册第二个 runner
./script/status.sh                             # 本地 + GitHub 端状态
```

Runner state 预设安装在 `<repo_root>/runners/`；要改位置用 `RUNNER_HOME=...`。

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
| `script/init.sh` | 检查 host 先决条件；透过 GitHub API 解析 actions/runner 最新 release（离线时退回内建 pinned fallback），下载并缓存至 `<repo_root>/runners/.bin/`（即 `$RUNNER_HOME/.bin/`）。可用 `RUNNER_VERSION=...` 覆盖。若带 org 参数，会同时注册该 org 的第一个 runner |
| `script/add-runner.sh` | 注册新 runner。用法：`org <org>` 或 `repo <owner> <repo>`。labels 取自 `setup.conf`（默认 `gpu`，详见配置）。`org` scope 会把 Default runner group 的 `allows_public_repositories=true` 打开，让 public repo 的 workflow 能 dispatch（详见下方安全性说明） |
| `script/configure.sh` | 生成／更新 `${RUNNER_HOME}/setup.conf`。`--labels <csv>` 设定新注册 runner 的 labels；无参数则打印当前生效的配置 |
| `script/set-labels.sh` | 通过 GitHub API 即时改既有 runner 的 labels（免 remove + 重新注册）。用法：`org <org> <csv>` 或 `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | 取消注册 + uninstall systemd service + 删目录 |
| `script/status.sh` | 列出所有 registered runner 的本地与 GitHub 端状态，以及当前的 labels。`-w`/`--watch` 持续刷新（`-i`/`--interval` 设定间隔，默认 5 秒），以行为单位高亮差异；`--no-color` 关闭颜色 |
| `script/update.sh` | 解析 actions/runner 最新 release（或 `RUNNER_VERSION=...` 指定），cache 不存在则下载，再覆盖所有 registered runner 的 binary。保留 config |
| `script/uninstall.sh` | `script/init.sh` 的对等：把此 checkout 注册过的 runner 全部拆掉 + 删 tarball cache。预设 prompt 确认，`--yes` 跳过，`--dry-run` 预览。**不**动 org runner-group flag、**不**删 checkout 本身（详见 #11） |
| `script/cleanup.sh` | 清掉 GitHub 自动升级循环留下的占空间残料：陈旧 `bin.X` / `externals.X` 版本目录、`${RUNNER_HOME}/.bin/` 内的旧版 tarball、`_work/_update*` 残留。可安全排程，**不**动 registration state、log、进行中的 job 目录。预设 prompt 确认，`--yes` 跳过，`--dry-run` 预览 |
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

`script/status.sh` 多了一栏 `PUBLIC-DISPATCH` 显示每个 org 的 knob 2 状态，
避免设定静默偏移。

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

`script/init.sh <org>` 会准备好 host 并同时注册第一个 runner。其他 runner 用
`script/add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                       # 装 gh/jq/curl/sudo + gh auth login
                                               # （已设定好可略过;Docker+NVIDIA 须先存在）

./script/init.sh ycpss91255-docker             # 准备 + 第一个 runner（-docker org）
./script/add-runner.sh org ycpss91255-research # 第二个 runner（-research org）
./script/status.sh
```

若只想准备环境、暂不注册（例如 CI lint，或之后再注册）：

```bash
./script/init.sh   # 不带 org 参数 = 只 bootstrap
```

`./script/status.sh` 预期输出：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB     PUBLIC-DISPATCH  LABELS
<hostname>-ycpss91255-docker-org         org        running    online     public-ok        self-hosted,Linux,X64,gpu
<hostname>-ycpss91255-research-org       org        running    online     public-ok        self-hosted,Linux,X64,gpu
```

## 验证 runner

End-to-end 验证需要一个 canary workflow 放在跟 runner 同 org 的 repo 内
（GitHub org-level runner 只接受同 org 的 workflow）。立即的健康检查：`./script/status.sh`
显示 GitHub 端的 `online` flag，且 `script/init.sh` 已验证过
`docker run --gpus all nvidia-smi` 在 host 上能跑。

## 升级 runner 二进制

```bash
RUNNER_VERSION=<new-version> ./script/update.sh
```

停每个 runner 的 service、覆盖 binary、重启。config 跟 credentials 保留。

## 重建 SOP

机器遗失 / 重装后：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh ycpss91255-docker
./script/add-runner.sh org ycpss91255-research
```

没有未记录的机器状态。注册 token 透过 `gh api` 重新申请，旧机器上的 runner
entry 若无法回收，需在 GitHub UI 手动移除（Settings → Actions → Runners →
Remove offline runners）。

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
