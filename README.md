# AI on EKS — Startup Time Optimizing Workshop
# AI on EKS — 起動時間最適化ワークショップ

This workshop measures how long a GPU inference pod takes to become ready on Amazon
EKS, breaks that time into stages, and then measures three methods of reducing it.
Each stage is calculated from timestamps that Kubernetes already records. The scripts
that do the measurement are included.

このワークショップでは、Amazon EKS 上で GPU 推論 Pod が Ready になるまでの時間を計測し、
段階に分解した上で、短縮方法を 3 つ計測します。各段階は Kubernetes が元から記録している
タイムスタンプから算出します。計測に使うスクリプトも同梱しています。

**Out of scope / 対象外:** building custom Bottlerocket AMIs.
カスタム Bottlerocket AMI のビルドは扱いません。

---

## What gets measured / 何を計測するか

There are four variants. The pod spec, instance type, VPC, subnets and container image are
the same in all four. The difference between them is how the container image reaches
the node.

variant は 4 つあります。Pod spec、インスタンスタイプ、VPC、サブネット、コンテナイメージは
4 つとも同じです。異なるのは、コンテナイメージがノードに届く方法です。

| Variant | Node | Image mechanism | Configuration required |
|---|---|---|---|
| `baseline` | Karpenter + Bottlerocket | EBS data volume, containerd's default sequential pull | none |
| `snapshot` | Karpenter + Bottlerocket | data volume restored from an EBS snapshot that already holds the layers | build and maintain a snapshot per image version |
| `soci` | Karpenter + Bottlerocket | container storage on local NVMe, SOCI snapshotter in parallel pull/unpack mode | `instanceStorePolicy` and 6 lines of Bottlerocket settings |
| `automode` | EKS Auto Mode | local NVMe and parallel pull, both set up by the service | none |

Two constraints apply to these variants.

この 4 つには制約が 2 つあります。

**B and C cannot both be used on the same node.** Both of them govern the volume that
Bottlerocket uses for container images. The snapshot variant requires the images to be on the volume
restored from the snapshot. If you also set `instanceStorePolicy`, container storage
moves to local NVMe and the restored volume is no longer used. You choose one of the
two.

**B と C は同じノードで併用できません。** どちらも、Bottlerocket がコンテナイメージに
使うボリュームを対象にしています。snapshot はスナップショットから復元したボリューム上に
イメージがあることを前提にしていますが、`instanceStorePolicy` も設定するとコンテナ
ストレージはローカル NVMe に移り、復元したボリュームは使われなくなります。どちらか一方を
選ぶことになります。

**The snapshot mechanism is not available on EKS Auto Mode.** Auto Mode's `NodeClass`
exposes `ephemeralStorage` with the fields `size`, `iops`, `throughput` and
`kmsKeyID`. There is no `snapshotID` field. If a workload needs pre-baked images, that
workload cannot run on Auto Mode.

**snapshot の方式は EKS Auto Mode では使えません。** Auto Mode の `NodeClass` が公開する
`ephemeralStorage` のフィールドは `size` / `iops` / `throughput` / `kmsKeyID` で、
`snapshotID` はありません。イメージの事前焼き込みが必要なワークロードは Auto Mode では
動かせません。

Two further measurements follow the four variants.

4 つの variant の後に、さらに 2 つの計測を行います。

- **Warm scale-out.** The same variant is run again on a node that is already running. The
  four variants above all measure the first pod on a new node.
  **warm スケールアウト。** 同じ variant を、すでに動いているノードに対して再実行します。
  上記 4 つはいずれも、新しいノードでの 1 個目の Pod を計測しています。
- **How the model weights reach GPU memory.** Three variants, including Run:ai Model
  Streamer, with time to first token.
  **モデルウェイトが GPU メモリに届く経路。** Run:ai Model Streamer を含む 3 通りと、
  time to first token を計測します。

### How the numbers are produced / 数字の算出方法

`bin/stages.py` reads the timestamps Kubernetes records and reports the interval
between each consecutive pair:

`bin/stages.py` は Kubernetes が記録しているタイムスタンプを読み、隣接する時刻の間隔を
報告します。

- Pod `creationTimestamp`, conditions, container and init-container states
- NodeClaim `creationTimestamp` and Karpenter's `Launched` and `Registered` conditions
- The Node's `Ready` condition
- kubelet `Pulling` and `Pulled` events, which also contain the pull duration and the
  compressed image size in their message text
