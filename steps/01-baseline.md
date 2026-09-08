# Step 1 — Baseline: measure before changing anything
# ステップ 1 — ベースライン：何も変えずに計測する

**Goal / 目的:** find out where the time actually goes, so the later steps have
something to be measured against.

時間が実際どこに消えているかを掴み、以降のステップの比較対象を作ります。

---

## What you configure / 設定するもの

**Nothing.** That is the point of this step. This is Bottlerocket exactly as it
ships.

**何も設定しません。** それがこのステップの主旨です。素の Bottlerocket です。

The only thing worth looking at is the shape of the node class, because every later
step is a change to it. Open
[`manifests/karpenter/10-arm-a-baseline.yaml`](../manifests/karpenter/10-arm-a-baseline.yaml):

見ておく価値があるのは node class の形だけです。以降のステップはすべてこれへの変更です。

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: arm-a-baseline
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest       # resolves the -nvidia variant for GPU types
  role: "<node IAM role>"
  blockDeviceMappings:
    - deviceName: /dev/xvda            # Bottlerocket CONTROL volume (the OS)
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb            # Bottlerocket DATA volume
      ebs:                             # <-- container images live HERE
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
```

| Field | Why it is here / なぜここにあるか |
|---|---|
| `alias: bottlerocket@latest` | Karpenter resolves the `aws-k8s-<version>-nvidia` variant automatically for GPU instance types. The NVIDIA driver, container toolkit **and Kubernetes device plugin** are already in that AMI — you do not deploy a device plugin.<br>GPU インスタンスタイプでは Karpenter が `-nvidia` variant を自動選択します。ドライバ・container toolkit・**Kubernetes device plugin** が AMI に含まれるため、device plugin のデプロイは不要です。 |
| `/dev/xvda` | Bottlerocket's control volume — the immutable OS. Small on purpose.<br>Bottlerocket の control ボリューム（イミュータブルな OS）。意図的に小容量。 |
| `/dev/xvdb` | **The data volume. Container images and logs go here.** Every later step changes how this volume is used.<br>**データボリューム。コンテナイメージとログがここに入ります。** 以降のステップはこのボリュームの使い方を変えます。 |
| `iops`/`throughput` at gp3 maximum | So that later comparisons cannot be explained by a slow volume. Keep these identical across arms.<br>後の比較を「ボリュームが遅かった」で説明できないようにするため。arm 間で必ず同一に保ちます。 |

---

## Apply and run / 適用と実行

```bash
bin/prep.sh                    # applies the node class and node pool
bin/show_config.sh arm-a-baseline
bin/bench.sh arm-a-baseline
```

Each step's number prints as it completes. Watch for the line that stalls:

各段階の数字はその都度出ます。止まる行に注目してください。

```
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s   <-- stalls here
```

---

## Verify / 検証

```bash
bin/verify_config.sh arm-a-baseline
```

This confirms `userData`, `instanceStorePolicy` and `snapshotID` are all **absent**,
and that the node reports an ephemeral-storage capacity matching the **EBS** data
volume rather than local NVMe. That matters: it makes every later arm's gain
attributable to what that arm added.

`userData` / `instanceStorePolicy` / `snapshotID` がすべて**無い**こと、そしてノードが
報告する ephemeral-storage 容量がローカル NVMe ではなく **EBS** データボリューム相当で
あることを確認します。これにより、以降の arm の改善をその arm が追加したものに帰属
できます。

---

## What you should conclude / ここで得る結論

- **Provisioning is not the problem.** Karpenter's decision, the EC2 launch, boot,
  registration and node Ready together are well under a minute.
  **プロビジョニングは問題ではありません。** Karpenter の判断・EC2 起動・ブート・登録・
  ノード Ready の合計は 1 分未満です。
- **The image pull dominates.** In the reference run it was ~3× everything else
  combined.
  **イメージ pull が支配的です。** 参考計測では他の合計の約 3 倍でした。
- **Read the throughput line.** If it is far below what the instance's network can
  do, layers are being unpacked one at a time — which is what steps 2 and 3 attack.
  **スループットの行を読んでください。** インスタンスの帯域を大きく下回っていれば、
  レイヤを 1 つずつ展開しているということで、ステップ 2 と 3 がそこを攻めます。

> **Do not skip this step to save time.** Without a baseline the later numbers are
> unanchored, and "97 seconds" means nothing on its own.
>
> **時間節約のためにこのステップを飛ばさないでください。** ベースラインが無いと以降の
> 数字は基準を失い、「97 秒」だけでは何も意味しません。

---

Next / 次: [Step 2 — pre-bake the image into an EBS snapshot](02-snapshot.md)
