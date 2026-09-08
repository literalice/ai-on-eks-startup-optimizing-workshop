# Reference Results / 参考計測値

One measured run, recorded so that the breakdown can be reviewed before running the
workshop.

計測 1 回分の結果です。ワークショップを実行する前に内訳を確認できるように記載しています。

> This is a single measurement from a single account. Absolute figures depend on image
> size, instance type, region and registry conditions, so figures from another
> environment will differ. What can be compared across environments is which stage
> accounts for most of the time, and how each mechanism changes it.
>
> 1 アカウントでの 1 回の計測です。絶対値はイメージサイズ、インスタンスタイプ、リージョン、
> レジストリの状況に依存するため、別環境の数字は異なります。環境間で比較できるのは、
> どの段階が時間の大部分を占めるか、および各方式がそれをどう変えるかです。

## Conditions / 条件

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

## Phase 1 — how the image reaches the node / イメージの届き方

| Arm | Provisioning | Image | Workload | Start to Ready | Throughput |
|---|---:|---:|---:|---:|---:|
| `arm-a-baseline` | 29s | 95s | 1s | 125s | 98 MB/s |
| `arm-b-snapshot` | 40s | 0s (no pull) | 10s | 50s | — |
| `arm-c-soci` | 33s | 62s | 2s | 97s | 151 MB/s |
| `arm-d-automode` | 35s | 57s | 2s | 94s | 164 MB/s |
| `arm-c-soci-warm` | 0s | 0s (no pull) | 1s | 1s | — |

Throughput is the compressed image size divided by the observed pull duration, so it
includes both download and unpack. It can be compared across environments with
different image sizes.

スループットは圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージサイズが異なる環境間でも比較できます。

### Observations / 観察された内容

Provisioning took 29 to 40 seconds and was similar across the four arms. The image pull
varied between arms, and in the baseline it was longer than all other stages combined.

プロビジョニングは 29〜40 秒で、4 arm でほぼ同じでした。イメージ pull は arm 間で変動し、
ベースラインでは他の全段階の合計より長くなっています。

Arm D reached the same throughput range as arm C without any of arm C's configuration.
Arm C required `instanceStorePolicy: RAID0` and six lines of Bottlerocket settings; arm
D required neither. The throughput difference between the two, 164 against 151 MB/s, is
within the run-to-run variation shown in the repeatability section below.

arm D は arm C の設定を一切行わずに、arm C と同じスループット帯に達しました。arm C は
`instanceStorePolicy: RAID0` と Bottlerocket 設定 6 行を必要とし、arm D はどちらも不要です。
両者のスループット差（164 対 151 MB/s）は、後述の再現性セクションに示す実行ごとのばらつきの
範囲内です。

SOCI reduced the pull from 95 to 62 seconds and raised throughput from 98 to 151 MB/s,
with the image unchanged and no change to the build pipeline.

SOCI は pull を 95 秒から 62 秒に、スループットを 98 から 151 MB/s にしました。イメージは
変更せず、ビルドパイプラインの変更もありません。

The snapshot removed the pull. kubelet reported the image as already present and did not
contact the registry, and start-to-Ready went from 125 to 50 seconds. The snapshot took
several minutes to build and has to be rebuilt whenever the image changes; that time is
not included in the table.

スナップショットは pull を無くしました。kubelet はイメージが既に存在すると報告し、
レジストリには接続せず、start-to-Ready は 125 秒から 50 秒になりました。スナップショットの
作成には数分かかり、イメージが変わるたびに作り直しが必要です。その時間は表に含まれていません。

The warm run went from 97 seconds to 1 second, so 96 seconds of the cold measurement was
incurred once per node rather than once per pod. For a workload where most pods are
scheduled onto nodes that are already running, the mechanisms in arms B, C and D affect
a small part of the total startup time.

warm 実行は 97 秒から 1 秒になり、cold の計測のうち 96 秒が Pod ごとではなくノード 1 台に
つき 1 回発生する分でした。Pod の大半がすでに動いているノードにスケジュールされる
ワークロードでは、arm B / C / D の各方式が影響するのは起動時間全体の一部です。

