# Step 3 — Local NVMe and the SOCI snapshotter
# ステップ 3 — ローカル NVMe と SOCI snapshotter

**Goal / 目的:** make the pull itself faster, with the image unmodified and no
per-image pre-work.

イメージを無改変・イメージ単位の事前作業なしで、pull 自体を速くします。

---

## The idea / 考え方

containerd's default snapshotter downloads and unpacks layers **one at a time**.
The [SOCI snapshotter][soci] in *parallel pull/unpack* mode opens several HTTP
connections per layer and decompresses several layers concurrently. It needs
somewhere fast to buffer, which is what the local NVMe is for.

containerd の既定 snapshotter はレイヤを**1 つずつ**ダウンロード・展開します。
[SOCI snapshotter][soci] の *parallel pull/unpack* モードは、レイヤごとに複数の HTTP
接続を開き、複数レイヤを同時に展開します。バッファ用に高速な領域が必要で、そのために
ローカル NVMe を使います。

**No SOCI index is built. The image is not modified. Your build pipeline does not
change.**

**SOCI index の作成は不要。イメージは無改変。ビルドパイプラインも変更なしです。**

---

## The configuration change / 設定変更

Two additions to the node class
([`12-arm-c-soci.yaml`](../manifests/karpenter/12-arm-c-soci.yaml)):

node class への追加は 2 箇所です。

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: arm-c-soci
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: "<node IAM role>"

  instanceStorePolicy: RAID0                 # <-- CHANGE 1

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true }
    - deviceName: /dev/xvdb
      ebs: { volumeSize: 100Gi, volumeType: gp3, throughput: 1000, iops: 16000, encrypted: true }

  userData: |                                # <-- CHANGE 2 (Bottlerocket TOML)
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

### Change 1 — `instanceStorePolicy: RAID0`

Karpenter builds a RAID0 array from the instance's NVMe disks and moves
`/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods` and SOCI's data directory
(`/var/lib/soci-snapshotter` on Bottlerocket) onto it, symlinking them back.

Karpenter がインスタンスの NVMe から RAID0 を構成し、`/var/lib/containerd`、
`/var/lib/kubelet`、`/var/log/pods`、SOCI のデータディレクトリを移して symlink します。

**Why it is needed:** SOCI buffers layers on disk while downloading. Without this,
that buffering happens on EBS and becomes the limit — you would enable parallelism
and then throttle it.

**必要な理由:** SOCI はダウンロード中にレイヤをディスクへバッファします。これが無いと
バッファ先が EBS になり、それが律速します。並列化しておいて自ら絞ることになります。

### Change 2 — `userData`

Bottlerocket takes **TOML settings, not a shell script**. This is the most common
thing people get wrong when coming from AL2023.

Bottlerocket が受け取るのは**シェルスクリプトではなく TOML 設定**です。AL2023 から
来た人が最もよく間違える点です。

| Setting | What it does / 役割 |
|---|---|
| `snapshotter = "soci"` | Switches containerd's snapshotter. Without this, everything below is inert.<br>containerd の snapshotter を切り替えます。これが無いと以下はすべて無効です。 |
| `pull-mode = "parallel-pull-unpack"` | Selects the mode that parallelises. SOCI also has lazy-loading modes; this is not one of them.<br>並列化するモードを選びます。SOCI には lazy-load 系もありますが、これはそれではありません。 |
| `max-concurrent-downloads-per-image = 20` | HTTP connections per layer. Uses bandwidth a single connection cannot.<br>レイヤあたりの HTTP 接続数。単一接続では使えない帯域を使います。 |
| `concurrent-download-chunk-size = "16mb"` | How large layers are split for parallel fetch.<br>並列取得のためにレイヤを分割する単位。 |
| `max-concurrent-unpacks-per-image = 12` | Layers decompressed at once. **CPU-bound** — this is why vCPU count changes the result.<br>同時展開レイヤ数。**CPU バウンド**であり、vCPU 数が結果を変える理由です。 |
| `discard-unpacked-layers = true` | Frees the compressed copy after unpacking, saving disk.<br>展開後に圧縮コピーを破棄しディスクを節約します。 |

