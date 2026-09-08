# Step 2 — Pre-bake the image into an EBS snapshot
# ステップ 2 — イメージを EBS スナップショットに焼き込む

**Goal / 目的:** remove the pull entirely, and find out what that costs.

pull を完全に消し、その代償を把握します。

---

## The idea / 考え方

Bottlerocket keeps container images on its **data volume**. If that volume is
restored from a snapshot that already contains the layers, containerd finds them
locally and there is nothing to pull.

Bottlerocket はコンテナイメージを**データボリューム**に置きます。そのボリュームを、
既にレイヤを含むスナップショットから復元すれば、containerd はローカルで見つけるため
pull するものがありません。

---

## Part A — build the snapshot / スナップショットを作る

The snapshot has to come from a node that has already pulled the image. Step 1 left
you one, so **do not reset before doing this**:

スナップショットは、既にイメージを pull したノードから作る必要があります。ステップ 1 の
ノードが残っているので、**その前に reset しないでください**。

```bash
bin/bench.sh arm-a-baseline          # if you already reset, run it again
snapshot/snapshot-from-node.sh       # ~3-5 min
```

What it does / 動作:

1. finds the node for the `arm-a-baseline` node pool
   `arm-a-baseline` node pool のノードを見つける
2. locates its `/dev/xvdb` volume
   その `/dev/xvdb` ボリュームを特定する
3. `aws ec2 create-snapshot` on that volume, then waits for `completed`
   そのボリュームを `create-snapshot` し、`completed` まで待つ
4. writes the ID to `results/snapshot-id.txt`
   ID を `results/snapshot-id.txt` に書く

> **It must be an arm A node, not arm C.** Arm C's `instanceStorePolicy` moves
> container storage to local NVMe, which leaves its EBS data volume empty. You would
> snapshot an empty disk and the arm would silently fall back to pulling.
>
> **対象は arm A のノードで、arm C では駄目です。** arm C は `instanceStorePolicy` で
> コンテナストレージがローカル NVMe に移るため、EBS データボリュームは空です。空の
> ディスクをスナップショットしてしまい、arm は黙って pull に戻ります。

> **`snapshot/build-snapshot.sh` did not work for us.** It wraps
> `aws-samples/bottlerocket-images-cache`, which launches its own instance and drives
> it over SSM Run Command. On the EKS-optimized Bottlerocket NVIDIA AMI the instance
> never registered with SSM and the script has no timeout, so it hangs. Kept for
> reference only.
>
> **`snapshot/build-snapshot.sh` は当環境では動きませんでした。** SSM Run Command で
> 専用インスタンスを操作する方式ですが、EKS 最適化 Bottlerocket NVIDIA AMI では SSM に
> 登録されず、タイムアウトも無いためハングします。参考として残しているだけです。

---

## Part B — the configuration change / 設定変更

**One field.** Compare
[`11-arm-b-snapshot.yaml`](../manifests/karpenter/11-arm-b-snapshot.yaml) with step
1's node class:

**1 フィールドだけです。**

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
        snapshotID: "snap-0123456789abcdef0"       # <-- THE ONLY CHANGE
        deleteOnTermination: true
```

`bin/prep.sh` substitutes the ID from `results/snapshot-id.txt`, so you do not paste
it by hand.

`bin/prep.sh` が `results/snapshot-id.txt` から ID を差し込むので、手で貼る必要は
ありません。

| Field | Why / 理由 |
|---|---|
| `snapshotID` on `/dev/xvdb` | Restores the data volume from the snapshot. The layers are on disk before kubelet asks for them.<br>データボリュームをスナップショットから復元します。kubelet が要求する前にレイヤがディスク上にあります。 |
| `volumeSize` ≥ snapshot size | A volume smaller than its snapshot is rejected outright.<br>スナップショットより小さいボリュームは拒否されます。 |
| `encrypted` is **gone** | Not a downgrade: a restored volume inherits the snapshot's encryption, and the snapshot came from step 1's encrypted volume. Setting it too is allowed but redundant.<br>ダウングレードではありません。復元ボリュームはスナップショットの暗号化を継承し、そのスナップショットはステップ 1 の暗号化ボリューム由来です。併記しても構いませんが冗長です。 |

### What is deliberately absent / 意図的に無いもの

**`instanceStorePolicy`.** This is the exclusivity, and it is the single most
important thing to understand in this workshop:

**`instanceStorePolicy` です。** これが排他性であり、本ワークショップで最も理解すべき
点です。

> Arm B needs the images on the volume restored from the snapshot. The moment you add
> `instanceStorePolicy` (step 3), container storage moves to local NVMe and **the
> snapshot is bypassed** — you keep paying to build it and get nothing for it.
>
> arm B はスナップショットから復元したボリューム上にイメージが必要です。
> `instanceStorePolicy`（ステップ 3）を追加した瞬間、コンテナストレージはローカル
> NVMe に移り、**スナップショットは参照されません。** 作成コストを払い続けて何も
> 得られない状態になります。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh                       # picks up the snapshot ID
bin/show_config.sh arm-b-snapshot # shows the one-line diff
bin/bench.sh arm-b-snapshot
```

The pull stage should be absent from the breakdown.

内訳から pull の段が消えるはずです。

---

## Verify / 検証

```bash
bin/verify_config.sh arm-b-snapshot
```

Two independent proofs / 独立した 2 つの証明:

1. **The volume really came from your snapshot.** It reads the instance's
   `/dev/xvdb` volume and compares its `SnapshotId` with
   `results/snapshot-id.txt`. This is stronger than any timing number.
   **ボリュームが本当にそのスナップショット由来か。** インスタンスの `/dev/xvdb` の
   `SnapshotId` を `results/snapshot-id.txt` と照合します。どんな時間の数字より強い証拠です。
2. **kubelet skipped the pull.** It looks for the event
   `Container image "..." already present on machine`. The registry was never
   contacted.
   **kubelet が pull を省略したか。**`already present on machine` イベントを確認します。
   レジストリには一度も行っていません。

---

## What you should conclude / ここで得る結論

- **The pull can be reduced to zero.** In the reference run 125s → 50s.
  **pull はゼロにできます。** 参考計測では 125 → 50 秒。
- **The cost is not in the table.** Building the snapshot took minutes, and it must
  be rebuilt on **every image change**. That recurring cost — not the measured gain —
  is what decides whether to adopt this.
  **コストは表に出ていません。** 作成に数分かかり、**イメージ更新ごとに**作り直しが
  必要です。採用可否を決めるのは実測の短縮幅ではなく、この繰り返し発生するコストです。
- **This mechanism is unavailable on EKS Auto Mode** (step 4). If it turns out to be
  the right answer for a workload, that workload cannot go on Auto Mode.
  **この方式は EKS Auto Mode では使えません**（ステップ 4）。あるワークロードの答えが
  これなら、そのワークロードは Auto Mode に乗りません。

### Common failures / よくある失敗

| Symptom | Cause |
|---|---|
| Pod Pending, node class missing<br>Pod が Pending | No `results/snapshot-id.txt`; `prep.sh` skipped arm B<br>スナップショット未作成で `prep.sh` が arm B を飛ばした |
| Node fails to launch<br>ノードが起動しない | `volumeSize` smaller than the snapshot<br>`volumeSize` がスナップショットより小さい |
| Image pulled anyway<br>結局 pull される | Snapshot taken from an NVMe arm (empty volume), or a different image than the one under test<br>NVMe の arm から取った（空）か、テスト対象と別イメージ |

---

Next / 次: [Step 3 — local NVMe and the SOCI snapshotter](03-soci.md)