- For phase 2, vLLM's log lines for weight load, `torch.compile` and engine warmup

The stages therefore add up to the total. No interval is left out and there is no
remainder category. Kubernetes records these timestamps to one-second resolution, so
differences below one second are not meaningful.

このため段階の合計は全体と一致します。除外される区間はなく、余りの分類もありません。
Kubernetes のタイムスタンプは秒単位なので、1 秒未満の差には意味がありません。

---

## The hands-on steps / ハンズオンのステップ

If you are working through the workshop, start here. Each step gives the
configuration: which field, in which resource, the reason for it, what happens if it
is missing, and how to check that it took effect without relying on the timing
figures.

ワークショップを実際に進める場合は、ここから始めてください。各ステップに設定内容
（どのフィールドを、どのリソースに、なぜ入れるのか、無い場合に何が起きるのか、時間の
数字に頼らずに効いたことをどう確認するか）を記載しています。

| Step | Configuration change / 設定変更 |
|---|---|
| [1 — Baseline](steps/01-baseline.md) | None. Provides the figures the later steps are compared against.<br>なし。以降のステップの比較対象となる数字を得る |
| [2 — EBS snapshot](steps/02-snapshot.md) | One field: `snapshotID` on the data volume<br>1 フィールド: データボリュームの `snapshotID` |
| [3 — NVMe + SOCI](steps/03-soci.md) | `instanceStorePolicy: RAID0` and 6 lines of Bottlerocket TOML<br>`instanceStorePolicy: RAID0` と Bottlerocket TOML 6 行 |
| [4 — Auto Mode](steps/04-automode.md) | None. Compared against step 3 by looking at what is absent.<br>なし。ステップ 3 と比べて何が無いかを見る |
| [5 — Warm scale-out](steps/05-warm.md) | No configuration change; the run command differs<br>設定変更なし。実行コマンドが異なる |
| [6 — Model weights](steps/06-weights.md) | Three vLLM command lines, including Run:ai Model Streamer<br>vLLM の引数 3 通り（Run:ai Model Streamer を含む） |

Two scripts display the configuration at the terminal. The demo calls both of them
for each variant.

設定を端末に表示するスクリプトが 2 つあります。デモは各 variant でこの両方を呼びます。

```bash
bin/show_config.sh soci     # what changes and where, before you apply it
bin/verify_config.sh soci   # checks that it took effect, after you run it
```

`show_config.sh` diffs the rendered manifests against the baseline and removes
comments and lines that differ only by the variant's name, so the output contains only
the configuration that differs. It reads the rendered manifests rather than a separate
copy, so it stays consistent with what was applied.

`show_config.sh` は展開済みのマニフェストをベースラインと diff し、コメントと
variant 名だけが異なる行を除きます。そのため出力には異なる設定だけが残ります。別途用意した
コピーではなく展開済みマニフェストを読むので、適用内容と一致した状態を保ちます。

`verify_config.sh` checks the mechanism itself: whether the volume came from the
snapshot, whether container storage moved to NVMe, and which loader vLLM started
with. Each check also states what it does not confirm, so that a check is not read as
covering more than it does.

`verify_config.sh` は仕組み自体を確認します。ボリュームがスナップショット由来か、
コンテナストレージが NVMe に移ったか、vLLM がどのローダーで起動したか、です。各確認は
確認できていない範囲も併記しており、確認内容を実際より広く受け取らないようにしています。

---

## Reference results / 参考計測値

One measured run is recorded in [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md). It is a
single measurement from a single account. Absolute figures depend on image size,
instance type, region and registry conditions, so your figures will differ.

計測結果 1 回分を [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md) に記載しています。
1 アカウントでの 1 回の計測です。絶対値はイメージサイズ、インスタンスタイプ、リージョン、
レジストリの状況に依存するため、実行環境によって変わります。

---

## Prerequisites / 前提

- `aws`, `kubectl`, `terraform`, `jq`, `python3`
- Credentials for an account in which you can create two EKS clusters
  EKS クラスターを 2 面作成できるアカウントの認証情報
- **GPU quota.** All variants use one instance type, `g6.4xlarge`, which is 16 vCPU.
  Running them one at a time needs 16 vCPU of *Running On-Demand G and VT
  instances*. Requesting 64 leaves room for re-runs.
  **GPU クォータ。** 全 variant が `g6.4xlarge`（16 vCPU）を使います。逐次実行なら 16 vCPU
  で足りますが、64 を申請しておくと再実行の余地ができます。
  ```bash
  aws service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --region us-west-2
  ```
