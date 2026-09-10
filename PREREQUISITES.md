# Prerequisites

**English** | [日本語](#japanese)

What an AWS account needs before this workshop can run in it. Four things determine whether it
can run and what it will cost: the GPU instance type, the GPU quota, GPU capacity at the time of
the run, and the account's permissions. Cost and duration follow from the first of those.

---

## 1. The GPU instance type

Set in `config.env`:

```bash
export GPU_INSTANCE_TYPE="gr6.8xlarge"
```

Every variant runs on this one type, so that nothing in the comparison is explained by
hardware. The type has to have two properties.

**Local NVMe instance store.** Steps 3 and 4 place container storage on it. A type without
instance store makes both of those steps measure the same thing as step 1.

**Two or more instance-store disks**, if the striping in step 3 is to be exercised.
Bottlerocket skips the array when there is only one disk, so `instanceStorePolicy: RAID0`
relocates container storage without striping it. The figures are still valid with one disk;
one part of step 3 stops applying.

The vCPU count also changes the result. SOCI's parallel unpack is CPU-bound, so a smaller type
produces a smaller improvement in step 3 and a larger type a larger one. A figure obtained on
one type does not carry to another.

Single-GPU types with instance store:

| Type | vCPU | GPU | Instance store | Quota needed |
|---|---:|---|---|---:|
| `g6.xlarge` | 4 | L4 24 GB | 1× 250 GB | 4 |
| `g6.2xlarge` | 8 | L4 24 GB | 1× 450 GB | 8 |
| `g6.4xlarge` | 16 | L4 24 GB | 1× 600 GB | 16 |
| **`gr6.8xlarge`** (default) | **32** | **L4 24 GB** | **2× 450 GB** | **32** |
| `g6.8xlarge` | 32 | L4 24 GB | 2× 450 GB | 32 |
| `g5.4xlarge` | 16 | A10G 24 GB | 1× 600 GB | 16 |
| `g5.8xlarge` | 32 | A10G 24 GB | 1× 900 GB | 32 |
| `g6e.4xlarge` | 16 | L40S 48 GB | 1× 600 GB | 16 |
| `g6e.8xlarge` | 32 | L40S 48 GB | 2× 450 GB | 32 |
| `g4dn.4xlarge` | 16 | T4 16 GB | 1× 225 GB | 16 |

The GPU memory column matters only if `MODEL_HF_REPO` is raised to a larger model. The default
model is 2.9 GB and fits on any of these.

### P types are refused

`bin/prep.sh` and `bin/preflight.sh` both reject a `p` type. This is a cost constraint, not a
technical one.

The model is 1.5B parameters and fits in 24 GB, so a P type produces the same measurement at
several times the hourly rate. On-Demand in `us-west-2`:

| Type | USD/hour |
|---|---:|
| `g6.4xlarge` | 1.32 |
| `gr6.8xlarge` | 2.45 |
| `p5.4xlarge` | 6.88 |
| `p4d.24xlarge` | 21.96 |

P types also count against a different quota, `L-417A185B` instead of `L-DB2E81BA`. An account
whose G quota was raised for this workshop will not launch one, and that appears as a variant
stuck `Pending` rather than as a quota error.

`ALLOW_LARGE_GPU_FAMILY=1` overrides both checks. The cost figures below assume a G type.

---

## 2. The GPU quota

These quotas are counted in vCPU, not in instances. The variants run one at a time, so the
requirement is one node's worth of the type in use: 32 vCPU for `gr6.8xlarge`, 16 for
`g6.4xlarge`, and so on from the table above.

```bash
aws service-quotas get-service-quota --region us-west-2 \
  --service-code ec2 --quota-code L-DB2E81BA
```

`L-DB2E81BA` is *Running On-Demand G and VT instances*. Every type in the table above counts
against it, so changing between them needs more of the same quota rather than a different one.

Four nodes' worth allows a variant to be re-run without waiting for the previous node to
terminate.

GPU instances already running in the same region consume the same quota, including instances
belonging to unrelated work.

---

## 3. GPU capacity

Separate from the quota, and not something a quota increase affects. Capacity is per instance
type per Availability Zone, and it changes over minutes.

A zone with no capacity for the chosen type does not stop Karpenter, which can use another
zone. It does affect the measurement: Karpenter holds a refused offering unavailable for three
minutes, and a pod submitted during that window waits out the TTL before a node is requested at
all. That wait is added to the variant's total with no error to explain it.

No API reports available capacity. `bin/check_capacity.sh` launches one instance per subnet and
terminates it immediately, which is the only way to know:

```bash
bin/check_capacity.sh
```

On failure it prints the error from EC2, which names the Availability Zones that can serve the
request at that moment.

This needs the VPC to exist, so it runs after Terraform rather than before.

---

## 4. Permissions

An administrative role, or one that can create the resources listed below, including IAM roles
and policies.

This cannot be verified in advance. IAM has no dry-run, and a permissions boundary or a Service
Control Policy denies at apply time without being visible beforehand. If the account uses a
permissions boundary, the roles Terraform creates need it applied, which is a change to
`terraform/main.tf`.

### What gets created

All of it in one region, in a VPC of its own. Nothing is placed in an existing VPC and nothing
existing is modified.

| | |
|---|---|
| VPC | One, with private and public subnets across three Availability Zones, one NAT gateway (which uses one Elastic IP), and an S3 Gateway VPC endpoint |
| EKS clusters | Two. One with self-managed Karpenter, one with EKS Auto Mode. Two are required because both controllers own the same `karpenter.sh` CRDs |
| Managed node group | One group of two `m6i.large` nodes per cluster, for CoreDNS and the Karpenter controller |
| GPU nodes | Created and removed by Karpenter during the runs, one at a time |
| IAM | Roles and policies for the two clusters, the Karpenter controller, the nodes, and one role bound to a service account through EKS Pod Identity |
| S3 | One bucket for the model weights, with public access blocked and server-side encryption enabled |
| EBS snapshot | One, holding the container image layers, built by a temporary instance that is terminated afterwards |
| Helm release | Karpenter, on the first cluster |

Teardown is `terraform destroy`. The snapshot and the bucket are outside Terraform's state and
are removed separately.

### Other service quotas

| Quota | Code | Needed | Default |
|---|---|---:|---:|
| VPCs per Region | `L-F678F1CE` | 1 | 5 |
| EC2-VPC Elastic IPs | `L-0263D0A3` | 1 | 5 |

Existing VPCs and Elastic IPs count against these. An account already near either default needs
an increase for a reason that has nothing to do with GPUs, which is easy to overlook when the
GPU quota is the one being planned for.

---

## 5. Cost

About **USD 6 to 12** for one pass through the workshop.

| | |
|---|---|
| Two EKS clusters and a NAT gateway | about USD 0.35 per hour, whether or not a GPU node exists |
| One GPU node | 1.32 to 2.45 USD per hour depending on the type, and only while a run is in progress |

The distinction matters for an environment left standing. The clusters are a few dollars a day.
A GPU node left running is not, and one can be left behind: Karpenter keeps a node for 30
minutes after its last pod, which the warm runs depend on.

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # expect no output
```

---

## 6. Time

About **two hours** in total, most of which needs no attention.

| Step | Duration |
|---|---|
| `terraform apply` | 15 to 20 minutes, mostly two EKS control planes |
| `snapshot/build-snapshot.sh` | 14 minutes for a 9 GB image, unattended |
| `snapshot/stage-model.sh` | a few minutes, depending on the connection to Hugging Face |
| `bin/prep.sh` | under a minute |
| One variant | 1 to 3 minutes, plus node provisioning for a cold run |
| All variants and both later phases | about 25 minutes |

The snapshot build and the model staging are the two that take minutes without producing
anything to watch, and neither is needed again unless the image or the model changes.

---

## Tools and region

- `aws` (v2), `kubectl`, `terraform`, `jq`, `python3`
- The `hf` CLI, for staging the model: `pip install --upgrade 'huggingface_hub[cli]'`
- `us-west-2` by default, set in `config.env`. Another region works if it offers the GPU
  instance type, EKS 1.34 and the AWS Deep Learning Container image.

Kubernetes 1.34 or above is required. The EKS-optimized Bottlerocket NVIDIA AMI ships NVIDIA
driver 580 from 1.34 onwards, and the CUDA 13 image used here needs driver 580.

Bottlerocket 1.44.0 or above is required for step 3. SOCI parallel pull/unpack was added in
that version, and on an earlier one the setting is ignored without an error, so step 3 would
measure the same thing as step 1.

---

## What is not required

- **Registry credentials.** The container image is an AWS Deep Learning Container, readable
  from any AWS account.
- **A Hugging Face token.** The default model, Qwen2.5-1.5B-Instruct, is not gated.
- **A licence for Run:ai Model Streamer.** Apache-2.0, and already present in the container
  image.
- **A custom AMI.** The EKS-optimized Bottlerocket NVIDIA AMI is used as published.
- **GPU quota beyond one node**, unless variants are run concurrently, which this workshop
  does not do.

---

## Checking all of the above

```bash
bin/preflight.sh
```

Read-only, creates nothing. It reports the tools, credentials, the quota for whichever instance
type is configured, GPU instances already consuming it, whether the container image and the
model repository are readable, the Kubernetes version, the Bottlerocket AMI version, and the
instance store on the configured type. It exits non-zero when a required check fails.

It also prints what it cannot check, which is the permissions above and GPU capacity.

After `terraform apply`, `bin/verify_env.sh` checks what was built, and `bin/check_capacity.sh`
checks capacity before a measurement run.

---

## Running it more than once in one account

Several of these environments can exist in one account. They cannot share one, because the
measurements are of a cold first pod: `bin/reset.sh` deletes the pods labelled for the variant
it is about to run and then the NodeClaim, which terminates the instance. Two people on one
cluster would delete each other's nodes mid-run, and a separate namespace does not help,
because each variant is pinned to one node pool and the node pool is what gets reset.

Each environment needs its own `NAME_PREFIX`, its own clone and its own Terraform state. The
prefix is set in two places and they have to agree:

```bash
# config.env
export NAME_PREFIX="br-startup-alice"
```

```bash
terraform -chdir=terraform apply -var 'name_prefix=br-startup-alice'
```

Almost everything is named from it: both clusters, the VPC, the model bucket, the IAM policy,
the Karpenter subnet discovery tag and the snapshot. If the two disagree, `bin/prep.sh` looks
for clusters Terraform did not create.

Per additional environment: one VPC, one Elastic IP, one node's worth of GPU quota, and the
cost above. The VPC and Elastic IP defaults of 5 are usually the limit reached first.

Concurrent runs draw on the same GPU capacity in the same Availability Zones, so they make the
capacity problem in section 3 more likely. Staggering the runs avoids it.

The snapshot and the model bucket are read-only once built and can be shared, which saves each
of the others the snapshot build. Within one account this needs no cross-account policy, but
the reading role needs `s3:GetObject` on the other prefix's bucket.

<br>

---
---

<a id="japanese"></a>

# 前提条件

[English](#prerequisites) | **日本語**

本ワークショップを実行するために AWS アカウントに必要なものです。実行可否と費用を決めるのは 4 点
です。GPU インスタンスタイプ、GPU クォータ、実行時点の GPU 容量、アカウントの権限です。費用と
所要時間は 1 点目から決まります。

---

## 1. GPU インスタンスタイプ

`config.env` で設定します。

```bash
export GPU_INSTANCE_TYPE="gr6.8xlarge"
```

すべての variant がこの 1 つのタイプで動きます。比較の中にハードウェアで説明できる差を作らない
ためです。このタイプには 2 つの性質が必要です。

**ローカル NVMe インスタンスストア。** ステップ 3 と 4 はそこにコンテナストレージを配置します。
インスタンスストアを持たないタイプでは、この 2 つのステップがステップ 1 と同じものを計測します。

**ステップ 3 のストライピングを扱う場合は、インスタンスストアが 2 本以上。** Bottlerocket は
ディスクが 1 本の場合アレイを省くため、`instanceStorePolicy: RAID0` はコンテナストレージを移動
しますがストライピングはしません。1 本でも計測値は妥当で、ステップ 3 の一部が当てはまらなくなる
だけです。

vCPU 数も結果を変えます。SOCI の並列展開は CPU バウンドなので、小さいタイプではステップ 3 の
改善幅が小さくなり、大きいタイプでは大きくなります。あるタイプで得た数字は別のタイプには
当てはまりません。

インスタンスストアを持つシングル GPU のタイプです。

| タイプ | vCPU | GPU | インスタンスストア | 必要クォータ |
|---|---:|---|---|---:|
| `g6.xlarge` | 4 | L4 24 GB | 250 GB × 1 | 4 |
| `g6.2xlarge` | 8 | L4 24 GB | 450 GB × 1 | 8 |
| `g6.4xlarge` | 16 | L4 24 GB | 600 GB × 1 | 16 |
| **`gr6.8xlarge`**（既定） | **32** | **L4 24 GB** | **450 GB × 2** | **32** |
| `g6.8xlarge` | 32 | L4 24 GB | 450 GB × 2 | 32 |
| `g5.4xlarge` | 16 | A10G 24 GB | 600 GB × 1 | 16 |
| `g5.8xlarge` | 32 | A10G 24 GB | 900 GB × 1 | 32 |
| `g6e.4xlarge` | 16 | L40S 48 GB | 600 GB × 1 | 16 |
| `g6e.8xlarge` | 32 | L40S 48 GB | 450 GB × 2 | 32 |
| `g4dn.4xlarge` | 16 | T4 16 GB | 225 GB × 1 | 16 |

GPU メモリの列が問題になるのは、`MODEL_HF_REPO` をより大きいモデルに変更する場合だけです。既定の
モデルは 2.9 GB で、上記のいずれにも収まります。

### P 系は拒否されます

`bin/prep.sh` と `bin/preflight.sh` はどちらも `p` 系を拒否します。これは技術的な制約ではなく
費用の制約です。

モデルは 1.5B パラメータで 24 GB に収まるため、P 系でも計測結果は同じで、時間単価が数倍になります。
On-Demand、`us-west-2` の価格です。

| タイプ | USD/時 |
|---|---:|
| `g6.4xlarge` | 1.32 |
| `gr6.8xlarge` | 2.45 |
| `p5.4xlarge` | 6.88 |
| `p4d.24xlarge` | 21.96 |

P 系は `L-DB2E81BA` ではなく `L-417A185B` という別のクォータに計上されます。本ワークショップの
ために G のクォータを引き上げたアカウントでは起動せず、クォータのエラーではなく **variant が
`Pending` のまま**という形で現れます。

`ALLOW_LARGE_GPU_FAMILY=1` で両方のチェックを上書きできます。以下の費用は G 系を前提としています。

---

## 2. GPU クォータ

これらのクォータはインスタンス数ではなく **vCPU 単位**で数えられます。variant は 1 台ずつ実行
するため、必要なのは使用するタイプのノード 1 台分です。`gr6.8xlarge` なら 32 vCPU、`g6.4xlarge`
なら 16 で、以降は上記の表のとおりです。

```bash
aws service-quotas get-service-quota --region us-west-2 \
  --service-code ec2 --quota-code L-DB2E81BA
```

`L-DB2E81BA` は *Running On-Demand G and VT instances* です。上記の表のタイプはすべてここに
計上されるため、この中で切り替える場合に必要なのは別のクォータではなく同じクォータの追加枠です。

ノード 4 台分あれば、前のノードの終了を待たずに variant を再実行できます。

同じリージョンで既に動いている GPU インスタンスは同じクォータを消費します。本ワークショップと
無関係な作業のインスタンスも含みます。

---

## 3. GPU 容量

クォータとは別で、クォータの引き上げでは変わりません。容量はインスタンスタイプと AZ の組み合わせ
ごとで、分単位で変動します。

選択したタイプの容量が無い AZ があっても Karpenter は止まらず、別の AZ を使えます。ただし計測には
影響します。Karpenter は拒否された offering を 3 分間 unavailable に保持し、その間に投入された
Pod はノードが要求される前に TTL を待ちます。この待ち時間は、説明するエラーを伴わずに variant の
合計に加算されます。

利用可能な容量を報告する API はありません。`bin/check_capacity.sh` は各サブネットに 1 台起動して
即座に終了させます。これが確認する唯一の方法です。

```bash
bin/check_capacity.sh
```

失敗した場合は EC2 のエラーを表示します。そこにはその時点で要求を満たせる AZ が示されます。

これは VPC の存在が前提なので、Terraform の前ではなく後に実行します。

---

## 4. 権限

管理者ロール、または後述のリソースを作成できるロールです。IAM ロールとポリシーの作成を含みます。

これは事前に検証できません。IAM に dry-run が無く、Permissions Boundary や Service Control Policy
は事前に見えない形で apply 時に拒否します。アカウントで Permissions Boundary を使用している場合、
Terraform が作成するロールにもそれを適用する必要があり、これは `terraform/main.tf` の変更になります。

### 作成されるもの

すべて 1 リージョン内の専用 VPC に作成します。既存の VPC には何も配置せず、既存のリソースを変更
しません。

| | |
|---|---|
| VPC | 1 つ。3 つの AZ にまたがるプライベート/パブリックサブネット、NAT ゲートウェイ 1 つ（Elastic IP を 1 つ使用）、S3 Gateway VPC エンドポイント |
| EKS クラスター | 2 面。1 面は自己管理の Karpenter、1 面は EKS Auto Mode。両コントローラが同じ `karpenter.sh` CRD を所有するため 2 面必要です |
| マネージドノードグループ | 各クラスターに `m6i.large` 2 台のグループ 1 つ。CoreDNS と Karpenter コントローラ用 |
| GPU ノード | 実行中に Karpenter が 1 台ずつ作成・削除します |
| IAM | 2 つのクラスター、Karpenter コントローラ、ノード用のロールとポリシー、および EKS Pod Identity でサービスアカウントに紐付けるロール 1 つ |
| S3 | モデルウェイト用のバケット 1 つ。パブリックアクセスをブロックし、サーバーサイド暗号化を有効化 |
| EBS スナップショット | 1 つ。コンテナイメージのレイヤを保持します。一時インスタンスが作成し、そのインスタンスは終了します |
| Helm リリース | Karpenter。1 面目のクラスターに |

撤去は `terraform destroy` です。スナップショットとバケットは Terraform の state 外なので別途
削除します。

### その他のサービスクォータ

| クォータ | コード | 必要 | 既定 |
|---|---|---:|---:|
| VPCs per Region | `L-F678F1CE` | 1 | 5 |
| EC2-VPC Elastic IPs | `L-0263D0A3` | 1 | 5 |

既存の VPC と Elastic IP もこれらに計上されます。どちらかの既定値に近いアカウントでは、GPU とは
無関係の理由で引き上げが必要になります。GPU クォータだけを想定していると見落としやすい点です。

---

## 5. 費用

ワークショップを 1 回通すのに **6〜12 USD** 程度です。

| | |
|---|---|
| EKS クラスター 2 面と NAT ゲートウェイ | GPU ノードの有無にかかわらず約 0.35 USD/時 |
| GPU ノード 1 台 | タイプにより 1.32〜2.45 USD/時。実行中のみ |

この区別は環境を残す場合に効いてきます。クラスターは 1 日あたり数ドルです。GPU ノードを残した
場合はそうならず、しかも残ることがあります。Karpenter は最後の Pod が消えてから 30 分ノードを
保持し、これは warm 実行が依存している挙動です。

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # 何も出力されないこと
```

---

## 6. 所要時間

合計 **約 2 時間**で、大半は注意を向ける必要がありません。

| 工程 | 所要時間 |
|---|---|
| `terraform apply` | 15〜20 分。大半は EKS コントロールプレーン 2 面 |
| `snapshot/build-snapshot.sh` | 9 GB のイメージで 14 分。無人 |
| `snapshot/stage-model.sh` | 数分。Hugging Face への接続速度による |
| `bin/prep.sh` | 1 分未満 |
| variant 1 つ | 1〜3 分。cold 実行ではノードのプロビジョニングが加わる |
| 全 variant と後続 2 フェーズ | 約 25 分 |

スナップショットの作成とモデルの配置は、数分かかるが見るものが無い 2 つです。イメージまたは
モデルが変わらない限り再実行は不要です。

---

## ツールとリージョン

- `aws`（v2）、`kubectl`、`terraform`、`jq`、`python3`
- モデル配置用の `hf` CLI: `pip install --upgrade 'huggingface_hub[cli]'`
- 既定は `us-west-2`。`config.env` で設定します。GPU インスタンスタイプ、EKS 1.34、AWS Deep
  Learning Container のイメージが提供されていれば他のリージョンでも動作します。

Kubernetes 1.34 以上が必要です。EKS 最適化 Bottlerocket NVIDIA AMI は 1.34 以降で NVIDIA
ドライバ 580 を同梱し、ここで使う CUDA 13 のイメージはドライバ 580 を必要とします。

ステップ 3 には Bottlerocket 1.44.0 以上が必要です。SOCI の parallel pull/unpack はこのバージョンで
追加されました。それより前では設定がエラーなく無視されるため、ステップ 3 はステップ 1 と同じものを
計測します。

---

## 不要なもの

- **レジストリの認証情報。** コンテナイメージは AWS Deep Learning Container で、任意の AWS
  アカウントから読み取れます。
- **Hugging Face のトークン。** 既定のモデル Qwen2.5-1.5B-Instruct は gated ではありません。
- **Run:ai Model Streamer のライセンス。** Apache-2.0 で、コンテナイメージに既に含まれています。
- **カスタム AMI。** EKS 最適化 Bottlerocket NVIDIA AMI を公開されたまま使用します。
- **ノード 1 台分を超える GPU クォータ。** variant を同時実行する場合を除きます。本ワークショップ
  では同時実行しません。

---

## 上記の確認

```bash
bin/preflight.sh
```

読み取り専用で、何も作成しません。ツール、認証情報、設定されたインスタンスタイプに対応する
クォータ、既にそれを消費している GPU インスタンス、コンテナイメージとモデルリポジトリが読めるか、
Kubernetes バージョン、Bottlerocket AMI のバージョン、設定されたタイプのインスタンスストアを
報告します。必須項目が失敗した場合は非ゼロで終了します。

確認できない範囲も出力します。上記の権限と GPU 容量です。

`terraform apply` の後は `bin/verify_env.sh` が構築されたものを確認し、計測実行の前に
`bin/check_capacity.sh` が容量を確認します。

---

## 1 つのアカウントで複数回実行する場合

1 つのアカウントにこの環境を複数持つことはできますが、1 つの環境を共有することはできません。
計測対象が cold な 1 個目の Pod だからです。`bin/reset.sh` は、これから実行する variant の
ラベルが付いた Pod を削除し、続いて NodeClaim を削除します。後者はインスタンスの終了を意味します。
1 クラスターを 2 人で使うと、実行途中の相手のノードを削除します。名前空間を分けても解決しません。
各 variant はノードプールに pin されており、reset の対象がそのノードプールだからです。

各環境に別の `NAME_PREFIX`、別の clone、別の Terraform state が必要です。prefix は 2 箇所に設定し、
両者を一致させてください。

```bash
# config.env
export NAME_PREFIX="br-startup-alice"
```

```bash
terraform -chdir=terraform apply -var 'name_prefix=br-startup-alice'
```

ほぼすべてがこれから命名されます。2 面のクラスター、VPC、モデルバケット、IAM ポリシー、Karpenter
のサブネット discovery タグ、スナップショットです。両者が食い違うと、`bin/prep.sh` は Terraform が
作成していないクラスターを探します。

環境 1 つあたり、VPC 1 つ、Elastic IP 1 つ、GPU クォータのノード 1 台分、および上記の費用が
必要です。先に到達する上限は通常、VPC と Elastic IP の既定値 5 です。

同時実行は同じ AZ の同じ GPU 容量を消費するため、セクション 3 の容量問題が起きやすくなります。
実行時間をずらせば回避できます。

スナップショットとモデルバケットは作成後は読み取り専用で共有できます。他の各人がスナップショット
作成を省けます。同一アカウント内であればクロスアカウントのポリシーは不要ですが、読み取り側の
ロールには他の prefix のバケットへの `s3:GetObject` が必要です。
