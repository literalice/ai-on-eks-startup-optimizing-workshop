# Step 2 — Pre-bake the image into an EBS snapshot

**English** | [日本語](#japanese)

Goal: remove the image pull, and measure what maintaining that arrangement costs.

---

## How it works

Bottlerocket stores container images on its data volume. If that volume is restored from a
snapshot that already contains the image layers, containerd finds them on disk and does
not contact the registry.

---

## Part A — build the snapshot

Use a dedicated builder instance. This is the method to take back to your own environment,
so it is the one the workshop runs.

First, which image. The snapshot has to hold the image the pods will actually run: kubelet
compares the reference, so a different tag means a full pull and the figures read as the
mechanism having no effect. Ask the cluster rather than recalling it:

```bash
bin/gpu_images.py
```

```
==> images running in br-startup-karpenter, from containers requesting a GPU resource

    pods  image                                                                                     namespaces
       1  763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2  bench

==> one candidate. To pre-bake it:
      IMAGE="763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2" snapshot/build-snapshot.sh
```

It lists the images of containers that request a GPU resource. If nothing does, it falls back to
the pods running on nodes that advertise GPU capacity, and says which of the two produced the
list.

Then build it. With no `IMAGE`, the script runs the same discovery and prints what it chose:

```bash
snapshot/build-snapshot.sh                                  # takes 10-20 minutes
IMAGE="<one of the images above>" snapshot/build-snapshot.sh # or name it
```

```
==> which image to bake
    763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2
    from the only image the cluster's GPU pods run
```

It resolves `IMAGE`, then the cluster, then `WORKLOAD_IMAGE` in `config.env`. The cluster comes
before `config.env` because `config.env` holds this workshop's image, which is the wrong answer
on a cluster that was running something before the workshop arrived. If the cluster runs several
GPU images it prints them and stops, rather than picking one.

The script wraps [`aws-samples/bottlerocket-images-cache`][cache], which:

1. launches a Bottlerocket instance from the AMI you name, on a GPU instance type
2. stops `kubelet`, then removes every image already on the volume
3. pulls the images you listed
4. **stops the instance**, then snapshots its `/dev/xvdb`
5. terminates the instance and writes the snapshot ID to an SSM parameter

[cache]: https://github.com/aws-samples/bottlerocket-images-cache

Steps 2 and 4 are the reason to prefer this in production. The snapshot is taken from a
stopped instance, so it is filesystem-consistent, and it holds only the images you asked
for. The volume size is a parameter (`SNAPSHOT_SIZE`), so the snapshot is as large as the
images need rather than as large as some node's data volume. And it runs from an image tag
with no cluster involved, which is what a pipeline triggered by an image build needs.

> The builder instance type must have a GPU, because the AMI is the NVIDIA variant. On a
> GPU-less instance the NVIDIA variant does not finish booting, the SSM agent never starts,
> and the wrapped script waits forever — see
> [step 1](01-baseline.md#why-the-alias-rather-than-a-pinned-nvidia-ami) for the boot
> sequence. The script checks this before launching anything.

### The other two ways, and when they win

There are three places the snapshot can come from. The workshop walks through the first one
only; the other two are listed so you can tell whether your environment changes the answer.

| Source | Consistent | Contents | Volume size | Needs |
|---|---|---|---|---|
| **Dedicated builder instance** (`build-snapshot.sh`) | Yes — instance stopped first | Only the images you name | `SNAPSHOT_SIZE` | An instance with an SSM-capable role; no cluster |
| **A build-only node in the cluster** (`snapshot-from-node.sh` with `SOURCE_NODEPOOL`) | No — volume is mounted | Your images plus kubelet state and DaemonSet images | The node class's `blockDeviceMappings` | A node pool you taint so nothing else lands there |
| **An existing workload node** (`snapshot-from-node.sh`) | No — volume is mounted | Whatever that node has pulled | Inherited from the node | Nothing |

The middle row is the one worth knowing about, because it wins on a case the builder does
not cover: **images that need pull credentials the cluster already holds.** The builder pulls
with its instance role, so ECR works and a private third-party registry needing an
`imagePullSecret` does not. A node in the cluster pulls the way your workloads do. It also
suits accounts where launching an ad-hoc instance with its own IAM role outside the cluster
is not permitted, or where SSM is unreachable from the subnets the snapshot must live in.

It needs no separate script. Create a node pool for building, taint it so only the build pod
tolerates it, run a pod that pulls the images, then point the existing script at that pool:

```bash
SOURCE_NODEPOOL=snapshot-builder snapshot/snapshot-from-node.sh
```

What neither of the lower two rows gives you is a consistent snapshot. The volume is mounted
and being written, so the result is crash-consistent. For a read-only image cache a partially
written layer is discarded and re-pulled, so the effect is limited — but that is a property of
this workload, not a general guarantee. You cannot fix it by stopping the instance either,
because Karpenter would see the node as unhealthy and replace it.

The bottom row is for a quick one-off. In this workshop, step 1 already leaves such a node:

```bash
bin/bench.sh baseline                # leaves such a node; do not reset afterwards
snapshot/snapshot-from-node.sh       # takes 3-5 minutes
```

> For either of the lower two rows the node must not be a `soci` node. `soci` sets
> `instanceStorePolicy`, which moves container storage to local NVMe, so its EBS data volume
> is empty. Snapshotting it produces an empty snapshot, and `snapshot` then pulls the image
> as normal.

---

## Part B — the configuration change

One field is added. Compare
[`11-snapshot.yaml`](../manifests/karpenter/11-snapshot.yaml) with step 1's node class:

```yaml
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi                          # must be >= the snapshot size
        volumeType: gp3
        throughput: 1000
        iops: 16000
        snapshotID: "snap-0123456789abcdef0"       # the added field
        deleteOnTermination: true
```

`bin/prep.sh` substitutes the ID from `results/snapshot-id.txt`, so it does not need to be
entered manually.

| Field | Reason |
|---|---|
| `snapshotID` on `/dev/xvdb` | Restores the data volume from the snapshot, so the layers are on disk before kubelet requests the image. |
| `volumeSize` at least the snapshot size | EC2 rejects a volume smaller than the snapshot it is restored from. |
| `encrypted` is not set here | A volume restored from a snapshot inherits the snapshot's encryption. The snapshot was taken from step 1's encrypted volume, so this volume is encrypted. Setting the field as well is permitted and has no additional effect. |

### What is not set

`instanceStorePolicy` is not set in this variant. `snapshot` requires the images to be on
the volume restored from the snapshot. Setting `instanceStorePolicy` (step 3) moves
container storage to local NVMe, and the restored volume is then unused. The snapshot
would still be built and maintained, without affecting the pull.

---

## Apply and run

```bash
bin/prep.sh                     # reads the snapshot ID
bin/show_config.sh snapshot     # shows the one-line difference
bin/bench.sh snapshot
```

The breakdown should contain no image pull stage.

---

## Verify

```bash
bin/verify_config.sh snapshot
```

Two checks:

1. The volume was restored from the expected snapshot. The script reads the instance's
   `/dev/xvdb` volume and compares its `SnapshotId` with `results/snapshot-id.txt`.
2. kubelet did not pull the image. The script looks for the event
   `Container image "..." already present on machine`.

---

## What the figures show

- Start-to-Ready was 50 seconds in the reference run, compared with 125 seconds for step 1.
- The snapshot build time is not included in that figure. It took several minutes, and it
  has to be repeated whenever the image changes. That recurring cost is the main factor in
  deciding whether to use this mechanism.
- This mechanism is not available on EKS Auto Mode (step 4).

### Common failures

| Symptom | Cause |
|---|---|
| Pod stays Pending; the node class is missing | `results/snapshot-id.txt` does not exist, so `prep.sh` skipped this variant |
| The node fails to launch | `volumeSize` is smaller than the snapshot |
| The image is pulled anyway | The snapshot was taken from an NVMe variant, so it is empty; or it contains a different image than the one being tested |

---

Next: [Step 3 — local NVMe and the SOCI snapshotter](03-soci.md)

<br>

---
---

<a id="japanese"></a>

# ステップ 2 — イメージを EBS スナップショットに焼き込む

[English](#step-2--pre-bake-the-image-into-an-ebs-snapshot) | **日本語**

目的: イメージ pull を無くし、その方式の維持コストを把握します。

---

## 仕組み

Bottlerocket はコンテナイメージをデータボリュームに保存します。そのボリュームを、イメージ層
を含むスナップショットから復元すると、containerd はディスク上でそれを見つけ、レジストリには
接続しません。

---

## パート A — スナップショットを作る

専用のビルダーインスタンスを使います。自身の環境に持ち帰るのはこの方式なので、
ワークショップでもこちらを実行します。

まずどのイメージかを決めます。スナップショットには、Pod が実際に動かすイメージが入っていなければ
なりません。kubelet は参照を比較するため、タグが違えば pull が全量発生し、数字はこの機構に効果が
ないように見えます。記憶に頼らず、クラスターに尋ねます。

```bash
bin/gpu_images.py
```

```
==> images running in br-startup-karpenter, from containers requesting a GPU resource

    pods  image                                                                                     namespaces
       1  763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2  bench

==> one candidate. To pre-bake it:
      IMAGE="763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2" snapshot/build-snapshot.sh
```

GPU リソースを要求しているコンテナのイメージを列挙します。要求しているものが無い場合は、GPU 容量を
広告しているノード上で動いている Pod にフォールバックし、どちらで列挙したかを出力します。

そのうえで作成します。`IMAGE` を渡さない場合、スクリプトは同じ探索を行い、何を選んだかを出力します。

```bash
snapshot/build-snapshot.sh                                    # 10〜20 分
IMAGE="<上記のいずれか>" snapshot/build-snapshot.sh            # 直接指定する場合
```

```
==> which image to bake
    763104351884.dkr.ecr.us-west-2.amazonaws.com/vllm:0.22.0-gpu-py312-cu130-ubuntu22.04-ec2
    from the only image the cluster's GPU pods run
```

解決順は `IMAGE`、クラスター、`config.env` の `WORKLOAD_IMAGE` です。クラスターが `config.env` より
先なのは、`config.env` にはこのワークショップのイメージが入っており、ワークショップ以前から何かが
動いていたクラスターでは正しい答えにならないためです。GPU イメージが複数ある場合は、一覧を出して
停止します。勝手に 1 つを選ぶことはしません。

このスクリプトは [`aws-samples/bottlerocket-images-cache`][cache] のラッパーで、次を行います。

1. 指定した AMI で Bottlerocket インスタンスを GPU インスタンスタイプ上に起動する
2. `kubelet` を停止し、ボリューム上の既存イメージをすべて削除する
3. 指定したイメージを pull する
4. **インスタンスを停止し**、その `/dev/xvdb` をスナップショットする
5. インスタンスを終了し、スナップショット ID を SSM パラメータに書き込む

[cache]: https://github.com/aws-samples/bottlerocket-images-cache

本番でこちらを選ぶ理由は 2 と 4 です。停止したインスタンスから取得するためファイルシステムと
して整合しており、内容は指定したイメージだけです。ボリュームサイズはパラメータ
（`SNAPSHOT_SIZE`）なので、どこかのノードのデータボリューム容量ではなく、イメージに必要な
サイズになります。さらに、クラスターを介さずイメージタグから実行できます。これはイメージ
ビルドを起点とするパイプラインが必要とする性質です。

> ビルダーのインスタンスタイプには GPU が必要です。AMI が NVIDIA variant のためです。GPU の
> 無いインスタンスでは NVIDIA variant の boot が完了せず、SSM agent が起動しないため、ラップ
> 対象のスクリプトは待ち続けます。boot シーケンスは
> [ステップ 1](01-baseline.md#nvidia-ami-を固定せず-alias-を使う理由) にあります。本スクリプトは
> インスタンス起動前にこれを検査します。

### 残る 2 つの方法と、それが有利になる条件

スナップショットの取得元は 3 通りあります。ワークショップで手順を追うのは 1 つ目だけです。
残りは、自身の環境で答えが変わるかどうかを判断できるように併記します。

| 取得元 | 整合性 | 内容 | ボリュームサイズ | 必要なもの |
|---|---|---|---|---|
| **専用ビルダーインスタンス**（`build-snapshot.sh`） | あり（先にインスタンスを停止） | 指定したイメージだけ | `SNAPSHOT_SIZE` | SSM を使えるロールを持つインスタンス。クラスターは不要 |
| **クラスター内のビルド専用ノード**（`snapshot-from-node.sh` + `SOURCE_NODEPOOL`） | なし（マウント中） | 指定イメージ + kubelet state + DaemonSet のイメージ | node class の `blockDeviceMappings` | 他が載らないよう taint した node pool |
| **稼働中のワークロードノード**（`snapshot-from-node.sh`） | なし（マウント中） | そのノードが pull したもの全部 | ノードから継承 | なし |

知っておく価値があるのは中段です。ビルダーがカバーしない条件で有利になります。
**クラスターが既に保持している認証情報を必要とするイメージ**です。ビルダーはインスタンス
ロールで pull するため ECR は動きますが、`imagePullSecret` を要するサードパーティの
プライベートレジストリは動きません。クラスター内のノードなら、ワークロードと同じ経路で
pull します。クラスター外で独自 IAM ロールを持つ一時インスタンスを起動できないアカウントや、
スナップショットを置くべきサブネットから SSM に到達できない場合にも適します。

専用のスクリプトは不要です。ビルド用の node pool を作り、ビルド Pod だけが tolerate する
taint を付け、イメージを pull する Pod を動かしたうえで、既存のスクリプトをその pool に
向けます。

```bash
SOURCE_NODEPOOL=snapshot-builder snapshot/snapshot-from-node.sh
```

下 2 段のどちらでも得られないのが、整合したスナップショットです。ボリュームはマウントされ
書き込みが続いているため、結果はクラッシュ整合になります。読み取り専用のイメージキャッシュ
であれば書き込み途中の層は破棄されて再 pull されるので影響は限定的ですが、これはこの
ワークロードの性質であり一般的な保証ではありません。インスタンスを停止して回避することも
できません。Karpenter がノードを異常と判断して置き換えるためです。

最下段は一回限りの用途向けです。本ワークショップではステップ 1 がその状態のノードを残します。

```bash
bin/bench.sh baseline                # この状態のノードが残る。以降 reset しない
snapshot/snapshot-from-node.sh       # 3〜5 分
```

> 下 2 段のいずれでも、対象は `soci` のノードであってはいけません。`soci` は
> `instanceStorePolicy` を設定してコンテナストレージをローカル NVMe に移すため、EBS データ
> ボリュームは空です。これをスナップショットすると空のスナップショットができ、`snapshot` は
> 通常どおり pull します。

---

## パート B — 設定変更

追加するフィールドは 1 つです。
[`11-snapshot.yaml`](../manifests/karpenter/11-snapshot.yaml) をステップ 1 の node class と
比較してください。

```yaml
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi                          # スナップショットサイズ以上が必要
        volumeType: gp3
        throughput: 1000
        iops: 16000
        snapshotID: "snap-0123456789abcdef0"       # 追加するフィールド
        deleteOnTermination: true
```

`bin/prep.sh` が `results/snapshot-id.txt` から ID を差し込むため、手入力は不要です。

| フィールド | 理由 |
|---|---|
| `/dev/xvdb` の `snapshotID` | データボリュームをスナップショットから復元します。kubelet がイメージを要求する前に層がディスク上にあります。 |
| `volumeSize` はスナップショットサイズ以上 | EC2 は復元元のスナップショットより小さいボリュームを拒否します。 |
| `encrypted` はここでは設定しない | スナップショットから復元したボリュームは、スナップショットの暗号化を継承します。ステップ 1 の暗号化ボリュームから取得しているため、このボリュームは暗号化されています。フィールドを併記しても構いませんが、追加の効果はありません。 |

### 設定しないもの

この variant では `instanceStorePolicy` を設定しません。`snapshot` はスナップショットから
復元したボリューム上にイメージがあることを前提としています。`instanceStorePolicy`
（ステップ 3）を設定するとコンテナストレージはローカル NVMe に移り、復元したボリュームは
使われません。スナップショットの作成と維持は続きますが、pull には影響しなくなります。

---

## 適用と実行

```bash
bin/prep.sh                     # スナップショット ID を読む
bin/show_config.sh snapshot     # 1 行の差分を表示
bin/bench.sh snapshot
```

内訳にイメージ pull の段階が現れないはずです。

---

## 検証

```bash
bin/verify_config.sh snapshot
```

確認は 2 つです。

1. ボリュームが想定のスナップショットから復元されたか。インスタンスの `/dev/xvdb` の
   `SnapshotId` を `results/snapshot-id.txt` と比較します。
2. kubelet が pull しなかったか。`Container image "..." already present on machine`
   イベントを確認します。

---

## 数字から分かること

- start-to-Ready は参考計測で 50 秒でした。ステップ 1 は 125 秒です。
- スナップショットの作成時間はこの数字に含まれていません。数分かかり、イメージが変わる
  たびに繰り返す必要があります。この継続的なコストが、この方式を採用するかの主な判断材料に
  なります。
- この方式は EKS Auto Mode では使えません（ステップ 4）。

### よくある失敗

| 症状 | 原因 |
|---|---|
| Pod が Pending のまま、node class が無い | `results/snapshot-id.txt` が無く、`prep.sh` がこの variant を飛ばした |
| ノードが起動しない | `volumeSize` がスナップショットより小さい |
| 結果的に pull される | NVMe の variant から取得したため空、またはテスト対象と別のイメージが入っている |

---

次: [ステップ 3 — ローカル NVMe と SOCI snapshotter](03-soci.md)
