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
| Instance type | `gr6.8xlarge` (1× L4 24 GB, 32 vCPU, 2× 450 GB local NVMe) |
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
| `baseline` | 31s | 124s | 2s | 157s | 75 MB/s |
| `snapshot` | 37s | 0s (no pull) | 24s | 61s | — |
| `soci` | 30s | 35s | 1s | 66s | 267 MB/s |
| `automode` | 42s | 35s | 1s | 78s | 267 MB/s |
| `soci-warm` | 0s | 0s (no pull) | 1s | 1s | — |

Throughput is the compressed image size divided by the observed pull duration, so it
includes both download and unpack. It can be compared across environments with different
image sizes.

### Observations

In the baseline the image pull was longer than all other stages combined: 124 seconds out of
157.

SOCI reduced the pull from 124 seconds to 35 and raised throughput from 75 to 267 MB/s. The
image is unchanged and the build pipeline is unchanged.

`automode` reached the same image stage as `soci` without any of its configuration: 35 seconds
and 267 MB/s in both. `soci` required `instanceStorePolicy: RAID0` and six lines of Bottlerocket
settings, and `automode` required neither. Its total was higher, 78 against 66 seconds, but that
difference is in provisioning, which is not what either mechanism changes.

The snapshot removed the pull. kubelet reported the image as already present and did not contact
the registry, and start-to-Ready went from 157 seconds to 61. Building the snapshot took 14
minutes and it has to be rebuilt whenever the image changes. That time is not in the table.

The warm run went from 66 seconds to 1, so 65 seconds of the cold measurement was incurred once
per node rather than once per pod. If most of your pods are scheduled onto nodes that are
already running, the mechanisms in `snapshot`, `soci` and `automode` affect a small part of
your total startup time.

Provisioning is the stage to be most careful with. It was 30 to 37 seconds for the three
Karpenter variants and 42 seconds for `automode` here, but it is the stage a capacity shortage
inflates without producing an error.

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
| `s3-initcontainer` — copy to disk, vLLM default loader | 95s | 0.66s | 95.7s |
| `runai-local` — copy to disk, Run:ai Model Streamer | 92s | 0.66s | 92.7s |
| `runai-s3` — no copy, streamer reads S3 directly | 84s | 0.66s | 84.7s |

Within the "workload becomes Ready" stage, from vLLM's log:

| | `s3-initcontainer` | `runai-local` | `runai-s3` |
|---|---:|---:|---:|
| Model load total | 0.62s | 1.05s | 2.71s |
| &nbsp;&nbsp;of which reading the weights | 0.30s | — | — |
| Engine init: profile, KV cache, warmup | 28.0s | 28.0s | 28.0s |
| &nbsp;&nbsp;of which `torch.compile` | 14.8s | 14.7s | 14.8s |
| &nbsp;&nbsp;of which CUDA graph capture | 4.0s | 4.0s | 4.0s |

The indented rows are **inside** the row above, not additional to it. vLLM reports the
nesting on the line itself — `init engine (profile, create kv cache, warmup model) took
27.98 s (compilation: 14.76 s)` — so adding these figures would count compilation twice.

### Observations

Changing only the loader did not change the total meaningfully. The first two variants use
identical bytes on identical disk with a different loader, and took 95 and 92 seconds. vLLM's
log shows that reading the weights took 0.30 seconds out of 95, so a faster loader had only
that interval to work with. The Run:ai loader's model load was in fact slower here, 1.05
against 0.62 seconds.

Changing the delivery reduced the total from 95 seconds to 84. The model load time went up from
0.62 seconds to 2.71, because reading from S3 is slower per tensor than reading from a local
disk. The reduction comes from removing the copy step, which the init container performs before
the workload image pull rather than alongside it.

At this model size engine initialisation was the largest component: 28.0 of the 84 seconds, and
that figure contains the 14.8 seconds of compilation. Neither the loader nor the delivery method
affects that stage. Reusing the compiled artifacts does, and phase 3 measures it.

## Phase 3 — reusing vLLM's compiled artifacts

Both runs use the `runai-s3` loader from phase 2 on the same node, with the same image, GPU,
model and vLLM arguments. They differ only in whether the mounted compile cache directory
already had contents.

