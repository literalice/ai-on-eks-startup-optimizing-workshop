# AI on EKS — Startup Time Optimizing Workshop
# AI on EKS — 起動時間最適化ワークショップ

Measure where a GPU inference pod's start-to-ready time actually goes on Amazon
EKS, then put a number on each way of making it shorter. Nothing here is a
benchmark you are asked to believe: every stage is computed from timestamps
Kubernetes already records, and the scripts are the deliverable.

Amazon EKS 上で GPU 推論 Pod の起動時間が実際どこに消えているかを計測し、短縮手段
それぞれに数字を付けるワークショップです。信じてもらう前提のベンチマークではありません。
すべての段階は Kubernetes が元から記録しているタイムスタンプから算出しており、
スクリプト自体が成果物です。

**Out of scope / 対象外:** building custom Bottlerocket AMIs.
カスタム Bottlerocket AMI のビルドは扱いません。

---

## What gets measured / 何を計測するか

Four arms. Same pod spec, same instance type, same VPC and subnets, same
container image. The only thing that differs is **how the container image reaches
the node**.

4 つの arm を比較します。Pod spec、インスタンスタイプ、VPC とサブネット、
コンテナイメージはすべて同一です。違うのは **コンテナイメージがどうノードに届くか**
だけです。

| Arm | Node | Image mechanism | Configuration required |
|---|---|---|---|
| **A** `arm-a-baseline` | Karpenter + Bottlerocket | EBS data volume, containerd's default sequential pull | none — Bottlerocket as shipped |
| **B** `arm-b-snapshot` | Karpenter + Bottlerocket | data volume restored from an EBS snapshot that already holds the layers | build and maintain a snapshot per image version |
| **C** `arm-c-soci` | Karpenter + Bottlerocket | container storage on local NVMe, SOCI snapshotter in parallel pull/unpack mode | `instanceStorePolicy` + 6 lines of Bottlerocket settings |
| **D** `arm-d-automode` | EKS Auto Mode | local NVMe and parallel pull, both set up by the service | none |

Two constraints to state before any numbers appear:

数字を出す前に、制約を 2 点明示しておきます。

**B and C are mutually exclusive.** They compete for the same thing: the volume
Bottlerocket uses for container images. Arm B needs the images on the volume
restored from the snapshot; the moment you move container storage to local NVMe
the snapshot is bypassed. You pick one — measuring them side by side is the point.

**B と C は排他です。** 両者は Bottlerocket がコンテナイメージに使う同じボリュームを
取り合います。B はスナップショットから復元したボリューム上にイメージが必要ですが、
コンテナストレージをローカル NVMe に移した瞬間 (C) にスナップショットは参照されなく
なります。どちらか一方しか選べません。並べて計測することがこのワークショップの主眼です。

**Arm D cannot do arm B's mechanism.** Auto Mode's `NodeClass` exposes
`ephemeralStorage` as size, IOPS, throughput and KMS key only — there is no
`snapshotID`. If pre-baked images turn out to be the right answer for a workload,
that workload does not go on Auto Mode.

**D では B の方式が取れません。** Auto Mode の `NodeClass` が公開しているのは
`ephemeralStorage` の size / IOPS / throughput / KMS キーだけで、`snapshotID` は
ありません。あるワークロードの答えが「イメージ事前焼き込み」だった場合、その
ワークロードは Auto Mode に乗りません。

Then two further measurements that change the conclusion:

さらに、結論を左右する計測を 2 つ行います。

- **Warm scale-out** — the same arm again onto a node that is already running.
  The cold runs measure the *first* pod on a *new* node, which is not what most
  scale-out events look like.
  **warm スケールアウト** — 既に動いているノードに 2 個目の Pod を投げます。
  cold の計測は「新しいノードの 1 個目」であり、実際のスケールアウトの多くはそうでは
  ありません。
- **How the model weights reach GPU memory** — three variants, including
  Run:ai Model Streamer, plus time to first token.
  **モデルウェイトが GPU メモリに届く経路** — Run:ai Model Streamer を含む 3 通りと、
  time to first token。

### How the numbers are produced / 数字の作り方

`bin/stages.py` collects every timestamp Kubernetes already records and reports
the gap between each consecutive pair:

`bin/stages.py` は Kubernetes が元から記録している時刻を集め、隣接する時刻の差を
段階として報告します。

