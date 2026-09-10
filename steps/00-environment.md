# Step 0 — Build the environment

**English** | [日本語](#japanese)

Everything the later steps measure runs on this. There is nothing to compare yet, so the
purpose here is different: the environment is built so that the only thing differing between
the variants is the mechanism each one adds. Four decisions in the Terraform exist for that
reason, and one exists to keep the environment working at all.

---

## Build it

```bash
cd terraform
terraform init
terraform apply
cd ..
```

About 15 to 20 minutes, most of it waiting for two EKS control planes.

```bash
bin/verify_env.sh
```

Run that before the first variant. Every check in it corresponds to something that fails later
in a way that does not name its cause.

---

## Why two clusters

```
<prefix>-karpenter   self-managed Karpenter    baseline, snapshot, soci
<prefix>-automode    EKS Auto Mode             automode
```

Self-managed Karpenter and EKS Auto Mode both own the `karpenter.sh` CRDs — `NodePool` and
`NodeClaim` are the same API group in both. Installing one on a cluster that already has the
other means two controllers reconciling the same objects. Two clusters avoids that.

The cost of the split is that `automode` runs on a different control plane from the other
three, so its figure is not a like-for-like comparison. `bin/report.py` prints that caveat
alongside the table.

What is not split is the VPC. Both clusters use the same subnets, so the route to the registry
is identical and the image figures remain comparable. `bin/verify_env.sh` checks this, because
a change that moved one cluster to its own VPC would invalidate the comparison without
producing any error.

---

## Four decisions that make the comparison valid

### One instance type, pinned

Every node pool pins `node.kubernetes.io/instance-type` to a single value from `config.env`.
Karpenter would otherwise choose a type per pod, and a variant that happened to get more vCPU
would look like a faster mechanism. SOCI's unpack is CPU-bound, so that would not be a subtle
difference.

`bin/verify_env.sh` reads the pinned type back from all three pools and compares them with
`config.env`, and `bin/report.py` refuses to treat a run as a comparison if the variants
launched on different types.

### One VPC, one set of subnets

Covered above. Same route to the registry for every variant.

### Kubernetes 1.34 or above

The EKS-optimized Bottlerocket NVIDIA AMI ships NVIDIA driver 580 from 1.34 onwards, and the
CUDA 13 image used here needs driver 580. On an earlier version the pod fails to start, which
at least fails loudly.

### No NVIDIA device plugin is deployed

The Bottlerocket NVIDIA AMI already contains the driver, the container toolkit and the
Kubernetes device plugin, and Auto Mode provides its own. Deploying another would be a
difference between the two clusters.

The readiness probe runs `nvidia-smi` inside the container, so a pod reaching Ready means the
GPU is usable from the container rather than only present on the node.

---

## The decision that keeps it working

### The Karpenter controller needs a node that is not managed by Karpenter

Each cluster has a small managed node group of two `m6i.large` instances, labelled
`karpenter.sh/controller=true`, and the Karpenter controller is pinned to that label by
`nodeSelector`.

What happens when this is wrong is worth knowing, because it is silent. If that node group has
no nodes, the controller has nowhere to run and goes `Pending`. Nothing then creates NodeClaims,
so every variant's pod also sits `Pending`, and no message anywhere says the controller is
missing. `bin/bench.sh` waits 25 minutes and reports that the pod never became Ready.

```bash
# what that failure looks like
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
# karpenter-5d65f95469-4hjk2   0/1   Pending   0   11h
```

`bin/verify_env.sh` checks for a Ready node with that label and for a Running controller pod,
which is the check that turns 25 minutes of waiting into an immediate answer.

The managed node group's `min_size` is 2 rather than 0 for the same reason. If the scaling
config drifts to zero, EKS will reconcile the group down to zero and take the controller with
it.

### The Karpenter controller policy is inline, not managed

```hcl
enable_inline_policy = true
```

The controller's policy exceeds the 6144-byte quota for a managed policy, which fails at apply
time with `LimitExceeded: Cannot exceed quota for PolicySize: 6144`. An inline role policy
allows 10240 bytes, which it fits inside.

---

## Two things Terraform sets up that later steps depend on

### EKS Pod Identity for the weights bucket

Phases 2 and 3 read the model from S3. The obvious approach is to grant the node role and let
the container pick up credentials from instance metadata, and it does not work here: Karpenter
sets the IMDS hop limit to 1, so a request from inside a container is one hop too far and the
AWS SDK reports `Unable to locate credentials`.

Terraform binds a role to the `bench` service account with
`aws_eks_pod_identity_association` instead. The hop limit is left as it is, because it is what
stops a pod from using the node's permissions, and scoping a role to a service account is what
to do in production as well. [Step 6](06-weights.md) shows the pod spec side of this.

### An S3 Gateway VPC endpoint

Both things this workshop measures downloading end up at S3: the model weights directly, and
the container image layers, because ECR stores layers in S3. The endpoint adds a route for the
regional S3 prefix list to the private route tables, which is more specific than the default
route, so that traffic does not go through the NAT gateway.

This removes the NAT data-processing charge and the dependency on NAT. It does not promise a
faster download — at the rate one node pulls here, NAT is not the limit — and it does not
change an unencrypted connection into an encrypted one, since both paths can use HTTPS.
[Step 6](06-weights.md) covers what it does not cover.

---

## What is not built here

The EBS snapshot for step 2 and the model in S3 for step 6 are prepared separately. Each takes
several minutes and neither needs supervision:

```bash
IMAGE="$(grep WORKLOAD_IMAGE config.env | cut -d'"' -f2)" snapshot/build-snapshot.sh
snapshot/stage-model.sh
bin/prep.sh
```

`bin/prep.sh` applies the node classes and node pools and substitutes the snapshot ID into the
step 2 node class. It is safe to re-run, and it has to be re-run after changing
`GPU_INSTANCE_TYPE` or rebuilding the snapshot.

---

## Teardown

```bash
terraform -chdir=terraform destroy
```

The snapshot and the S3 bucket are outside Terraform's state, so they survive `destroy` and
have to be removed separately. The README covers this. Before destroying, check that no GPU
node is still running: Karpenter keeps a node for 30 minutes after its last pod leaves, which
the warm runs rely on, so a finished session can leave one behind.

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # expect no output
```

---

Next: [Step 1 — the baseline](01-baseline.md)

<br>

---
---

<a id="japanese"></a>

# ステップ 0 — 環境を構築する

[English](#step-0--build-the-environment) | **日本語**

以降のステップが計測する対象は、すべてこの環境の上で動きます。ここでは比較するものがまだ無いため
目的が異なります。variant 間で異なるのが各 variant が追加する機構だけになるように環境を作ります。
Terraform 上の 4 つの判断はそのためにあり、もう 1 つは環境が動作し続けるためにあります。

---

## 構築する

```bash
cd terraform
terraform init
terraform apply
cd ..
```

15〜20 分程度です。大半は EKS のコントロールプレーン 2 面の待ち時間です。

```bash
bin/verify_env.sh
```

最初の variant を実行する前にこれを実行してください。含まれる各チェックは、後段で原因を示さない
形で失敗する事象に対応しています。

---

## クラスターを 2 面にする理由

```
<prefix>-karpenter   自己管理の Karpenter    baseline, snapshot, soci
<prefix>-automode    EKS Auto Mode           automode
```

自己管理の Karpenter と EKS Auto Mode は、どちらも `karpenter.sh` の CRD を所有します。
`NodePool` と `NodeClaim` はどちらでも同じ API グループです。一方が入っているクラスターに他方を
入れると、2 つのコントローラが同じオブジェクトを調整することになります。2 面に分ければこれを
避けられます。

分割の代償は、`automode` が他の 3 つと異なるコントロールプレーンで動くことです。その数字は
like-for-like な比較ではありません。`bin/report.py` はこの注意書きを表と並べて出力します。

分割しないのは VPC です。両クラスターが同じサブネットを使うため、レジストリへの経路は同一で、
イメージの数字は比較可能なままです。`bin/verify_env.sh` がこれを確認します。一方のクラスターを
別 VPC に移す変更は、エラーを出さずに比較を無効化するためです。

---

## 比較を成立させる 4 つの判断

### インスタンスタイプを 1 つに固定する

各 node pool は `node.kubernetes.io/instance-type` を `config.env` の 1 つの値に固定します。
そうしないと Karpenter が Pod ごとにタイプを選び、より多い vCPU を得た variant が、速い機構を
持っているかのように見えます。SOCI の展開は CPU バウンドなので、これは些細な差にはなりません。

`bin/verify_env.sh` は 3 つの pool から固定されたタイプを読み戻して `config.env` と比較します。
また `bin/report.py` は、variant が異なるタイプで起動した実行を比較として扱いません。

### VPC とサブネットを 1 組にする

前述のとおりです。すべての variant でレジストリへの経路が同一になります。

### Kubernetes 1.34 以上

EKS 最適化 Bottlerocket NVIDIA AMI は 1.34 以降で NVIDIA ドライバ 580 を同梱し、ここで使う
CUDA 13 のイメージはドライバ 580 を必要とします。それより前のバージョンでは Pod が起動に失敗
します。少なくともこれは明示的に失敗します。

### NVIDIA device plugin を導入しない

Bottlerocket NVIDIA AMI にはドライバ、container toolkit、Kubernetes device plugin が既に含まれて
おり、Auto Mode は独自のものを提供します。別途導入すると、2 面のクラスター間の差異になります。

readiness probe はコンテナ内で `nvidia-smi` を実行します。したがって Pod が Ready になることは、
GPU がノード上に存在するだけでなくコンテナから使えることを意味します。

---

## 環境を動作させ続けるための判断

### Karpenter コントローラには Karpenter が管理しないノードが必要

各クラスターに `m6i.large` 2 台の小さなマネージドノードグループがあり、
`karpenter.sh/controller=true` のラベルが付いています。Karpenter コントローラは `nodeSelector`
でこのラベルに固定されています。

これが誤ったときに何が起きるかは、知っておく価値があります。無言で失敗するためです。この
ノードグループにノードが無いと、コントローラは動く場所が無く `Pending` になります。すると
NodeClaim を作るものが無くなり、各 variant の Pod も `Pending` のままになります。そして
**コントローラが不在であることを、どこも報告しません。** `bin/bench.sh` は 25 分待ち、Pod が
Ready にならなかったと報告します。

```bash
# この失敗の見え方
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
# karpenter-5d65f95469-4hjk2   0/1   Pending   0   11h
```

`bin/verify_env.sh` は、そのラベルを持つ Ready なノードと、Running なコントローラ Pod を確認
します。25 分の待機を即座の回答に変えるチェックです。

マネージドノードグループの `min_size` が 0 ではなく 2 なのも同じ理由です。スケーリング設定が 0 に
drift すると、EKS はグループを 0 に収束させ、コントローラも消えます。

### Karpenter コントローラのポリシーは managed ではなく inline

```hcl
enable_inline_policy = true
```

コントローラのポリシーは managed policy の 6144 バイト上限を超え、apply 時に
`LimitExceeded: Cannot exceed quota for PolicySize: 6144` で失敗します。インラインのロール
ポリシーは 10240 バイトまで許容され、その中に収まります。

---

## 後のステップが依存する 2 つの設定

### ウェイトバケット用の EKS Pod Identity

フェーズ 2 と 3 は S3 からモデルを読みます。思いつきやすいのはノードロールに権限を与え、コンテナが
インスタンスメタデータから認証情報を取得する方法ですが、ここでは動きません。Karpenter が IMDS の
hop limit を 1 に設定するため、コンテナ内からのリクエストは 1 hop 超過となり、AWS SDK は
`Unable to locate credentials` を返します。

代わりに Terraform は `aws_eks_pod_identity_association` で `bench` サービスアカウントにロールを
紐付けます。hop limit はそのままにします。Pod がノードの権限を使うことを防いでいるのがこれで
あり、サービスアカウント単位でロールを絞るのは本番でもそうすべき方法です。Pod spec 側は
[ステップ 6](06-weights.md) にあります。

### S3 Gateway VPC エンドポイント

本ワークショップがダウンロードを計測する対象は、どちらも最終的に S3 に到達します。モデル
ウェイトは直接、コンテナイメージのレイヤは ECR がレイヤを S3 に保存しているためです。エンド
ポイントは、リージョンの S3 プレフィックスリスト向けのルートをプライベートルートテーブルに
追加します。これはデフォルトルートより具体的なため、その通信は NAT ゲートウェイを通りません。

これにより NAT のデータ処理料金と NAT への依存が取り除かれます。ダウンロードが速くなることは
保証しません。ここで 1 台のノードが取得する速度では NAT は制約ではありません。また非暗号の接続を
暗号化するものでもありません。どちらの経路でも HTTPS を使えます。カバーしない範囲は
[ステップ 6](06-weights.md) に記載しています。

---

## ここで作らないもの

ステップ 2 用の EBS スナップショットと、ステップ 6 用の S3 上のモデルは別に準備します。どちらも
数分かかり、監視は不要です。

```bash
IMAGE="$(grep WORKLOAD_IMAGE config.env | cut -d'"' -f2)" snapshot/build-snapshot.sh
snapshot/stage-model.sh
bin/prep.sh
```

`bin/prep.sh` は node class と node pool を適用し、ステップ 2 の node class にスナップショット ID を
埋め込みます。再実行して問題ありません。`GPU_INSTANCE_TYPE` の変更後やスナップショットの再作成後は
再実行が必要です。

---

## 撤去

```bash
terraform -chdir=terraform destroy
```

スナップショットと S3 バケットは Terraform の state 外なので `destroy` では残り、別途削除が必要
です。手順は README にあります。destroy の前に、GPU ノードが残っていないか確認してください。
Karpenter は最後の Pod が消えてから 30 分ノードを保持します。これは warm 実行が依存している挙動
なので、セッション終了後にノードが残ることがあります。

```bash
kubectl -n bench delete pods --all
kubectl get nodeclaims        # 何も出力されないこと
```

---

次: [ステップ 1 — ベースライン](01-baseline.md)