- For phase 2: the `hf` CLI (`pip install --upgrade 'huggingface_hub[cli]'`)
  フェーズ 2 用: `hf` CLI

### Cost and time / 費用と時間

About USD 6–12 and about 2 hours in total. Most of that time is preparation that runs
without supervision. Two EKS clusters and a NAT gateway cost about USD 0.35 per hour
even when no GPU nodes are running, so run the teardown when you have finished.

合計でおよそ 6〜12 USD、約 2 時間です。時間の大半は無人で進む準備作業です。GPU ノードが
動いていない状態でも EKS クラスター 2 面と NAT ゲートウェイで約 0.35 USD/時かかるため、
終了後は破棄手順を実行してください。

### Why the instance type matters / インスタンスタイプについて

`g6.4xlarge` has one L4 GPU, 16 vCPU, 600 GB of local NVMe, and up to 25 Gbps of
network bandwidth.

Local NVMe is required, because the soci and automode variants both use it. The vCPU count affects the
result as well: SOCI's parallel unpack is CPU-bound, so a `2xlarge` produces a smaller
improvement and an `8xlarge` a larger one than a typical inference node would. Set
`GPU_INSTANCE_TYPE` in `config.env` to the type you use, and expect the soci figure
to change with it.

ローカル NVMe は soci と automode が使うため必須です。vCPU 数も結果に影響します。SOCI の並列
展開は CPU バウンドなので、`2xlarge` では一般的な推論ノードより改善幅が小さく、
`8xlarge` では大きく出ます。`config.env` の `GPU_INSTANCE_TYPE` を実際に使う型に設定し、
soci の数字がそれに応じて変わることを前提にしてください。

---

## Setup / セットアップ

### 1. Configure / 設定

```bash
$EDITOR config.env
```

Each value is written as `${VAR:-default}`, so a value already set in the environment
takes precedence. You can override one setting for a single run without editing the
file:

各値は `${VAR:-default}` の形式で書かれているため、環境変数が優先されます。ファイルを
編集せずに 1 回だけ上書きできます。

```bash
GPU_INSTANCE_TYPE=g6.8xlarge bin/bench.sh soci
```

Check that the workload image tag still exists. AWS Deep Learning Container tags are
updated over time, and a tag that no longer exists causes the run to fail at pull
time:

ワークロードイメージのタグが存在するか確認してください。AWS Deep Learning Container の
タグは更新されるため、存在しないタグを指定すると pull 時に失敗します。

```bash
aws ecr describe-images --region us-west-2 \
  --registry-id 763104351884 --repository-name vllm \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags'
```

The default image is a vLLM Deep Learning Container. It is large, GPU-enabled, and
readable by any AWS account, so no registry credentials and no build step are needed.

既定のイメージは vLLM の Deep Learning Container です。サイズが大きく GPU 対応で、
どの AWS アカウントからも読めるため、レジストリ認証もビルド工程も不要です。

### 2. Build the environment / 環境構築

```bash
cd terraform
terraform init
terraform apply
cd ..
```

This creates one shared VPC and two clusters:

共有 VPC 1 つとクラスター 2 面を作成します。

- `<prefix>-karpenter` — self-managed Karpenter, used by baseline, snapshot and soci
- `<prefix>-automode` — EKS Auto Mode, used by automode

There are two clusters because self-managed Karpenter and Auto Mode both own the
`karpenter.sh` CRDs. The clusters share the VPC and subnets, so the image pull path is
the same in both and the figures remain comparable. The control plane is not the same,
which the generated report notes.

クラスターを 2 面にしているのは、self-managed Karpenter と Auto Mode がどちらも
`karpenter.sh` の CRD を所有するためです。VPC とサブネットは共有するので、イメージ pull
の経路は同じで数字は比較できます。コントロールプレーンは同じではなく、この点は生成される
レポートにも記載されます。

Kubernetes is set to 1.34 or above. The EKS-optimized Bottlerocket NVIDIA AMI includes
NVIDIA driver 580 from 1.34 onwards, and driver 580 is required for the CUDA 13 image
used here.

Kubernetes は 1.34 以上にしています。EKS 最適化 Bottlerocket NVIDIA AMI が NVIDIA
ドライバ 580 を含むのは 1.34 以降で、ここで使う CUDA 13 イメージには 580 が必要です。