| Variant | Cache | `torch.compile` | Engine init | Model load | Ready | Submit to first token |
|---|---|---:|---:|---:|---:|---:|
| `compile-cold` | miss | 14.78s | 28.00s | 2.62s | 82s | 82.7s |
| `compile-warm` | hit | 3.01s | 15.33s | 2.65s | 69s | 69.7s |

### Observations

Reusing the artifacts removed 13 of the 82 seconds, or 16%. Compilation went from 14.78
seconds to 3.01, and the engine stage that contains it went from 28.00 to 15.33.

The model load figure is the check that this measures what it claims. It was 2.62 seconds cold
and 2.65 warm, so the weights came from S3 in both runs. Only `torch_compile_cache` is mounted
from the node, not the whole of `/root/.cache/vllm`, where Run:ai Model Streamer also keeps a
copy of the model. Had the whole root been mounted, the warm run would have skipped the S3 read
as well and the 13 seconds could not be attributed to compilation.

Whether the cache was used is read from vLLM's log rather than inferred from the compile time
being short, because a short compile time is also what a different compilation configuration
looks like. On a miss vLLM logs that it compiled and saved the artifacts; on a hit it logs
`Directly load the compiled graph(s) ... from the cache`.

Two limits. Compilation is the only part this removes: the profiling, KV-cache creation and
warmup in the same stage accounted for the remaining 12 seconds or so and are unaffected, and
CUDA graph capture stayed at 4 seconds in both runs. And the artifacts are on the node, so they
do not survive a node replacement. Restoring them from S3 onto a new node is a third test that
this workshop describes but does not script.

## What the instance type changed

An earlier run used `g6.4xlarge`: the same L4 GPU, but 16 vCPU instead of 32 and one NVMe disk
instead of two.

| Variant | `g6.4xlarge` | `gr6.8xlarge` |
|---|---:|---:|
| `baseline` | 152s | 157s |
| `snapshot` | 56s | 61s |
| `soci` | 96s, 146 MB/s | 66s, **267 MB/s** |
| `automode` | 90s | 78s, 267 MB/s |
| `soci-warm` | 2s | 1s |

SOCI's throughput went from 146 to 267 MB/s on the same image from the same registry. This is
the measurement behind the statement that parallel unpack is CPU-bound, and it means a `soci`
figure from one instance type does not apply to another.

Read the rest of the table as indicative rather than as a controlled comparison, because the two
runs differ in more than the instance type. The `g6.4xlarge` run resolved a coarser stage split
for `baseline` and `automode`, which is why their throughput is absent. Its snapshot came from a
workload node rather than from a dedicated builder. And the registry conditions were not the
same: `baseline` pulled at 97 MB/s in an intermediate run on `g6.8xlarge` and at 75 MB/s here,
with no configuration difference between them.

## Repeatability

These are single runs. Treat a difference below about 10% between two variants as needing a
repeat run before it is relied on. The reason is visible in this document. `baseline` has pulled
at 75, 97 and 146 MB/s across runs with no configuration change, so the sequential-pull figure
is the least stable number here. `soci` and `automode` came out identical on the image stage in
this run and differed by 15 MB/s in an earlier one, which is not enough to order them.

Provisioning varies more than the image stage and needs the most care. On the same instance type
the image figures have been consistent, while provisioning has ranged from 29s to 222s. A
capacity shortage produces a long provisioning figure and no error, so check that stage before
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
| インスタンスタイプ | `gr6.8xlarge`（L4 1 基 24 GB、32 vCPU、ローカル NVMe 450 GB × 2） |
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
| `baseline` | 31s | 124s | 2s | 157s | 75 MB/s |
| `snapshot` | 37s | 0s（pull なし） | 24s | 61s | — |
| `soci` | 30s | 35s | 1s | 66s | 267 MB/s |
| `automode` | 42s | 35s | 1s | 78s | 267 MB/s |
| `soci-warm` | 0s | 0s（pull なし） | 1s | 1s | — |

スループットは圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージサイズが異なる環境間でも比較できます。

### 観察された内容

ベースラインではイメージ pull が他の全段階の合計より長く、157 秒のうち 124 秒でした。

