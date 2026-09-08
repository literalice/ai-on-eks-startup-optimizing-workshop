# Step 2 — Pre-bake the image into an EBS snapshot
# ステップ 2 — イメージを EBS スナップショットに焼き込む

**Goal / 目的:** remove the image pull, and measure what maintaining that arrangement
costs.

イメージ pull を無くし、その方式の維持コストを把握します。

---

## How it works / 仕組み

Bottlerocket stores container images on its data volume. If that volume is restored
from a snapshot that already contains the image layers, containerd finds them on disk
and does not contact the registry.

Bottlerocket はコンテナイメージをデータボリュームに保存します。そのボリュームを、
イメージ層を含むスナップショットから復元すると、containerd はディスク上でそれを見つけ、
レジストリには接続しません。

---

## Part A — build the snapshot / スナップショットを作る

The snapshot has to be taken from a node that has already pulled the image. Step 1
leaves such a node, so do not run `reset.sh` before this:

スナップショットは、イメージを pull 済みのノードから取得する必要があります。ステップ 1 の
ノードがその状態なので、その前に `reset.sh` を実行しないでください。

```bash
bin/bench.sh arm-a-baseline          # run again if you have already reset
snapshot/snapshot-from-node.sh       # takes 3-5 minutes
```

The script does the following / スクリプトの動作:

1. finds the node for the `arm-a-baseline` node pool
   `arm-a-baseline` node pool のノードを見つける
2. locates that instance's `/dev/xvdb` volume
   そのインスタンスの `/dev/xvdb` ボリュームを特定する
3. calls `aws ec2 create-snapshot` on the volume and waits for it to complete
   そのボリュームに対して `create-snapshot` を実行し、完了まで待つ
4. writes the snapshot ID to `results/snapshot-id.txt`
   スナップショット ID を `results/snapshot-id.txt` に書き込む

> The node must be an arm A node. Arm C sets `instanceStorePolicy`, which moves
> container storage to local NVMe, so an arm C node's EBS data volume is empty.
> Snapshotting it produces an empty snapshot, and arm B then pulls the image as
> normal.
>
> 対象は arm A のノードである必要があります。arm C は `instanceStorePolicy` を設定して
> コンテナストレージをローカル NVMe に移すため、arm C ノードの EBS データボリュームは
> 空です。これをスナップショットすると空のスナップショットができ、arm B は通常どおり
> pull します。

> `snapshot/build-snapshot.sh` did not work in our environment. It wraps
> `aws-samples/bottlerocket-images-cache`, which launches its own instance and controls
> it through SSM Run Command. On the EKS-optimized Bottlerocket NVIDIA AMI the instance
> did not register with SSM, and the script has no timeout, so it stopped at
> "Launching SSM". It is kept for reference.
>
> `snapshot/build-snapshot.sh` は当環境では動作しませんでした。
> `aws-samples/bottlerocket-images-cache` のラッパーで、専用インスタンスを起動して
> SSM Run Command で操作します。EKS 最適化 Bottlerocket NVIDIA AMI ではインスタンスが
> SSM に登録されず、スクリプトにタイムアウトが無いため "Launching SSM" で停止しました。
> 参考として残しています。

---

## Part B — the configuration change / 設定変更

One field is added. Compare
[`11-arm-b-snapshot.yaml`](../manifests/karpenter/11-arm-b-snapshot.yaml) with step 1's
node class:

追加するフィールドは 1 つです。

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

`bin/prep.sh` substitutes the ID from `results/snapshot-id.txt`, so it does not need to
be entered manually.

`bin/prep.sh` が `results/snapshot-id.txt` から ID を差し込むため、手入力は不要です。