## Phase 2 — how the weights reach GPU memory / ウェイトの届き方

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` — copy to disk, vLLM default loader | 96s | 0.65s | 96.6s |
| `runai-local` — copy to disk, Run:ai Model Streamer | 93s | 0.65s | 93.6s |
| `runai-s3` — no copy, streamer reads S3 directly | 82s | 0.65s | 82.6s |

Within the "workload becomes Ready" stage, from vLLM's log:

「workload becomes Ready」の段階の内訳（vLLM のログより）:

| | `s3-initcontainer` | `runai-s3` |
|---|---:|---:|
| Reading the weights | 0.31s | — |
| Model load total | 0.63s | 3.36s |
| `torch.compile` | 14.8s | 14.7s |
| Engine init, KV cache, warmup | 28.2s | 27.9s |
| CUDA graph capture | 4.0s | 4.0s |

### Observations / 観察された内容

Changing only the loader did not change the total. Variants 1 and 2 use identical bytes
on identical disk with a different loader, and both took 93 to 96 seconds. vLLM's log
shows that reading the weights took 0.31 seconds out of 96, so a faster loader could
only affect that interval.

ローダーのみを変えても合計は変わりませんでした。variant 1 と 2 は同じディスク上の同じ
バイト列をローダーだけ変えて読み、どちらも 93〜96 秒でした。vLLM のログでは、ウェイトの
読み込みは 96 秒中 0.31 秒であり、より速いローダーが影響できるのはこの区間だけです。

Changing the delivery reduced the total from 96 to 82 seconds. The model load time
increased from 0.63 to 3.36 seconds, so reading from S3 is slower per tensor than reading
from local disk. The reduction comes from removing the copy step, which took about 10
seconds.

配送を変えると合計は 96 秒から 82 秒になりました。モデルロード時間は 0.63 秒から 3.36 秒に
増えており、S3 からの読み込みはテンソル単位ではローカルディスクより遅くなっています。
短縮分は、約 10 秒かかっていたコピー工程が無くなったことによります。

At this model size, compilation and warmup were the largest components. `torch.compile`
at 14.7 seconds, engine init at 27.9 seconds and graph capture at 4 seconds account for
about 47 of the 82 seconds. Neither the loader nor the delivery method affects these.

このモデルサイズでは、コンパイルとウォームアップが最大の要素でした。`torch.compile` が
14.7 秒、engine init が 27.9 秒、graph capture が 4 秒で、82 秒のうち約 47 秒を占めます。
ローダーも配送方法もこれには影響しません。

## Repeatability / 再現性

Phase 1 was run twice, several hours apart, with newly provisioned nodes each time:

フェーズ 1 は数時間の間隔をあけて 2 回、いずれも新規に起動したノードで実行しました。

| Arm | Run 1 | Run 2 | Difference |
|---|---:|---:|---:|
| `arm-a-baseline` | 127s | 125s | 1.6% |
| `arm-b-snapshot` | 46s | 50s | 8.7% |
| `arm-c-soci` | 89s | 97s | 9.0% |
| `arm-d-automode` | 89s | 94s | 5.6% |
| `arm-c-soci-warm` | 2s | 1s | — |
| `weights-runai-s3` | 83s | 82s | 1.2% |

All differences were within about 9%, which is the basis for treating a difference below
about 10% as requiring a repeat run before being relied on.

差はいずれも約 9% 以内でした。10% 程度未満の差については、再実行で確認してから判断する
根拠になります。

In run 1, arms C and D were both 89 seconds. In run 2 they were 97 and 94 seconds. The
ordering between them was not the same in both runs, so these figures do not show one to
be faster than the other.

1 回目は arm C と D がともに 89 秒、2 回目は 97 秒と 94 秒でした。arm C と arm D の順序は
2 回で同じではないため、これらの数字からどちらが速いとは言えません。