- Pod `creationTimestamp`, conditions, container and init-container states
- NodeClaim `creationTimestamp` and Karpenter's `Launched` / `Registered` conditions
- The Node's own `Ready` condition
- kubelet `Pulling` and `Pulled` events, which also carry the pull duration and
  the compressed image size in their message text
- For phase 2, vLLM's own log lines (weight load, `torch.compile`, engine warmup)

**The stages therefore sum to the total exactly.** There is no residual bucket and
no time quietly unattributed, which is what makes comparing arms worth arguing
about. Kubernetes records these at one-second granularity, so treat sub-second
differences as noise.

**したがって段階の合計は必ず全体と一致します。** 余り箱もなく、黙って取りこぼした時間も
ありません。これが arm 間の比較を議論に耐えるものにしています。Kubernetes の記録は
秒単位なので、1 秒未満の差はノイズとして扱ってください。

---

## Reference results / 参考計測値

One measured run is published in [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md), so
you can see the shape before spending anything. Read it as *one* measurement in
*one* account — your absolute numbers will differ, and the point of running this
yourself is to get yours.

実測値を 1 回分 [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md) に載せています。費用を
かける前に傾向を確認できます。ただし **1 アカウントでの 1 回の計測**として読んでください。
絶対値は環境で変わります。自分で回して自分の数字を得ることが目的です。

---

## Prerequisites / 前提

- `aws`, `kubectl`, `terraform`, `jq`, `python3`
- Credentials for an account you are willing to build two EKS clusters in
  EKS クラスターを 2 面作って構わないアカウントの認証情報
- **GPU quota.** The arms are pinned to one instance type (`g6.4xlarge` = 16 vCPU).
  Sequential runs need 16 vCPU of *Running On-Demand G and VT instances*; request
  64 so re-runs do not block.
  **GPU クォータ。** 全 arm を 1 つのインスタンスタイプ (`g6.4xlarge` = 16 vCPU) に
  固定しています。逐次実行なら 16 vCPU で足りますが、再実行で詰まらないよう 64 を
  申請してください。
  ```bash
  aws service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --region us-west-2
  ```
- For phase 2 only: the `hf` CLI (`pip install --upgrade 'huggingface_hub[cli]'`)
  フェーズ 2 のみ: `hf` CLI

### Cost and time / 費用と時間

Roughly **USD 6–12** and about **2 hours** end to end, most of it unattended
preparation. Two EKS clusters plus a NAT gateway accrue about USD 0.35/hour even
with no GPU nodes running, so tear down when finished.

おおよそ **6〜12 USD**、所要 **約 2 時間**（大半は無人で進む準備作業）。GPU ノードが
無くても EKS クラスター 2 面 + NAT ゲートウェイで **約 0.35 USD/時**かかるため、
終わったら破棄してください。

### Why the instance type matters / インスタンスタイプが重要な理由

`g6.4xlarge` — 1× L4, 16 vCPU, 600 GB local NVMe, up to 25 Gbps.

Local NVMe is **mandatory**: arms C and D both need it. The vCPU count is not
incidental either — SOCI's parallel unpack is CPU-bound, so a `2xlarge`
understates the gain and an `8xlarge` overstates it relative to a typical
inference node. Change `GPU_INSTANCE_TYPE` in `config.env` to match what you
actually run, and expect the arm C number to move with it.

ローカル NVMe は **必須**です（arm C と D が必要とします）。vCPU 数も偶然ではありません。
SOCI の並列展開は CPU バウンドなので、`2xlarge` では効果を過小評価し、`8xlarge` では
一般的な推論ノードに比べて過大評価になります。`config.env` の `GPU_INSTANCE_TYPE` を
実際に使う型に変え、arm C の数字がそれに応じて動くことを前提にしてください。

---

## Setup / セットアップ

### 1. Configure / 設定

```bash
$EDITOR config.env
```

Every value uses `${VAR:-default}`, so anything already set in the environment
wins — you can override one setting for a single run without editing the file:

すべての値が `${VAR:-default}` 形式なので、環境変数が優先されます。ファイルを編集せず
1 回だけ上書きできます。

```bash
GPU_INSTANCE_TYPE=g6.8xlarge bin/bench.sh arm-c-soci
```

Confirm the workload image tag still exists — AWS Deep Learning Container tags
move, and a stale tag fails at the worst moment:

ワークロードイメージのタグが生きているか確認してください。AWS Deep Learning Container
のタグは更新されるため、古いタグは最悪のタイミングで失敗します。