No NVIDIA device plugin is deployed in either cluster. The Bottlerocket NVIDIA AMI
contains the driver, the container toolkit and the Kubernetes device plugin, and Auto
Mode provides its own. The readiness probe runs `nvidia-smi` inside the container, so
a pod reaching Ready indicates the GPU is available to the container.

どちらのクラスターにも NVIDIA device plugin をデプロイしていません。Bottlerocket
NVIDIA AMI にドライバ、container toolkit、Kubernetes device plugin が含まれており、
Auto Mode は自前で用意します。readiness probe はコンテナ内で `nvidia-smi` を実行するため、
Pod が Ready になればコンテナから GPU が使える状態だと分かります。

### 3. Build the snapshot / snapshot 用スナップショット作成

Run the baseline first and do not reset afterwards, then snapshot that node's data volume:

先に baseline を実行し、その後 reset せずに、そのノードのデータボリュームをスナップショット
します。

```bash
./bin/bench.sh baseline        # leaves a node with the image cached
./snapshot/snapshot-from-node.sh     # takes 3-5 minutes
```

The snapshot ID is written to `results/snapshot-id.txt`, and `bin/prep.sh` reads it
from there.

スナップショット ID は `results/snapshot-id.txt` に書かれ、`bin/prep.sh` がそこから
読み取ります。

> `snapshot/build-snapshot.sh` did not work in our environment. It wraps
> [`aws-samples/bottlerocket-images-cache`][cache], which launches its own Bottlerocket
> instance and controls it through SSM Run Command. On the EKS-optimized Bottlerocket
> NVIDIA AMI the instance did not register with SSM, and the script has no timeout, so
> it stopped at "Launching SSM". The subnet, public IP and instance profile were all
> configured correctly. The script is kept for reference.
>
> `snapshot/build-snapshot.sh` は当環境では動作しませんでした。
> [`aws-samples/bottlerocket-images-cache`][cache] のラッパーで、専用の Bottlerocket
> インスタンスを起動して SSM Run Command で操作します。EKS 最適化 Bottlerocket NVIDIA
> AMI ではインスタンスが SSM に登録されず、スクリプトにタイムアウトが無いため
> "Launching SSM" で停止しました。サブネット、パブリック IP、インスタンスプロファイルは
> いずれも正しく設定されていました。参考として残しています。
>
> Snapshotting a node from the workshop itself also means the cached layers were
> written by the same containerd and OS version that will read them later. The node
> must be a baseline node. The soci variant's `instanceStorePolicy` moves container storage to local
> NVMe, so its EBS data volume is empty.
>
> ワークショップ内のノードをスナップショットする方式では、キャッシュされた層を書いた
> containerd と OS のバージョンが、後で読む側と同じになります。対象は baseline のノードで
> ある必要があります。soci は `instanceStorePolicy` によりコンテナストレージがローカル
> NVMe に移るため、EBS データボリュームは空です。

The time this takes is part of the cost of the snapshot variant, and it recurs whenever the image
changes. Compare it against the snapshot variant's measured improvement in section 5.

この所要時間は snapshot のコストの一部で、イメージが変わるたびに発生します。セクション 5 で
snapshot の実測改善幅と比較してください。

### 4. Apply the variants / variant の適用

```bash
./bin/prep.sh
```

This renders the manifests using the Terraform outputs, applies each variant to the
appropriate cluster, and checks that the Bottlerocket AMI is at least 1.44.0. SOCI
parallel pull/unpack was added in 1.44.0. On an earlier version the snapshotter
setting is ignored without an error, the node boots and the pod runs, and soci
measures the same thing as the baseline variant. The resulting figures would suggest that SOCI has no
effect.

Terraform の出力を使ってマニフェストを展開し、各 variant を該当クラスターに適用し、
Bottlerocket AMI が 1.44.0 以上であることを確認します。SOCI の parallel pull/unpack は
1.44.0 で追加されました。それより前のバージョンでは snapshotter の設定がエラーなしで
無視され、ノードは起動し Pod も動き、soci は baseline と同じものを計測します。その結果の
数字は「SOCI に効果がない」ように見えます。

---

## Running it / 実行

Run one variant at a time. Each run deletes that variant's node first, so each measurement
starts from a cold node.

variant は 1 つずつ実行します。各実行はまずその variant のノードを削除するため、毎回コールドな
ノードから計測が始まります。

```bash
./bin/bench.sh baseline
./bin/bench.sh snapshot
./bin/bench.sh soci
./bin/bench.sh automode
```

Each step's figure is printed when that step completes, so the breakdown appears
during the run rather than only at the end:

