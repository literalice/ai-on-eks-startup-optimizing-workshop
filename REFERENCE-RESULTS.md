# Reference Results / 参考計測値

One measured run, published so you can see the shape before spending anything.

実測 1 回分です。費用をかける前に傾向を確認できるように載せています。

> **This is one measurement in one account, not a benchmark.** Your absolute numbers
> will differ — image size, instance type, region and registry conditions all move
> them. What transfers is the *shape*: which stage dominates, and what each mechanism
> does to it. The point of running this yourself is to get your own numbers.
>
> **1 アカウントでの 1 回の計測であり、ベンチマークではありません。** 絶対値は環境で
> 変わります（イメージサイズ、インスタンスタイプ、リージョン、レジストリの状況）。
> 転用できるのは**傾向**です。どの段階が支配的か、各方式がそれをどう変えるか。
> 自分で回して自分の数字を得ることが目的です。

## Conditions / 条件

| | |
|---|---|
| Region | `us-west-2` |
| Instance type | `g6.4xlarge` (1× L4, 16 vCPU, 600 GB local NVMe) |
| Kubernetes | 1.34 |
| Node OS | Bottlerocket OS 1.64.0 (`aws-k8s-1.34-nvidia`) |
| Container runtime | `containerd://2.2.5+bottlerocket` |
| Image | AWS DLC `vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2` |
| Image size | 9.35 GB compressed, per kubelet |
| Model (phase 2) | Qwen2.5-1.5B-Instruct, 2.9 GB safetensors |
| Capacity | On-Demand |

## Phase 1 — how the image reaches the node / イメージの届き方

| Arm | Provisioning | Image | Workload | **Start to Ready** | Throughput |
|---|---:|---:|---:|---:|---:|
| `arm-a-baseline` | 29s | 95s | 1s | **125s** | 98 MB/s |
| `arm-b-snapshot` | 40s | 0s (no pull) | 10s | **50s** | — |
| `arm-c-soci` | 33s | 62s | 2s | **97s** | 151 MB/s |
| `arm-d-automode` | 35s | 57s | 2s | **94s** | 164 MB/s |
| `arm-c-soci-warm` | 0s | 0s (no pull) | 1s | **1s** | — |

Throughput is the compressed image size over the observed pull window, so it covers
download *and* unpack. It is the figure that stays comparable when the image differs
from this one.

スループットは圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージが異なる環境でも比較可能な数字はこれです。

### What this says / 読み取れること

**Provisioning is not the problem.** It is 29–40s and roughly constant across all
four arms. The image pull is what varies, and in the baseline it is about three
times everything else put together.

**プロビジョニングは問題ではありません。** 29〜40 秒で 4 arm ほぼ一定です。変動するのは
イメージ pull で、ベースラインではそれ以外の合計の約 3 倍でした。

**Auto Mode matched the hand-tuned arm, with no configuration.** Arm C needed
`instanceStorePolicy: RAID0` plus six lines of Bottlerocket settings. Arm D has
none of that and pulled slightly faster (164 vs 151 MB/s). Read the difference
between C and D as within noise — they are on different control planes — but the
*configuration* difference is not noise.

**Auto Mode は無設定で手動チューニング版と同等でした。** arm C は
`instanceStorePolicy: RAID0` と Bottlerocket 設定 6 行が必要でしたが、arm D はそれが
ゼロで僅かに速い（164 対 151 MB/s）。C と D の差自体はノイズ範囲と読むべきですが
（コントロールプレーンが別）、**設定量の差はノイズではありません。**

**SOCI roughly halved the pull.** 95s → 62s, throughput 98 → 151 MB/s, on an
unmodified image with no build-pipeline change.

**SOCI は pull をおよそ半減させました。** 95→62 秒、98→151 MB/s。イメージは無改変で、
ビルドパイプラインの変更もありません。

**The snapshot removed the pull entirely** — kubelet reported the image as already
present and never contacted the registry. 125s → 50s. Not in this table: the
snapshot took several minutes to build and must be rebuilt on every image change.
That cost is what decides whether the mechanism is worth adopting.

**スナップショットは pull を完全に消しました。** kubelet はイメージが既に存在すると
報告し、レジストリに一度も行きません。125→50 秒。ただしこの表に無いのは、スナップ
ショット作成に数分かかり、イメージ更新ごとに作り直しが必要という点です。採用可否を
決めるのはこのコストです。

**The most consequential number is the warm run: 97s → 1s.** Ninety-six of
ninety-seven seconds was a once-per-node cost, not a once-per-pod cost. If most of
your scale-out lands on nodes that are already running, none of the three
mechanisms above is where your time goes — the answer is capacity policy.

