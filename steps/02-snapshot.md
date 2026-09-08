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

The snapshot has to be taken from a node that has already pulled the image. Step 1 leaves
such a node, so do not run `reset.sh` before this:

```bash
bin/bench.sh baseline                # run again if you have already reset
snapshot/snapshot-from-node.sh       # takes 3-5 minutes
```

The script does the following:

1. finds the node for the `baseline` node pool
2. locates that instance's `/dev/xvdb` volume
3. calls `aws ec2 create-snapshot` on the volume and waits for it to complete
4. writes the snapshot ID to `results/snapshot-id.txt`

> The node must be a `baseline` node. `soci` sets `instanceStorePolicy`, which moves
> container storage to local NVMe, so a `soci` node's EBS data volume is empty.
> Snapshotting it produces an empty snapshot, and `snapshot` then pulls the image as
> normal.

> `snapshot/build-snapshot.sh` did not work in our environment. It wraps
> `aws-samples/bottlerocket-images-cache`, which launches its own instance and controls it
> through SSM Run Command. On the EKS-optimized Bottlerocket NVIDIA AMI the instance did
> not register with SSM, and the script has no timeout, so it stopped at "Launching SSM".
> It is kept for reference.

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

スナップショットは、イメージを pull 済みのノードから取得する必要があります。ステップ 1 の
ノードがその状態なので、その前に `reset.sh` を実行しないでください。

```bash
bin/bench.sh baseline                # 既に reset した場合は再実行
snapshot/snapshot-from-node.sh       # 3〜5 分
```

スクリプトの動作:

1. `baseline` node pool のノードを見つける
2. そのインスタンスの `/dev/xvdb` ボリュームを特定する
3. そのボリュームに対して `aws ec2 create-snapshot` を実行し、完了まで待つ
4. スナップショット ID を `results/snapshot-id.txt` に書き込む

> 対象は `baseline` のノードである必要があります。`soci` は `instanceStorePolicy` を
> 設定してコンテナストレージをローカル NVMe に移すため、`soci` ノードの EBS データ
> ボリュームは空です。これをスナップショットすると空のスナップショットができ、`snapshot` は
> 通常どおり pull します。

> `snapshot/build-snapshot.sh` は当環境では動作しませんでした。
> `aws-samples/bottlerocket-images-cache` のラッパーで、専用インスタンスを起動して SSM Run
> Command で操作します。EKS 最適化 Bottlerocket NVIDIA AMI ではインスタンスが SSM に
> 登録されず、スクリプトにタイムアウトが無いため "Launching SSM" で停止しました。参考として
> 残しています。

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