SOCI は pull を 124 秒から 35 秒に、スループットを 75 から 267 MB/s にしました。イメージは変更
しておらず、ビルドパイプラインも変更していません。

`automode` は `soci` の設定を一切行わずに、`soci` と同じイメージ段階に達しました。どちらも
35 秒、267 MB/s です。`soci` は `instanceStorePolicy: RAID0` と Bottlerocket 設定 6 行を必要とし、
`automode` はどちらも不要です。合計は 78 対 66 秒で `automode` の方が長いものの、その差は
プロビジョニングにあり、どちらの機構も変えていない部分です。

スナップショットは pull を無くしました。kubelet はイメージが既に存在すると報告してレジストリ
には接続せず、start-to-Ready は 157 秒から 61 秒になりました。スナップショットの作成には 14 分
かかり、イメージが変わるたびに作り直しが必要です。その時間は表に含まれていません。

warm 実行は 66 秒から 1 秒になり、cold の計測のうち 65 秒が Pod ごとではなくノード 1 台につき
1 回発生する分でした。Pod の大半がすでに動いているノードにスケジュールされる場合、
`snapshot` / `soci` / `automode` の各方式が影響するのは起動時間全体の一部です。

最も注意が必要なのはプロビジョニングです。この実行では Karpenter の 3 variant が 30〜37 秒、
`automode` が 42 秒でしたが、容量不足がエラーを出さずに数字を長くするのはこの段階です。

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
| `s3-initcontainer` — ディスクへコピー、vLLM 既定ローダー | 95s | 0.66s | 95.7s |
| `runai-local` — ディスクへコピー、Run:ai Model Streamer | 92s | 0.66s | 92.7s |
| `runai-s3` — コピーなし、streamer が S3 を直接読む | 84s | 0.66s | 84.7s |

「workload becomes Ready」の段階の内訳（vLLM のログより）:

| | `s3-initcontainer` | `runai-local` | `runai-s3` |
|---|---:|---:|---:|
| モデルロード合計 | 0.62s | 1.05s | 2.71s |
| &nbsp;&nbsp;うちウェイトの読み込み | 0.30s | — | — |
| engine init（profile、KV cache、warmup） | 28.0s | 28.0s | 28.0s |
| &nbsp;&nbsp;うち `torch.compile` | 14.8s | 14.7s | 14.8s |
| &nbsp;&nbsp;うち CUDA graph capture | 4.0s | 4.0s | 4.0s |

字下げした行は、上の行に**含まれる**内訳であり、加算するものではありません。vLLM はその行自体で
入れ子を報告しています（`init engine (profile, create kv cache, warmup model) took 27.98 s
(compilation: 14.76 s)`）。これらを足すとコンパイル時間を二重に数えることになります。

### 観察された内容

ローダーのみを変えても合計は実質的に変わりませんでした。最初の 2 つは同じディスク上の同じ
バイト列をローダーだけ変えて読み、95 秒と 92 秒でした。vLLM のログでは、ウェイトの読み込みは
95 秒中 0.30 秒であり、より速いローダーに与えられているのはこの区間だけです。実際には Run:ai
ローダーのモデルロードの方が遅く、1.05 対 0.62 秒でした。

配送を変えると合計は 95 秒から 84 秒になりました。モデルロード時間は 0.62 秒から 2.71 秒に
増えています。S3 からの読み込みはテンソル単位ではローカルディスクより遅いためです。短縮分は
コピー工程が無くなったことによります。この工程は init コンテナが、ワークロードイメージの pull と
並行してではなくその前に実行します。

このモデルサイズでは engine init が最大の要素でした。84 秒のうち 28.0 秒で、その中にコンパイルの
14.8 秒が含まれます。ローダーも配送方法もこの段階には影響しません。影響するのはコンパイル成果物
の再利用で、フェーズ 3 でそれを計測します。

## フェーズ 3 — vLLM のコンパイル成果物を再利用する

どちらの実行もフェーズ 2 の `runai-s3` ローダーを使い、同じノード上で、同じイメージ、GPU、
モデル、vLLM 引数で動かしています。違いは、マウントしたコンパイルキャッシュディレクトリに
既に内容があったかどうかだけです。

