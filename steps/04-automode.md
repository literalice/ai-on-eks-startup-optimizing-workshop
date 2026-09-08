# Step 4 — Let EKS Auto Mode do it
# ステップ 4 — EKS Auto Mode に任せる

**Goal / 目的:** see how much of step 3 the service does for you, and what you give
up in exchange.

ステップ 3 のうちどれだけをサービスが代行するか、そして代わりに何を諦めるかを見ます。

---

## The configuration change / 設定変更

This step is best understood by **subtraction**. Here is the entire node class
([`13-arm-d-automode.yaml`](../manifests/automode/13-arm-d-automode.yaml)):

このステップは**引き算**で理解するのが早いです。これが node class の全体です。

```yaml
apiVersion: eks.amazonaws.com/v1        # note: NOT karpenter.k8s.aws/v1
kind: NodeClass                         # note: NOT EC2NodeClass
metadata:
  name: arm-d-automode
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

That is all of it. Compare against step 3 and count what is **gone**:

これで全部です。ステップ 3 と比べて**無くなったもの**を数えてください。

| Absent | Yet you still get / それでも得られるもの |
|---|---|
| `instanceStorePolicy: RAID0` | The NVMe is formatted (RAID 0 across multiple drives) and container storage is put on it.<br>NVMe がフォーマットされ（複数本なら RAID 0）、コンテナストレージが載ります。 |
| The whole `userData` TOML block | Parallel image pull and unpack on GPU instances.<br>GPU インスタンスでの並列 pull・展開。 |
| `blockDeviceMappings` | Auto Mode sizes the volumes.<br>Auto Mode がボリュームを決めます。 |
| `amiSelectorTerms` | Auto Mode selects and updates the AMI.<br>Auto Mode が AMI を選定・更新します。 |

**That is step 3's configuration, done by the service.**

**これはステップ 3 の設定を、サービス側が実施しているということです。**

### The one field that needs care / 唯一注意が必要なフィールド

```yaml
  ephemeralStorage:
    size: "80Gi"        # deliberately BELOW the instance's NVMe capacity
```

Per the [Auto Mode docs][amdocs], when `ephemeralStorage.size` is **smaller** than
the instance's local NVMe capacity, Auto Mode attaches a small 20 GiB EBS volume and
puts ephemeral container data on the NVMe. When it **equals or exceeds** NVMe
capacity, Auto Mode skips the small EBS volume and hands the NVMe to your workload
instead — which is not what we want to measure here.

[Auto Mode のドキュメント][amdocs]によると、`ephemeralStorage.size` がインスタンスの
ローカル NVMe 容量**より小さい**場合、Auto Mode は小さな 20 GiB の EBS ボリュームを付け、
一時的なコンテナデータを NVMe に置きます。NVMe 容量**以上**にすると、小さな EBS を
付けずに NVMe をワークロードに渡します。ここで計測したいのは後者ではありません。

> On `g6.4xlarge` the NVMe is 600 GB, so `80Gi` is comfortably below it. **If you
> change the instance type, re-check this number** — it is the one setting in this
> arm that can silently change what you are measuring.
>
> `g6.4xlarge` の NVMe は 600 GB なので `80Gi` は十分下です。**インスタンスタイプを
> 変える場合はこの値を再確認してください。** この arm で唯一、計測対象を黙って変えて
> しまいうる設定です。

### Also note the API group / API グループの違い

`eks.amazonaws.com/v1` `NodeClass`, not `karpenter.k8s.aws/v1` `EC2NodeClass`. A
different controller — the one EKS operates — but the **same** `karpenter.sh/v1`
`NodePool` CRD. That shared CRD is exactly why this workshop uses two clusters:
self-managed Karpenter and Auto Mode both own it, and co-locating them is not worth
the trouble during a workshop.

`eks.amazonaws.com/v1` の `NodeClass` で、`karpenter.k8s.aws/v1` の `EC2NodeClass` では
ありません。コントローラは別（EKS が運用するもの）ですが、`karpenter.sh/v1` の
`NodePool` CRD は**同じ**です。この CRD の共有こそ、本ワークショップがクラスターを
2 面に分けている理由です。self-managed Karpenter と Auto Mode の両方がこれを所有する
ため、ワークショップ中に同居させる価値はありません。

---

## What Auto Mode cannot do / Auto Mode ができないこと

State these before showing the number. They are the reason this is a trade, not a
free win.

数字を見せる前に明示してください。これが「無料の勝ち」ではなく取引である理由です。

1. **There is no `snapshotID`.** `ephemeralStorage` exposes `size`, `iops`,
   `throughput` and `kmsKeyID` only. **Step 2's mechanism is unavailable here.** If
   pre-baked images turn out to be the right answer for a workload, that workload does
   not go on Auto Mode.
   **`snapshotID` がありません。** `ephemeralStorage` は `size` / `iops` /
   `throughput` / `kmsKeyID` のみです。**ステップ 2 の方式はここでは使えません。**
   あるワークロードの答えがイメージ事前焼き込みなら、それは Auto Mode に乗りません。
2. **The SOCI tuning knobs are not exposed.** You get the service's defaults. If you
   found that a particular concurrency mattered for your layer profile in step 3, you
   cannot carry that here.
   **SOCI のチューニング項目は露出していません。** サービスの既定値になります。
   ステップ 3 で自分のレイヤ構成に特定の並列度が効くと分かっても、ここには持ち込めません。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh
bin/show_config.sh arm-d-automode   # diffs against step 3 -- watch the deletions
bin/bench.sh arm-d-automode
```