```bash
aws ecr describe-images --region us-west-2 \
  --registry-id 763104351884 --repository-name vllm \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags'
```

The default is a vLLM Deep Learning Container: large, GPU, and readable by any AWS
account, so there is no registry credential and no build step.

既定値は vLLM の Deep Learning Container です。サイズが大きく GPU 対応で、どの AWS
アカウントからも読めるため、レジストリ認証もビルド工程も不要です。

### 2. Build the environment / 環境構築

```bash
cd terraform
terraform init
terraform apply
cd ..
```

This creates one shared VPC and two clusters:

共有 VPC 1 つとクラスター 2 面を作ります。

- `<prefix>-karpenter` — self-managed Karpenter, carries arms A, B and C
- `<prefix>-automode` — EKS Auto Mode, carries arm D

Two clusters rather than one because self-managed Karpenter and Auto Mode both own
the `karpenter.sh` CRDs. They share the VPC and subnets, so the image pull path is
identical and the numbers stay comparable — but it is not the same control plane,
which the generated report restates.

1 面ではなく 2 面にしているのは、self-managed Karpenter と Auto Mode が同じ
`karpenter.sh` の CRD を持つためです。VPC とサブネットは共有するので pull 経路は
同一で数字は比較可能ですが、コントロールプレーンは別です。この点は生成されるレポートにも
明記されます。

Kubernetes is pinned to **1.34 or above** deliberately: the EKS-optimized
Bottlerocket NVIDIA AMI ships NVIDIA driver 580 only from 1.34, and driver 580 is
required for the CUDA 13 image used here.

Kubernetes を **1.34 以上**に固定しているのは意図的です。EKS 最適化 Bottlerocket
NVIDIA AMI が NVIDIA ドライバ 580 を載せるのは 1.34 以降で、ここで使う CUDA 13
イメージには 580 が必要です。

No NVIDIA device plugin is deployed anywhere in either cluster. The Bottlerocket
NVIDIA AMI already contains the driver, the container toolkit **and** the
Kubernetes device plugin; Auto Mode handles its own. The readiness probe runs
`nvidia-smi` inside the container, so "Ready" proves the GPU is genuinely usable.

どちらのクラスターにも NVIDIA device plugin をデプロイしていません。Bottlerocket
NVIDIA AMI にはドライバ、container toolkit、**および Kubernetes device plugin** が
既に入っており、Auto Mode は自前で面倒を見ます。readiness probe はコンテナ内で
`nvidia-smi` を実行するので、Ready は GPU が実際に使える状態を意味します。

### 3. Build the arm B snapshot / arm B のスナップショット作成

Run arm A first and do not reset afterwards, then snapshot that node's data volume:

先に arm A を実行し、reset せずにそのノードのデータボリュームをスナップショットします。

```bash
./bin/bench.sh arm-a-baseline        # leaves a node with the image cached
./snapshot/snapshot-from-node.sh     # ~3-5 min
```

The snapshot ID lands in `results/snapshot-id.txt` and `bin/prep.sh` picks it up.

スナップショット ID は `results/snapshot-id.txt` に書かれ、`bin/prep.sh` が拾います。

> **`snapshot/build-snapshot.sh` did not work for us.** It wraps
> [`aws-samples/bottlerocket-images-cache`][cache], which launches its own
> Bottlerocket instance and drives it over SSM Run Command. On the EKS-optimized
> Bottlerocket NVIDIA AMI the instance never registered with SSM — public subnet,
> public IP and instance profile all correct — and the script sat at
> "Launching SSM" indefinitely with no timeout. It is kept for reference only.
>
> **`snapshot/build-snapshot.sh` は当環境では動作しませんでした。**
> [`aws-samples/bottlerocket-images-cache`][cache] のラッパーで、専用の Bottlerocket
> インスタンスを起動して SSM Run Command で操作します。EKS 最適化 Bottlerocket
> NVIDIA AMI では、パブリックサブネット・パブリック IP・インスタンスプロファイルが
> すべて正しいにもかかわらず SSM に登録されず、タイムアウトも無いまま
> "Launching SSM" で停止しました。参考として残してあります。
>
> Snapshotting a node you already have is also strictly more faithful: the cached
> layers were written by the same containerd and OS version that will later consume
> them. It must be an **arm A** node, not arm C — `instanceStorePolicy` moves arm
> C's container storage to local NVMe, leaving its EBS data volume empty.
>
> 既にあるノードをスナップショットする方が忠実でもあります。キャッシュされた層を書いた
> containerd と OS のバージョンが、後でそれを読む側と同一になるためです。対象は
> **arm A** のノードである必要があります。arm C は `instanceStorePolicy` で
> コンテナストレージがローカル NVMe に移るため、EBS データボリュームは空です。