各段階の数字はその段階が完了した時点で出力されるため、内訳は実行中に順次表示されます。

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

`at` is measured from the pod's `creationTimestamp`, which is the same reference the
final table uses, so the live output and the report agree. `step took` is the duration
of each step.

`at` は Pod の `creationTimestamp` を起点としています。最終集計表と同じ起点なので、
実行中の出力とレポートの数字は一致します。`step took` が各段階の所要時間です。

When the variant finishes, `stages.py` prints the breakdown again together with the node's
instance type, availability zone and OS image, and the effective image throughput.
Throughput is the compressed image size divided by the observed pull duration, so it
includes both download and unpack. Throughput can be compared across different images,
which the elapsed figures cannot.

variant が終了すると、`stages.py` がノードのインスタンスタイプ、AZ、OS イメージとあわせて
内訳を再表示し、実効イメージスループットを出力します。スループットは圧縮イメージサイズ ÷
実測 pull 時間で、ダウンロードと展開の両方を含みます。経過時間と違い、スループットは
イメージが異なる環境間でも比較できます。

### Warm scale-out / warm スケールアウト

```bash
./bin/bench.sh soci --warm
```

This deletes only the pod, keeps the NodeClaim, and submits the pod again. The pod is
deleted first because these instance types have one GPU, so two pods requesting a GPU
cannot run on the same node.

Pod だけを削除し、NodeClaim は残して Pod を再投入します。これらのインスタンスタイプは
GPU が 1 基なので、GPU を要求する Pod は 2 つ同じノードで動かせません。そのため先に Pod を
削除します。

`report.py` then prints both figures:

```
  soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

The last figure is the portion that a node which is already running does not incur. If
that portion is large relative to the total, the mechanisms in this workshop affect
most of the startup time. If it is small, the startup time is mostly in the pod
itself, and node capacity policy has more effect than image delivery. Running this
measurement also shows how much of the snapshot variant's improvement applies only to the first pod
on a node.

最後の数字は、すでに動いているノードでは発生しない部分です。この部分が全体に対して大きい
場合、本ワークショップの各方式が起動時間の大部分に影響します。小さい場合、起動時間の大半は
Pod 側にあり、イメージ配送よりノードのキャパシティ方針の方が効きます。この計測により、
snapshot の改善のうちノードの 1 個目の Pod にしか効かない分も分かります。

### Phase 2 — how the weights reach GPU memory / ウェイトが GPU メモリに届く経路

Stage the weights once:

```bash
# put MODEL_BUCKET from `terraform output -raw model_bucket` into config.env
./snapshot/stage-model.sh
```

Then run three variants. The node, model and bytes are the same in all three, and only
the loader differs:

続いて 3 通りを実行します。ノード、モデル、バイト列は 3 つとも同じで、ローダーだけが
異なります。

```bash
./bin/bench.sh weights s3-initcontainer   # copy S3 -> disk, vLLM default loader
./bin/bench.sh weights runai-local        # copy S3 -> disk, Run:ai Model Streamer
./bin/bench.sh weights runai-s3           # no copy: streamer reads S3 directly
```

The three variants separate two effects, which are reported individually:

3 つの variant は 2 つの効果を切り分けており、それぞれ別に報告されます。

- `s3-initcontainer` to `runai-local` changes the loader only. The bytes and the disk
  are the same, so the difference is the effect of concurrent tensor streaming.
  `s3-initcontainer` から `runai-local` はローダーのみの変更です。バイト列とディスクは
  同じなので、差は並列テンソルストリーミングの効果です。
- `runai-local` to `runai-s3` changes the delivery only. The init container is removed.
  `runai-local` から `runai-s3` は配送のみの変更です。init コンテナが無くなります。

The second change also removes a property of the init container approach: kubelet
pulls the init image, runs the init container, and then pulls the workload image.
The copy and the image pull do not overlap. Because of this, moving weights out of the
image can increase start-to-Ready time even though the image is smaller. Reading from
S3 directly removes the copy step.

2 つ目の変更は、init コンテナ方式が持つ性質も取り除きます。kubelet は init イメージを
pull し、init コンテナを実行し、その後で本体イメージを pull します。コピーと pull は
重なりません。このため、イメージからウェイトを出してイメージが小さくなっても
start-to-Ready が伸びる場合があります。S3 から直接読む方式ではコピー工程が無くなります。

`runai-streamer` and its S3 backend are included in the AWS vLLM Deep Learning
Container base image, so no custom image build is needed. To check this on the tag you
configured, using a node that already has the image:

`runai-streamer` とその S3 バックエンドは AWS vLLM Deep Learning Container のベース
イメージに含まれているため、独自イメージのビルドは不要です。設定したタグについて、
イメージを持っているノードで確認するには次を実行します。

```bash
./bin/check_runai.sh
```

Credentials come from EKS Pod Identity, which Terraform binds to the `bench` service
account. The node role cannot be used: Karpenter sets the IMDS hop limit to 1, so a
container cannot reach instance metadata, and the AWS SDK reports `Unable to locate
credentials`. That hop limit prevents pods from using node permissions, and scoping a
role to a service account is the approach to use in production as well.

認証情報は EKS Pod Identity から取得し、Terraform が `bench` サービスアカウントに
紐付けます。ノードロールは使えません。Karpenter は IMDS の hop limit を 1 に設定するため
コンテナはインスタンスメタデータに到達できず、AWS SDK は `Unable to locate credentials`
を返します。この hop limit は Pod がノードの権限を使うことを防ぐもので、サービス
アカウント単位でロールを絞る方法は本番でも同様に使えます。

### Time to first token / TTFT

A pod reaching Ready means vLLM responds to `/health`. It does not indicate how soon
the server produces a token. Phase 2 runs therefore also measure the interval from
submit to first token:

Pod が Ready になることは、vLLM が `/health` に応答することを意味します。トークンを
どれだけ早く出せるかは分かりません。そのためフェーズ 2 では submit から最初のトークンまでも
計測します。

```
  time to first token after Ready  0.65s
  submit to first token            93.6s