**Show the diff before the number.** The configuration difference is the lesson; the
timing is the confirmation.

**数字より先に差分を見せてください。** 教訓は設定量の差で、時間はその裏付けです。

---

## Verify / 検証

```bash
bin/verify_config.sh arm-d-automode
```

It asserts that `userData`, `instanceStorePolicy` and `blockDeviceMappings` are all
**absent** from the node class, *and* that the node's ephemeral-storage capacity
still reflects local NVMe. Together those prove the NVMe setup came from the service
rather than from you.

node class に `userData` / `instanceStorePolicy` / `blockDeviceMappings` が
**すべて無い**こと、かつノードの ephemeral-storage 容量がローカル NVMe を反映して
いることを確認します。この 2 つで、NVMe の設定が自分ではなくサービス由来であることが
証明されます。

---

## What you should conclude / ここで得る結論

- **Auto Mode reached step 3's result with none of step 3's configuration.** In the
  reference run: 164 MB/s versus 151 MB/s, with eleven fewer lines of YAML.
  **Auto Mode はステップ 3 の設定ゼロでステップ 3 の結果に到達しました。** 参考計測では
  164 対 151 MB/s、YAML は 11 行少ない状態で。
- **Do not claim Auto Mode beats arm C.** Read the difference as within noise. The
  reference results were measured twice and the C-versus-D ordering was **not stable
  between runs** — 89s/89s on one run, 97s/94s on another. The *configuration*
  difference is not noise; the *timing* difference is.
  **Auto Mode が arm C に勝つとは主張しないでください。** 差はノイズ範囲と読むべきです。
  参考計測は 2 回実施しており、C と D の優劣は**実行間で安定しませんでした**（1 回目は
  89/89 秒、2 回目は 97/94 秒）。ノイズでないのは**設定量**の差で、**時間**の差はノイズです。
- **This arm is on a different control plane.** Same VPC, subnets and instance type,
  so the pull path is identical — but read it as indicative rather than
  like-for-like.
  **この arm はコントロールプレーンが別です。** VPC・サブネット・インスタンスタイプは
  同一なので pull 経路は同じですが、like-for-like ではなく目安として読んでください。

---

[amdocs]: https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html

Next / 次: [Step 5 — cold first pod versus warm scale-out](05-warm.md)
