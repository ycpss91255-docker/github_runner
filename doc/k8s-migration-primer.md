# Kubernetes 遷移入門 primer（給 github_runner 的未來方向）

## 這份文件在幹嘛（先讀這段）

這是一份**自學用的參考資料 + 方向判斷**，不是產品文件、也還沒是決議。

背景：`github_runner` 目前是「單一主機、bash + 一小塊 Go」的 ephemeral self-hosted
runner 工具（ADR-0001~0003）。在討論「一台開多個 runner 並行 / 用滿閒置資源 /
動態調整 / 未來還想涵蓋 GitLab / GPU 一卡多 job」時，發現這些需求**集體指向
Kubernetes（k8s）**——因為那正是 k8s 的本業。

這份文件的用途是：
1. 讓你**用已經懂的 bespoke 設計去對照學 k8s**（降低入門門檻）；
2. 給你一條**由淺入深、對到你情境**的官方學習路徑（附連結）；
3. 記錄「**為什麼你的需求指向 k8s**」的判斷，之後要不要遷移時當評估依據。

> **決策狀態（2026-07-07）**：已在 **[ADR-0004](adr/0004-defer-k8s-with-tripwires.md)**
> 記錄——**現在維持 bespoke，k8s 是「觸發線後」的計畫終點**（不是現在、也不是永不）。
> 那份 ADR 完整記錄了團隊規模、負載、機群類型、A/B 比例趨勢等決策依據。這份 primer
> 是搭配它的**自學材料**：等觸發線接近、要真的規劃遷移時再回來精讀。

---

## k8s 是單機還是多機用的？

**本質是多機（叢集）**。k8s 的核心價值就是把很多台機器（**node**）併成一個叢集，
由 **scheduler** 自動把工作（**pod**）排到「還有空閒資源」的機器上。

但它**也能單機跑**（control-plane + worker 同一台；用 k3s 幾乎零負擔）。所以你可以：

- **現在**：單機起一個 k3s（單 node 叢集）。
- **未來**：加機器時，只要把新機器 `join` 進叢集當 node，**scheduler 自動開始往上面塞
  job，你的 runner / pod 定義完全不用改**。

> 這就是決定性的一點：你「現在單機、預期多機展開」的路線，正是 k8s 為之而生的情境。
> 反過來說，現在這套 **bespoke 單機設計要擴到多機，等於得自己造一個跨主機排程器
> ——而那就是 k8s**。所以多機預期基本上把選擇推向 k8s。

---

## 為什麼你的需求指向 k8s（用你已懂的東西對照）

| 你剛親手建的 bespoke | k8s 對應 | 一句話 |
|---|---|---|
| listener（Go 腦，監看要跑什麼去生容器） | **Controller / Operator** | 監看需求、生 workload |
| 每個 job 一個用後即丟的容器 | **Pod** | 排程與隔離的最小單位 |
| per-runner-type 設定（labels/image/devices…） | **Pod spec + 資源 requests/limits** | 每型宣告要多少 CPU/GPU/記憶體 |
| 自動 sizing pool（依裝置數） | **Scheduler + requests/limits + autoscaler** | 依「宣告需求 vs 節點空閒」自動塞 = 你要的動態 packing |
| 硬化旗標（cap-drop / no-new-priv / seccomp） | **SecurityContext / Pod Security / seccomp** | 同一組東西，k8s 的講法 |
| 「不 idle、塞滿資源」 | **bin-packing scheduler** | k8s 內建，正是你要動態化的那件事 |
| 跨主機展開 | **多 node 叢集** | 加 node 即擴，定義不變 |

你提出的三個需求，逐一對到 k8s 現成能力：

1. **動態、依即時空閒塞 job（CPU/GPU 都能多開）** → scheduler 依每個 pod 的
   **requests/limits** 與節點剩餘資源自動放置。**不用維護靜態數字**（正是你嫌靜態易過時的痛點）。
2. **通用、涵蓋 GitHub + GitLab** → 兩邊在 k8s 上「各插一個 controller」：GitHub 用
   **ARC**、GitLab 用 **Kubernetes executor**，跑在同一個叢集、共用同一批資源與排程。
3. **GPU 一卡多 job** → NVIDIA device plugin + **time-slicing（軟共享）** 或
   **MIG（硬體切分、有記憶體隔離）**。

> 附帶認知：**ARC 其實就是我們 bespoke listener 的「GitHub 官方 k8s 版」**。等於你自幹的那套
> 概念，k8s 上有現成且維護好的實作可用。

---

## 學習路徑（由淺入深，對到你的目標）

