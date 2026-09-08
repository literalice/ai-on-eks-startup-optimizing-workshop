# Step 4 — Let EKS Auto Mode do it
# ステップ 4 — EKS Auto Mode に任せる

**Goal / 目的:** determine how much of step 3's configuration EKS Auto Mode performs
without being configured, and which options are not available in exchange.

ステップ 3 の設定のうち、EKS Auto Mode が設定なしで実施する範囲と、その代わりに使えなく
なる選択肢を確認します。

---

## The configuration / 設定内容

This is the complete node class, from
[`13-automode.yaml`](../manifests/automode/13-automode.yaml):

これが node class の全体です。

```yaml
apiVersion: eks.amazonaws.com/v1        # not karpenter.k8s.aws/v1
kind: NodeClass                         # not EC2NodeClass
metadata:
  name: automode
spec:
  role: "<Auto Mode node IAM role>"
  ephemeralStorage:
    size: "80Gi"
  subnetSelectorTerms:
    - tags:
        kubernetes.io/role/internal-elb: "1"
  securityGroupSelectorTerms:
    - tags:
        aws:eks:cluster-name: "<cluster>"
```

Compared with step 3, the following are absent:

ステップ 3 と比べて、次のものがありません。

| Absent | What still happens / それでも行われること |
|---|---|
| `instanceStorePolicy: RAID0` | The NVMe is formatted, using RAID 0 across multiple drives, and container storage is placed on it.<br>NVMe がフォーマットされ（複数本の場合は RAID 0）、コンテナストレージが配置されます。 |
| The `userData` TOML block | Image pull and unpack run in parallel on GPU instances.<br>GPU インスタンスでイメージの pull と展開が並列で実行されます。 |
| `blockDeviceMappings` | Auto Mode determines the volume configuration.<br>Auto Mode がボリューム構成を決めます。 |
| `amiSelectorTerms` | Auto Mode selects and updates the AMI.<br>Auto Mode が AMI を選定・更新します。 |

### The field that needs attention / 注意が必要なフィールド

```yaml
  ephemeralStorage:
    size: "80Gi"        # below the instance's NVMe capacity
```

According to the [Auto Mode documentation][amdocs], when `ephemeralStorage.size` is
smaller than the instance's local NVMe capacity, Auto Mode attaches a 20 GiB EBS volume
and places ephemeral container data on the NVMe. When the value equals or exceeds NVMe
capacity, Auto Mode does not attach the EBS volume and makes the NVMe available to the
workload instead.

[Auto Mode のドキュメント][amdocs]によると、`ephemeralStorage.size` がインスタンスの
ローカル NVMe 容量より小さい場合、Auto Mode は 20 GiB の EBS ボリュームを付け、一時的な
コンテナデータを NVMe に置きます。NVMe 容量以上の値にすると、EBS ボリュームを付けず、
NVMe をワークロードに割り当てます。

On `g6.4xlarge` the NVMe is 600 GB, so `80Gi` is below it. If you change the instance
type, check this value again, because it determines where container storage is placed.

`g6.4xlarge` の NVMe は 600 GB なので `80Gi` はそれより小さい値です。インスタンスタイプを
変更する場合は、この値を再確認してください。コンテナストレージの配置先を決める設定です。

### The API group / API グループ

This resource is `eks.amazonaws.com/v1` `NodeClass`, not `karpenter.k8s.aws/v1`
`EC2NodeClass`. The controller is the one EKS operates. The `NodePool` CRD is
`karpenter.sh/v1` in both cases. Because both controllers own that CRD, this workshop
uses two clusters rather than running both on one.

このリソースは `eks.amazonaws.com/v1` の `NodeClass` で、`karpenter.k8s.aws/v1` の
`EC2NodeClass` ではありません。コントローラは EKS が運用するものです。`NodePool` CRD は
どちらの場合も `karpenter.sh/v1` です。両方のコントローラがこの CRD を所有するため、
本ワークショップは 1 面に同居させず 2 面のクラスターを使います。

---

## What is not available on Auto Mode / Auto Mode で使えないもの

1. There is no `snapshotID` field. `ephemeralStorage` exposes `size`, `iops`,
   `throughput` and `kmsKeyID`. Step 2's mechanism cannot be used here, so a workload
   that needs pre-baked images cannot run on Auto Mode.
   `snapshotID` フィールドがありません。`ephemeralStorage` が公開するのは `size` /
   `iops` / `throughput` / `kmsKeyID` です。ステップ 2 の方式は使えないため、イメージの
   事前焼き込みが必要なワークロードは Auto Mode では動かせません。
2. The SOCI settings are not exposed. Auto Mode uses its own defaults, so a concurrency
   value that suited your layer profile in step 3 cannot be applied here.
   SOCI の設定は露出していません。Auto Mode は独自の既定値を使うため、ステップ 3 で自分の
   レイヤ構成に合っていた並列度をここに適用することはできません。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh
bin/show_config.sh automode   # diffs against step 3
bin/bench.sh automode
```

---

## Verify / 検証

```bash
bin/verify_config.sh automode
```

This confirms that `userData`, `instanceStorePolicy` and `blockDeviceMappings` are
absent from the node class, and that the node's ephemeral-storage capacity corresponds
to local NVMe. Together these indicate that the NVMe configuration came from the
service.

node class に `userData`、`instanceStorePolicy`、`blockDeviceMappings` が無いこと、および
ノードの ephemeral-storage 容量がローカル NVMe に対応することを確認します。この 2 つから、
NVMe の設定がサービス側で行われたことが分かります。

---

## What the figures show / 数字から分かること

- In the reference run this variant reached 164 MB/s, compared with 151 MB/s for step 3,
  with 11 fewer lines of configuration.
  参考計測ではこの variant は 164 MB/s で、ステップ 3 は 151 MB/s でした。設定は 11 行少ない
  状態です。
- The difference between the SOCI and Auto Mode variants is within the run-to-run variation. The
  reference results include two runs of phase 1: the SOCI and Auto Mode variants were both 89 seconds
  in the first run, and 97 and 94 seconds in the second. The ordering between them is
  not consistent, so the timing figures do not show one to be faster than the other.
  The difference in the amount of configuration is consistent.
  soci と automode の差は実行ごとのばらつきの範囲内です。参考計測にはフェーズ 1 の 2 回分が
  含まれており、1 回目は soci と automode がともに 89 秒、2 回目は 97 秒と 94 秒でした。両者の
  順序は一定でないため、時間の数字からどちらが速いとは言えません。設定量の差は一定です。
- This variant runs on a different control plane. The VPC, subnets and instance type are the
  same, so the image pull path is the same, but the comparison with the other three is not
  a direct one.
  この variant はコントロールプレーンが異なります。VPC、サブネット、インスタンスタイプは同じで
  イメージ pull の経路も同じですが、他の 3 つとの比較は直接的なものではありません。

---

[amdocs]: https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html

Next / 次: [Step 5 — cold first pod versus warm scale-out](05-warm.md)
