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
| Instance type | `g6.4xlarge` (1× L4, 16 vCPU, 600 GB local NVMe) |
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
| `baseline` | 29s | 95s | 1s | 125s | 98 MB/s |
| `snapshot` | 40s | 0s (no pull) | 10s | 50s | — |
| `soci` | 33s | 62s | 2s | 97s | 151 MB/s |
| `automode` | 35s | 57s | 2s | 94s | 164 MB/s |
| `soci-warm` | 0s | 0s (no pull) | 1s | 1s | — |

Throughput is the compressed image size divided by the observed pull duration, so it
includes both download and unpack. It can be compared across environments with different
image sizes.

### Observations

Provisioning took 29 to 40 seconds and was similar across the four variants. The image pull
varied between variants, and in the baseline it was longer than all other stages combined.

`automode` reached the same throughput range as `soci` without any of its configuration.
`soci` required `instanceStorePolicy: RAID0` and six lines of Bottlerocket settings;
`automode` required neither. The throughput difference between the two, 164 against
151 MB/s, is within the run-to-run variation shown in the repeatability section below.

SOCI reduced the pull from 95 to 62 seconds and raised throughput from 98 to 151 MB/s, with
the image unchanged and no change to the build pipeline.

The snapshot removed the pull. kubelet reported the image as already present and did not
contact the registry, and start-to-Ready went from 125 to 50 seconds. The snapshot took
several minutes to build and has to be rebuilt whenever the image changes; that time is not
included in the table.

The warm run went from 97 seconds to 1 second, so 96 seconds of the cold measurement was
incurred once per node rather than once per pod. For a workload where most pods are
scheduled onto nodes that are already running, the mechanisms in `snapshot`, `soci` and
`automode` affect a small part of the total startup time.