> **These values are AWS's published starting point, not a recommendation for your
> images.** Layer count, layer size and vCPU all move the right answer. Tuning them
> against your own images is part of step 6.
>
> **これらの値は AWS が公開する出発点であり、あなたのイメージ向けの推奨値ではありません。**
> レイヤ数・サイズ・vCPU で最適値は変わります。自分のイメージでの調整はステップ 6 の一部です。

### The version requirement / バージョン要件

> **Bottlerocket >= 1.44.0 is mandatory.** SOCI parallel pull/unpack landed there.
> On anything older, `snapshotter = "soci"` is **silently ignored** — the node boots,
> the pod runs, and this arm quietly measures the same thing as step 1. That reads as
> "SOCI does not help", which is the wrong conclusion to take away.
> `bin/prep.sh` asserts the version for exactly this reason.
>
> **Bottlerocket 1.44.0 以上が必須です。** parallel pull/unpack はそこで入りました。
> それより古いと `snapshotter = "soci"` は**黙って無視され**、ノードは起動し Pod も動き、
> この arm はステップ 1 と同じものを計測します。結果は「SOCI は効かない」と読めますが、
> それは誤った結論です。`bin/prep.sh` がこのために検証します。

---

## Apply and run / 適用と実行

```bash
bin/prep.sh
bin/show_config.sh arm-c-soci     # shows both changes as a diff against step 1
bin/bench.sh arm-c-soci
```

---

## Verify / 検証

```bash
bin/verify_config.sh arm-c-soci
```

Three checks, and note honestly what each does and does not prove:

3 つの確認です。それぞれが何を証明し、何を証明しないかを正直に押さえてください。

1. **Container storage moved to NVMe.** The node's ephemeral-storage capacity now
   reflects the NVMe array rather than the 100 GiB EBS volume. Proves change 1 took
   effect.
   **コンテナストレージが NVMe に移ったか。** ノードの ephemeral-storage 容量が
   100 GiB の EBS ではなく NVMe を反映します。変更 1 が効いた証明です。
2. **The settings reached the node.** It reads `userData` back off the applied
   `EC2NodeClass`. This proves the settings were **delivered** — it does not prove
   SOCI ran, because Bottlerocket has no shell to check from.
   **設定がノードに届いたか。** 適用済み `EC2NodeClass` の `userData` を読み戻します。
   これは**配送**の証明で、SOCI が動いた証明ではありません。Bottlerocket にシェルが
   無いため確認できません。
3. **The Bottlerocket version is >= 1.44.0.**
   **Bottlerocket が 1.44.0 以上か。**

**The behavioural evidence is the throughput figure.** If SOCI were being ignored,
this arm would land on step 1's MB/s. It does not — that is the check that matters.

**挙動としての証拠はスループットの数字です。** SOCI が無視されていれば、この arm は
ステップ 1 と同じ MB/s になります。そうならないことが本質的な確認です。

---

## What you should conclude / ここで得る結論

- **The pull roughly halved** on an unmodified image, with no per-image pre-work
  and no build-pipeline change. In the reference run 95s → 62s, 98 → 151 MB/s.
  **pull はおよそ半減しました。** イメージ無改変、イメージ単位の事前作業なし、ビルド
  パイプライン変更なし。参考計測では 95→62 秒、98→151 MB/s。
- **This is the honest comparison in the whole workshop:** step 1 versus step 3.
  Same provisioner, same OS, same instance type, one mechanism changed.
  **本ワークショップで最も厳密な比較がこれです。** ステップ 1 対 3。プロビジョナ・OS・
  インスタンスタイプが同一で、変えたのは 1 方式だけです。
- **It is mutually exclusive with step 2.** You are choosing, not stacking.
  **ステップ 2 とは排他です。** 積み上げるのではなく選ぶ関係です。

---

[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md

Next / 次: [Step 4 — let EKS Auto Mode do it](04-automode.md)