### ① 基本心智模型（先讀，約 1–2 小時）
- [Learn Kubernetes Basics（官方互動教學）](https://kubernetes.io/docs/tutorials/kubernetes-basics/) — 最快建立整體概念
- [Cluster Architecture（control plane + nodes）](https://kubernetes.io/docs/concepts/architecture/)
- [Pods](https://kubernetes.io/docs/concepts/workloads/pods/)

### ② 你的核心：資源排程（「動態 packing」的原理）
- [Kubernetes 概念總覽](https://kubernetes.io/docs/concepts/)
- [Schedule GPUs / 資源與排程](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
  — **重點抓一句**：每個 job 宣告 `requests`（要多少），scheduler 看節點還剩多少，
  剛好塞得下就放。懂這句就懂了動態、不 idle、免維護靜態數字。

### ③ 單主機落地（你是單機起步 → 用 k3s，別上完整 k8s）
- [k3s 官方文件](https://docs.k3s.io/)
- [k3s Quick-Start](https://docs.k3s.io/quick-start) — 一顆 <100MB binary、單機就是完整叢集，
  跟你「單主機、簡單」的初衷最接近；未來加 node 即變多機。

### ④ CI runner 跑在 k8s（你的兩個平台）
- GitHub：[Get started with Actions Runner Controller (ARC)](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/get-started)
  ／ [ARC 概念](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)
  ／ [ARC repo](https://github.com/actions/actions-runner-controller)
- GitLab：[Kubernetes executor](https://docs.gitlab.com/runner/executors/kubernetes/)
  ／ [GitLab Runner Helm chart](https://docs.gitlab.com/runner/install/kubernetes/)

### ⑤ GPU 一卡多 job（你的第三點）
- [Kubernetes: Schedule GPUs](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
- [NVIDIA device plugin for Kubernetes](https://github.com/nvidia/k8s-device-plugin)
- [Time-Slicing GPUs（NVIDIA 官方）](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html)
  — **關鍵區別**：
  - **Time-slicing**：軟切分、**無**記憶體/故障隔離（輕量共享，會互搶 VRAM）。
  - **MIG**：硬體切分、**有**記憶體/故障隔離（安全的一卡多 job，需 A100/H100 等支援）。

---

## 閱讀重點提示（免得迷路）

- **①②③ 是必修**（心智模型 + 資源排程 + k3s 落地）；④⑤ 是應用層，讀完①②再看很快。
- 讀 ② 只要記住一句話：**「pod 宣告 requests，scheduler 看節點剩餘，塞得下就放。」**
- 讀 ④ 時把 ARC 想成「listener 的官方 k8s 版」、pod 想成「我們的 per-job 容器」，就都對得上。
- 你不需要一開始就懂 networking / ingress / storage class 那些——CI runner 情境用不太到，
  先跳過，別被勸退。

---

## 讀完之後：下一步

決策已在 [ADR-0004](adr/0004-defer-k8s-with-tripwires.md) 定案（現在 bespoke、觸發線後遷
k8s）。真的要遷時，做一份「**k8s 遷移評估**」，內容大致（下方清單即其雛形）：

- **現況（bespoke）→ 目標（k3s + ARC + 未來 GitLab executor + GPU 共享）** 的架構圖。
- **留 / 棄清單**：
  - *可能被 k8s 取代*：listener（→ ARC）、bespoke 並行 pool / auto-sizing（→ scheduler + requests）、
    systemd 部署（→ k8s manifests）。
  - *概念可轉移保留*：容器硬化（→ SecurityContext / Pod Security）、job 歷史/稽核觀念
    （→ k8s logging/audit）、供應鏈驗證（→ image 簽章 / admission）、ADR-0011 核准閘（不變）。
- **風險 / 成本**：維運一個 k8s（即使 k3s）的學習與運維負擔 vs 自幹跨主機排程的成本；
  遷移期間兩套並存的過渡策略。

---

## 附錄：k3s + ARC PoC runbook（丟棄式，將來熟悉用）

目的：在**一台備用機**上把 k8s/ARC 跑一遍，建立熟悉度，讓將來觸發線到、真要遷時**不是
冷啟動**。**這是丟棄式實驗**——玩完整個拆掉，不上線、不承諾。約半天~一天。

**前置**
- [ ] 一台**穩定、常開的 x86 server**（**別**用 rpi/jetson/筆電——那些是目標裝置或會關機）。
- [ ] 一個**測試用** GitHub org/repo（別拿正式的）＋一顆 PAT（classic，含 runner 註冊權限）。

**步驟**
1. [ ] 裝 k3s（單機即完整叢集）：`curl -sfL https://get.k3s.io | sh -`；確認 `kubectl get nodes` 看到一個 Ready node。
2. [ ] 用 Helm 裝 ARC controller：`helm install arc --namespace arc-systems --create-namespace oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`。
3. [ ] 裝一個 runner scale set（指到測試 org/repo + PAT），給它一個 `runs-on` 用的名字。
4. [ ] 推一個最小 workflow（`runs-on: <scale-set-name>`，內容就 `echo hi`），觀察一個 **pod 自動生出來→跑完→消失**。
5. [ ]（可選，對應你的 A 類）試 `nodeSelector` / taint 把 pod **釘到特定 node**。
6. [ ]（可選，對應你的動態/GPU）在 pod 設 `resources.requests/limits`；若機器有 GPU，裝 NVIDIA device plugin 試 GPU 排程 + time-slicing。
7. [ ] 拆掉：`/usr/local/bin/k3s-uninstall.sh`（k3s 自帶），刪掉測試 scale set / PAT。

**要看懂/帶走的重點**
- [ ] pod ↔ job 的對應（= 我們 bespoke 的 per-job 容器）。
- [ ] `requests/limits` 如何影響 scheduler 擺放（= 你要的「動態、不 idle」原理）。
- [ ] `nodeSelector`/taint 如何釘裝置（= 你的 A 類「綁特定硬體」）。
- [ ] ARC 如何隨 job 量擴縮（= 我們 bespoke listener 的官方版）。

（追蹤用的 spike issue 見 repo issue tracker；本 runbook 的決策背景見
[ADR-0004](adr/0004-defer-k8s-with-tripwires.md)。）

