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
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org        # 若尚未登录

./scripts/init.sh ycpss91255-docker             # 准备 host + 注册第一个 runner
./scripts/add-runner.sh org ycpss91255-research # 注册第二个 runner
./scripts/status.sh                             # 本地 + GitHub 端状态
```

Runner state 预设安装在 `<repo_root>/runners/`；要改位置用 `RUNNER_HOME=...`。

## 概览

为 `ycpss91255-research` 与 `ycpss91255-docker` 两个 org 提供 self-hosted
GitHub Actions runner 的安装部署工具。实作 [ADR-0012]（位于上层 workspace
repo）的 tooling 部分。

Repo 放在 `ycpss91255-docker` 是因为 runner 部署属于 host 环境 /
infrastructure 范畴（依使用者对 docker-vs-research org 边界的解读，详见
ADR-0012 原始切分与后续 refinement）。

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
`RUNNER_HOME=/var/lib/gh-runners ./scripts/init.sh ...`）。

## Scripts

| Script | 用途 |
|---|---|
| `scripts/init.sh` | 检查 host 先决条件；透过 GitHub API 解析 actions/runner 最新 release（离线时退回内建 pinned fallback），下载并缓存至 `<repo_root>/runners/.bin/`（即 `$RUNNER_HOME/.bin/`）。可用 `RUNNER_VERSION=...` 覆盖。若带 org 参数，会同时注册该 org 的第一个 runner |
| `scripts/add-runner.sh` | 注册新 runner。用法：`org <org>` 或 `repo <owner> <repo>`。`org` scope 会把 Default runner group 的 `allows_public_repositories=true` 打开，让 public repo 的 workflow 能 dispatch（详见下方安全性说明） |
| `scripts/remove-runner.sh` | 取消注册 + uninstall systemd service + 删目录 |
| `scripts/status.sh` | 列出所有 registered runner 的本地与 GitHub 端状态 |
| `scripts/update.sh` | 解析 actions/runner 最新 release（或 `RUNNER_VERSION=...` 指定），cache 不存在则下载，再覆盖所有 registered runner 的 binary。保留 config |
| `scripts/uninstall.sh` | `scripts/init.sh` 的对等：把此 checkout 注册过的 runner 全部拆掉 + 删 tarball cache。预设 prompt 确认，`--yes` 跳过，`--dry-run` 预览。**不**动 org runner-group flag、**不**删 checkout 本身（详见 #11） |
| `scripts/cleanup.sh` | 清掉 GitHub 自动升级循环留下的占空间残料：陈旧 `bin.X` / `externals.X` 版本目录、`${RUNNER_HOME}/.bin/` 内的旧版 tarball、`_work/_update*` 残留。可安全排程，**不**动 registration state、log、进行中的 job 目录。预设 prompt 确认，`--yes` 跳过，`--dry-run` 预览 |

所有 script 均为 idempotent。

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
   「Require approval for all external contributors」）。依 ADR-0011 Public
   repo security 设定。挡住 fork PR 在 runner 上任意执行 code，直到
   maintainer 按「Approve and run」。
2. **Runner group `allows_public_repositories` flag**（各 org 的 Default
   group）。GitHub 2024 起预设 `false`，会把 public repo 的 workflow
   永远卡在 queued 状态 — runner 显示 `online` + idle 但实际不接 job。
   `scripts/add-runner.sh org <org>` 会把它打开成 `true`，maintainer 触发的
   dispatch 才会通。

两个保护同时开 = 跟 GitHub 预设保护等价：外部贡献者没被 approve 不能跑，
maintainer 跟受信任 collaborator 可跑。只关一个的话：knob 2 关
→ public repo 工作再次卡死；knob 1 关 → fork PR 漏洞再开。原始分析详见
#6。

`scripts/status.sh` 多了一栏 `PUBLIC-DISPATCH` 显示每个 org 的 knob 2 状态，
避免设定静默偏移。

## 先决条件

- Linux x64（测试过 Ubuntu 22.04）
- Docker 含 GPU runtime（`docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` 须能成功）
- Host 上可直接执行 `nvidia-smi`
- `gh` CLI 已登入且 token 含 `admin:org` scope
- 当前使用者在 `docker` group 内
- 安装 `curl`, `jq`, `sudo`

`scripts/init.sh` 会跑完上述所有检查，任何一项失败即 exit non-zero。

## 快速开始

`scripts/init.sh <org>` 会准备好 host 并同时注册第一个 runner。其他 runner 用
`scripts/add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org   # 若尚未登入

./scripts/init.sh ycpss91255-docker             # 准备 + 第一个 runner（-docker org）
./scripts/add-runner.sh org ycpss91255-research # 第二个 runner（-research org）
./scripts/status.sh
```

若只想准备环境、暂不注册（例如 CI lint，或之后再注册）：

```bash
./scripts/init.sh   # 不带 org 参数 = 只 bootstrap
```

`./scripts/status.sh` 预期输出：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB
<hostname>-ycpss91255-docker-org         org        running    online
<hostname>-ycpss91255-research-org       org        running    online
```

## 验证 runner

End-to-end 验证需要一个 canary workflow 放在跟 runner 同 org 的 repo 内
（GitHub org-level runner 只接受同 org 的 workflow）。Canary 放置位置仍在
设计中 — 详见上层 issue / ADR-0012 当前决定。立即的健康检查：`./scripts/status.sh`
显示 GitHub 端的 `online` flag，且 `scripts/init.sh` 已验证过
`docker run --gpus all nvidia-smi` 在 host 上能跑。

## 升级 runner 二进制

```bash
RUNNER_VERSION=<new-version> ./scripts/update.sh
```

停每个 runner 的 service、覆盖 binary、重启。config 跟 credentials 保留。

## 重建 SOP

机器遗失 / 重装后：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
./scripts/init.sh ycpss91255-docker
./scripts/add-runner.sh org ycpss91255-research
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
