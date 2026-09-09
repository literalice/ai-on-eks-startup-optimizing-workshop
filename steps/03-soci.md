# Step 3 — Local NVMe and the SOCI snapshotter

**English** | [日本語](#japanese)

Goal: reduce the pull duration without modifying the image and without per-image
preparation.

---

## How it works

containerd's default snapshotter downloads and unpacks layers one at a time. The
[SOCI snapshotter][soci] in parallel pull/unpack mode opens several HTTP connections per
layer and decompresses several layers concurrently. It buffers layers on disk while
downloading, which is why local NVMe is used.

No SOCI index is created, the image is not modified, and the build pipeline does not
change.

---

## The configuration change

Two additions to the node class, in
[`12-soci.yaml`](../manifests/karpenter/12-soci.yaml):

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: "<node IAM role>"

  instanceStorePolicy: RAID0                 # addition 1

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true }
    - deviceName: /dev/xvdb
      ebs: { volumeSize: 100Gi, volumeType: gp3, throughput: 1000, iops: 16000, encrypted: true }

  userData: |                                # addition 2 (Bottlerocket TOML)
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true
```

### Addition 1 — `instanceStorePolicy: RAID0`

Karpenter turns this field into a Bottlerocket bootstrap command, which is what the
generated `userData` carries in addition to the settings shown above:

```toml
[settings.bootstrap-commands.000-mount-instance-storage]
commands = [
  ["apiclient", "ephemeral-storage", "init"],
  ["apiclient", "ephemeral-storage", "bind"],
]
essential = true
mode = "always"
```

`init` prepares the instance's NVMe instance-store disks and mounts them at `/mnt`. `bind`
then runs `mount --rbind` from a subdirectory of that mount onto each target directory. The
data volume is not moved and no symlink is created: the target paths are covered by a
mount, so reads and writes below them land on the instance store instead of the EBS volume.

What `init` does depends on how many instance-store disks the instance type has, and this is
worth checking for your own type rather than assuming.

| Disks | What happens |
|---|---|
| 2 or more | `mdadm --create --level=0 --chunk=256` across them, then XFS on the array |
| 1 | **No array.** The device is formatted XFS directly |
| 0 | `init` logs that it found no ephemeral disks and exits successfully. `bind` then has nothing to bind, the setting fails quietly rather than failing the node, and this variant measures the same thing as step 1 |

`g6.8xlarge` has two 450 GB NVMe SSDs, so the array is real here. `g6.4xlarge` and most of
the smaller G types have one, where the policy still moves container storage to the instance
store but nothing is striped. Check before you draw a conclusion from a throughput figure:

```bash
aws ec2 describe-instance-types --instance-types g6.8xlarge \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

That single-disk case explains something about the field's name. `instanceStorePolicy` is a
Karpenter field whose enum has exactly one value, `RAID0`, and it is named after its original
implementation: on AL2 and AL2023 it reaches `setup-local-disks`, which runs `mdadm --create`
with no single-disk exception, so one NVMe disk there still produces a single-device array at
`/dev/md/0`. Bottlerocket support was added later, for Bottlerocket 1.22.0 and above, and
skips the array when it would have one member. What the policy promises holds either way:
container and kubelet state on the instance store, and allocatable ephemeral-storage equal to
the instance store's total size.

If the instance type has no instance store at all, `init` logs that it found no ephemeral
disks and exits successfully, and `bind` then has nothing to bind. The setting fails quietly
rather than failing the node, and the variant would measure the same thing as step 1.

`bind` with no `--dirs` argument binds Bottlerocket's allow list of bindable directories,
which is assembled from drop-in files under `/usr/lib/bottlerocket/ephemeral-storage.d`.
The soci-snapshotter package contributes `/var/lib/soci-snapshotter` to that list, so
SOCI's data directory is included along with `/var/lib/containerd`, `/var/lib/kubelet` and
`/var/log/pods`. That matters, because SOCI buffers layers on disk while downloading. If
its data directory stayed on the EBS volume, the EBS volume's throughput would limit the
result.

