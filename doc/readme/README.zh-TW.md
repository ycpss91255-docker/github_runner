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
- [概述](#概述)
- [目錄結構](#目錄結構)
- [Scripts](#scripts)
- [設定](#設定)
- [測試](#測試)
- [安全性說明](#安全性說明)
- [先決條件](#先決條件)
- [快速開始](#快速開始)
- [驗證 runner](#驗證-runner)
- [升級 runner 二進位](#升級-runner-二進位)
- [解除安裝](#解除安裝)
- [重建 SOP](#重建-sop)
- [疑難排解](#疑難排解)
- [參考資料](#參考資料)
- [授權](#授權)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # 若尚未登入

./script/init.sh <your-org>             # 準備 host + 註冊第一個 runner
./script/add-runner.sh org <other-org>  # (選用) 為另一個 org 註冊 runner
./script/status.sh                      # 本地 + GitHub 端狀態
```

`<your-org>` 是**你自己的 GitHub organization**(帳號名稱,例如 `my-company`)
——不是 repo,也不是本專案名稱。你需要一個你具有 **admin/owner** 權限的 GitHub
org。若你沒有 org(個人帳號),改為註冊 repo-scoped runner —— 見[快速開始](#快速開始)。

有兩件事要先設好,否則第一次跑會中斷 / job 會卡住:

- **核准閘門**——org runner 請先開啟 *Settings → Actions → General →
  「Require approval for all outside collaborators」*,否則 `add-runner.sh org`
  會拒絕註冊(可加 `--force` 略過)。詳見安全性說明。
- **標籤**——預設標籤是 `gpu`。非 GPU 主機請先設標籤
  (`./script/configure.sh --labels <label>`),否則 `runs-on` 沒指定 `gpu` 的
  job 會無聲卡在 `queued`。

Runner state 預設安裝在 `<repo_root>/runners/`;要改位置用 `RUNNER_HOME=...`。

## 概述

佈署、管理與拆除 self-hosted GitHub Actions runner 的工具:註冊 / 移除
org-level 或 repo-level runner、安裝成 systemd service、cache 與升級 runner
binary、回報本地與 GitHub 端狀態、清理自動升級殘料。一份 clone 擁有
`<repo_root>/runners/` 底下所有 runner state,所有 script 皆為 idempotent。

這些 script 是通用的 — 任何 org 或 repo 都能傳入。`ycpss91255-research` 與
`ycpss91255-docker` 兩個 org 在全文只是具體範例(作者自己跑的 org),並未寫死綁定。

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
`RUNNER_HOME=/var/lib/gh-runners ./script/init.sh ...`）。

## Scripts

| Script | 用途 |
|---|---|
| `script/install-deps.sh` | 在 apt/Ubuntu host 上安裝 CLI 先決條件（`gh`、`jq`、`curl`、`sudo`）並跑 `gh auth login`。`-y` 接受所有安裝提示;`--dry-run` 只回報缺什麼。Docker 與 NVIDIA Container Toolkit 假設已安裝。冪等 |
| `script/init.sh` | 檢查 host 先決條件；透過 GitHub API 解析 actions/runner 最新 release（當 gh 缺失 / 未認證 / 離線時退回內建 pinned 版本），下載並 cache 至 `<repo_root>/runners/.bin/`（即 `$RUNNER_HOME/.bin/`）。可用 `RUNNER_VERSION=...` 覆蓋。若帶 scope 參數，會原封不動轉交給 `add-runner.sh` 並註冊第一個 runner：`org <org>`、`repo <owner> <repo>`，或只給 org 名稱作為 `org` 形式的簡寫 |
| `script/add-runner.sh` | 註冊新 runner。用法：`[--force] org <org>` 或 `repo <owner> <repo>`。labels 取自 `setup.conf`（預設 `gpu`，詳見設定）。`org` scope 會先驗證外部貢獻者 approval gate,再把 Default runner group 的 `allows_public_repositories=true` 打開讓 public repo workflow 能 dispatch；gate 未設時會**拒絕**,除非加 `--force`(詳見下方安全性說明） |
| `script/configure.sh` | 產生／更新 `${RUNNER_HOME}/setup.conf`。`--labels <csv>` 設定新註冊 runner 的 labels；無參數則印出目前生效的設定 |
| `script/set-labels.sh` | 透過 GitHub API 即時改既有 runner 的 labels（免 remove + 重新註冊）。用法：`org <org> <csv>` 或 `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | 取消註冊 + uninstall systemd service + 刪目錄 |
| `script/status.sh` | 列出所有 registered runner 的本地與 GitHub 端狀態，以及目前的 labels。`-w`/`--watch` 持續刷新（`-i`/`--interval` 設定間隔，預設 5 秒），以列為單位高亮差異；`--no-color` 關閉顏色 |
| `script/update.sh` | 解析 actions/runner 最新 release（或 `RUNNER_VERSION=...` 指定，與 init 相同的 fallback），cache 不存在則下載，再把新版的 versioned runner 檔案 seed 到各 runner 目錄（既有檔案保留原狀）；runner 會在下次連線時透過正常的 self-update 接手新版本。保留 config |
| `script/uninstall.sh` | `script/init.sh` 的對等：把此 checkout 註冊過的 runner 全部拆掉 + 刪 tarball cache。預設 prompt 確認，`--yes` 跳過，`--dry-run` 預覽。**不**動 org runner-group flag、**不**刪 checkout 本身（詳見 #11） |
| `script/cleanup.sh` | 清掉 GitHub 自動升級循環留下的占空間殘料：陳舊 `bin.X` / `externals.X` 版本目錄、`${RUNNER_HOME}/.bin/` 內的舊版 tarball、`_work/_update*` 殘留、過期的 `_diag/*.log`。可安全排程，**不**動 registration state、進行中的 job 目錄。預設 prompt 確認,`--yes` 跳過,`--dry-run` 預覽。選用 `--work-caches` 會額外修剪**閒置** runner 的 `_work/_tool` / `_work/_actions` 舊 cache 項目(正在跑 job 的 runner 會跳過;需要 `pgrep`) |
| `script/schedule-cleanup.sh` | 安裝／移除 user crontab 內的排程，定時自動跑 `cleanup.sh`（daily / weekly / monthly 可選；時段、星期幾互動選擇）。沒帶參數會進互動模式，也可用 `--every` / `--at` / `--day` 一行帶完。`--status` 看目前排程，`--uninstall` 移除。輸出 append 到 `${RUNNER_HOME}/.cleanup.log`，`flock` 防併發重跑 |

所有 script 皆為 idempotent。

## 設定

Runner 註冊時會讀取選用的設定檔 `${RUNNER_HOME}/setup.conf`（`KEY=value`，可被 shell source）。用 `script/configure.sh` 產生或更新：

```bash
./script/configure.sh --labels gpu,cuda12   # 新註冊 runner 的 labels
./script/configure.sh                         # 印出目前生效的設定
```

`LABELS`（預設 `gpu`）會在註冊當下成為 runner 的 custom labels；系統 label `self-hosted` / `Linux` / `X64` 由 GitHub 一律保留。labels 是 `runs-on` 的路由 key：唯有 job 的 `runs-on` labels 是某 runner labels 的子集，job 才會落到該 runner。

`setup.conf` 只影響寫入之後才註冊的 runner。要即時改既有 runner 的 label（免 remove + 重新註冊），用 `script/set-labels.sh`：

```bash
./script/set-labels.sh org ycpss91255-docker gpu,cuda12
./script/set-labels.sh repo <owner> <repo> gpu,cuda12
```

`script/status.sh` 會在 `LABELS` 欄顯示每個 runner 目前的 labels。

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
   「Require approval for all outside collaborators」）。依 ADR-0011 Public
   repo security 設定。擋住 fork PR 在 runner 上任意執行 code，直到
   maintainer 按「Approve and run」。
2. **Runner group `allows_public_repositories` flag**（各 org 的 Default
   group）。GitHub 2024 起預設 `false`，會把 public repo 的 workflow
   永遠卡在 queued 狀態 — runner 顯示 `online` + idle 但實際不接 job。
   `script/add-runner.sh org <org>` 會把它打開成 `true`，maintainer 觸發的
   dispatch 才會通。

兩個保護同時開 = 跟 GitHub 預設保護等價：外部貢獻者沒被 approve 不能跑，
maintainer 跟受信任 collaborator 可跑。只關一個的話：knob 2 關
→ public repo 工作再次卡死；knob 1 關 → fork PR 漏洞再開。原始分析詳見
#6。

由於 knob 2 會降低 GitHub 的安全預設,`add-runner.sh org` 會**先驗證 knob 1**:
讀取該 org 的 approval gate,若未設為「對所有外部貢獻者要求核准」就**拒絕註冊**,
讓工具不會只降低一邊。要照樣繼續可加 `--force`(代表你接受 fork-PR 風險,
例如純內部 org)。

`script/status.sh` 提供 `PUBLIC-DISPATCH` 欄(knob 2)**與 `APPROVAL-GATE` 欄
(knob 1)**,讓單邊設定一眼可見、不會靜默偏移。

回報安全漏洞請見 [SECURITY.md](../../SECURITY.md)(使用 GitHub 私密漏洞回報,
勿開公開 issue)。

### Runner-user 權限

Workflow job 直接以 runner service user 在 host 上執行，而該 user 屬於
`docker` group —— 這**等同 root**（`docker run -v /:/host …` 即可碰到整台主機）。
對單租戶、自管的 GPU 主機而言這是刻意接受的取捨:真正的安全邊界是**哪些
workflow 被允許執行**(由上述兩個 knob 把關，只有維護者與已核准的 PR 能
dispatch)，而**不是** runner user 的本機權限。由此衍生、且刻意**不**在 repo 內
追的後果:短效的 registration token 會出現在 runner `config.sh` 的命令列上
(其他本機 user 可透過 `ps` 看到 —— 單租戶下非問題)，且 `sudo ./svc.sh` 信任
runner 樹。若這台主機未來要跑不可信的 workflow 或變成多租戶,升級路徑是
**rootless Docker 或 rootless Podman**(不需 `docker` group，daemon 以非特權執行)
—— 可行,但有 GPU + docker-in-docker 的摩擦,屆時再單獨評估。

專用 CI user **本身不構成邊界**。因為 runner user 在 `docker` group(如上,等同
root),另開一個登入帳號、清空 home、或 `chmod 600 ~/.ssh` 都只是裝飾:任何跑起來
的 job 都能 `docker run -v /:/host …` 讀走 operator 的 SSH key、cloud 憑證與
token,跟檔案擁有者無關。專用 CI user 只有在搭配 **rootless**(user 不再是 root)
**或** **host 無機密**(root 沒東西可偷)時才會變成真正的邊界 —— 缺一不可。實際
操作步驟見 [host hardening runbook](../runbook/HOST-HARDENING.md)。

repo 內**有**做的硬化:下載的 actions/runner tarball 在解壓前會比對 GitHub 為該
release asset 公布的 SHA-256(供應鏈檢查,與上述正交)。

## 先決條件

**主機 / 硬體**

- Linux x64（測試過 Ubuntu 22.04）
- NVIDIA GPU —— **選用**。有卡時:host 上 `nvidia-smi` 可執行、
  `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` 須能成功,
  且 runner 預設掛 `gpu` 標籤。無卡時:`script/init.sh` 會自動偵測（無 `nvidia-smi`）、
  跳過 GPU 檢查,並提醒你設非 gpu 標籤（`./script/configure.sh --labels <label>`）。
- Docker（用 GPU 時並需 NVIDIA Container Toolkit）
- 當前使用者在 `docker` group 內（注意:這等同 root —— 見 [Security model](#security-model)）

**CLI 工具**

- `gh`、`jq`、`curl`、`sudo`

**存取 / 網路**

- 一個你具有 **admin/owner 權限的 GitHub organization** ——org-scoped 流程
  (`init.sh <org>` / `add-runner.sh org <org>`)是預設。個人帳號請改註冊
  repo-scoped runner(`init.sh repo <owner> <repo>`,或 `add-runner.sh repo <owner> <repo>`)。
- `gh` 已登入且 token 含 `admin:org` scope（`gh auth login --scopes admin:org`）
- 對 `github.com`、`api.github.com`、`cli.github.com`、`objects.githubusercontent.com` 的對外 HTTPS（runner 下載 + 註冊）
- `sudo` 權限（runner 以 systemd service 安裝）

**安裝先決條件**

Docker 與 NVIDIA Container Toolkit 須先自行安裝（牽涉 kernel driver / repo，本工具刻意不碰），
照 Docker 與 NVIDIA 官方文件即可。之後 `script/install-deps.sh` 會在 apt/Ubuntu host 上
裝好其餘 CLI 工具（`gh`、`jq`、`curl`、`sudo`）並帶你跑 `gh auth login`:

```bash
./script/install-deps.sh            # 每項安裝前先詢問,再做 auth
./script/install-deps.sh -y         # 接受所有安裝提示（apt -y）;auth 仍為互動式
./script/install-deps.sh --dry-run  # 只回報缺什麼,不安裝
```

`script/init.sh` 接著會重新檢查以上全部,任何一項失敗即 exit non-zero（並列出每個缺項）。

## 快速開始

`script/init.sh <your-org>` 會準備好 host 並同時註冊第一個 runner。下面的
`<your-org>` / `<other-org>` 請換成**你自己的 GitHub organization** 名稱
——它們是佔位符,不是字面值。其他 runner 用 `script/add-runner.sh` 新增：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                # 裝 gh/jq/curl/sudo + gh auth login
                                        # （已設定好可略過;Docker+NVIDIA 須先存在）

./script/init.sh <your-org>             # 準備 + 為你的 org 註冊第一個 runner
./script/add-runner.sh org <other-org>  # (選用) 為另一個 org 註冊 runner
./script/status.sh
```

若只想準備環境、暫不註冊（例如 CI lint，或之後再註冊）：

```bash
./script/init.sh   # 不帶 org 參數 = 只 bootstrap
```

org vs repo scope：org runner 服務該 org 下所有 repo;repo runner 只綁定單一 repo。
`script/init.sh` 兩種 scope 都接,所以 repo-level runner 也能一步到位 —— 帶上
`repo <owner> <repo>`,它會準備 host 並註冊該 runner(轉交給 `script/add-runner.sh`)。
沒有 org 的個人帳號就走這條路:

```bash
./script/init.sh repo <owner> <repo>  # 準備 host + runner 綁定 <owner>/<repo>
```

(上面 org 範例裡的 `init.sh <your-org>` 只是 `init.sh org <your-org>` 的簡寫。)

`./script/status.sh` 預期輸出(`APPROVAL-GATE` 欄為 knob 1、`PUBLIC-DISPATCH`
為 knob 2,詳見安全性說明):

```
NAME                               SCOPE  LOCAL-SVC  GITHUB   PUBLIC-DISPATCH   APPROVAL-GATE   LABELS
<hostname>-<your-org>-org          org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
<hostname>-<other-org>-org         org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
```

## 驗證 runner

End-to-end 驗證需要一個 canary workflow 放在跟 runner 同 org 的 repo 內
（GitHub org-level runner 只接受同 org 的 workflow）。立即的健康檢查：`./script/status.sh`
顯示 GitHub 端的 `online` flag，且在 GPU 主機上 `script/init.sh` 已驗證過
`docker run --gpus all nvidia-smi` 在 host 上能跑（偵測不到 GPU 時會跳過）。

## 升級 runner 二進位

```bash
RUNNER_VERSION=<new-version> ./script/update.sh
```

把新版的 versioned runner 檔案 seed 到各 runner 目錄（既有檔案保留原狀）；runner 會在下次連線時透過正常的 self-update 接手新版本。config 跟 credentials 保留。

## 解除安裝

移除**單一** runner(deregister + 卸載 systemd service + 刪目錄):

```bash
./script/remove-runner.sh org <your-org>          # org runner
./script/remove-runner.sh repo <owner> <repo>     # repo runner
```

拆除這個 checkout 註冊過的**全部** runner + 刪 tarball cache(預設會 prompt,
先預覽再確認):

```bash
./script/uninstall.sh --dry-run   # 顯示會移除什麼
./script/uninstall.sh --yes       # 實際移除(非 TTY 必須加)
```

`uninstall.sh` 刻意**不**做:重設 org 的 `allows_public_repositories` runner-group
旗標(可能被其他主機共用)、或刪除這個 checkout。主機消失後 GitHub 端殘留的
`offline` runner 請到 UI 移除(Settings → Actions → Runners → Remove)。卡住的
狀態見[疑難排解](#疑難排解)。

## 重建 SOP

機器遺失 / 重灌後：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh <your-org>
./script/add-runner.sh org <other-org>
```

沒有未記錄的機器狀態。註冊 token 透過 `gh api` 重新申請，舊機器上的 runner
entry 若無法回收，需在 GitHub UI 手動移除（Settings → Actions → Runners →
Remove offline runners）。注意 labels 存在 gitignored 的 `setup.conf`,主機重灌
後不會留存——用 `./script/configure.sh --labels ...` 重新設定(見疑難排解)。

## 疑難排解

on-call 對照表:把 `status.sh` 的每個狀態(`offline` / `not-found` / `n/a` /
`stopped` / `public-BLOCKED`),以及 job 卡 queued、磁碟滿、`gh` auth 過期、
重灌後標籤漂移等情境,對應到成因、第一步診斷指令與修法:
**[doc/runbook/TROUBLESHOOTING.md](../runbook/TROUBLESHOOTING.md)**。

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