**最も重要な数字は warm 実行の 97→1 秒です。** 97 秒中 96 秒が「ノード 1 台につき
1 回」のコストで、Pod ごとではありません。スケールアウトの大半が既存ノードに乗るなら、
上記 3 方式はどれも時間の使われ先ではなく、答えはキャパシティ方針になります。

## Phase 2 — how the weights reach GPU memory / ウェイトの届き方

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` — copy to disk, vLLM default loader | 96s | 0.65s | **96.6s** |
| `runai-local` — copy to disk, Run:ai Model Streamer | 93s | 0.65s | **93.6s** |
| `runai-s3` — no copy, streamer reads S3 directly | 82s | 0.65s | **82.6s** |

Inside "workload becomes Ready", from vLLM's own log:

「workload becomes Ready」の内訳（vLLM 自身のログより）:

| | `s3-initcontainer` | `runai-s3` |
|---|---:|---:|
| Reading the weights | **0.31s** | — |
| Model load total | 0.63s | 3.36s |
| `torch.compile` | 14.8s | 14.7s |
| Engine init, KV cache, warmup | 28.2s | 27.9s |
| CUDA graph capture | 4.0s | 4.0s |

### What this says / 読み取れること

**Changing only the loader achieved nothing — and that is the useful result.**
`s3-initcontainer` → `runai-local` is identical bytes on identical disk with a
different loader, and the total did not move. The reason is in vLLM's log:
**reading the weights was 0.31 seconds out of 96.** Faster tensor reading had
nothing to win. Shown as a before-and-after total alone, this would have read as
"the tool does not work"; the vLLM timings show it was never given anything to do.

**ローダーだけを変えても何も起きませんでした。そしてそれが有用な結果です。**
`s3-initcontainer` → `runai-local` は同じディスク上の同じバイト列でローダーだけが違い、
合計は動きませんでした。理由は vLLM のログにあります。**ウェイト読み込みは 96 秒中
0.31 秒。** 速く読む手段に取り分がありませんでした。前後の合計だけを見せていたら
「このツールは効かない」と読めますが、vLLM の内訳はそもそも仕事が無かったことを示します。

**Changing the delivery did work, for a reason worth being precise about.**
`runai-s3` removes the init container entirely — 96s → 82s. But note the model load
went *up*, 0.63s → 3.36s: streaming from S3 is slower per tensor than reading local
disk. **The gain is from deleting a step, not from doing it faster.** At a larger
model size the loader would matter too; at this size only the delivery does.

**配送を変えた方は効きました。ただし理由を正確に言う価値があります。**
`runai-s3` は init コンテナを完全に削除し 96→82 秒。ただしモデルロードは 0.63→3.36 秒と
**増えています。** S3 ストリーミングはテンソル単位ではローカルディスクより遅いのです。
**短縮の出所は工程の削除であり、高速化ではありません。** モデルが大きければローダーも
効きますが、このサイズでは配送だけが効きます。

**At this model size, model load is dominated by compilation and warmup, not I/O.**
`torch.compile` 14.7s plus engine init 27.9s plus graph capture 4s is about 47 of
the 82 seconds. Neither a faster loader nor faster delivery touches any of it —
caching compiled artifacts would.

**このモデルサイズでは、モデルロードは I/O ではなくコンパイルとウォームアップに
支配されています。** `torch.compile` 14.7 秒 + engine init 27.9 秒 + graph capture
4 秒で、82 秒のうち約 47 秒です。ローダーの高速化も配送の変更もここには触れません。
効くのはコンパイル成果物のキャッシュです。

## Repeatability / 再現性

Phase 1 was run twice, several hours apart, on freshly provisioned nodes each time:

フェーズ 1 は数時間あけて 2 回、毎回新規ノードで実行しました。

| Arm | Run 1 | Run 2 | Δ |
|---|---:|---:|---:|
| `arm-a-baseline` | 127s | 125s | 1.6% |
| `arm-b-snapshot` | 46s | 50s | 8.7% |
| `arm-c-soci` | 89s | 97s | 9.0% |
| `arm-d-automode` | 89s | 94s | 5.6% |
| `arm-c-soci-warm` | 2s | 1s | — |
| `weights-runai-s3` | 83s | 82s | 1.2% |

All within about 9%, which is why the guidance is to treat a difference under
roughly 10% as noise until it repeats. Note that on run 1, arms C and D were level
at 89s; on run 2 they were 97s and 94s. **The C-versus-D ordering is not stable
across runs, so do not claim one beats the other.**

いずれも約 9% 以内でした。だからこそ「10% 未満の差は再現するまでノイズ扱い」という
指針にしています。なお 1 回目は arm C と D がともに 89 秒でしたが、2 回目は 97 秒と
94 秒でした。**C と D の優劣は実行間で安定しないため、どちらが勝ると主張しないでください。**
