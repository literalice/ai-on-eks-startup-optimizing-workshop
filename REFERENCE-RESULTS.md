# Reference Results

**English** | [日本語](#japanese)

One measured run, recorded so that the breakdown can be reviewed before running the
workshop.

> This is a single measurement from a single account, not a benchmark. Absolute figures
> depend on image size, instance type, region and registry conditions, so figures from
> another environment will differ. What can be compared across environments is which stage
> accounts for most of the time, and how each mechanism changes it.

## Conditions

| | |
|---|---|
| Region | `us-west-2` |
| Instance type | `g6.8xlarge` (1× L4 24 GB, 32 vCPU, 2× 450 GB local NVMe) |
| Kubernetes | 1.34 |
| Node OS | Bottlerocket OS 1.64.0 (`aws-k8s-1.34-nvidia`) |
| Container runtime | `containerd://2.2.5+bottlerocket` |
| Image | AWS DLC `vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2` |
| Image size | 9.35 GB compressed, as reported by kubelet |
| Model (phase 2) | Qwen2.5-1.5B-Instruct, 2.9 GB safetensors |
| Capacity | On-Demand |

## Phase 1 — how the image reaches the node

| Variant | Provisioning | Image | Workload | Start to Ready | Throughput |
|---|---:|---:|---:|---:|---:|
| `baseline` | 29s | 96s | 0s | 125s | 97 MB/s |
| `snapshot` | 35s | 0s (no pull) | 13s | 48s | — |
| `soci` | 34s | 36s | 1s | 71s | 260 MB/s |
| `automode` | 63s | 34s | 1s | 98s | 275 MB/s |
| `soci-warm` | 0s | 0s (no pull) | 2s | 2s | — |

Throughput is the compressed image size divided by the observed pull duration, so it
includes both download and unpack. It can be compared across environments with different
image sizes.

### Observations

In the baseline the image pull was longer than all other stages combined: 96 seconds out of
125.

SOCI reduced the pull from 96 to 36 seconds and raised throughput from 97 to 260 MB/s, with
the image unchanged and no change to the build pipeline.

`automode` reached the same throughput as `soci`, 275 against 260 MB/s, without any of its
configuration. `soci` required `instanceStorePolicy: RAID0` and six lines of Bottlerocket
settings; `automode` required neither. Its total was higher, 98 against 71 seconds, but that
came from provisioning at 63 seconds rather than from the image stage, and provisioning is
not what either mechanism changes.

The snapshot removed the pull. kubelet reported the image as already present and did not
contact the registry, and start-to-Ready went from 125 to 48 seconds. The snapshot took 14
minutes to build and has to be rebuilt whenever the image changes; that time is not included
in the table.

The warm run went from 71 seconds to 2 seconds, so 69 seconds of the cold measurement was
incurred once per node rather than once per pod. For a workload where most pods are
scheduled onto nodes that are already running, the mechanisms in `snapshot`, `soci` and
`automode` affect a small part of the total startup time.

Provisioning is the stage to be most careful with. It was 29 to 35 seconds for the three
Karpenter variants and 63 seconds for `automode` here, but it is the stage a capacity
shortage inflates without producing an error.

One run was discarded for exactly that and is not reported in this document: `baseline`
provisioning came out at 222 seconds, of which 191 was the interval between the pod being
created and Karpenter creating a NodeClaim. No instance had been launched yet in that
interval. One Availability Zone had no capacity for the instance type, and Karpenter holds a
capacity-starved offering unavailable for 3 minutes at a time, so the pod waited out the TTL.
The variant's configuration has no bearing on that wait. Run `bin/check_capacity.sh` before a
measurement run, and check the provisioning column afterwards — `bin/report.py` flags a
`Karpenter decision` segment over 90 seconds.

## Phase 2 — how the weights reach GPU memory

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` — copy to disk, vLLM default loader | 94s | 0.66s | 94.7s |
| `runai-local` — copy to disk, Run:ai Model Streamer | 91s | 0.66s | 91.7s |
| `runai-s3` — no copy, streamer reads S3 directly | 84s | 0.66s | 84.7s |

Within the "workload becomes Ready" stage, from vLLM's log:

| | `s3-initcontainer` | `runai-local` | `runai-s3` |
|---|---:|---:|---:|
| Reading the weights | 0.31s | — | — |
| Model load total | 0.62s | 1.01s | 2.63s |
| `torch.compile` | 14.7s | 14.7s | 14.6s |
| Engine init, KV cache, warmup | 27.9s | 28.0s | 27.8s |
| CUDA graph capture | 4.0s | 4.0s | 4.0s |

### Observations

Changing only the loader did not change the total meaningfully. The first two variants use
identical bytes on identical disk with a different loader, and took 94 and 91 seconds. vLLM's
log shows that reading the weights took 0.31 seconds out of 94, so a faster loader could only
affect that interval. The Run:ai loader's model load was in fact slower here, 1.01 against
0.62 seconds.

Changing the delivery reduced the total from 94 to 84 seconds. The model load time increased
from 0.62 to 2.63 seconds, so reading from S3 is slower per tensor than reading from local
disk. The reduction comes from removing the copy step, which the init container performs
before the workload image pull rather than alongside it.

At this model size, compilation and warmup were the largest components. `torch.compile` at
14.6 seconds, engine init at 27.8 seconds and graph capture at 4 seconds account for about
46 of the 84 seconds. Neither the loader nor the delivery method affects these.

## What the instance type changed

An earlier run used `g6.4xlarge`: same L4 GPU, but 16 vCPU instead of 32 and a single NVMe
disk instead of two.

| Variant | `g6.4xlarge` | `g6.8xlarge` |
|---|---:|---:|
| `baseline` | 152s | 125s |
| `snapshot` | 56s | 48s |
| `soci` | 96s, 146 MB/s | 71s, **260 MB/s** |
| `automode` | 90s | 98s, 275 MB/s |
| `soci-warm` | 2s | 2s |

SOCI's throughput went from 146 to 260 MB/s on the same image from the same registry. Only
the instance type changed. This is the measurement behind the statement that parallel unpack
is CPU-bound, and it means a `soci` figure from one instance type does not apply to another.

The two runs also differ in ways that are not the instance type, so read the table as
indicative rather than as a controlled comparison. The `g6.4xlarge` run resolved a coarser
stage split for `baseline` and `automode`, which is why their throughput is absent, and its
snapshot came from a workload node rather than from a dedicated builder.

## Repeatability

These are single runs. A difference below about 10% between two variants should be repeated
before being relied on, and the reason is visible in this document: `automode` came out at
90 seconds on one instance type and 98 on another while its image stage barely moved, and
`soci` and `automode` have swapped places between runs. Where the two are within about 10%
of each other, these figures do not show one to be faster than the other.

Provisioning varies more than the image stage. On the same instance type the image figures
have been consistent across runs, while provisioning has ranged from 29s to 222s. A capacity
shortage produces a long provisioning figure with no error, so check that stage before
comparing totals. See the note at the end of the phase 1 observations.

<br>

---
---

<a id="japanese"></a>

# 参考計測値

[English](#reference-results) | **日本語**

計測 1 回分の結果です。ワークショップを実行する前に内訳を確認できるように記載しています。

> 1 アカウントでの 1 回の計測であり、ベンチマークではありません。絶対値はイメージサイズ、
> インスタンスタイプ、リージョン、レジストリの状況に依存するため、別環境の数字は異なります。
> 環境間で比較できるのは、どの段階が時間の大部分を占めるか、および各方式がそれをどう変えるか
> です。

## 条件

| | |
|---|---|
| リージョン | `us-west-2` |
| インスタンスタイプ | `g6.8xlarge`（L4 1 基 24 GB、32 vCPU、ローカル NVMe 450 GB × 2） |
| Kubernetes | 1.34 |
| ノード OS | Bottlerocket OS 1.64.0（`aws-k8s-1.34-nvidia`） |
| コンテナランタイム | `containerd://2.2.5+bottlerocket` |
| イメージ | AWS DLC `vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2` |
| イメージサイズ | kubelet 報告で圧縮 9.35 GB |
| モデル（フェーズ 2） | Qwen2.5-1.5B-Instruct、safetensors 2.9 GB |
| キャパシティ | On-Demand |

## フェーズ 1 — イメージの届き方

| Variant | プロビジョニング | イメージ | ワークロード | start to Ready | スループット |
|---|---:|---:|---:|---:|---:|
| `baseline` | 29s | 96s | 0s | 125s | 97 MB/s |
| `snapshot` | 35s | 0s（pull なし） | 13s | 48s | — |
| `soci` | 34s | 36s | 1s | 71s | 260 MB/s |
| `automode` | 63s | 34s | 1s | 98s | 275 MB/s |
| `soci-warm` | 0s | 0s（pull なし） | 2s | 2s | — |

スループットは圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージサイズが異なる環境間でも比較できます。

### 観察された内容

ベースラインではイメージ pull が他の全段階の合計より長く、125 秒のうち 96 秒でした。

SOCI は pull を 96 秒から 36 秒に、スループットを 97 から 260 MB/s にしました。イメージは
変更せず、ビルドパイプラインの変更もありません。

`automode` は `soci` の設定を一切行わずに、`soci` と同じスループット（275 対 260 MB/s）に
達しました。`soci` は `instanceStorePolicy: RAID0` と Bottlerocket 設定 6 行を必要とし、
`automode` はどちらも不要です。合計は 98 対 71 秒で `automode` の方が長いものの、その差は
プロビジョニングが 63 秒だったことに由来し、イメージ段階ではありません。プロビジョニングは
どちらの機構も変えていない部分です。

スナップショットは pull を無くしました。kubelet はイメージが既に存在すると報告し、レジストリ
には接続せず、start-to-Ready は 125 秒から 48 秒になりました。スナップショットの作成には 14 分
かかり、イメージが変わるたびに作り直しが必要です。その時間は表に含まれていません。

warm 実行は 71 秒から 2 秒になり、cold の計測のうち 69 秒が Pod ごとではなくノード 1 台につき
1 回発生する分でした。Pod の大半がすでに動いているノードにスケジュールされるワークロードでは、
`snapshot` / `soci` / `automode` の各方式が影響するのは起動時間全体の一部です。

最も注意が必要なのはプロビジョニングです。この実行では Karpenter の 3 variant が 29〜35 秒、
`automode` が 63 秒でしたが、容量不足がエラーを出さずに数字を長くするのはこの段階です。

まさにその理由で破棄した実行が 1 回あり、本文書には掲載していません。`baseline` の
プロビジョニングが 222 秒になり、そのうち 191 秒は Pod の作成から Karpenter が NodeClaim を
作成するまでの区間でした。この区間ではインスタンスはまだ 1 台も起動していません。ある AZ に
そのインスタンスタイプの容量がなく、Karpenter は容量が枯渇した offering を 3 分間 unavailable に
保持するため、Pod がその TTL を待ちました。この待ち時間に variant の設定は関係しません。計測前に
`bin/check_capacity.sh` を実行し、実行後はプロビジョニング列を確認してください。
`bin/report.py` は `Karpenter decision` セグメントが 90 秒を超えた場合に警告します。

## フェーズ 2 — ウェイトの届き方

| Variant | Ready | Ready 後の TTFT | submit から最初のトークンまで |
|---|---:|---:|---:|
| `s3-initcontainer` — ディスクへコピー、vLLM 既定ローダー | 94s | 0.66s | 94.7s |
| `runai-local` — ディスクへコピー、Run:ai Model Streamer | 91s | 0.66s | 91.7s |
| `runai-s3` — コピーなし、streamer が S3 を直接読む | 84s | 0.66s | 84.7s |

「workload becomes Ready」の段階の内訳（vLLM のログより）:

| | `s3-initcontainer` | `runai-local` | `runai-s3` |
|---|---:|---:|---:|
| ウェイトの読み込み | 0.31s | — | — |
| モデルロード合計 | 0.62s | 1.01s | 2.63s |
| `torch.compile` | 14.7s | 14.7s | 14.6s |
| engine init、KV cache、warmup | 27.9s | 28.0s | 27.8s |
| CUDA graph capture | 4.0s | 4.0s | 4.0s |

### 観察された内容

ローダーのみを変えても合計は実質的に変わりませんでした。最初の 2 つは同じディスク上の同じ
バイト列をローダーだけ変えて読み、94 秒と 91 秒でした。vLLM のログでは、ウェイトの読み込みは
94 秒中 0.31 秒であり、より速いローダーが影響できるのはこの区間だけです。実際には Run:ai
ローダーのモデルロードの方が遅く、1.01 対 0.62 秒でした。

配送を変えると合計は 94 秒から 84 秒になりました。モデルロード時間は 0.62 秒から 2.63 秒に
増えており、S3 からの読み込みはテンソル単位ではローカルディスクより遅くなっています。短縮分は、
コピー工程が無くなったことによります。この工程は init コンテナが、ワークロードイメージの pull と
並行してではなくその前に実行します。

このモデルサイズでは、コンパイルとウォームアップが最大の要素でした。`torch.compile` が
14.6 秒、engine init が 27.8 秒、graph capture が 4 秒で、84 秒のうち約 46 秒を占めます。
ローダーも配送方法もこれには影響しません。

## インスタンスタイプで変わったこと

以前の実行では `g6.4xlarge` を使いました。GPU は同じ L4 ですが、vCPU が 32 ではなく 16、
NVMe が 2 本ではなく 1 本です。

| Variant | `g6.4xlarge` | `g6.8xlarge` |
|---|---:|---:|
| `baseline` | 152s | 125s |
| `snapshot` | 56s | 48s |
| `soci` | 96s、146 MB/s | 71s、**260 MB/s** |
| `automode` | 90s | 98s、275 MB/s |
| `soci-warm` | 2s | 2s |

SOCI のスループットは、同じイメージを同じレジストリから取得して 146 から 260 MB/s になりました。
変えたのはインスタンスタイプだけです。これが「並列展開は CPU バウンドである」という記述の計測上の
根拠です。また、あるインスタンスタイプで得た `soci` の数字は別のタイプには当てはまりません。

この 2 回の実行にはインスタンスタイプ以外の差もあるため、統制された比較ではなく参考として
読んでください。`g6.4xlarge` の実行では `baseline` と `automode` の段階分解が粗く、そのため
スループットが空欄です。またスナップショットは専用ビルダーではなくワークロードノードから
取得したものでした。

## 再現性

いずれも 1 回の実行です。2 つの variant 間の差が 10% 程度未満の場合は、判断する前に再実行で
確認してください。その理由はこの文書の中に現れています。`automode` はイメージ段階がほとんど
動いていないのに、一方のインスタンスタイプで 90 秒、他方で 98 秒でした。また `soci` と
`automode` は実行間で順位が入れ替わっています。両者が互いに 10% 程度の範囲にある場合、これらの
数字からどちらが速いとは言えません。

プロビジョニングはイメージ段階よりばらつきます。同一インスタンスタイプではイメージの数字は
実行間で一貫していますが、プロビジョニングは 29 秒から 222 秒まで幅がありました。容量不足は
エラーを出さずにプロビジョニングの数字を長くするため、合計を比較する前にこの段階を確認して
ください。フェーズ 1 の観察の最後の注記を参照してください。