Which form of the command Karpenter emits depends on the AMI version. `alias:
bottlerocket@latest` in this node class resolves to the bare `bind` above. Pinning an AMI
version below 1.46.0 makes Karpenter emit `bind --dirs /var/lib/containerd
/var/lib/kubelet /var/log/pods` instead, which omits `/var/lib/soci-snapshotter`. On a
pinned 1.44.x or 1.45.x node, SOCI would run but buffer on EBS.

### Why steps 2 and 3 cannot be combined

The snapshot puts the image layers in `/local/var/lib/containerd` on the EBS data volume,
which is where `/var/lib/containerd` resolves to on an unmodified node. The bind mount
covers that path with an empty directory on the NVMe array, so kubelet cannot reach the
pre-baked layers and pulls the image again. The cause is the mount, not the volume: the
snapshot is still restored and the layers are still on the EBS volume, but that path now
resolves to the instance store.

### Addition 2 — `userData`

Bottlerocket reads TOML settings from `userData`, not a shell script. This differs from
Amazon Linux 2023, where `userData` contains a `NodeConfig` document or a script.

| Setting | Effect |
|---|---|
| `snapshotter = "soci"` | Selects SOCI as containerd's snapshotter. Without this line the settings below have no effect. |
| `pull-mode = "parallel-pull-unpack"` | Selects the parallel mode. SOCI also has lazy-loading modes, which this is not. |
| `max-concurrent-downloads-per-image = 20` | Number of HTTP connections per layer. |
| `concurrent-download-chunk-size = "16mb"` | Size that large layers are split into for parallel download. |
| `max-concurrent-unpacks-per-image = 12` | Number of layers decompressed at the same time. Decompression is CPU-bound, which is why the instance's vCPU count affects the result. |
| `discard-unpacked-layers = true` | Frees the compressed copy of each layer after unpacking. |

These values are the ones AWS publishes as a starting point. Layer count, layer size and
vCPU affect which values are appropriate for a given image.

### Version requirement

SOCI parallel pull/unpack was added in Bottlerocket 1.44.0. On an earlier version,
`snapshotter = "soci"` is ignored without an error: the node boots, the pod runs, and this
variant measures the same thing as step 1. The resulting figures would suggest SOCI has no
effect. `bin/prep.sh` checks the version before the variants run.

---

## Apply and run

```bash
bin/prep.sh
bin/show_config.sh soci     # shows both additions as a diff against step 1
bin/bench.sh soci
```

---

## Verify

```bash
bin/verify_config.sh soci
```

Three checks, with their limits stated:

1. Container storage moved to NVMe. The node's ephemeral-storage capacity corresponds to
   the NVMe array rather than the 100 GiB EBS volume. This confirms addition 1.
2. The settings reached the node. The script reads `userData` back from the applied
   `EC2NodeClass`. This confirms the settings were delivered. It does not confirm that SOCI
   ran, because Bottlerocket does not provide a shell for checking the running
   configuration.
3. The Bottlerocket version is 1.44.0 or later.

The throughput figure indicates whether SOCI ran. If the setting were being ignored, this
variant's throughput would match step 1's.

---

## What the figures show

- The pull dropped from 95 seconds to 62 seconds in the reference run, and throughput rose
  from 98 MB/s to 151 MB/s. The image was not modified and no per-image preparation was
  needed.
- Step 1 and step 3 differ by one mechanism, with the same provisioner, OS and instance
  type, so the difference is attributable to that mechanism.
- This variant and step 2 cannot both be applied to the same node.

---