| Variant | キャッシュ | `torch.compile` | engine init | モデルロード | Ready | submit から最初のトークンまで |
|---|---|---:|---:|---:|---:|---:|
| `compile-cold` | miss | 14.78s | 28.00s | 2.62s | 82s | 82.7s |
| `compile-warm` | hit | 3.01s | 15.33s | 2.65s | 69s | 69.7s |

### 観察された内容

成果物の再利用により、82 秒のうち 13 秒（16%）が減りました。コンパイルは 14.78 秒から 3.01 秒に、
それを内包する engine 段階は 28.00 秒から 15.33 秒になりました。

この計測が主張どおりのものを測っていることの確認は、モデルロードの数字です。cold で 2.62 秒、
warm で 2.65 秒なので、ウェイトは両方の実行で S3 から来ています。ノードからマウントしているのは
`torch_compile_cache` だけで、`/root/.cache/vllm` 全体ではありません。このルート配下には Run:ai
Model Streamer もモデルのコピーを置きます。ルート全体をマウントしていた場合、warm 実行では S3 の
読み込みもスキップされ、13 秒をコンパイルに帰属させることはできませんでした。

キャッシュが使われたかどうかは、コンパイル時間が短いことからの推測ではなく vLLM のログから読み
取ります。コンパイル時間が短いのは、コンパイル設定が違う場合にも同じように見えるためです。ミスの
場合、vLLM はコンパイルして成果物を保存したことを記録し、ヒットの場合は
`Directly load the compiled graph(s) ... from the cache` を記録します。

限界が 2 つあります。これが除去するのはコンパイルだけです。同じ段階にある profiling、KV cache
作成、warmup は残りの約 12 秒を占めており影響を受けません。CUDA graph capture もどちらの実行でも
4 秒のままです。もう 1 つは、成果物がノード上にあるため、ノードの置き換えには残らないことです。
新規ノードへ S3 から復元することは 3 つ目の試験で、本ワークショップでは記述はしますがスクリプト化
していません。

## インスタンスタイプで変わったこと

以前の実行では `g6.4xlarge` を使いました。GPU は同じ L4 ですが、vCPU が 32 ではなく 16、
NVMe が 2 本ではなく 1 本です。

| Variant | `g6.4xlarge` | `gr6.8xlarge` |
|---|---:|---:|
| `baseline` | 152s | 157s |
| `snapshot` | 56s | 61s |
| `soci` | 96s、146 MB/s | 66s、**267 MB/s** |
| `automode` | 90s | 78s、267 MB/s |
| `soci-warm` | 2s | 1s |

SOCI のスループットは、同じイメージを同じレジストリから取得して 146 から 267 MB/s になりました。
これが「並列展開は CPU バウンドである」という記述の計測上の根拠です。また、あるインスタンス
タイプで得た `soci` の数字は別のタイプには当てはまりません。

表の残りは、統制された比較ではなく参考として読んでください。2 回の実行はインスタンスタイプ以外
でも異なります。`g6.4xlarge` の実行では `baseline` と `automode` の段階分解が粗く、そのため
スループットが空欄です。スナップショットは専用ビルダーではなくワークロードノードから取得した
ものでした。さらにレジストリの条件も同一ではありません。`baseline` は `g6.8xlarge` での中間的な
実行で 97 MB/s、今回は 75 MB/s で、両者の間に設定の違いはありません。

## 再現性

いずれも 1 回の実行です。2 つの variant 間の差が 10% 程度未満の場合は、判断する前に再実行で
確認してください。その理由はこの文書の中に現れています。`baseline` は設定を変えずに 75、97、
146 MB/s で pull しており、逐次 pull の数字がここで最も安定しません。`soci` と `automode` は
今回の実行でイメージ段階が同一になり、以前の実行では 15 MB/s 差でした。順位を付けられる差では
ありません。

プロビジョニングはイメージ段階よりばらつき、最も注意が必要です。同一インスタンスタイプでは
イメージの数字は一貫していますが、プロビジョニングは 29 秒から 222 秒まで幅がありました。容量
不足はプロビジョニングの数字を長くし、エラーは出しません。合計を比較する前にこの段階を確認して
ください。フェーズ 1 の観察の最後の注記を参照してください。
