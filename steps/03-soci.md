# Step 3 — Local NVMe and the SOCI snapshotter
# ステップ 3 — ローカル NVMe と SOCI snapshotter

**Goal / 目的:** reduce the pull duration without modifying the image and without
per-image preparation.

イメージを変更せず、イメージ単位の準備も行わずに、pull の所要時間を短縮します。

---

## How it works / 仕組み

containerd's default snapshotter downloads and unpacks layers one at a time. The
[SOCI snapshotter][soci] in parallel pull/unpack mode opens several HTTP connections
per layer and decompresses several layers concurrently. It buffers layers on disk while
downloading, which is why local NVMe is used.

containerd の既定 snapshotter はレイヤを 1 つずつダウンロード・展開します。
[SOCI snapshotter][soci] の parallel pull/unpack モードは、レイヤごとに複数の HTTP 接続を
開き、複数のレイヤを同時に展開します。ダウンロード中にレイヤをディスクにバッファするため、
ローカル NVMe を使います。

No SOCI index is created, the image is not modified, and the build pipeline does not
change.

SOCI index の作成は不要で、イメージは変更せず、ビルドパイプラインも変わりません。

---

## The configuration change / 設定変更

Two additions to the node class, in
[`12-soci.yaml`](../manifests/karpenter/12-soci.yaml):

node class への追加は 2 箇所です。

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

Karpenter creates a RAID0 array from the instance's NVMe disks and moves
`/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods` and SOCI's data directory
(`/var/lib/soci-snapshotter` on Bottlerocket) onto it, leaving symlinks in the original
locations.

Karpenter がインスタンスの NVMe ディスクから RAID0 を構成し、`/var/lib/containerd`、
`/var/lib/kubelet`、`/var/log/pods`、SOCI のデータディレクトリを移動して、元の場所には
symlink を残します。

SOCI buffers layers on disk while downloading. Without this setting the buffering
happens on the EBS volume, and the EBS volume's throughput then limits the result.

SOCI はダウンロード中にレイヤをディスクにバッファします。この設定が無い場合、バッファ先は
EBS ボリュームになり、EBS のスループットが結果を制限します。

### Addition 2 — `userData`

Bottlerocket reads TOML settings from `userData`, not a shell script. This differs from
Amazon Linux 2023, where `userData` contains a `NodeConfig` document or a script.

Bottlerocket は `userData` からシェルスクリプトではなく TOML 設定を読みます。この点は、
`userData` に `NodeConfig` やスクリプトを書く Amazon Linux 2023 とは異なります。

| Setting | Effect / 効果 |
|---|---|
| `snapshotter = "soci"` | Selects SOCI as containerd's snapshotter. Without this line the settings below have no effect.<br>containerd の snapshotter として SOCI を選択します。この行が無いと以下の設定は効きません。 |
| `pull-mode = "parallel-pull-unpack"` | Selects the parallel mode. SOCI also has lazy-loading modes, which this is not.<br>並列モードを選択します。SOCI には lazy-load 系のモードもありますが、これはそれではありません。 |
| `max-concurrent-downloads-per-image = 20` | Number of HTTP connections per layer.<br>レイヤあたりの HTTP 接続数。 |
| `concurrent-download-chunk-size = "16mb"` | Size that large layers are split into for parallel download.<br>並列ダウンロードのためにレイヤを分割する単位。 |
| `max-concurrent-unpacks-per-image = 12` | Number of layers decompressed at the same time. Decompression is CPU-bound, which is why the instance's vCPU count affects the result.<br>同時に展開するレイヤ数。展開は CPU バウンドなので、インスタンスの vCPU 数が結果に影響します。 |
| `discard-unpacked-layers = true` | Frees the compressed copy of each layer after unpacking.<br>展開後に各レイヤの圧縮コピーを解放します。 |

These values are the ones AWS publishes as a starting point. Layer count, layer size
and vCPU affect which values are appropriate for a given image.

これらは AWS が出発点として公開している値です。適切な値はレイヤ数、レイヤサイズ、vCPU に
よって変わります。

### Version requirement / バージョン要件

SOCI parallel pull/unpack was added in Bottlerocket 1.44.0. On an earlier version,
`snapshotter = "soci"` is ignored without an error: the node boots, the pod runs, and
this variant measures the same thing as step 1. The resulting figures would suggest SOCI
has no effect. `bin/prep.sh` checks the version before the variants run.

SOCI の parallel pull/unpack は Bottlerocket 1.44.0 で追加されました。それより前の
バージョンでは `snapshotter = "soci"` がエラーなしで無視され、ノードは起動し Pod も動き、
この variant はステップ 1 と同じものを計測します。その結果の数字は SOCI に効果がないように
見えます。`bin/prep.sh` は variant の実行前にバージョンを確認します。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh
bin/show_config.sh soci     # shows both additions as a diff against step 1
bin/bench.sh soci
```

---

## Verify / 検証

```bash
bin/verify_config.sh soci
```

Three checks, with their limits stated:

確認は 3 つで、それぞれ確認できる範囲も示されます。

1. Container storage moved to NVMe. The node's ephemeral-storage capacity corresponds
   to the NVMe array rather than the 100 GiB EBS volume. This confirms addition 1.
   コンテナストレージが NVMe に移ったか。ノードの ephemeral-storage 容量が、100 GiB の
   EBS ボリュームではなく NVMe アレイに対応します。追加 1 の確認になります。
2. The settings reached the node. The script reads `userData` back from the applied
   `EC2NodeClass`. This confirms the settings were delivered. It does not confirm that
   SOCI ran, because Bottlerocket does not provide a shell for checking the running
   configuration.
   設定がノードに届いたか。適用済み `EC2NodeClass` の `userData` を読み戻します。設定が
   配送されたことの確認です。SOCI が動作したことの確認にはなりません。Bottlerocket は
   稼働中の設定を確認するためのシェルを提供していないためです。
3. The Bottlerocket version is 1.44.0 or later.
   Bottlerocket が 1.44.0 以降か。

The throughput figure indicates whether SOCI ran. If the setting were being ignored,
this variant's throughput would match step 1's.

SOCI が動作したかはスループットの数字から判断できます。設定が無視されていれば、この variant の
スループットはステップ 1 と同じ値になります。

---

## What the figures show / 数字から分かること

- The pull dropped from 95 seconds to 62 seconds in the reference run, and throughput
  rose from 98 MB/s to 151 MB/s. The image was not modified and no per-image
  preparation was needed.
  参考計測では pull が 95 秒から 62 秒になり、スループットは 98 MB/s から 151 MB/s に
  なりました。イメージは変更せず、イメージ単位の準備も不要です。
- Step 1 and step 3 differ by one mechanism, with the same provisioner, OS and instance
  type, so the difference is attributable to that mechanism.
  ステップ 1 と 3 は、プロビジョナ・OS・インスタンスタイプが同じで、異なるのは 1 つの
  方式だけです。差はその方式に帰属できます。
- This variant and step 2 cannot both be applied to the same node.
  この variant とステップ 2 は同じノードに併用できません。

---

[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md

Next / 次: [Step 4 — let EKS Auto Mode do it](04-automode.md)