## Phase 2 — how the weights reach GPU memory

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` — copy to disk, vLLM default loader | 96s | 0.65s | 96.6s |
| `runai-local` — copy to disk, Run:ai Model Streamer | 93s | 0.65s | 93.6s |
| `runai-s3` — no copy, streamer reads S3 directly | 82s | 0.65s | 82.6s |

Within the "workload becomes Ready" stage, from vLLM's log:

| | `s3-initcontainer` | `runai-s3` |
|---|---:|---:|
| Reading the weights | 0.31s | — |
| Model load total | 0.63s | 3.36s |
| `torch.compile` | 14.8s | 14.7s |
| Engine init, KV cache, warmup | 28.2s | 27.9s |
| CUDA graph capture | 4.0s | 4.0s |

### Observations

Changing only the loader did not change the total. Variants 1 and 2 use identical bytes on
identical disk with a different loader, and both took 93 to 96 seconds. vLLM's log shows
that reading the weights took 0.31 seconds out of 96, so a faster loader could only affect
that interval.

Changing the delivery reduced the total from 96 to 82 seconds. The model load time increased
from 0.63 to 3.36 seconds, so reading from S3 is slower per tensor than reading from local
disk. The reduction comes from removing the copy step, which took about 10 seconds.

At this model size, compilation and warmup were the largest components. `torch.compile` at
14.7 seconds, engine init at 27.9 seconds and graph capture at 4 seconds account for about
47 of the 82 seconds. Neither the loader nor the delivery method affects these.

## Repeatability

Phase 1 was run twice, several hours apart, with newly provisioned nodes each time:

| Variant | Run 1 | Run 2 | Difference |
|---|---:|---:|---:|
| `baseline` | 127s | 125s | 1.6% |
| `snapshot` | 46s | 50s | 8.7% |
| `soci` | 89s | 97s | 9.0% |
| `automode` | 89s | 94s | 5.6% |
| `soci-warm` | 2s | 1s | — |
| `weights-runai-s3` | 83s | 82s | 1.2% |

All differences were within about 9%, which is the basis for treating a difference below
about 10% as requiring a repeat run before being relied on.

In run 1, `soci` and `automode` were both 89 seconds. In run 2 they were 97 and 94 seconds.
The ordering between them was not the same in both runs, so these figures do not show one to
be faster than the other.

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
| インスタンスタイプ | `g6.4xlarge`（L4 1 基、16 vCPU、ローカル NVMe 600 GB） |
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
| `baseline` | 29s | 95s | 1s | 125s | 98 MB/s |
| `snapshot` | 40s | 0s（pull なし） | 10s | 50s | — |
| `soci` | 33s | 62s | 2s | 97s | 151 MB/s |
| `automode` | 35s | 57s | 2s | 94s | 164 MB/s |
| `soci-warm` | 0s | 0s（pull なし） | 1s | 1s | — |

スループットは圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージサイズが異なる環境間でも比較できます。

### 観察された内容

プロビジョニングは 29〜40 秒で、4 variant でほぼ同じでした。イメージ pull は variant 間で変動
し、ベースラインでは他の全段階の合計より長くなっています。

`automode` は `soci` の設定を一切行わずに、`soci` と同じスループット帯に達しました。`soci` は
`instanceStorePolicy: RAID0` と Bottlerocket 設定 6 行を必要とし、`automode` はどちらも不要
です。両者のスループット差（164 対 151 MB/s）は、後述の再現性セクションに示す実行ごとの
ばらつきの範囲内です。

SOCI は pull を 95 秒から 62 秒に、スループットを 98 から 151 MB/s にしました。イメージは
変更せず、ビルドパイプラインの変更もありません。

スナップショットは pull を無くしました。kubelet はイメージが既に存在すると報告し、レジストリ
には接続せず、start-to-Ready は 125 秒から 50 秒になりました。スナップショットの作成には数分
かかり、イメージが変わるたびに作り直しが必要です。その時間は表に含まれていません。

warm 実行は 97 秒から 1 秒になり、cold の計測のうち 96 秒が Pod ごとではなくノード 1 台につき
1 回発生する分でした。Pod の大半がすでに動いているノードにスケジュールされるワークロードでは、
`snapshot` / `soci` / `automode` の各方式が影響するのは起動時間全体の一部です。

## フェーズ 2 — ウェイトの届き方

| Variant | Ready | Ready 後の TTFT | submit から最初のトークンまで |
|---|---:|---:|---:|
| `s3-initcontainer` — ディスクへコピー、vLLM 既定ローダー | 96s | 0.65s | 96.6s |
| `runai-local` — ディスクへコピー、Run:ai Model Streamer | 93s | 0.65s | 93.6s |
| `runai-s3` — コピーなし、streamer が S3 を直接読む | 82s | 0.65s | 82.6s |

「workload becomes Ready」の段階の内訳（vLLM のログより）:

| | `s3-initcontainer` | `runai-s3` |
|---|---:|---:|
| ウェイトの読み込み | 0.31s | — |
| モデルロード合計 | 0.63s | 3.36s |
| `torch.compile` | 14.8s | 14.7s |
| engine init、KV cache、warmup | 28.2s | 27.9s |
| CUDA graph capture | 4.0s | 4.0s |

### 観察された内容

ローダーのみを変えても合計は変わりませんでした。variant 1 と 2 は同じディスク上の同じバイト列
をローダーだけ変えて読み、どちらも 93〜96 秒でした。vLLM のログでは、ウェイトの読み込みは
96 秒中 0.31 秒であり、より速いローダーが影響できるのはこの区間だけです。

配送を変えると合計は 96 秒から 82 秒になりました。モデルロード時間は 0.63 秒から 3.36 秒に
増えており、S3 からの読み込みはテンソル単位ではローカルディスクより遅くなっています。短縮分は、
約 10 秒かかっていたコピー工程が無くなったことによります。

このモデルサイズでは、コンパイルとウォームアップが最大の要素でした。`torch.compile` が
14.7 秒、engine init が 27.9 秒、graph capture が 4 秒で、82 秒のうち約 47 秒を占めます。
ローダーも配送方法もこれには影響しません。

## 再現性

フェーズ 1 は数時間の間隔をあけて 2 回、いずれも新規に起動したノードで実行しました。

| Variant | 1 回目 | 2 回目 | 差 |
|---|---:|---:|---:|
| `baseline` | 127s | 125s | 1.6% |
| `snapshot` | 46s | 50s | 8.7% |
| `soci` | 89s | 97s | 9.0% |
| `automode` | 89s | 94s | 5.6% |
| `soci-warm` | 2s | 1s | — |
| `weights-runai-s3` | 83s | 82s | 1.2% |

差はいずれも約 9% 以内でした。10% 程度未満の差については、再実行で確認してから判断する根拠に
なります。

1 回目は `soci` と `automode` がともに 89 秒、2 回目は 97 秒と 94 秒でした。両者の順序は 2 回で
同じではないため、これらの数字からどちらが速いとは言えません。
