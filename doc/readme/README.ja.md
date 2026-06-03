# github_runner

[![CI](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml/badge.svg)](https://github.com/ycpss91255-docker/github_runner/actions/workflows/ci.yaml)
![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](../../LICENSE)
[![codecov](https://codecov.io/gh/ycpss91255-docker/github_runner/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/github_runner)

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## 目次

- [TL;DR](#tldr)
- [概要](#概要)
- [ディレクトリ構成](#ディレクトリ構成)
- [スクリプト](#スクリプト)
- [設定](#設定)
- [テスト](#テスト)
- [セキュリティモデル](#セキュリティモデル)
- [前提条件](#前提条件)
- [クイックスタート](#クイックスタート)
- [runner の検証](#runner-の検証)
- [runner バイナリのアップグレード](#runner-バイナリのアップグレード)
- [再構築 SOP](#再構築-sop)
- [参考資料](#参考資料)
- [ライセンス](#ライセンス)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # 未ログインの場合

./script/init.sh ycpss91255-docker             # ホスト準備 + 最初の runner を登録
./script/add-runner.sh org ycpss91255-research # 2 つ目の runner を登録
./script/status.sh                             # ローカル + GitHub 側の状態
```

runner state はデフォルトで `<repo_root>/runners/` に置かれます。変更は
`RUNNER_HOME=...` で上書きします。

## 概要

self-hosted GitHub Actions runner をプロビジョニング・管理・撤去するツール
です。org / repo レベルの runner の登録・削除、systemd service としての
インストール、runner バイナリのキャッシュとアップグレード、ローカル +
GitHub 側の状態のレポート、自動アップグレードの残骸のクリーンアップを行い
ます。1 つの clone が `<repo_root>/runners/` 配下のすべての runner state を
所有し、すべてのスクリプトは idempotent です。

スクリプトは汎用的で、任意の org / repo を渡せます。`ycpss91255-research` と
`ycpss91255-docker` の 2 org は全文を通じて具体例にすぎず（作者が運用している
org）、ハードコードされていません。

## ディレクトリ構成

デフォルトではすべての runner state は `<repo_root>/runners/` 配下
（このチェックアウトの隣、gitignore 済み）に置かれます。1 つの clone で
すべての状態を所有し、別途 `~/github_runner` ディレクトリは不要です。

```
<repo_root>/runners/                                   # デフォルト RUNNER_HOME
├── .bin/
│   └── actions-runner-linux-x64-<version>.tar.gz      # キャッシュ済み tarball
├── ycpss91255-docker/
│   └── _org/                                          # org-level runner
└── ycpss91255-research/
    └── _org/                                          # org-level runner
```

`_org` は「その org の org-level runner」を意味します。Repo-level runner は
`<org>/<repo>/` に配置されます。

インストール先を変更したい場合は、スクリプトを実行する前に `RUNNER_HOME`
を export してください（例：`RUNNER_HOME=/var/lib/gh-runners ./script/init.sh ...`）。

## スクリプト

| Script | 用途 |
|---|---|
| `script/install-deps.sh` | apt/Ubuntu ホストに CLI 前提条件（`gh`、`jq`、`curl`、`sudo`）をインストールし `gh auth login` を実行。`-y` ですべてのインストール確認を承認;`--dry-run` は不足分の報告のみ。Docker と NVIDIA Container Toolkit はインストール済み前提。冪等 |
| `script/init.sh` | ホストの前提条件チェック、GitHub API 経由で actions/runner の最新 release を解決し（gh 不在 / 未認証 / オフライン時は同梱の pinned バージョンにフォールバック）、`<repo_root>/runners/.bin/`（= `$RUNNER_HOME/.bin/`）にキャッシュ。`RUNNER_VERSION=...` で上書き可能。org 引数を渡せば最初の runner も同時に登録 |
| `script/add-runner.sh` | 新しい runner を登録。使い方：`org <org>` または `repo <owner> <repo>`。labels は `setup.conf` から取得（デフォルト `gpu`、設定を参照）。`org` スコープでは Default runner group の `allows_public_repositories=true` も同時に有効化し、public リポジトリの workflow がディスパッチできるようにする（下記セキュリティモデルを参照） |
| `script/configure.sh` | `${RUNNER_HOME}/setup.conf` を生成／更新。`--labels <csv>` で新規登録 runner の labels を設定、引数なしで現在有効な設定を表示 |
| `script/set-labels.sh` | GitHub API 経由で既存 runner の labels をライブで変更（remove + 再登録は不要）。使い方：`org <org> <csv>` または `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | 登録解除 + systemd service の uninstall + ディレクトリ削除 |
| `script/status.sh` | 登録済み runner のローカル + GitHub 側の状態と現在の labels を一覧表示。`-w`/`--watch` で継続的にリフレッシュ（`-i`/`--interval` で間隔指定、デフォルト 5 秒）し、行単位で差分をハイライト；`--no-color` で色を無効化 |
| `script/update.sh` | actions/runner の最新 release（または `RUNNER_VERSION=...`、init と同じフォールバック）を解決し、キャッシュになければダウンロード、その後 versioned な新しい runner ファイルを各 runner ディレクトリに seed（既存ファイルはそのまま残す）。runner は次回接続時に通常の self-update で新バージョンを取り込む。config は保持 |
| `script/uninstall.sh` | `script/init.sh` の対となるスクリプト：このチェックアウトから登録したすべての runner をテアダウン + キャッシュ tarball を削除。デフォルトでは確認プロンプト、`--yes` でスキップ、`--dry-run` でプレビュー。org runner-group フラグの変更や checkout 自体の削除は **行いません**（#11 参照） |
| `script/cleanup.sh` | GitHub の自動更新サイクルで溜まるディスク食いの残骸を掃除：古い `bin.X` / `externals.X` バージョンディレクトリ、`${RUNNER_HOME}/.bin/` 内の古いキャッシュ tarball、`_work/_update*` の残り物。スケジュール実行しても安全 — 登録 state、ログ、進行中の job ディレクトリには **触れません**。デフォルトでは確認プロンプト、`--yes` でスキップ、`--dry-run` でプレビュー |
| `script/schedule-cleanup.sh` | user crontab に `cleanup.sh` の定期実行エントリをインストール／削除する（daily / weekly / monthly から選択、時刻と曜日もインタラクティブに指定可）。引数なしでインタラクティブモード、`--every` / `--at` / `--day` を渡せば一発で完了。`--status` で現在のエントリを表示、`--uninstall` で削除。出力は `${RUNNER_HOME}/.cleanup.log` に append、`flock` で重複実行をブロック |

すべてのスクリプトは idempotent です。

## 設定

runner の登録時に、オプションの設定ファイル `${RUNNER_HOME}/setup.conf`（`KEY=value`、shell で source 可能）を読み込みます。`script/configure.sh` で生成・更新します：

```bash
./script/configure.sh --labels gpu,cuda12   # 新規登録 runner の labels
./script/configure.sh                         # 現在有効な設定を表示
```

`LABELS`（デフォルト `gpu`）は登録時に runner の custom labels になります。システム label `self-hosted` / `Linux` / `X64` は GitHub が常に保持します。labels は `runs-on` のルーティングキーです：job の `runs-on` labels がある runner の labels の部分集合である場合にのみ、その runner で job が実行されます。

`setup.conf` は書き込み後に登録される runner にのみ影響します。既存 runner の label をライブで変更する（remove + 再登録なし）には `script/set-labels.sh` を使います：

```bash
./script/set-labels.sh org ycpss91255-docker gpu,cuda12
./script/set-labels.sh repo <owner> <repo> gpu,cuda12
```

`script/status.sh` は各 runner の現在の labels を `LABELS` 列に表示します。

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

## セキュリティモデル

Self-hosted runner 上での public リポジトリの workflow ディスパッチに
ついて、GitHub には揃えるべき 2 つのスイッチがあります：

1. **外部コントリビューター approval gate**（org Settings → Actions →
   General → 「Require approval for all outside collaborators」）。
   ADR-0011 Public repo security に従って設定。fork PR が runner 上で
   任意のコードを実行することを、maintainer が「Approve and run」を
   クリックするまでブロックします。
2. **Runner group `allows_public_repositories` フラグ**（各 org の
   Default group）。GitHub の 2024 年以降のデフォルトは `false` で、
   runner が `online` + idle に見えても public リポジトリの workflow
   が永遠に queued のままになります。`script/add-runner.sh org <org>` はこれを
   `true` に切り替え、maintainer がトリガーする正当なディスパッチを
   通します。

両方の保護を同時に有効化することで GitHub のデフォルト保護と等価になり
ます：外部コントリビューターは承認なしでは実行できず、maintainer と
信頼できるコラボレーターは実行できます。片方だけ閉じると、knob 2 オフ
で public リポジトリのジョブが再びストランドし、knob 1 オフで fork PR
の穴が再び開きます。元の分析は #6 を参照。

`script/status.sh` は `PUBLIC-DISPATCH` カラムを表示し、各 org の knob 2 状態
を可視化することで設定の静かなドリフトを防ぎます。

### Runner ユーザーの権限

Workflow ジョブは runner サービスユーザーとしてホスト上で直接実行され、その
ユーザーは `docker` group に属します —— これは **root 相当**です（`docker run
-v /:/host …` でホスト全体に到達できます）。シングルテナントで自己管理の GPU
ホストでは、これは意図的なトレードオフです。本当のセキュリティ境界は**どの
workflow の実行を許すか**（上記 2 つの knob で制御し、メンテナと承認済み PR
のみ dispatch 可能）であり、runner ユーザーのローカル権限**ではありません**。
ここから派生し、リポジトリ内で意図的に**追わない**帰結:短命の registration
token は runner の `config.sh` にコマンドライン引数として渡され（他のローカル
ユーザーから `ps` で見える —— シングルテナントでは非問題）、`sudo ./svc.sh` は
runner ツリーを信頼します。将来このホストで信頼できない workflow を実行する、
あるいはマルチテナントにする場合の移行先は **rootless Docker または rootless
Podman**（`docker` group 不要、daemon を非特権で実行）です —— 可能ですが GPU +
docker-in-docker の摩擦があるため、その時点で別途評価してください。

リポジトリ内で**実施している**ハードニング:ダウンロードした actions/runner
tarball は、展開前に GitHub が release asset 向けに公開する SHA-256 と照合され
ます（サプライチェーンチェック、上記とは独立）。

## 前提条件

**ホスト / ハードウェア**

- Linux x64（テスト済み：Ubuntu 22.04）
- NVIDIA GPU —— **任意**。GPU ありの場合：ホスト上で `nvidia-smi` が実行でき、
  `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` が成功すること。
  runner は既定で `gpu` ラベルになります。GPU なしの場合：`script/init.sh` が自動検出
  （`nvidia-smi` なし）して GPU チェックをスキップし、非 gpu ラベルの設定を促します
  （`./script/configure.sh --labels <label>`）。
- Docker（GPU 利用時は NVIDIA Container Toolkit も）
- 現在のユーザーが `docker` group に所属（注意：これは root 相当 —— [Security model](#security-model) 参照）

**CLI ツール**

- `gh`、`jq`、`curl`、`sudo`

**アクセス / ネットワーク**

- `gh` が認証済みで token に `admin:org` scope を含む（`gh auth login --scopes admin:org`）
- `github.com`、`api.github.com`、`cli.github.com`、`objects.githubusercontent.com` への外向き HTTPS（runner のダウンロード + 登録）
- `sudo` 権限（runner は systemd service として導入）

**前提条件のインストール**

Docker と NVIDIA Container Toolkit は先に各自で導入してください（kernel driver / repo が
絡むため、本ツールは意図的に触れません）。Docker と NVIDIA の公式手順に従えば OK です。
その後 `script/install-deps.sh` が apt/Ubuntu ホストで残りの CLI ツール（`gh`、`jq`、`curl`、
`sudo`）を導入し、`gh auth login` まで案内します：

```bash
./script/install-deps.sh            # 各インストール前に確認し、その後 auth
./script/install-deps.sh -y         # すべてのインストール確認を承認（apt -y）；auth は対話式のまま
./script/install-deps.sh --dry-run  # 不足分を報告するのみ、インストールしない
```

`script/init.sh` はその後、上記すべてを再チェックし、いずれかが失敗すると non-zero で
exit します（不足項目をすべて列挙）。

## クイックスタート

`script/init.sh <org>` はホスト準備と同時に最初の runner を登録します。追加の
runner は `script/add-runner.sh` で登録：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                       # gh/jq/curl/sudo + gh auth login を導入
                                               # （設定済みならスキップ可；Docker+NVIDIA は事前に必要）

./script/init.sh ycpss91255-docker             # 準備 + 最初の runner（-docker org）
./script/add-runner.sh org ycpss91255-research # 2 つ目の runner（-research org）
./script/status.sh
```

準備のみ、登録を後回しにする場合（CI lint や後で登録する場合）：

```bash
./script/init.sh   # org 引数なし = bootstrap のみ
```

org スコープ vs repo スコープ：org runner は org 配下の全 repo を、repo runner は
単一 repo のみを担当します。`script/init.sh` は org スコープの最初の runner しか
登録しないため、repo スコープの runner はホスト準備後に `script/add-runner.sh` で
明示的に登録します：

```bash
./script/init.sh                                      # 準備のみ（org 引数なし、上記と同じ）
./script/add-runner.sh repo ycpss91255-docker my-repo # ycpss91255-docker/my-repo に紐づく runner
```

`./script/status.sh` の想定出力：

```
NAME                                     SCOPE      LOCAL-SVC  GITHUB     PUBLIC-DISPATCH  LABELS
<hostname>-ycpss91255-docker-org         org        running    online     public-ok        self-hosted,Linux,X64,gpu
<hostname>-ycpss91255-research-org       org        running    online     public-ok        self-hosted,Linux,X64,gpu
```

## runner の検証

End-to-end 検証には、runner と同じ org のリポジトリ内にある canary
workflow が必要です（GitHub の org-level runner は同 org の workflow
からのみ呼び出せます）。即時のサニティチェック：`./script/status.sh`
の GitHub 側 `online` フラグ、および GPU ホストでは `script/init.sh` が
`docker run --gpus all nvidia-smi` のホスト動作をすでに検証済みです
（GPU が検出されない場合はスキップ）。

## runner バイナリのアップグレード

```bash
RUNNER_VERSION=<new-version> ./script/update.sh
```

versioned な新しい runner ファイルを各 runner ディレクトリに seed します
（既存ファイルはそのまま残す）。runner は次回接続時に通常の self-update で
新バージョンを取り込みます。config と credentials は保持されます。

## 再構築 SOP

マシン消失 / OS 再インストール後：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh ycpss91255-docker
./script/add-runner.sh org ycpss91255-research
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
