# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../../LICENSE)

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

为 `ycpss91255-research` 与 `ycpss91255-docker` 两个 org 提供 self-hosted
GitHub Actions runner 的安装部署工具。实作 [ADR-0012]（位于上层 workspace
repo）的 tooling 部分。

Repo 放在 `ycpss91255-docker` 是因为 runner 部署属于 host 环境 /
infrastructure 范畴（依使用者对 docker-vs-research org 边界的解读，详见
ADR-0012 原始切分与后续 refinement）。

## 目录

- [快速开始](#快速开始)
- [目录结构](#目录结构)
- [Scripts](#scripts)
- [先决条件](#先决条件)
- [测试](#测试)
- [验证 runner](#验证-runner)
- [升级 runner 二进制](#升级-runner-二进制)
- [重建 SOP](#重建-sop)
- [参考资料](#参考资料)

## 目录结构

```
~/github_runner/                                       # 本机安装位置
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # 缓存的 tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` 代表「该 org 的 org-level runner」。Repo-level runner 会放在
`<org>/<repo>/`。

## Scripts

| Script | 用途 |
|---|---|
| `init.sh` | 检查 host 先决条件；下载并缓存 runner tarball 至 `~/github_runner/.bin/`。若带 org 参数，会同时注册该 org 的第一个 runner |
| `add-runner.sh` | 注册新 runner。用法：`org <org>` 或 `repo <owner> <repo>` |
| `remove-runner.sh` | 取消注册 + uninstall systemd service + 删目录 |
| `status.sh` | 列出所有 registered runner 的本地与 GitHub 端状态 |
| `update.sh` | 升级所有 runner 的 binary，保留 config |

所有 script 均为 idempotent。

## 测试

测试在 `ghcr.io/ycpss91255-docker/test-tools` image 内执行（alpine +
bats + shellcheck + hadolint，跟 `ycpss91255-docker/base` 用同一个 image），
本机跑跟 CI 跑共用完全相同的工具版本。

```bash
make pull    # 拉 test-tools image（首次）
make lint    # shellcheck（在 docker 内）
make test    # bats smoke tests（在 docker 内）
make check   # 两者
make help    # 列出 targets
```

若想直接在 host 跑（需本机已装 `shellcheck` / `bats`）：

```bash
make lint-host
make test-host
```

CI 透过 `.github/workflows/ci.yaml` 用同一个 image 跑 `make lint` +
`make test`。

## 先决条件

- Linux x64（测试过 Ubuntu 22.04）
- Docker 含 GPU runtime（`docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` 须能成功）
- Host 上可直接执行 `nvidia-smi`
- `gh` CLI 已登入且 token 含 `admin:org` scope
- 当前使用者在 `docker` group 内
- 安装 `curl`, `jq`, `sudo`

`init.sh` 会跑完上述所有检查，任何一项失败即 exit non-zero。

## 快速开始

`init.sh <org>` 会准备好 host 并同时注册第一个 runner。其他 runner 用
`add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org   # 若尚未登入

./init.sh ycpss91255-docker             # 准备 + 第一个 runner（-docker org）
./add-runner.sh org ycpss91255-research # 第二个 runner（-research org）
./status.sh
```

若只想准备环境、暂不注册（例如 CI lint，或之后再注册）：

```bash
./init.sh   # 不带 org 参数 = 只 bootstrap
```

`./status.sh` 预期输出：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB
<hostname>-ycpss91255-docker-org         org        running    online
<hostname>-ycpss91255-research-org       org        running    online
```

## 验证 runner

End-to-end 验证需要一个 canary workflow 放在跟 runner 同 org 的 repo 内
（GitHub org-level runner 只接受同 org 的 workflow）。Canary 放置位置仍在
设计中 — 详见上层 issue / ADR-0012 当前决定。立即的健康检查：`./status.sh`
显示 GitHub 端的 `online` flag，且 `init.sh` 已验证过
`docker run --gpus all nvidia-smi` 在 host 上能跑。

## 升级 runner 二进制

```bash
RUNNER_VERSION=<new-version> ./update.sh
```

停每个 runner 的 service、覆盖 binary、重启。config 跟 credentials 保留。

## 重建 SOP

机器遗失 / 重装后：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
./init.sh ycpss91255-docker
./add-runner.sh org ycpss91255-research
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
