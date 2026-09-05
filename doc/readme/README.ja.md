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
- [アンインストール](#アンインストール)
- [再構築 SOP](#再構築-sop)
- [トラブルシューティング](#トラブルシューティング)
- [参考資料](#参考資料)
- [ライセンス](#ライセンス)

## TL;DR

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
gh auth login --scopes admin:org        # 未ログインの場合

./script/init.sh <your-org>             # ホスト準備 + 最初の runner を登録
./script/add-runner.sh org <other-org>  # (任意) 別の org 用の runner を登録
./script/status.sh                      # ローカル + GitHub 側の状態
```

`<your-org>` は**あなた自身の GitHub organization**(アカウント名、例:
`my-company`)です——repo でも本プロジェクト名でもありません。**admin/owner**
権限を持つ GitHub org が必要です。org がない(個人アカウントの)場合は repo-scoped
runner を登録してください ——[クイックスタート](#クイックスタート)を参照。

先に設定すべき 2 点(さもないと初回実行が中断 / job が queued のまま):

- **承認ゲート**——org runner では先に *Settings → Actions → General →
  「Require approval for all outside collaborators」* を有効化してください。
  さもないと `add-runner.sh org` は登録を拒否します(`--force` で上書き可)。
  セキュリティモデル参照。
- **ラベル**——デフォルトラベルは `gpu`。GPU の無いホストでは先にラベルを
  設定(`./script/configure.sh --labels <label>`)してください。さもないと
  `gpu` を指定しない job は無言で `queued` のままになります。

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
| `script/init.sh` | ホストの前提条件チェック、GitHub API 経由で actions/runner の最新 release を解決し（gh 不在 / 未認証 / オフライン時は同梱の pinned バージョンにフォールバック）、`<repo_root>/runners/.bin/`（= `$RUNNER_HOME/.bin/`）にキャッシュ。`RUNNER_VERSION=...` で上書き可能。scope 引数を渡すとそのまま `add-runner.sh` に転送して最初の runner も登録：`org <org>`、`repo <owner> <repo>`、または org 名のみ（`org` 形式の短縮形）|
| `script/add-runner.sh` | 新しい runner を登録。使い方：`[--force] org <org>` または `repo <owner> <repo>`。labels は `setup.conf` から取得（デフォルト `gpu`、設定を参照）。`org` スコープでは外部コントリビューター承認ゲートを検証してから Default runner group の `allows_public_repositories=true` を有効化し public リポジトリの workflow をディスパッチ可能にする；ゲート未設定なら**拒否**(`--force` で上書き、下記セキュリティモデル参照） |
| `script/configure.sh` | `${RUNNER_HOME}/setup.conf` を生成／更新。`--labels <csv>` で新規登録 runner の labels を設定、引数なしで現在有効な設定を表示 |
| `script/set-labels.sh` | GitHub API 経由で既存 runner の labels をライブで変更（remove + 再登録は不要）。使い方：`org <org> <csv>` または `repo <owner> <repo> <csv>` |
| `script/remove-runner.sh` | 登録解除 + systemd service の uninstall + ディレクトリ削除。デフォルトでは確認プロンプト、`--yes` でスキップ、`--dry-run` でプレビュー |
| `script/status.sh` | 登録済み runner のローカル + GitHub 側の状態と現在の labels を一覧表示。`-w`/`--watch` で継続的にリフレッシュ（`-i`/`--interval` で間隔指定、デフォルト 5 秒）し、行単位で差分をハイライト；`--no-color` で色を無効化 |
| `script/update.sh` | actions/runner の最新 release（または `RUNNER_VERSION=...`、init と同じフォールバック）を解決し、キャッシュになければダウンロード、その後 versioned な新しい runner ファイルを各 runner ディレクトリに seed（既存ファイルはそのまま残す）。runner は次回接続時に通常の self-update で新バージョンを取り込む。config は保持 |
| `script/uninstall.sh` | `script/init.sh` の対となるスクリプト：このチェックアウトから登録したすべての runner をテアダウン + キャッシュ tarball を削除。デフォルトでは確認プロンプト、`--yes` でスキップ、`--dry-run` でプレビュー。org runner-group フラグの変更や checkout 自体の削除は **行いません**（#11 参照） |
| `script/cleanup.sh` | GitHub の自動更新サイクルで溜まるディスク食いの残骸を掃除：古い `bin.X` / `externals.X` バージョンディレクトリ、`${RUNNER_HOME}/.bin/` 内の古いキャッシュ tarball、`_work/_update*` の残り物、期限切れの `_diag/*.log`。スケジュール実行しても安全 — 登録 state、進行中の job ディレクトリには **触れません**。デフォルトでは確認プロンプト、`--yes` でスキップ、`--dry-run` でプレビュー。オプションの `--work-caches` は**アイドルな** runner の `_work/_tool` / `_work/_actions` の古いキャッシュ項目も削除(job 実行中の runner はスキップ;`pgrep` が必要) |
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

self-test のエントリは root `justfile` です。base リポジトリの慣例に合わせ
ています（base も self-test エントリを `just` へ移行済み）。

```bash
just pull       # test-tools + kcov イメージを pull（初回）
just lint       # shellcheck（docker 内）
just test       # bats smoke tests（docker 内）
just check      # lint + test（coverage を含まない）
just coverage   # bats + kcov カバレッジ → ./coverage/
just            # recipe 一覧
```

ホスト直接実行（`shellcheck` / `bats` のローカルインストールが必要）：

```bash
just lint-host
just test-host
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
   fork PR が runner 上で任意のコードを実行することを、maintainer が
   「Approve and run」をクリックするまでブロックします。
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

knob 2 は GitHub の安全なデフォルトを下げるため、`add-runner.sh org` は
**まず knob 1 を検証**します:org の承認ゲートを読み取り、「すべての外部
コントリビューターに承認を要求」に設定されていなければ**登録を拒否**します
(片方だけ下げることがないように)。`--force` で続行可(fork-PR の露出を
受け入れる場合 — 例:内部専用 org)。

`script/status.sh` は `PUBLIC-DISPATCH` カラム(knob 2)**と `APPROVAL-GATE`
カラム(knob 1)**を表示し、片側だけの設定が一目で分かり静かにドリフトしない
ようにします。

脆弱性の報告は [SECURITY.md](../../SECURITY.md) を参照(公開 issue ではなく
GitHub のプライベート脆弱性報告を使用)。

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

専用 CI ユーザーは**それ自体では境界になりません**。runner ユーザーが `docker`
group に属する（上記のとおり root 相当）ため、ログインを分ける・home を空にする・
`chmod 600 ~/.ssh` といった対策は見かけだけです:実行されるジョブは `docker run -v
/:/host …` で operator の SSH 鍵・クラウド認証情報・トークンを所有者に関係なく読め
ます。専用 CI ユーザーが本当の境界になるのは、**rootless**（ユーザーがもはや root
でない）**または** **ホストに機密を置かない**（root が盗む物を持たない）と組み合わ
せたときだけで、どちらか一方では不十分です。具体的な手順は
[host hardening runbook](../runbook/HOST-HARDENING.md) を参照してください。

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

- **admin/owner 権限を持つ GitHub organization**。org-scoped フロー
  (`init.sh <org>` / `add-runner.sh org <org>`)がデフォルトです。個人
  アカウントの場合は repo-scoped runner（`init.sh repo <owner> <repo>`、または
  `add-runner.sh repo <owner> <repo>`）を登録してください。
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

`script/init.sh <your-org>` はホスト準備と同時に最初の runner を登録します。
以下の `<your-org>` / `<other-org>` は**あなた自身の GitHub organization** 名に
置き換えてください——プレースホルダであり、そのままの値ではありません。追加の
runner は `script/add-runner.sh` で登録：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/install-deps.sh                # gh/jq/curl/sudo + gh auth login を導入
                                        # （設定済みならスキップ可；Docker+NVIDIA は事前に必要）

./script/init.sh <your-org>             # 準備 + あなたの org 用の最初の runner
./script/add-runner.sh org <other-org>  # (任意) 別の org 用の runner
./script/status.sh
```

準備のみ、登録を後回しにする場合（CI lint や後で登録する場合）：

```bash
./script/init.sh   # org 引数なし = bootstrap のみ
```

org スコープ vs repo スコープ：org runner は org 配下の全 repo を、repo runner は
単一 repo のみを担当します。`script/init.sh` はどちらの scope も受け付けるため、
repo レベルの runner も一括で登録できます —— `repo <owner> <repo>` を渡せば
ホスト準備と runner 登録を同時に行います（`script/add-runner.sh` に転送）。org を
持たない個人アカウントはこの方法を使ってください：

```bash
./script/init.sh repo <owner> <repo>  # ホスト準備 + <owner>/<repo> に紐づく runner
```

（上記 org の例の `init.sh <your-org>` は `init.sh org <your-org>` の短縮形です。）

`./script/status.sh` の想定出力(`APPROVAL-GATE` カラムが knob 1、
`PUBLIC-DISPATCH` が knob 2、セキュリティモデル参照):

```
NAME                               SCOPE  LOCAL-SVC  GITHUB   PUBLIC-DISPATCH   APPROVAL-GATE   LABELS
<hostname>-<your-org>-org          org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
<hostname>-<other-org>-org         org    running    online   public-ok         gate-ok         self-hosted,Linux,X64,gpu
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

## アンインストール

**単一**の runner を削除(登録解除 + systemd service の uninstall + ディレクトリ削除)。
デフォルトはプロンプト。まずプレビューしてから確定:

```bash
./script/remove-runner.sh --dry-run org <your-org>   # 削除対象を表示
./script/remove-runner.sh org <your-org>             # org runner(プロンプトあり)
./script/remove-runner.sh repo <owner> <repo>        # repo runner(プロンプトあり)
./script/remove-runner.sh --yes org <your-org>       # プロンプトを省略(非 TTY では必須)
```

この checkout が登録した**すべて**の runner + キャッシュ tarball を撤去
(デフォルトはプロンプト。まずプレビューしてから確定):

```bash
./script/uninstall.sh --dry-run   # 削除対象を表示
./script/uninstall.sh --yes       # 実際に削除(非 TTY では必須)
```

`uninstall.sh` が意図的に**行わない**こと:org の `allows_public_repositories`
runner-group フラグのリセット(他ホストと共有の可能性)、この checkout 自体の
削除。ホスト消失後に GitHub 側へ残る `offline` runner は UI で削除してください
(Settings → Actions → Runners → Remove)。詰まった状態は[トラブルシューティング](#トラブルシューティング)参照。

## 再構築 SOP

マシン消失 / OS 再インストール後：

```bash
git clone https://github.com/ycpss91255-docker/github_runner.git && cd github_runner
./script/init.sh <your-org>
./script/add-runner.sh org <other-org>
```

未記録のマシン状態はありません。登録トークンは `gh api` で都度取得する
ため、旧マシンの runner エントリーが残っている場合は GitHub UI から
手動で削除してください（Settings → Actions → Runners → Remove offline
runners）。labels は gitignore された `setup.conf` にあり、ホスト消去後は
残らないため `./script/configure.sh --labels ...` で再設定してください
(トラブルシューティング参照)。

## トラブルシューティング

on-call 向け対応表:`status.sh` の各状態(`offline` / `not-found` / `n/a` /
`stopped` / `public-BLOCKED`)に加え、job が queued のまま・ディスク満杯・
`gh` 認証切れ・再構築後のラベルドリフトなどの状況を、原因・最初の診断コマンド・
対処にマッピング:**[doc/runbook/TROUBLESHOOTING.md](../runbook/TROUBLESHOOTING.md)**。

## 参考資料

- GitHub docs: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub docs: [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)

## ライセンス

[Apache-2.0](../../LICENSE) — [ycpss91255-docker/base] および org 内の
他のリポジトリと整合。

[ycpss91255-docker/base]: https://github.com/ycpss91255-docker/base