```

The probe requests a streamed completion and stops timing at the first token that
contains text. Streaming is used because without it the measurable interval is total
latency, which depends on the number of tokens requested. The probe runs inside the
pod ([bin/first_token.py](bin/first_token.py), loaded as a ConfigMap by `prep.sh`), so
it does not need a port-forward and does not require `curl` in the image.

プローブはストリーミングで補完を要求し、テキストを含む最初のトークンで計測を止めます。
ストリーミングを使うのは、使わない場合に計測できるのが総レイテンシであり、要求トークン数に
依存するためです。プローブは Pod 内で動作するため（[bin/first_token.py](bin/first_token.py)、
`prep.sh` が ConfigMap として投入）、port-forward は不要で、イメージに `curl` がある
必要もありません。

### Resetting / リセット

```bash
./bin/reset.sh                 # all variants
./bin/reset.sh soci            # one variant
```

---

## Recording it / 録画

`bin/demo.sh` runs the whole sequence and prints English commentary between the
commands, so a recording can be followed without a voice track. `bin/record.sh` runs
that under asciinema and produces an mp4:

`bin/demo.sh` は一連の流れを実行し、コマンドの間に英語の解説を出力するため、録画物を
音声なしで追えます。`bin/record.sh` はそれを asciinema で収録して mp4 にします。

```bash
./bin/record.sh              # the full run
./bin/record.sh --quick      # skips the cold baseline, for a shorter video
./bin/record.sh --rehearse   # fixture data, no AWS calls
```

Output is written to `recording/`: a `.cast` file, which is small and can be
re-rendered, a `.gif`, and an `.mp4` at 1184x840.

出力は `recording/` に置かれます。小さく再レンダリング可能な `.cast`、`.gif`、
1184x840 の `.mp4` です。

> asciinema is given `--idle-time-limit`, which shortens periods of no output during
> playback. A 96-second image pull appears as a few seconds of video. The elapsed
> times shown on screen are the measured values and are not modified; only the waiting
> between them is shortened. Mention this when showing the video, because otherwise the
> playback speed can be read as the measurement.
>
> asciinema には `--idle-time-limit` を指定しており、再生時に出力の無い期間を短縮します。
> 96 秒の pull は数秒の映像になります。画面に表示される経過時間は計測値そのままで、
> 変更していません。短縮しているのはその間の待ち時間だけです。動画を見せる際はこの点を
> 説明してください。説明がないと、再生速度が計測値として受け取られる場合があります。

The idle limit is set to the same value as the narration interval. A shorter limit
would also shorten the pauses that make the commentary readable.

idle の上限値は、ナレーションの間隔と同じ値にしています。これより短くすると、解説を
読むための間も短縮されます。

`--rehearse` runs the same demo against fixture data, with a fake `kubectl` on `PATH`
and no AWS calls. It is intended for checking the narration timing and the recording
pipeline. `bench.sh`, `watch_stages.py`, `stages.py` and `report.py` all run unmodified
and only `kubectl` is replaced, so the tooling itself is exercised. The figures a
rehearsal produces are fixture values: `record.sh` includes `REHEARSAL` in the
filename, and rehearsal output is written to `rehearsal/.sandbox/` rather than
`results/`.

`--rehearse` は、偽の `kubectl` を `PATH` に置き、AWS を呼ばずにフィクスチャデータで
同じデモを実行します。ナレーションの尺と録画パイプラインの確認用です。`bench.sh` /
`watch_stages.py` / `stages.py` / `report.py` は本物がそのまま動き、差し替えるのは
`kubectl` だけなので、ツール自体の動作確認になります。リハーサルが出す数字はフィクスチャの
値です。`record.sh` はファイル名に `REHEARSAL` を入れ、出力は `results/` ではなく
`rehearsal/.sandbox/` に書かれます。

---

## Reading the result / 結果の読み方

`results/report.md` groups the stages into three categories:

`results/report.md` は段階を 3 つに分類します。

- **Provisioning** — Karpenter's decision, the EC2 launch, boot, registration, node
  Ready and binding. In the reference run this was similar across all four variants. A
  large difference here usually indicates instance-type availability rather than
  configuration.
  **プロビジョニング** — Karpenter の判断、EC2 起動、ブート、登録、ノード Ready、バインド。
  参考計測では 4 variant でほぼ同じでした。ここに大きな差がある場合、通常は設定ではなく
  インスタンスタイプの在庫が原因です。
- **Image** — the pull and unpack. The snapshot, soci and automode variants each address this differently.
  **イメージ** — pull と展開。snapshot / soci / automode がそれぞれ異なる方法で扱います。
- **Workload** — container start, and in phase 2 the weight download and model load.
  **ワークロード** — コンテナ起動、およびフェーズ 2 のウェイトダウンロードとモデルロード。

The baseline and SOCI variants differ by one mechanism, with the same provisioner, OS and instance
type, so their difference is attributable to that mechanism. The Auto Mode variant also runs on a
different control plane, so its figures indicate what Auto Mode provides without
configuration rather than a direct comparison.

baseline と soci は、プロビジョナ・OS・インスタンスタイプが同じで、異なるのは 1 つの方式
だけなので、差はその方式に帰属できます。automode はコントロールプレーンも異なるため、
数字は直接比較ではなく、Auto Mode が設定なしで提供する内容を示すものとして読みます。

The report also lists the instance type, availability zone, OS image and runtime read
from each node, so the assumption that the variants ran on equivalent hardware can be
checked. If they did not all use the same instance type, the report says so.

レポートには各ノードから読み取ったインスタンスタイプ、AZ、OS イメージ、ランタイムも
記載されるため、variant が同等のハードウェアで動いたという前提を確認できます。variant 間で
インスタンスタイプが揃わなかった場合はその旨が出力されます。

### Limits of the figures / 数字の限界

- Each variant was run once. Pull times vary with registry and network conditions.
  Differences below about 10% should be confirmed by a repeat run before being relied
  on. `report.py` retains earlier runs rather than replacing them.
  各 variant は 1 回の計測です。pull 時間はレジストリとネットワークの状況で変わります。
  10% 程度未満の差は、再実行で確認してから判断してください。`report.py` は以前の結果を
  置き換えずに残します。
- The time to build the snapshot is not in the table. It is the recurring cost of
  that mechanism.
  snapshot 用スナップショット作成時間は表に含まれていません。この方式の継続的なコストです。
- The SOCI variant's settings are the values AWS publishes as a starting point. Layer count,
  layer size and vCPU affect which values are appropriate.
  soci の SOCI 設定は AWS が出発点として公開している値です。適切な値はレイヤ数、レイヤ
  サイズ、vCPU によって変わります。

---

## Section 5 — what to adopt / 何を採用するか

| If / 条件 | Then / 選択 | Because / 理由 |
|---|---|---|
| Images change rarely and startup latency matters<br>イメージ更新が稀で起動遅延が重要 | `snapshot` | No pull occurs. A snapshot rebuild is needed per image version.<br>pull が発生しない。イメージ版ごとに再作成が必要 |
| Images change often<br>イメージ更新が頻繁 | `soci` | No per-image preparation, no build-pipeline change, image unchanged.<br>イメージ単位の準備もビルド変更も不要、イメージは無改変 |
| You do not want to maintain either<br>どちらも運用したくない | `automode` | The soci variant's behaviour without the SOCI variant's configuration. The snapshot mechanism and SOCI's settings are not available.<br>soci の挙動を設定なしで得られる。snapshot の方式と SOCI の設定項目は使えない |
| Weight loading takes longer than the pull<br>pull よりウェイト読み込みが長い | Stream from S3 | Reducing image size does not help if model load is the larger component.<br>モデルロードの方が大きいならイメージ縮小は効かない |
| Warm-node startup already dominates<br>warm ノードの起動時間が既に大半 | None of these; node capacity policy | If the once-per-node cost is small relative to steady-state startup, image delivery is not the main factor.<br>ノード 1 回のコストが定常起動に比べ小さいなら、イメージ配送は主要因ではない |

Two measurements determine most of this choice: how often your images change, and how
much of your startup time is incurred once per node. The warm scale-out run provides
the second.

この選択の大半は 2 つの計測で決まります。イメージの更新頻度と、起動時間のうちノード 1 回
あたりに発生する分です。後者は warm スケールアウトの計測で分かります。

---

## Teardown / 破棄

```bash
./bin/reset.sh
cd terraform && terraform destroy
```

The snapshot and the staged weights are not managed by Terraform:

snapshot 用スナップショットと S3 上のウェイトは Terraform の管理外です。

```bash
aws ec2 delete-snapshot --snapshot-id "$(cat results/snapshot-id.txt)" --region us-west-2
aws s3 rm "s3://$MODEL_BUCKET/$MODEL_PREFIX/" --recursive
```

---

## Layout / 構成

```
config.env                        settings; read by all the scripts
terraform/                        shared VPC, two clusters, model bucket, Pod Identity
manifests/
  karpenter/                      baseline, snapshot, soci  (EC2NodeClass + NodePool)
  automode/                       automode                  (NodeClass + NodePool)
  workload.yaml                   phase 1: the measured pod, cold and warm
  workload-weights.yaml           phase 2: one spec, three loader variants
  fragments/init-copy-weights.yaml  the S3-to-disk copy, used by two variants
  rendered/                       generated by prep.sh; what was applied