| Field | Reason / 理由 |
|---|---|
| `snapshotID` on `/dev/xvdb` | Restores the data volume from the snapshot, so the layers are on disk before kubelet requests the image.<br>データボリュームをスナップショットから復元します。kubelet がイメージを要求する前に層がディスク上にあります。 |
| `volumeSize` at least the snapshot size | EC2 rejects a volume smaller than the snapshot it is restored from.<br>EC2 は復元元のスナップショットより小さいボリュームを拒否します。 |
| `encrypted` is not set here | A volume restored from a snapshot inherits the snapshot's encryption. The snapshot was taken from step 1's encrypted volume, so this volume is encrypted. Setting the field as well is permitted and has no additional effect.<br>スナップショットから復元したボリュームは、スナップショットの暗号化を継承します。ステップ 1 の暗号化ボリュームから取得しているため、このボリュームは暗号化されています。フィールドを併記しても構いませんが、追加の効果はありません。 |

### What is not set / 設定しないもの

`instanceStorePolicy` is not set in this arm. Arm B requires the images to be on the
volume restored from the snapshot. Setting `instanceStorePolicy` (step 3) moves
container storage to local NVMe, and the restored volume is then unused. The snapshot
would still be built and maintained, without affecting the pull.

この arm では `instanceStorePolicy` を設定しません。arm B はスナップショットから復元した
ボリューム上にイメージがあることを前提としています。`instanceStorePolicy`（ステップ 3）を
設定するとコンテナストレージはローカル NVMe に移り、復元したボリュームは使われません。
スナップショットの作成と維持は続きますが、pull には影響しなくなります。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh                       # reads the snapshot ID
bin/show_config.sh arm-b-snapshot # shows the one-line difference
bin/bench.sh arm-b-snapshot
```

The breakdown should contain no image pull stage.

内訳にイメージ pull の段階が現れないはずです。

---

## Verify / 検証

```bash
bin/verify_config.sh arm-b-snapshot
```

Two checks / 確認は 2 つ:

1. The volume was restored from the expected snapshot. The script reads the instance's
   `/dev/xvdb` volume and compares its `SnapshotId` with `results/snapshot-id.txt`.
   ボリュームが想定のスナップショットから復元されたか。インスタンスの `/dev/xvdb` の
   `SnapshotId` を `results/snapshot-id.txt` と比較します。
2. kubelet did not pull the image. The script looks for the event
   `Container image "..." already present on machine`.
   kubelet が pull しなかったか。`already present on machine` イベントを確認します。

---

## What the figures show / 数字から分かること

- Start-to-Ready was 50 seconds in the reference run, compared with 125 seconds for
  step 1.
  start-to-Ready は参考計測で 50 秒でした。ステップ 1 は 125 秒です。
- The snapshot build time is not included in that figure. It took several minutes, and
  it has to be repeated whenever the image changes. That recurring cost is the main
  factor in deciding whether to use this mechanism.
  スナップショットの作成時間はこの数字に含まれていません。数分かかり、イメージが変わる
  たびに繰り返す必要があります。この継続的なコストが、この方式を採用するかの主な判断材料に
  なります。
- This mechanism is not available on EKS Auto Mode (step 4).
  この方式は EKS Auto Mode では使えません（ステップ 4）。

### Common failures / よくある失敗

| Symptom | Cause |
|---|---|
| Pod stays Pending; the node class is missing<br>Pod が Pending のまま、node class が無い | `results/snapshot-id.txt` does not exist, so `prep.sh` skipped arm B<br>`results/snapshot-id.txt` が無く、`prep.sh` が arm B を飛ばした |
| The node fails to launch<br>ノードが起動しない | `volumeSize` is smaller than the snapshot<br>`volumeSize` がスナップショットより小さい |
| The image is pulled anyway<br>結果的に pull される | The snapshot was taken from an NVMe arm, so it is empty; or it contains a different image than the one being tested<br>NVMe の arm から取得したため空、またはテスト対象と別のイメージが入っている |

---

Next / 次: [Step 3 — local NVMe and the SOCI snapshotter](03-soci.md)