Either way the build time is not a footnote — it is the cost of arm B, and it
recurs on **every** image change. Weigh it against arm B's measured gain in
section 5.

いずれの方式でも、この作成時間は注釈ではなく **arm B のコスト**です。しかもイメージを
更新するたびに再発します。セクション 5 で arm B の実測短縮幅と並べて検討してください。

### 4. Apply the arms / arm の適用

```bash
./bin/prep.sh
```

Renders the manifests with the Terraform outputs, applies each arm to the right
cluster, and **asserts the Bottlerocket AMI is at least 1.44.0**. That assertion
matters: SOCI parallel pull/unpack landed in 1.44.0, and on anything older the
snapshotter setting is silently ignored — arm C would then measure the same thing
as arm A and read as "SOCI does not help".

Terraform の出力でマニフェストを展開し、各 arm を正しいクラスターに適用し、
**Bottlerocket AMI が 1.44.0 以上であることを検証**します。この検証は重要です。
SOCI の parallel pull/unpack は 1.44.0 で入ったため、それより古いと snapshotter の
設定は黙って無視され、arm C は arm A と同じものを計測して「SOCI は効かない」と
読めてしまいます。

---

## Running it / 実行

One arm at a time. Each run deletes the arm's node first, so every measurement is
a genuine cold start.

1 つずつ実行します。各実行はまずその arm のノードを削除するので、毎回本当のコールド
スタートになります。

```bash
./bin/bench.sh arm-a-baseline
./bin/bench.sh arm-b-snapshot
./bin/bench.sh arm-c-soci
./bin/bench.sh arm-d-automode
```

**Each step's number appears on screen as that step completes**, so the breakdown
builds up during the run rather than arriving all at once at the end:

**各段階の数字は、その段階が終わった瞬間に画面に出ます。** 最後に一度に出るのではなく、
実行中に積み上がっていきます。

```
  step                                         at   step took
  -------------------------------------- -------- -----------
  -> node ip-10-0-42-17
  Karpenter decided, NodeClaim created         1s          1s
  EC2 instance launched                        3s          2s
  node registered with the cluster            20s         17s
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
  container started                          126s          0s
  workload Ready                             127s          1s
  -------------------------------------- -------- -----------
  submit to Ready                            127s
```

`at` is measured from the pod's own `creationTimestamp` — the same anchor the final
table uses, so the live numbers and the report agree. `step took` is the per-step
number.

`at` は Pod 自身の `creationTimestamp` を起点にしています。最終集計表と同じ起点なので、
ライブ表示とレポートの数字は一致します。`step took` が各段階の所要時間です。

When the arm finishes, `stages.py` reprints the breakdown with the node's actual
instance type, zone and OS image, plus the **effective image throughput** —
compressed image size over the observed pull window, covering download *and*
unpack. That rate is the number that stays comparable when the image is not ours.

arm が終わると `stages.py` が、実際に起動したノードのインスタンスタイプ・AZ・OS
イメージとあわせて内訳を再表示し、**実効イメージスループット**を出します。これは
圧縮イメージサイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。
イメージが異なる環境でも比較可能な数字はこれです。

### Warm scale-out / warm スケールアウト

```bash
./bin/bench.sh arm-c-soci --warm
```

Deletes only the pod, keeps the NodeClaim, and submits again. (The pod has to go
first — these instance types have one GPU, so two pods cannot share the node.)

Pod だけを削除し、NodeClaim は残して再投入します（GPU が 1 基なので 2 つの Pod は
同居できず、先に Pod を消す必要があります）。

`report.py` then prints the pair:

