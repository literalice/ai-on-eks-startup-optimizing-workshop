# Step 1 — Baseline: measure before changing anything

**English** | [日本語](#japanese)

Goal: determine how the startup time divides into stages, so that the later steps have
figures to be compared against.

---

## What you configure

Nothing. This variant runs Bottlerocket with its default settings.

The node class is worth reading because the later steps modify it. From
[`manifests/karpenter/10-baseline.yaml`](../manifests/karpenter/10-baseline.yaml):

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: baseline
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest       # resolves the -nvidia variant for GPU types
  role: "<node IAM role>"
  blockDeviceMappings:
    - deviceName: /dev/xvda            # Bottlerocket control volume (the OS)
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb            # Bottlerocket data volume
      ebs:                             # container images are stored here
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
```

| Field | Reason |
|---|---|
| `alias: bottlerocket@latest` | Karpenter resolves the `aws-k8s-<version>-nvidia` variant for GPU instance types. That AMI contains the NVIDIA driver, the container toolkit and the Kubernetes device plugin, so no device plugin needs to be deployed. |
| `/dev/xvda` | Bottlerocket's control volume, which holds the OS. It is small because the OS is immutable. |
| `/dev/xvdb` | The data volume. Container images and logs are stored here. The later steps change how this volume is used. |
| `iops` and `throughput` at the gp3 maximum | So that a difference between variants is not caused by volume performance. Keep these values the same in every variant. |

---

## Apply and run

```bash
bin/prep.sh                    # applies the node class and node pool
bin/show_config.sh baseline
bin/bench.sh baseline
```

Each step's figure prints as it completes. The image pull stage is the one that takes
noticeably longer than the others:

```
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
```

---

## Verify

```bash
bin/verify_config.sh baseline
```

This confirms that `userData`, `instanceStorePolicy` and `snapshotID` are all absent, and
that the node's ephemeral-storage capacity corresponds to the EBS data volume rather than
local NVMe. With those confirmed, any improvement in a later variant can be attributed to
what that variant added.

---

## What the figures show

- Provisioning — Karpenter's decision, the EC2 launch, boot, registration and node
  Ready — took 29 seconds in the reference run.
- The image pull took 96 seconds, which is longer than all the other stages combined.
- The throughput figure was 98 MB/s. The instance supports up to 25 Gbps, so the pull was
  not limited by network bandwidth. Layers are downloaded and unpacked one at a time,
  which steps 2 and 3 address in different ways.

Run this step even if you are short of time. Without baseline figures the later
measurements have nothing to be compared against.

---

Next: [Step 2 — pre-bake the image into an EBS snapshot](02-snapshot.md)

<br>

---
---

<a id="japanese"></a>

# ステップ 1 — ベースライン：何も変えずに計測する

[English](#step-1--baseline-measure-before-changing-anything) | **日本語**

目的: 起動時間が段階ごとにどう分かれるかを確認し、以降のステップの比較対象となる数字を
得ます。

---

## 設定するもの

何も設定しません。この variant は Bottlerocket を既定設定で動かします。

node class は以降のステップで変更するため、内容を確認しておきます。
[`manifests/karpenter/10-baseline.yaml`](../manifests/karpenter/10-baseline.yaml) より:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: baseline
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest       # GPU 型では -nvidia variant が解決される
  role: "<node IAM role>"
  blockDeviceMappings:
    - deviceName: /dev/xvda            # Bottlerocket の control ボリューム（OS）
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb            # Bottlerocket のデータボリューム
      ebs:                             # コンテナイメージはここに保存される
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
```

| フィールド | 理由 |
|---|---|
| `alias: bottlerocket@latest` | GPU インスタンスタイプでは Karpenter が `aws-k8s-<version>-nvidia` variant を解決します。この AMI にはドライバ、container toolkit、Kubernetes device plugin が含まれるため、device plugin のデプロイは不要です。 |
| `/dev/xvda` | OS を保持する control ボリューム。OS がイミュータブルなため小容量です。 |
| `/dev/xvdb` | データボリューム。コンテナイメージとログが保存されます。以降のステップはこのボリュームの使い方を変更します。 |
| `iops` と `throughput` を gp3 の最大値に | variant 間の差がボリューム性能に起因しないようにするためです。全 variant で同じ値にしてください。 |

---

## 適用と実行

```bash
bin/prep.sh                    # node class と node pool を適用
bin/show_config.sh baseline
bin/bench.sh baseline
```

各段階の数字は完了時に出力されます。イメージ pull の段階が他より明らかに長くなります。

```
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
```

---

## 検証

```bash
bin/verify_config.sh baseline
```

`userData`、`instanceStorePolicy`、`snapshotID` がいずれも無いこと、およびノードの
ephemeral-storage 容量がローカル NVMe ではなく EBS データボリュームに対応することを
確認します。これらを確認しておくと、以降の variant の改善をその variant が追加した内容に
帰属できます。

---

## 数字から分かること

- プロビジョニング（Karpenter の判断、EC2 起動、ブート、登録、ノード Ready）は参考計測で
  29 秒でした。
- イメージ pull は 96 秒で、他の全段階の合計より長くなっています。
- スループットは 98 MB/s でした。インスタンスは最大 25 Gbps に対応するため、pull は
  ネットワーク帯域で律速されていません。レイヤを 1 つずつダウンロード・展開しているためで、
  ステップ 2 と 3 が別々の方法でこれに対処します。

時間が限られていてもこのステップは実行してください。ベースラインの数字が無いと、以降の
計測に比較対象がありません。

---

次: [ステップ 2 — イメージを EBS スナップショットに焼き込む](02-snapshot.md)
