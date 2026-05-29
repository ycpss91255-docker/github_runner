# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../../LICENSE)
[![codecov](https://codecov.io/gh/ycpss91255-docker/github_runner/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/github_runner)

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## 目錄

- [TL;DR](#tldr)
- [概覽](#概覽)
- [目錄結構](#目錄結構)
- [Scripts](#scripts)
- [測試](#測試)
- [安全性說明](#安全性說明)
- [先決條件](#先決條件)
- [快速開始](#快速開始)
- [驗證 runner](#驗證-runner)
- [升級 runner 二進位](#升級-runner-二進位)
- [重建 SOP](#重建-sop)
- [參考資料](#參考資料)
- [授權](#授權)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org        # 若尚未登入

./scripts/init.sh ycpss91255-docker             # 準備 host + 註冊第一個 runner
./scripts/add-runner.sh org ycpss91255-research # 註冊第二個 runner
./scripts/status.sh                             # 本地 + GitHub 端狀態
```

Runner state 預設安裝在 `<repo_root>/runners/`；要改位置用 `RUNNER_HOME=...`。

## 概覽

為 `ycpss91255-research` 與 `ycpss91255-docker` 兩個 org 提供 self-hosted
GitHub Actions runner 的安裝佈署工具。實作 [ADR-0012]（位於上層 workspace
repo）的 tooling section。

Repo 放在 `ycpss91255-docker` 是因為 runner 佈署屬於 host 環境 /
infrastructure 範疇（依使用者對 docker-vs-research org 邊界的解讀，詳見
ADR-0012 原始切分與後續 refinement）。

## 目錄結構

預設所有 runner state 都住在 `<repo_root>/runners/`（跟此 checkout 同位，
已 gitignored）。一份 clone 擁有所有狀態，不需要額外的 `~/github_runner`
目錄：

```
<repo_root>/runners/                                   # 預設 RUNNER_HOME
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # 快取的 tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` 代表「該 org 的 org-level runner」。Repo-level runner 會放在
`<org>/<repo>/`。

要改安裝位置，在跑任一 script 前 export `RUNNER_HOME`（例如
`RUNNER_HOME=/var/lib/gh-runners ./scripts/init.sh ...`）。

## Scripts

| Script | 用途 |
|---|---|
| `scripts/init.sh` | 檢查 host 先決條件；透過 GitHub API 解析 actions/runner 最新 release（離線時退回內建 pinned fallback），下載並 cache 至 `<repo_root>/runners/.bin/`（即 `$RUNNER_HOME/.bin/`）。可用 `RUNNER_VERSION=...` 覆蓋。若帶 org 參數，會同時註冊該 org 的第一個 runner |
| `scripts/add-runner.sh` | 註冊新 runner。用法：`org <org>` 或 `repo <owner> <repo>`。`org` scope 會把 Default runner group 的 `allows_public_repositories=true` 打開，讓 public repo 的 workflow 能 dispatch（詳見下方安全性說明） |
| `scripts/remove-runner.sh` | 取消註冊 + uninstall systemd service + 刪目錄 |
| `scripts/status.sh` | 列出所有 registered runner 的本地與 GitHub 端狀態 |
| `scripts/update.sh` | 解析 actions/runner 最新 release（或 `RUNNER_VERSION=...` 指定），cache 不存在則下載，再覆蓋所有 registered runner 的 binary。保留 config |
| `scripts/uninstall.sh` | `scripts/init.sh` 的對等：把此 checkout 註冊過的 runner 全部拆掉 + 刪 tarball cache。預設 prompt 確認，`--yes` 跳過，`--dry-run` 預覽。**不**動 org runner-group flag、**不**刪 checkout 本身（詳見 #11） |
| `scripts/cleanup.sh` | 清掉 GitHub 自動升級循環留下的占空間殘料：陳舊 `bin.X` / `externals.X` 版本目錄、`${RUNNER_HOME}/.bin/` 內的舊版 tarball、`_work/_update*` 殘留。可安全排程，**不**動 registration state、log、進行中的 job 目錄。預設 prompt 確認，`--yes` 跳過，`--dry-run` 預覽 |
| `scripts/schedule-cleanup.sh` | 安裝／移除 user crontab 內的排程，定時自動跑 `cleanup.sh`（daily / weekly / monthly 可選；時段、星期幾互動選擇）。沒帶參數會進互動模式，也可用 `--every` / `--at` / `--day` 一行帶完。`--status` 看目前排程，`--uninstall` 移除。輸出 append 到 `${RUNNER_HOME}/.cleanup.log`，`flock` 防併發重跑 |

所有 script 皆為 idempotent。

## 測試

測試在 `ghcr.io/ycpss91255-docker/test-tools` image 內執行（alpine +
bats + shellcheck + hadolint，跟 `ycpss91255-docker/base` 用同一個 image），
覆蓋率在 `kcov/kcov` 內跑（Debian，內含 `kcov`；`bats` runtime apt 裝）。
本機跟 CI 共用相同 image。

Makefile 改名 `Makefile.ci`（無 top-level `Makefile`）對齊 base repo 慣例 —
都用 `-f Makefile.ci` 呼叫：

```bash
make -f Makefile.ci pull       # 拉 test-tools + kcov image（首次）
make -f Makefile.ci lint       # shellcheck（在 docker 內）
make -f Makefile.ci test       # bats smoke tests（在 docker 內）
make -f Makefile.ci check      # lint + test（不含 coverage）
make -f Makefile.ci coverage   # bats + kcov 覆蓋率 → ./coverage/
make -f Makefile.ci help       # 列 targets
```

若想直接在 host 跑（需本機已裝 `shellcheck` / `bats`）：

```bash
make -f Makefile.ci lint-host
make -f Makefile.ci test-host
```

CI 每次 push / PR 跑 `lint` + `test`，**push 到 main 才跑 `coverage`**
（kcov 比純 bats 慢 2-5×，留給 release-quality signal 用），Codecov
上傳走 `CODECOV_TOKEN` repo secret。

## 安全性說明

Public repo 的 workflow 在 self-hosted runner 上 dispatch，GitHub 有兩個
開關需同時對齊：

1. **外部貢獻者 approval gate**（org Settings → Actions → General →
   「Require approval for all external contributors」）。依 ADR-0011 Public
   repo security 設定。擋住 fork PR 在 runner 上任意執行 code，直到
   maintainer 按「Approve and run」。
2. **Runner group `allows_public_repositories` flag**（各 org 的 Default
   group）。GitHub 2024 起預設 `false`，會把 public repo 的 workflow
   永遠卡在 queued 狀態 — runner 顯示 `online` + idle 但實際不接 job。
   `scripts/add-runner.sh org <org>` 會把它打開成 `true`，maintainer 觸發的
   dispatch 才會通。

兩個保護同時開 = 跟 GitHub 預設保護等價：外部貢獻者沒被 approve 不能跑，
maintainer 跟受信任 collaborator 可跑。只關一個的話：knob 2 關
→ public repo 工作再次卡死；knob 1 關 → fork PR 漏洞再開。原始分析詳見
#6。

`scripts/status.sh` 多了一欄 `PUBLIC-DISPATCH` 顯示每個 org 的 knob 2 狀態，
避免設定靜默偏移。

## 先決條件

- Linux x64（測試過 Ubuntu 22.04）
- Docker 含 GPU runtime（`docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` 須能成功）
- Host 上可直接執行 `nvidia-smi`
- `gh` CLI 已登入且 token 含 `admin:org` scope
- 當前使用者在 `docker` group 內
- 安裝 `curl`, `jq`, `sudo`

`scripts/init.sh` 會跑完上述所有檢查，任何一項失敗即 exit non-zero。

## 快速開始

`scripts/init.sh <org>` 會準備好 host 並同時註冊第一個 runner。其他 runner 用
`scripts/add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org   # 若尚未登入

./scripts/init.sh ycpss91255-docker             # 準備 + 第一個 runner（-docker org）
./scripts/add-runner.sh org ycpss91255-research # 第二個 runner（-research org）
./scripts/status.sh
```

若只想準備環境、暫不註冊（例如 CI lint，或之後再註冊）：

```bash
./scripts/init.sh   # 不帶 org 參數 = 只 bootstrap
```

`./scripts/status.sh` 預期輸出：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB
<hostname>-ycpss91255-docker-org         org        running    online
<hostname>-ycpss91255-research-org       org        running    online
```

## 驗證 runner

End-to-end 驗證需要一個 canary workflow 放在跟 runner 同 org 的 repo 內
（GitHub org-level runner 只接受同 org 的 workflow）。Canary 放置位置仍在
設計中 — 詳見上層 issue / ADR-0012 當前決定。立即的健康檢查：`./scripts/status.sh`
顯示 GitHub 端的 `online` flag，且 `scripts/init.sh` 已驗證過
`docker run --gpus all nvidia-smi` 在 host 上能跑。

## 升級 runner 二進位

```bash
RUNNER_VERSION=<new-version> ./scripts/update.sh
```

停每個 runner 的 service、覆蓋 binary、重啟。config 跟 credentials 保留。

## 重建 SOP

機器遺失 / 重灌後：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
./scripts/init.sh ycpss91255-docker
./scripts/add-runner.sh org ycpss91255-research
```

沒有未記錄的機器狀態。註冊 token 透過 `gh api` 重新申請，舊機器上的 runner
entry 若無法回收，需在 GitHub UI 手動移除（Settings → Actions → Runners →
Remove offline runners）。

## 參考資料

- [ADR-0011] — 原始 CI 架構（已修訂）
- [ADR-0012] — research org 切分 + dual org-level runner（本 repo 實作其
  tooling section）
- GitHub docs：[Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs：[Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## 授權

[Apache-2.0](../../LICENSE) — 與 [ycpss91255-docker/base] 以及 org 內其他
repo 一致。

[ADR-0011]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0011-ci-architecture-with-self-hosted-gpu-runner.md
[ADR-0012]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0012-research-org-split-dual-org-runners.md
[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