```
  arm-c-soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

Read the last figure as the part a pre-warmed or longer-lived node avoids
entirely. **Where it dominates, the mechanisms in this workshop matter; where it
does not, the answer is capacity policy rather than image delivery.** Running this
also stops arm B being over-credited — a snapshot helps the cold pod and does
nothing for the warm one.

最後の数字は、事前ウォームや長寿命ノードなら完全に回避できる部分です。**ここが支配的なら
本ワークショップの各方式が効きますが、そうでなければ答えはイメージ配送ではなく
キャパシティ方針です。** これを計測することで arm B の過大評価も防げます。スナップ
ショットが効くのは cold な 1 個目だけで、warm には何もしません。

### Phase 2 — how the weights reach GPU memory / ウェイトが GPU メモリに届く経路

Stage the weights once:

```bash
# put MODEL_BUCKET from `terraform output -raw model_bucket` into config.env
./snapshot/stage-model.sh
```

Then three variants — same node, same model, same bytes, only the loader differs:

3 通りを実行します。ノード・モデル・バイト列は同一で、ローダーだけが違います。

```bash
./bin/bench.sh weights s3-initcontainer   # copy S3 -> disk, vLLM default loader
./bin/bench.sh weights runai-local        # copy S3 -> disk, Run:ai Model Streamer
./bin/bench.sh weights runai-s3           # no copy: streamer reads S3 directly
```

They isolate **two separate effects**, and reporting them separately keeps one from
being credited to the other:

**2 つの異なる効果**を切り分けます。別々に報告することで、一方の効果をもう一方の功績に
しないようにしています。

- `s3-initcontainer` → `runai-local` changes **only the loader**. Identical bytes
  on identical disk, so the difference is what concurrent tensor streaming is worth.
  **ローダーのみ**を変更。同じディスク上の同じバイト列なので、差は並列テンソル
  ストリーミング単体の効果です。
- `runai-local` → `runai-s3` changes **only the delivery**. The init container
  disappears entirely.
  **配送のみ**を変更。init コンテナが完全に消えます。

That second step also removes a defect in the obvious implementation: kubelet
pulls the init image, runs the init container, and *only then* pulls the workload
image. The copy and the image pull are **serialised**, so moving weights out of the
image can push start-to-Ready up even though the image got smaller. Streaming
straight from S3 deletes that step rather than optimising it.

2 つ目の変更は、素直な実装が持つ欠陥も取り除きます。kubelet は init イメージを pull し、
init コンテナを実行し、**その後で**本体イメージを pull します。コピーと pull は
**直列**なので、イメージを小さくしても start-to-Ready が伸びることがあります。
S3 から直接ストリームする方式は、この工程を最適化するのではなく削除します。

`runai-streamer` and its S3 backend already ship in the AWS vLLM Deep Learning
Container base image, so no custom build is needed. Verify it against a node that
already has the image:

`runai-streamer` と その S3 バックエンドは AWS vLLM Deep Learning Container の
ベースイメージに既に含まれており、独自ビルドは不要です。イメージを持っているノードで
確認できます。

```bash
./bin/check_runai.sh
```

**Credentials come from EKS Pod Identity**, bound by Terraform to the `bench`
service account. Not the node role, and this is worth knowing before you copy the
pattern: Karpenter defaults the IMDS hop limit to 1, so a container cannot reach
instance metadata at all, and using the node role fails with
`Unable to locate credentials`. That default is correct — pods should not silently
inherit node permissions — so scoping a role to one service account is both the
thing that works and the thing to do in production.

**認証情報は EKS Pod Identity** から取得します。Terraform が `bench` サービス
アカウントに紐付けます。ノードロールではありません。この点は流用前に知っておく価値が
あります。Karpenter は IMDS の hop limit を既定で 1 にするため、コンテナはインスタンス
メタデータに到達できず、ノードロールを使うと `Unable to locate credentials` で失敗します。
この既定は正しい挙動です（Pod がノードの権限を暗黙に継承すべきではない）。したがって
サービスアカウント単位でロールを絞ることが、動く方法であり本番でも正しい方法です。

### Time to first token / TTFT

Ready only means vLLM answers `/health`. It does not mean the server will produce
a token promptly. Phase 2 runs therefore also measure **submit to first token**:

Ready は vLLM が `/health` に応答することしか意味せず、速やかにトークンを出せることは
意味しません。そのためフェーズ 2 では **submit から最初のトークンまで**も計測します。

```
  time to first token after Ready  0.65s
  submit to first token            93.6s   <- the number a user would feel