snapshot/
  snapshot-from-node.sh           snapshot preparation
  build-snapshot.sh               snapshot preparation via aws-samples (did not work here)
  stage-model.sh                  phase 2 preparation
bin/
  prep.sh                         render, apply, check versions
  bench.sh                        run one variant, collect, compute
  reset.sh                        return a variant to a cold state
  watch_stages.py                 prints each step's figure as it completes
  stages.py                       timestamps to stage breakdown
  report.py                       all runs to comparison and results/report.md
  first_token.py                  time to first token, runs inside the pod
  render_weights.py               phase 2 render (handles multi-line insertion)
  check_runai.sh                  checks the image supports Run:ai streaming
  assert_br_version.py            checks the Bottlerocket version for SOCI
  show_config.sh                  what a variant changes and where, before applying
  verify_config.sh                checks the setting took effect, after running
  demo.sh                         the narrated sequence, for recording
  record.sh                       asciinema to gif to mp4
  rehearse.sh                     demo.sh against fixtures, no AWS calls
steps/                            the hands-on steps, one per configuration change
rehearsal/                        fixture data and a fake kubectl
raw/                              per-run Kubernetes objects, kept for reference
results/                          per-run JSON and report.md
```

`raw/` contains the data behind each figure in the report, so the calculation can be
checked afterwards. Each run's directory also contains the manifest that was applied.

`raw/` にはレポートの各数字の元データが入っており、後から計算を確認できます。各実行の
ディレクトリには、適用したマニフェストも含まれます。

Placeholders in the manifests are written as `@LIKE_THIS@`. The delimiters prevent a
substitution from also replacing the token names where they appear in comments, and
prevent `@NODE_IAM_ROLE@` from matching inside `@KARPENTER_NODE_IAM_ROLE_NAME@`. The
templates are valid YAML before rendering, so editors and linters can parse them.

マニフェストのプレースホルダは `@LIKE_THIS@` 形式です。この区切り文字により、コメント内に
現れるトークン名まで置換されることを防ぎ、`@NODE_IAM_ROLE@` が
`@KARPENTER_NODE_IAM_ROLE_NAME@` の内部に一致することも防ぎます。テンプレートは展開前でも
妥当な YAML なので、エディタや linter で解析できます。

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