[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md

Next: [Step 4 — let EKS Auto Mode do it](04-automode.md)

<br>

---
---

<a id="japanese"></a>

# ステップ 3 — ローカル NVMe と SOCI snapshotter

[English](#step-3--local-nvme-and-the-soci-snapshotter) | **日本語**

目的: イメージを変更せず、イメージ単位の準備も行わずに、pull の所要時間を短縮します。

---

## 仕組み

containerd の既定 snapshotter はレイヤを 1 つずつダウンロード・展開します。
[SOCI snapshotter][soci] の parallel pull/unpack モードは、レイヤごとに複数の HTTP 接続を
開き、複数のレイヤを同時に展開します。ダウンロード中にレイヤをディスクにバッファするため、
ローカル NVMe を使います。

SOCI index の作成は不要で、イメージは変更せず、ビルドパイプラインも変わりません。

---

## 設定変更

node class への追加は 2 箇所です。
[`12-soci.yaml`](../manifests/karpenter/12-soci.yaml):

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: "<node IAM role>"

  instanceStorePolicy: RAID0                 # 追加 1

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true }
    - deviceName: /dev/xvdb
      ebs: { volumeSize: 100Gi, volumeType: gp3, throughput: 1000, iops: 16000, encrypted: true }

  userData: |                                # 追加 2（Bottlerocket の TOML）
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true
```

### 追加 1 — `instanceStorePolicy: RAID0`

Karpenter はこのフィールドを Bottlerocket の bootstrap command に変換します。上記の設定に
加えて、生成される `userData` にはこれが入ります。

```toml
[settings.bootstrap-commands.000-mount-instance-storage]
commands = [
  ["apiclient", "ephemeral-storage", "init"],
  ["apiclient", "ephemeral-storage", "bind"],
]
essential = true
mode = "always"
```

`init` がインスタンスの NVMe インスタンスストアを準備して `/mnt` にマウントし、`bind` が
その配下のサブディレクトリを対象ディレクトリへ `mount --rbind` します。データボリュームは
移動せず、symlink も作られません。対象パスがマウントで覆われるため、その下への読み書きが
EBS ボリュームではなくインスタンスストアに向きます。

`init` の動作はインスタンスストアのディスク本数で変わります。ここは自身のタイプについて
確認する価値があります。

| ディスク | 動作 |
|---|---|
| 2 本以上 | `mdadm --create --level=0 --chunk=256` でストライピングし、アレイを XFS でフォーマット |
| 1 本 | **アレイを作りません。** デバイスを直接 XFS でフォーマット |
| 0 本 | `init` は ephemeral disk が見つからないと記録して正常終了。`bind` はバインド対象を持たず、設定はノードを失敗させずに静かに無効となり、この variant はステップ 1 と同じものを計測する |

`g6.8xlarge` は 450 GB の NVMe SSD が 2 本なので、ここではアレイが実際に作られます。
`g6.4xlarge` や小さめの G 系は 1 本で、ポリシーはコンテナストレージをインスタンスストアに
移しますが、ストライピングは発生しません。スループットの数字から結論を出す前に確認して
ください。

```bash
aws ec2 describe-instance-types --instance-types g6.8xlarge \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

この 1 本のケースが、フィールド名の由来を説明します。`instanceStorePolicy` は Karpenter の
フィールドで、enum の値は `RAID0` の 1 つだけです。名前は元の実装に由来します。AL2 と
AL2023 では `setup-local-disks` に到達し、そこには本数の分岐が無いため `mdadm --create` が
実行され、NVMe が 1 本でも単一デバイスのアレイが `/dev/md/0` にできます。Bottlerocket
対応は後から（Bottlerocket 1.22.0 以降で）入り、メンバーが 1 つになる場合はアレイを省きます。
ポリシーが約束するものはどちらでも成立します。containerd と kubelet の state を
インスタンスストアに置き、allocatable ephemeral-storage をインスタンスストア合計サイズに
することです。

`--dirs` を付けない `bind` は、Bottlerocket が持つバインド可能ディレクトリの許可リスト全体を
バインドします。許可リストは `/usr/lib/bottlerocket/ephemeral-storage.d` 配下のドロップイン
ファイルから構成され、soci-snapshotter パッケージが `/var/lib/soci-snapshotter` を寄与して
います。したがって `/var/lib/containerd`、`/var/lib/kubelet`、`/var/log/pods` と併せて SOCI の
データディレクトリも対象になります。SOCI はダウンロード中にレイヤをディスクにバッファする
ため、ここが重要です。データディレクトリが EBS ボリュームに残った場合、EBS のスループットが
結果を制限します。

Karpenter がどちらの形式のコマンドを出力するかは AMI バージョンで決まります。この node class
の `alias: bottlerocket@latest` は上記の `--dirs` 無しの形式になります。1.46.0 未満の AMI
バージョンを固定した場合は `bind --dirs /var/lib/containerd /var/lib/kubelet /var/log/pods`
になり、`/var/lib/soci-snapshotter` が対象から外れます。1.44.x や 1.45.x を固定したノードでは
SOCI は動作しますが、バッファ先は EBS になります。

### ステップ 2 と 3 を併用できない理由

スナップショットはイメージレイヤを EBS データボリューム上の `/local/var/lib/containerd` に
置きます。未変更のノードでは `/var/lib/containerd` がそこに解決されます。bind mount はその
パスを NVMe アレイ上の空ディレクトリで覆うため、kubelet は焼き込んだレイヤに到達できず、
イメージを再度 pull します。原因はボリュームではなくマウントです。スナップショットは復元され、
レイヤも EBS ボリューム上にありますが、そのパスの解決先がインスタンスストアに変わります。

### 追加 2 — `userData`

Bottlerocket は `userData` からシェルスクリプトではなく TOML 設定を読みます。この点は、
`userData` に `NodeConfig` やスクリプトを書く Amazon Linux 2023 とは異なります。

| 設定 | 効果 |
|---|---|
| `snapshotter = "soci"` | containerd の snapshotter として SOCI を選択します。この行が無いと以下の設定は効きません。 |
| `pull-mode = "parallel-pull-unpack"` | 並列モードを選択します。SOCI には lazy-load 系のモードもありますが、これはそれではありません。 |
| `max-concurrent-downloads-per-image = 20` | レイヤあたりの HTTP 接続数。 |
| `concurrent-download-chunk-size = "16mb"` | 並列ダウンロードのためにレイヤを分割する単位。 |
| `max-concurrent-unpacks-per-image = 12` | 同時に展開するレイヤ数。展開は CPU バウンドなので、インスタンスの vCPU 数が結果に影響します。 |
| `discard-unpacked-layers = true` | 展開後に各レイヤの圧縮コピーを解放します。 |

これらは AWS が出発点として公開している値です。適切な値はレイヤ数、レイヤサイズ、vCPU に
よって変わります。

### バージョン要件

SOCI の parallel pull/unpack は Bottlerocket 1.44.0 で追加されました。それより前の
バージョンでは `snapshotter = "soci"` がエラーなしで無視され、ノードは起動し Pod も動き、
この variant はステップ 1 と同じものを計測します。その結果の数字は SOCI に効果がないように
見えます。`bin/prep.sh` は variant の実行前にバージョンを確認します。

---

## 適用と実行

```bash
bin/prep.sh
bin/show_config.sh soci     # ステップ 1 との差分として追加 2 箇所を表示
bin/bench.sh soci
```

---

## 検証

```bash
bin/verify_config.sh soci
```

確認は 3 つで、それぞれ確認できる範囲も示されます。

1. コンテナストレージが NVMe に移ったか。ノードの ephemeral-storage 容量が、100 GiB の
   EBS ボリュームではなく NVMe アレイに対応します。追加 1 の確認になります。
2. 設定がノードに届いたか。適用済み `EC2NodeClass` の `userData` を読み戻します。設定が
   配送されたことの確認です。SOCI が動作したことの確認にはなりません。Bottlerocket は
   稼働中の設定を確認するためのシェルを提供していないためです。
3. Bottlerocket が 1.44.0 以降か。

SOCI が動作したかはスループットの数字から判断できます。設定が無視されていれば、この variant
のスループットはステップ 1 と同じ値になります。

---

## 数字から分かること

- 参考計測では pull が 95 秒から 62 秒になり、スループットは 98 MB/s から 151 MB/s に
  なりました。イメージは変更せず、イメージ単位の準備も不要です。
- ステップ 1 と 3 は、プロビジョナ・OS・インスタンスタイプが同じで、異なるのは 1 つの方式
  だけです。差はその方式に帰属できます。
- この variant とステップ 2 は同じノードに併用できません。

---

[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md

次: [ステップ 4 — EKS Auto Mode に任せる](04-automode.md)
