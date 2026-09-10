# Account prerequisites

**English** | [日本語](#japanese)

Read this if you want to run the workshop in your own AWS account, either alongside the
session or afterwards. The session itself does not require it — the presenter runs everything
in a separate account and shares the screen — so nothing here blocks attending.

One item has lead time and the rest do not. If you read only one section, read the quota one.

---

## Start here: the GPU quota

The workshop runs GPU instances one at a time, so the requirement is one node's worth of quota.
How much that is depends on which instance type you use, because these quotas are counted in
vCPU rather than in instances.

With the default type, `gr6.8xlarge`, that is **32 vCPU of Running On-Demand G and VT
instances**:

```bash
aws service-quotas get-service-quota --region us-west-2 \
  --service-code ec2 --quota-code L-DB2E81BA
```

If the value is below what your type needs, request an increase. Requesting four nodes' worth
leaves room to re-run a variant without waiting for the previous node to terminate.

**Increases are not granted immediately.** This is the one prerequisite worth handling several
days ahead. Everything else below can be done on the day.

If the account already runs GPU instances in the same region, they consume the same quota.
`bin/preflight.sh` reports both the quota and what is already running against it.

### If you use a different instance type

Set `GPU_INSTANCE_TYPE` in `config.env`. Two constraints apply:

**The type needs local NVMe instance store.** Steps 3 and 4 place container storage on it. On a
type without instance store, both of those steps measure the same thing as step 1 and the
workshop loses half its point. Two or more instance-store disks additionally means
`instanceStorePolicy: RAID0` stripes rather than just relocating, because Bottlerocket skips a
single-member array.

**The vCPU count changes the result.** SOCI's parallel unpack is CPU-bound, so a smaller type
produces a smaller improvement in step 3 and a larger type a larger one. This is not a defect
in the measurement — it is the finding — but it means a figure from one type does not carry to
another.

Single-GPU types with instance store, from `describe-instance-types`:

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

All of the above count against **G and VT**, quota `L-DB2E81BA`, so switching between them does
not need a different quota approved — only enough of the same one.

`bin/preflight.sh` compares the live quota against the configured type's vCPU count, so run it
after changing the type rather than reading this table.

The GPU memory column matters only if you raise `MODEL_HF_REPO` to a larger model. The default
model is 2.9 GB and fits on any of these.

### P types are not used

`bin/prep.sh` and `bin/preflight.sh` both refuse a `p` type. This is a cost guard rather than a
technical limit, and there are three reasons for it.

The model is 1.5B parameters and fits in 24 GB, so a P type produces the same measurement. It
costs several times as much while doing so:

| Type | On-Demand, `us-west-2` |
|---|---:|
| `g6.4xlarge` | 1.32 USD/hour |
| `gr6.8xlarge` (default) | 2.45 USD/hour |
| `p5.4xlarge` | 6.88 USD/hour |
| `p4d.24xlarge` | 21.96 USD/hour |

And P types count against a separate quota, `L-417A185B` — an account prepared for this
workshop by raising the G quota would not launch one at all, which surfaces as a variant that
stays Pending.

If you have a reason, `ALLOW_LARGE_GPU_FAMILY=1` overrides both checks. The cost figures below
assume a G type.

---

## Run the check script

The repository includes a read-only check that covers everything verifiable without creating
anything:

```bash
git clone <repository URL>
cd ai-on-eks-startup-optimizing-workshop
bin/preflight.sh
```

It reports the tools, credentials, quotas, existing usage, the container image, the model
repository, the Kubernetes version, the Bottlerocket AMI version and the instance store on the
chosen instance type. It exits non-zero if a required check fails, so the output can be sent
back as-is.

It also prints what it cannot check, which is the IAM permissions described below.

---

## What gets created

Terraform creates all of this in one region, in a VPC of its own. Nothing is placed in an
existing VPC and nothing existing is modified.

| | |
|---|---|
| VPC | One, with private and public subnets across three Availability Zones, one NAT gateway (which uses one Elastic IP), and an S3 Gateway VPC endpoint |
| EKS clusters | Two. One with self-managed Karpenter, one with EKS Auto Mode. Two are needed because both controllers own the same `karpenter.sh` CRDs |
| Managed node group | One small group of two `m6i.large` nodes per cluster, for CoreDNS and the Karpenter controller |
| GPU nodes | Created and removed by Karpenter during the runs, one at a time |
| IAM | Roles and policies for the two clusters, the Karpenter controller, the nodes, and one role bound to the workshop's service account through EKS Pod Identity |
| S3 | One bucket for the model weights, with public access blocked and server-side encryption enabled |
| EBS snapshot | One, holding the container image layers, built by a temporary instance that is terminated afterwards |
| Helm release | Karpenter, on the first cluster |

Teardown is `terraform destroy` plus deleting the snapshot and the bucket, which the
repository documents.

---

## Permissions

The account needs to be able to create the resources listed above. In practice this means an
administrative role, or one that can create IAM roles and policies. `bin/preflight.sh` cannot
verify this: IAM has no dry-run, and a permissions boundary or a Service Control Policy can
deny at apply time without being visible in advance.

If your account uses a permissions boundary, the roles Terraform creates will need it applied.
That is a change to `terraform/main.tf` rather than something to request, and it is worth
identifying before the day.

---

## Region

`us-west-2` by default, set in `config.env`. Another region works if it offers the GPU
instance type, EKS 1.34 and the AWS Deep Learning Container image. `bin/preflight.sh` checks
all three against whichever region is configured.

---

## Cost and time

About **USD 6 to 12** in total, and about **two hours**, most of which runs unattended.

Two EKS clusters and a NAT gateway cost about **USD 0.35 per hour** while they exist, whether
or not a GPU node is running. A GPU node costs roughly USD 2 per hour and exists only during a
run. Leaving the environment up overnight is therefore a few dollars; leaving a GPU node up
overnight is not.

The one step to schedule rather than run live is the EBS snapshot build, which takes 14 minutes
for this image.

---

## What you do not need

- **No registry credentials.** The container image is an AWS Deep Learning Container and is
  readable from any AWS account.
- **No Hugging Face token.** The model is Qwen2.5-1.5B-Instruct, which is not gated.
- **No licence for Run:ai Model Streamer.** It is Apache-2.0 and already present in the
  container image.
- **No custom AMI build.** The EKS-optimized Bottlerocket NVIDIA AMI is used as published.
- **No GPU quota beyond one node**, unless you want to run variants concurrently, which the
  workshop does not.

---

## If several people want to run it

One AWS account can hold several of these environments, but they cannot share one. Give each
person their own `NAME_PREFIX`, their own clone and their own Terraform state.

The prefix has to be set in two places, and they have to agree. `config.env` is what the
scripts read, and `name_prefix` is what Terraform reads:

```bash
# config.env
export NAME_PREFIX="br-startup-alice"
```

```bash
terraform -chdir=terraform apply -var 'name_prefix=br-startup-alice'
```

Almost everything is named from that prefix: both clusters, the VPC, the model bucket, the IAM
policy, the Karpenter subnet discovery tag and the snapshot. If the two disagree, `bin/prep.sh`
will look for clusters that Terraform did not create.

### Why one environment cannot be shared

The measurements are of a cold first pod, so the scripts delete what a previous run left
behind. `bin/reset.sh` removes the pods labelled for the variant it is about to run **and the
NodeClaim**, which terminates the instance:

```bash
kubectl -n bench delete pod -l "workshop-variant=${variant}"
kubectl delete nodeclaim -l "karpenter.sh/nodepool=${variant}"
```

Two people on one cluster would delete each other's nodes mid-run. A separate namespace does
not help, because each variant is pinned to one node pool and the node pool is what gets
reset.

### What to budget for each additional person

| Per person | Note |
|---|---|
| 1 VPC | The default quota is 5 per region, and existing VPCs count |
| 1 Elastic IP | For the NAT gateway. The default quota is also 5 |
| 32 vCPU of G and VT | Concurrent runs each need a node at the same time |
| About USD 6 to 12 | Costs do not share |

The GPU quota is the one to check against the number of people. Four people running
concurrently need 128 vCPU, not 32.

### The constraint that is not a quota

Concurrent runs draw on the same GPU capacity in the same Availability Zones. Capacity is per
instance type per zone, and a zone can be short of one type while another type is fine. When
Karpenter is refused, it holds that offering unavailable for three minutes, and the pod waits
out the TTL before a node is even requested. That wait lands in the measurement with no error
to explain it.

Two ways to reduce that. Have everyone run `bin/check_capacity.sh` before starting and agree
on an instance type that has capacity in every zone. Or stagger the runs rather than starting
together, which also avoids everyone hitting the registry at once.

### What can be shared

The snapshot and the model bucket are read-only once built, so one person can build them and
the others can point at them, which saves each of the others the 14-minute snapshot build:

```bash
# in config.env
export MODEL_BUCKET="<the bucket the first person created>"
# and in results/snapshot-id.txt, or via the SSM parameter /<their prefix>/image-cache-snapshot-id
```

Within one account this needs no cross-account policy. The reading role needs `s3:GetObject`
on that bucket, which is what `${NAME_PREFIX}-model-weights-read` grants for the bucket the
same prefix created, so sharing means either granting the other prefixes' roles access or
staging the model per person.

---

## On the day

GPU capacity varies by instance type and Availability Zone, and it changes within minutes. A
zone with no capacity for the chosen type does not stop Karpenter from using another zone, but
it does add a wait to the measurement, so it is worth checking shortly before starting:

```bash
bin/check_capacity.sh
```

This launches one instance per subnet and terminates it immediately, because no API reports
available capacity. If it fails, the error from EC2 names the Availability Zones that can serve
the request at that moment.

After the last run, check that no GPU node is still up. Phase 3 ends with a pod running, and
Karpenter keeps the node for 30 minutes after the last pod leaves, which is deliberate — the
warm runs need it — but it means a finished session can leave a GPU instance behind.

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # expect no output
```

<br>

---
---

<a id="japanese"></a>

# アカウントの前提条件

[English](#account-prerequisites) | **日本語**

ワークショップを自身の AWS アカウントで実行する場合にお読みください。セッションと並行して
実行することも、後日実行することもできます。セッション自体には不要です。発表者が別アカウントで
すべてを実行し画面を共有するため、ここに書かれた準備が整っていなくても参加に支障はありません。

リードタイムが必要な項目は 1 つだけです。1 節だけ読む場合はクォータの節をお読みください。

---

## 最初に: GPU クォータ

ワークショップは GPU インスタンスを 1 台ずつ起動するため、必要なのはノード 1 台分のクォータです。
それが何 vCPU になるかは使用するインスタンスタイプによって変わります。これらのクォータは
インスタンス数ではなく vCPU 単位で数えられるためです。

既定のタイプ `gr6.8xlarge` の場合は **Running On-Demand G and VT instances の 32 vCPU** です。

```bash
aws service-quotas get-service-quota --region us-west-2 \
  --service-code ec2 --quota-code L-DB2E81BA
```

値が使用するタイプの必要量を下回る場合は引き上げを申請してください。ノード 4 台分を申請しておくと、
前のノードの終了を待たずに variant を再実行する余裕ができます。

**引き上げは即時に承認されるものではありません。** 数日前から進めておく価値があるのはこの項目
だけです。以下はすべて当日でも対応できます。

同じリージョンで既に GPU インスタンスを動かしている場合、同じクォータを消費します。
`bin/preflight.sh` はクォータと、既にそれを消費して動いているものの両方を報告します。

### 別のインスタンスタイプを使う場合

`config.env` の `GPU_INSTANCE_TYPE` を設定します。制約が 2 つあります。

**ローカル NVMe インスタンスストアが必要です。** ステップ 3 と 4 はそこにコンテナストレージを
配置します。インスタンスストアを持たないタイプでは、この 2 つのステップがステップ 1 と同じものを
計測することになり、ワークショップの半分が意味を失います。ディスクが 2 本以上あれば、
`instanceStorePolicy: RAID0` は移動だけでなくストライピングも行います。Bottlerocket はメンバーが
1 つのアレイを省くためです。

**vCPU 数は結果を変えます。** SOCI の並列展開は CPU バウンドなので、小さいタイプではステップ 3 の
改善幅が小さくなり、大きいタイプでは大きくなります。これは計測の欠陥ではなく計測結果そのもの
ですが、あるタイプで得た数字が別のタイプには当てはまらないことを意味します。

`describe-instance-types` から取得した、インスタンスストアを持つシングル GPU のタイプです。

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

上記はすべて **G and VT**（クォータ `L-DB2E81BA`）に計上されます。この中で切り替える場合、別の
クォータの承認は不要で、同じクォータの枠が足りていれば済みます。

`bin/preflight.sh` は設定されたタイプの vCPU 数と実際のクォータを比較します。タイプを変更した
場合は、この表を読むのではなくスクリプトを実行してください。

GPU メモリの列が問題になるのは、`MODEL_HF_REPO` をより大きいモデルに変更する場合だけです。既定の
モデルは 2.9 GB で、上記のいずれにも収まります。

### P 系は使いません

`bin/prep.sh` と `bin/preflight.sh` はどちらも `p` 系を拒否します。これは技術的な制限ではなく
コストのガードで、理由は 3 つあります。

モデルは 1.5B パラメータで 24 GB に収まるため、P 系でも計測結果は同じです。そのうえで数倍の費用が
かかります。

| タイプ | On-Demand、`us-west-2` |
|---|---:|
| `g6.4xlarge` | 1.32 USD/時 |
| `gr6.8xlarge`（既定） | 2.45 USD/時 |
| `p5.4xlarge` | 6.88 USD/時 |
| `p4d.24xlarge` | 21.96 USD/時 |

そして P 系は別枠のクォータ `L-417A185B` に計上されます。G のクォータを引き上げて本ワークショップに
備えたアカウントでは、P 系はそもそも起動しません。これは variant が Pending のままになる形で
現れます。

理由がある場合は `ALLOW_LARGE_GPU_FAMILY=1` で両方のチェックを上書きできます。以下の費用の記載は
G 系を前提としています。

---

## チェックスクリプトの実行

リポジトリには、何も作成せずに確認できる範囲をすべて検査する読み取り専用のスクリプトが
含まれています。

```bash
git clone <リポジトリ URL>
cd ai-on-eks-startup-optimizing-workshop
bin/preflight.sh
```

ツール、認証情報、クォータ、既存の使用状況、コンテナイメージ、モデルリポジトリ、Kubernetes
バージョン、Bottlerocket AMI のバージョン、選択したインスタンスタイプのインスタンスストアを
確認します。必須項目が失敗した場合は非ゼロで終了するため、出力をそのまま返送いただけます。

確認できない範囲（後述の IAM 権限）も出力します。

---

## 作成されるもの

Terraform は以下をすべて 1 リージョン内の専用 VPC に作成します。既存の VPC には何も配置せず、
既存のリソースを変更しません。

| | |
|---|---|
| VPC | 1 つ。3 つの AZ にまたがるプライベート/パブリックサブネット、NAT ゲートウェイ 1 つ（Elastic IP を 1 つ使用）、S3 Gateway VPC エンドポイント |
| EKS クラスター | 2 面。1 面は自己管理の Karpenter、1 面は EKS Auto Mode。両コントローラが同じ `karpenter.sh` CRD を所有するため 2 面必要です |
| マネージドノードグループ | 各クラスターに `m6i.large` 2 台の小さなグループ 1 つ。CoreDNS と Karpenter コントローラ用 |
| GPU ノード | 実行中に Karpenter が 1 台ずつ作成・削除します |
| IAM | 2 つのクラスター、Karpenter コントローラ、ノード用のロールとポリシー、および EKS Pod Identity でワークショップのサービスアカウントに紐付けるロール 1 つ |
| S3 | モデルウェイト用のバケット 1 つ。パブリックアクセスをブロックし、サーバーサイド暗号化を有効化 |
| EBS スナップショット | 1 つ。コンテナイメージのレイヤを保持します。一時インスタンスが作成し、そのインスタンスは終了します |
| Helm リリース | Karpenter。1 面目のクラスターに |

撤去は `terraform destroy` と、スナップショットおよびバケットの削除です。手順はリポジトリに
記載しています。

---

## 権限

上記のリソースを作成できる権限が必要です。実際には管理者ロール、または IAM ロールとポリシーを
作成できるロールを意味します。`bin/preflight.sh` ではこれを検証できません。IAM に dry-run が
無く、Permissions Boundary や Service Control Policy は事前に見えない形で apply 時に拒否し得る
ためです。

アカウントで Permissions Boundary を使用している場合、Terraform が作成するロールにもそれを
適用する必要があります。これは申請ではなく `terraform/main.tf` の変更で対応するものなので、
当日より前に把握しておく価値があります。

---

## リージョン

既定は `us-west-2` で、`config.env` で設定します。GPU インスタンスタイプ、EKS 1.34、AWS Deep
Learning Container のイメージが提供されていれば他のリージョンでも動作します。
`bin/preflight.sh` は設定されたリージョンに対してこの 3 点を確認します。

---

## 費用と時間

合計で **6〜12 USD** 程度、**約 2 時間**です。時間の大半は無人で進みます。

EKS クラスター 2 面と NAT ゲートウェイは、GPU ノードが動いていなくても存在する間
**約 0.35 USD/時**かかります。GPU ノードは約 2 USD/時で、実行中のみ存在します。したがって環境を
一晩残す場合の費用は数ドルですが、GPU ノードを一晩残す場合はそうなりません。

当日実行ではなく事前に済ませるべき工程は EBS スナップショットの作成で、このイメージでは 14 分
かかります。

---

## 不要なもの

- **レジストリの認証情報は不要です。** コンテナイメージは AWS Deep Learning Container で、
  任意の AWS アカウントから読み取れます。
- **Hugging Face のトークンは不要です。** モデルは Qwen2.5-1.5B-Instruct で、gated ではありません。
- **Run:ai Model Streamer のライセンスは不要です。** Apache-2.0 で、コンテナイメージに既に
  含まれています。
- **カスタム AMI のビルドは不要です。** EKS 最適化 Bottlerocket NVIDIA AMI を公開されたまま
  使用します。
- **1 ノード分を超える GPU クォータは不要です。** variant を同時実行する場合を除きます。
  ワークショップでは同時実行しません。

---

## 複数人で実行する場合

1 つの AWS アカウントにこの環境を複数持つことはできますが、1 つの環境を共有することはできません。
各自に別の `NAME_PREFIX`、別の clone、別の Terraform state を用意してください。

prefix は 2 箇所に設定する必要があり、両者を一致させてください。スクリプトが読むのは
`config.env`、Terraform が読むのは `name_prefix` です。

```bash
# config.env
export NAME_PREFIX="br-startup-alice"
```

```bash
terraform -chdir=terraform apply -var 'name_prefix=br-startup-alice'
```

ほぼすべてがこの prefix から命名されます。2 面のクラスター、VPC、モデルバケット、IAM ポリシー、
Karpenter のサブネット discovery タグ、スナップショットです。両者が食い違うと、`bin/prep.sh` は
Terraform が作成していないクラスターを探すことになります。

### 1 つの環境を共有できない理由

計測対象が cold な 1 個目の Pod なので、スクリプトは前回の実行が残したものを削除します。
`bin/reset.sh` は、これから実行する variant のラベルが付いた Pod と、**NodeClaim** を削除します。
NodeClaim の削除はインスタンスの終了を意味します。

```bash
kubectl -n bench delete pod -l "workshop-variant=${variant}"
kubectl delete nodeclaim -l "karpenter.sh/nodepool=${variant}"
```

1 クラスターを 2 人で使うと、実行途中の相手のノードを削除します。名前空間を分けても解決しません。
各 variant はノードプールに pin されており、reset の対象がそのノードプールだからです。

### 1 人増えるごとに必要なもの

| 1 人あたり | 備考 |
|---|---|
| VPC 1 つ | 既定クォータはリージョンあたり 5。既存の VPC も数に含まれます |
| Elastic IP 1 つ | NAT ゲートウェイ用。既定クォータも 5 |
| G / VT の 32 vCPU | 同時実行する場合、各自が同時にノードを必要とします |
| 6〜12 USD 程度 | 費用は共有されません |

人数に対して確認すべきは GPU クォータです。4 人が同時実行するなら 32 ではなく 128 vCPU が
必要です。

### クォータではない制約

同時実行は同じ AZ の同じ GPU 容量を消費します。容量はインスタンスタイプと AZ の組み合わせごとで、
ある AZ が 1 つのタイプだけ不足していることもあります。Karpenter が拒否されると、その offering を
3 分間 unavailable に保持し、Pod はノードが要求される前に TTL を待ちます。この待ち時間は、説明する
エラーを伴わずに計測に入ります。

軽減する方法は 2 つあります。全員が開始前に `bin/check_capacity.sh` を実行し、全 AZ で容量のある
インスタンスタイプを合意することです。あるいは同時に始めず実行時間をずらすことです。後者は
レジストリへの同時アクセスも避けられます。

### 共有できるもの

スナップショットとモデルバケットは作成後は読み取り専用なので、1 人が作成して他の人がそれを指す
ことができます。他の各人が 14 分のスナップショット作成を省けます。

```bash
# config.env に指定
export MODEL_BUCKET="<最初の人が作成したバケット>"
# スナップショット ID は results/snapshot-id.txt、または
# SSM パラメータ /<その人の prefix>/image-cache-snapshot-id から
```

同一アカウント内であればクロスアカウントのポリシーは不要です。読み取り側のロールには対象バケットへの
`s3:GetObject` が必要です。これは `${NAME_PREFIX}-model-weights-read` が同じ prefix で作成した
バケットに対して付与しているものなので、共有する場合は他の prefix のロールにアクセスを許可するか、
各自でモデルを配置することになります。

---

## 当日

GPU の容量はインスタンスタイプと AZ の組み合わせごとに変動し、数分単位で変わります。選択した
タイプの容量が無い AZ があっても Karpenter は別の AZ を使えるため実行は止まりませんが、計測に
待ち時間が加わります。開始直前に確認する価値があります。

```bash
bin/check_capacity.sh
```

利用可能な容量を報告する API が存在しないため、各サブネットに 1 台起動して即座に終了させます。
失敗した場合、EC2 のエラーにはその時点で要求を満たせる AZ が示されます。

最後の実行の後、GPU ノードが残っていないか確認してください。フェーズ 3 は Pod が動いている状態で
終わり、Karpenter は最後の Pod が消えてから 30 分ノードを保持します。これは warm 実行に必要なため
意図的な設定ですが、セッション終了後に GPU インスタンスが残る原因になります。

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # 何も出力されないこと
```