```

The probe streams a completion and stops the clock on the first token carrying
text — streaming matters, because without it the only measurable thing is total
latency, which is dominated by how many tokens you asked for. It runs *inside* the
pod ([bin/first_token.py](bin/first_token.py), loaded as a ConfigMap by
`prep.sh`), so there is no port-forward to be flaky and no assumption about `curl`
being in the image.

プローブはストリーミングで補完を要求し、テキストを含む最初のトークンで時計を止めます。
ストリーミングが重要です。使わないと計測できるのは総レイテンシだけで、それは要求した
トークン数に支配されてしまいます。プローブは Pod の**内側**で動くため
（[bin/first_token.py](bin/first_token.py)、`prep.sh` が ConfigMap として投入）、
不安定な port-forward も、`curl` がイメージにある前提も不要です。

### Resetting / リセット

```bash
./bin/reset.sh                 # all arms
./bin/reset.sh arm-c-soci      # one arm
```

---

## Recording it / 録画

`bin/demo.sh` runs the whole sequence with English commentary printed between the
commands, so a recording explains itself without a voice track. `bin/record.sh`
wraps that in asciinema and renders an mp4:

`bin/demo.sh` は一連の流れをコマンド間に英語の解説を挟みながら実行するため、録画物が
音声なしで自己説明します。`bin/record.sh` は asciinema でそれを収録し mp4 にします。

```bash
./bin/record.sh              # the real thing
./bin/record.sh --quick      # skips the cold baseline, for a shorter video
./bin/record.sh --rehearse   # fixture data, no AWS calls
```

Output lands in `recording/`: a `.cast` (small, re-renderable source), a `.gif`,
and an `.mp4` at 1184x840.

出力は `recording/` に置かれます。`.cast`（小さく再レンダリング可能な元データ）、`.gif`、
1184x840 の `.mp4` です。

> **On the pacing.** asciinema is given `--idle-time-limit`, which caps dead air in
> *playback*. A 96-second image pull becomes a few seconds of video. The elapsed
> times printed on screen are the real ones and are untouched — only the waiting
> between them is shortened. **Say this out loud if you show the video to someone**,
> because a viewer will otherwise read the pace as the measurement.
>
> **再生速度について。** asciinema に `--idle-time-limit` を渡しており、**再生上の**
> 無音時間を打ち切ります。96 秒の pull は数秒の映像になります。画面に出る経過秒数は
> 本物で、一切加工していません。縮めているのはその間の待ち時間だけです。**動画を人に
> 見せるときは必ずこの点を口頭で添えてください。** そうしないと視聴者は再生速度を
> 計測値として読んでしまいます。

The idle cap is set equal to the narration beat rather than shorter. A shorter cap
would compress the reading pauses too and the commentary would scroll past faster
than anyone can follow.

idle の打ち切り値は、ナレーションの間隔と同じ値にしています。それより短くすると読ませる
ための間も圧縮され、解説が読めない速さで流れてしまいます。

`--rehearse` runs the same demo against invented fixture data with a fake
`kubectl` on `PATH` and **no AWS calls at all** — for pacing the narration and
checking the pipeline without spending money. The real `bench.sh`,
`watch_stages.py`, `stages.py` and `report.py` all run unmodified; only `kubectl`
is replaced, so it exercises the tooling rather than replaying a transcript.
**Every number a rehearsal produces is invented**: `record.sh` puts `REHEARSAL` in
the filename, and rehearsal output goes to `rehearsal/.sandbox/` so it can never be
mistaken for a measurement in `results/`.

`--rehearse` は、偽の `kubectl` を `PATH` に置いて架空のフィクスチャデータで同じデモを
実行します。**AWS 呼び出しは一切ありません。** ナレーションの尺合わせとパイプライン確認を
無料で行うためのものです。`bench.sh` / `watch_stages.py` / `stages.py` / `report.py` は
本物がそのまま動き、差し替えるのは `kubectl` だけなので、収録済みの記録を再生するのでは
なくツール自体を動かします。**リハーサルが出す数字はすべて架空です。**`record.sh` は
ファイル名に `REHEARSAL` を入れ、出力は `rehearsal/.sandbox/` に書かれるため、
`results/` の実測値と混同されることはありません。

---

## Reading the result / 結果の読み方

`results/report.md` groups the stages into three buckets:

`results/report.md` は段階を 3 つに束ねます。

- **Provisioning** — Karpenter's decision, the EC2 launch, boot, registration,
  node Ready, binding. Largely the same across all four arms. If it is not, the
  cause is usually instance-type availability, not anything you configured.
  **プロビジョニング** — Karpenter の判断、EC2 起動、ブート、登録、ノード Ready、
  バインド。4 arm でほぼ同一です。異なる場合、原因は通常インスタンスタイプの在庫であり、
  設定ではありません。
- **Image** — the pull and unpack. This is what arms B, C and D each attack in a
  different way.
  **イメージ** — pull と展開。arm B / C / D がそれぞれ異なる方法で攻める部分です。
- **Workload** — container start, and for phase 2 the weight download and model load.
  **ワークロード** — コンテナ起動、およびフェーズ 2 のウェイトダウンロードとモデルロード。

The honest comparison is **A against C**: same provisioner, same OS, same instance,
one mechanism changed. Arm D adds a second variable (a different control plane), so
read it as indicative of what Auto Mode gives you for no configuration, not as a
like-for-like delta.

厳密な比較は **A と C** です。プロビジョナ、OS、インスタンスが同一で、変えたのは
1 つの方式だけです。arm D は変数が 1 つ増える（コントロールプレーンが別）ため、
like-for-like の差分ではなく「無設定で Auto Mode が何を与えるか」の目安として読んでください。

The report also prints **what actually launched** — instance type, zone, OS image
and runtime read back off each node. That turns "we compared like with like" from
an assertion into a check, and the report warns if the arms did not all get the
same instance type.

レポートには **実際に何が起動したか**（各ノードから読み戻したインスタンスタイプ、AZ、
OS イメージ、ランタイム）も出ます。「同条件で比較した」を主張ではなく検証にするためです。
arm 間でインスタンスタイプが揃わなかった場合は警告が出ます。

### What the table cannot tell you / 表が語らないこと

- **One run per arm.** Pull times move with registry and network conditions. Treat
  a difference under roughly 10% as noise until it repeats. Re-running an arm is
  cheap; `report.py` keeps the superseded run visible rather than overwriting it.
  **各 arm 1 回の計測です。** pull 時間はレジストリとネットワークの状況で動きます。
  10% 未満の差は、再現するまではノイズとして扱ってください。再実行は安価で、
  `report.py` は上書きせず旧結果を残します。
- **Arm B's snapshot build time is not in the table.** It is the maintenance cost
  that decides whether the mechanism is worth adopting.
  **arm B のスナップショット作成時間は表に入っていません。** 採用可否を決めるのは
  この保守コストです。
- **Arm C's SOCI tuning is not tuned for your images.** The values are the ones AWS
  publishes as a starting point. Layer count, layer size and vCPU all move the
  right answer.
  **arm C の SOCI チューニングはあなたのイメージ向けではありません。** AWS が出発点として
  公開している値です。レイヤ数・レイヤサイズ・vCPU で最適値は変わります。

---

## Section 5 — what to adopt / 何を採用するか

| If / 条件 | Then / 選択 | Because / 理由 |
|---|---|---|
| Images change rarely, startup latency critical<br>イメージ更新が稀で起動遅延が重要 | Arm B, the snapshot | Nothing to pull at all. Costs a snapshot rebuild per image version.<br>pull が皆無。イメージ版ごとの再作成が代償 |
| Images change often<br>イメージ更新が頻繁 | Arm C, SOCI on NVMe | No pre-work per image, no build-pipeline change, image unmodified.<br>イメージ単位の事前作業もビルド変更も不要 |
| Neither should be your problem<br>どちらも自分で持ちたくない | Arm D, Auto Mode | Arm C's behaviour with none of arm C's configuration — and you give up arm B's mechanism and SOCI's knobs.<br>arm C の挙動を無設定で。ただし arm B の方式と SOCI の調整項目は諦める |
| Weights dominate, not layers<br>支配要因がレイヤでなくウェイト | Stream from S3 | Shrinking the image does not help if model load is the long pole.<br>モデルロードが律速ならイメージ縮小は効かない |
| Warm-node time already dominates<br>warm ノードの時間が既に支配的 | None of these — capacity policy | If once-per-node cost is small next to steady-state startup, image delivery is the wrong thing to optimise.<br>ノード1回コストが定常起動より小さいなら、最適化対象が違う |

Two questions decide most of this, and neither is a matter of opinion: **how often
do your images change**, and **how much of your startup cost is once-per-node** —
which is what the warm run answers.

大半を決めるのは 2 つの問いで、どちらも意見の問題ではありません。**イメージの更新頻度**
（arm B と C の分かれ目）と、**起動コストのうちノード 1 回あたりの割合**（warm 実行が
答えます）です。

---

## Teardown / 破棄

```bash
./bin/reset.sh
cd terraform && terraform destroy
```

The arm B snapshot and the staged weights are not managed by Terraform:

arm B のスナップショットと S3 上のウェイトは Terraform 管理外です。

```bash
aws ec2 delete-snapshot --snapshot-id "$(cat results/snapshot-id.txt)" --region us-west-2
aws s3 rm "s3://$MODEL_BUCKET/$MODEL_PREFIX/" --recursive
```

---

## Layout / 構成

```
config.env                        every knob; the scripts read this
terraform/                        shared VPC + two clusters + model bucket + Pod Identity
manifests/
  karpenter/                      arms A, B, C  (EC2NodeClass + NodePool)
  automode/                       arm D         (NodeClass + NodePool)
  workload.yaml                   phase 1: the measured pod, cold and warm
  workload-weights.yaml           phase 2: one spec, three loader variants
  fragments/init-copy-weights.yaml  the S3-to-disk copy, inserted for two of them
  rendered/                       generated by prep.sh -- what actually applied
