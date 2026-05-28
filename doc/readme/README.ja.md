# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../../LICENSE)
[![codecov](https://codecov.io/gh/ycpss91255-docker/github_runner/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/github_runner)

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

`ycpss91255-research` および `ycpss91255-docker` の 2 つの org 向けに、
self-hosted GitHub Actions runner をプロビジョニングするツールです。
上位 workspace repo の [ADR-0012] の tooling セクションを実装しています。

このリポジトリが `ycpss91255-docker` に属するのは、runner のプロビジョニ
ングがホスト環境 / インフラ層に該当するためです（docker と research の
org 境界の解釈については ADR-0012 を参照）。

## 目次

- [クイックスタート](#クイックスタート)
- [ディレクトリ構成](#ディレクトリ構成)
- [スクリプト](#スクリプト)
- [前提条件](#前提条件)
- [テスト](#テスト)
- [runner の検証](#runner-の検証)
- [runner バイナリのアップグレード](#runner-バイナリのアップグレード)
- [再構築 SOP](#再構築-sop)
- [参考資料](#参考資料)

## ディレクトリ構成

```
~/github_runner/                                       # ローカルインストール位置
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # キャッシュ済み tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` は「その org の org-level runner」を意味します。Repo-level runner は
`<org>/<repo>/` に配置されます。

## スクリプト

| Script | 用途 |
|---|---|
| `init.sh` | ホストの前提条件チェック、runner tarball を `~/github_runner/.bin/` にキャッシュ。org 引数を渡せば最初の runner も同時に登録 |
| `add-runner.sh` | 新しい runner を登録。使い方：`org <org>` または `repo <owner> <repo>` |
| `remove-runner.sh` | 登録解除 + systemd service の uninstall + ディレクトリ削除 |
| `status.sh` | 登録済み runner のローカル + GitHub 側の状態を一覧表示 |
| `update.sh` | すべての runner の binary をアップグレード（config は保持） |

すべてのスクリプトは idempotent です。

## テスト

テストは `ghcr.io/ycpss91255-docker/test-tools` イメージ内で実行します
（alpine + bats + shellcheck + hadolint、`ycpss91255-docker/base` と
同じイメージ）。カバレッジは `kcov/kcov` イメージ内で実行します
（Debian、`kcov` 同梱；`bats` は実行時に apt インストール）。ローカルと
CI で同じイメージを共有します。

Makefile は `Makefile.ci` にリネーム（top-level の `Makefile` なし）。
base リポジトリの慣例に合わせて常に `-f Makefile.ci` 経由で呼び出します。

```bash
make -f Makefile.ci pull       # test-tools + kcov イメージを pull（初回）
make -f Makefile.ci lint       # shellcheck（docker 内）
make -f Makefile.ci test       # bats smoke tests（docker 内）
make -f Makefile.ci check      # lint + test（coverage を含まない）
make -f Makefile.ci coverage   # bats + kcov カバレッジ → ./coverage/
make -f Makefile.ci help       # ターゲット一覧
```

ホスト直接実行（`shellcheck` / `bats` のローカルインストールが必要）：

```bash
make -f Makefile.ci lint-host
make -f Makefile.ci test-host
```

CI は push / PR ごとに `lint` + `test` を実行し、**main への push 時のみ
`coverage` を実行** します（kcov はプレーンな bats より 2-5 倍遅いため、
リリース品質のシグナルとして留保）。Codecov アップロードは
`CODECOV_TOKEN` の repo secret 経由です。

## 前提条件

- Linux x64（テスト済み：Ubuntu 22.04）
- GPU runtime を含む Docker（`docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` が動作すること）
- ホスト上で `nvidia-smi` が実行可能
- `gh` CLI が認証済みで token に `admin:org` scope を含む
- 現在のユーザーが `docker` group に所属
- `curl`、`jq`、`sudo` がインストール済み

`init.sh` は上記すべてをチェックし、いずれかが失敗すると non-zero で
exit します。

## クイックスタート

`init.sh <org>` はホスト準備と同時に最初の runner を登録します。追加の
runner は `add-runner.sh` で登録：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
gh auth login --scopes admin:org   # 未認証の場合

./init.sh ycpss91255-docker             # 準備 + 最初の runner（-docker org）
./add-runner.sh org ycpss91255-research # 2 つ目の runner（-research org）
./status.sh
```

準備のみ、登録を後回しにする場合（CI lint や後で登録する場合）：

```bash
./init.sh   # org 引数なし = bootstrap のみ
```

`./status.sh` の想定出力：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB
<hostname>-ycpss91255-docker-org         org        running    online
<hostname>-ycpss91255-research-org       org        running    online
```

## runner の検証

End-to-end 検証には、runner と同じ org のリポジトリ内にある canary
workflow が必要です（GitHub の org-level runner は同 org の workflow
からのみ呼び出せます）。canary の配置は設計中 — 上位 issue / ADR-0012
の現在の決定を参照してください。即時のサニティチェック：`./status.sh`
の GitHub 側 `online` フラグ、および `init.sh` が `docker run --gpus
all nvidia-smi` のホスト動作をすでに検証済みです。

## runner バイナリのアップグレード

```bash
RUNNER_VERSION=<new-version> ./update.sh
```

各 runner の service を停止 → バイナリを置き換え → 再起動。config と
credentials は保持されます。

## 再構築 SOP

マシン消失 / OS 再インストール後：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git ~/github_runner
cd ~/github_runner
./init.sh ycpss91255-docker
./add-runner.sh org ycpss91255-research
```

未記録のマシン状態はありません。登録トークンは `gh api` で都度取得する
ため、旧マシンの runner エントリーが残っている場合は GitHub UI から
手動で削除してください（Settings → Actions → Runners → Remove offline
runners）。

## 参考資料

- [ADR-0011] — 元の CI アーキテクチャ（改訂済み）
- [ADR-0012] — research org の分離 + dual org-level runner（本リポジト
  リは tooling セクションの実装）
- GitHub docs: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs: [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## ライセンス

[Apache-2.0](../../LICENSE) — [ycpss91255-docker/base] および org 内の
他のリポジトリと整合。

[ADR-0011]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0011-ci-architecture-with-self-hosted-gpu-runner.md
[ADR-0012]: https://github.com/ycpss91255-research/isaac/blob/main/doc/adr/0012-research-org-split-dual-org-runners.md
[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