snapshot/
  snapshot-from-node.sh           arm B pre-work (preferred)
  build-snapshot.sh               arm B pre-work via aws-samples (did not work for us)
  stage-model.sh                  phase 2 pre-work
bin/
  prep.sh                         render + apply + version assertions
  bench.sh                        run one arm, collect, compute
  reset.sh                        return an arm to cold
  watch_stages.py                 live: print each step's number as it completes
  stages.py                       timestamps -> stage breakdown
  report.py                       all runs -> comparison + results/report.md
  first_token.py                  time to first token, runs inside the pod
  render_weights.py               phase 2 render (not sed: multi-line insertion)
  check_runai.sh                  confirm the image can do Run:ai streaming
  assert_br_version.py            guard against SOCI silently not running
  demo.sh                         the narrated sequence, for recording
  record.sh                       asciinema -> gif -> mp4
  rehearse.sh                     demo.sh against fixtures, no AWS calls
rehearsal/                        invented fixtures + a fake kubectl
raw/                              per-run Kubernetes objects, kept for audit
results/                          per-run JSON + report.md
```

`raw/` is worth keeping. It is the evidence behind every number in the report, and
it lets someone who was not in the room check the arithmetic. Each run's directory
also holds the exact manifest that produced it.

`raw/` は残す価値があります。レポートの全数字の根拠であり、その場にいなかった人が
計算を検算できます。各実行のディレクトリには、それを生成した実際のマニフェストも入っています。

Placeholders in the manifests are written `@LIKE_THIS@`. The delimiters stop a
substitution rewriting the token names in comments, and stop `@NODE_IAM_ROLE@`
matching inside `@KARPENTER_NODE_IAM_ROLE_NAME@`. The templates are valid YAML as
they stand, so editors and linters parse them before rendering.

マニフェストのプレースホルダは `@LIKE_THIS@` 形式です。区切り文字により、コメント内の
トークン名を置換してしまう事故と、`@NODE_IAM_ROLE@` が
`@KARPENTER_NODE_IAM_ROLE_NAME@` の内部に一致する事故を防いでいます。テンプレートは
そのままで妥当な YAML なので、展開前にエディタや linter が解析できます。

---

## References / 参考

- [Reduce container startup time on Amazon EKS with Bottlerocket data volume][blog]
- [EKS best practices: application scaling and performance][bp]
- [SOCI snapshotter parallel mode][soci]
- [Karpenter blueprint: SOCI snapshotter parallel pull/unpack][bpsoci]
- [Run:ai Model Streamer][runai] and [vLLM's integration][vllmrunai]
- [`aws-samples/bottlerocket-images-cache`][cache]

[blog]: https://aws.amazon.com/blogs/containers/reduce-container-startup-time-on-amazon-eks-with-bottlerocket-data-volume/
[bp]: https://docs.aws.amazon.com/eks/latest/best-practices/aiml-performance.html
[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md
[bpsoci]: https://github.com/aws-samples/karpenter-blueprints/tree/main/blueprints/soci-snapshotter
[runai]: https://github.com/run-ai/runai-model-streamer
[vllmrunai]: https://docs.vllm.ai/en/latest/models/extensions/runai_model_streamer.html
[cache]: https://github.com/aws-samples/bottlerocket-images-cache
