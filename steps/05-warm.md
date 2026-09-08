# Step 5 — Cold first pod versus warm scale-out
# ステップ 5 — cold な 1 個目と warm なスケールアウト

**Goal / 目的:** measure how much of the startup time is incurred once per node rather
than once per pod.

起動時間のうち、Pod ごとではなくノード 1 台につき 1 回発生する分を計測します。

---

## Why this measurement / この計測を行う理由

The four variants all measure the first pod on a new node. When a deployment scales out,
some pods are scheduled onto nodes that are already running, where the image is already
in the node's cache. Those pods do not incur the provisioning or pull stages.

4 つの variant はいずれも、新しいノードでの 1 個目の Pod を計測しています。Deployment が
スケールアウトするとき、一部の Pod はすでに動いているノードにスケジュールされ、そのノードの
キャッシュにイメージがあります。その Pod にはプロビジョニングと pull の段階は発生しません。

---

## No configuration change / 設定変更はありません

This step changes the run command, not the configuration:

このステップで変わるのは実行コマンドで、設定ではありません。

```bash
bin/bench.sh soci --warm
```

| Cold run (default) | Warm run (`--warm`) |
|---|---|
| Deletes the NodeClaim, which terminates the instance and discards its image cache<br>NodeClaim を削除し、インスタンスを終了してイメージキャッシュを破棄 | Deletes the pod only, keeping the NodeClaim and the node<br>Pod のみを削除し、NodeClaim とノードは残す |
| Measures provisioning, pull and start<br>プロビジョニング、pull、起動を計測 | Measures start only<br>起動のみを計測 |

Run this immediately after the cold run of the same variant, while that node is still
present. The node pool's `consolidateAfter` is 30 minutes. If the node has been
removed, `bench.sh` reports that the result will not be a warm measurement.

同じ variant の cold 実行直後、そのノードが残っている間に実行してください。node pool の
`consolidateAfter` は 30 分です。ノードが削除されている場合、`bench.sh` は warm な計測に
ならないことを報告します。

The pod is deleted before the new one is submitted because these instance types have one
GPU. Two pods that each request `nvidia.com/gpu: 1` cannot run on the same node, so the
second pod would cause a new node to be provisioned and the run would measure a cold
start.

新しい Pod を投入する前に既存の Pod を削除するのは、これらのインスタンスタイプが GPU を
1 基しか持たないためです。`nvidia.com/gpu: 1` を要求する Pod は同じノードで 2 つ動かせない
ので、2 つ目の Pod は新しいノードの起動を引き起こし、cold な計測になってしまいます。

---

## How the stage calculation handles this / 段階計算の扱い

In a warm run the NodeClaim was created before this pod existed, so its `Launched` and
`Registered` timestamps precede the pod's `creationTimestamp`. If those were included
in the stage chain they would be sorted to the front and produce a provisioning stage
covering the time before the pod was created.

warm 実行では、NodeClaim はこの Pod が存在する前に作成されているため、その `Launched` と
`Registered` のタイムスタンプは Pod の `creationTimestamp` より前になります。これらを
段階の連鎖に含めると先頭に並び、Pod 作成前の時間を含むプロビジョニング段階が生成されます。

`stages.py` discards any timestamp that precedes the pod's `creationTimestamp` and
reports which ones it discarded:

`stages.py` は Pod の `creationTimestamp` より前のタイムスタンプを除外し、除外したものを
報告します。

```
  warm run       node already existed; dropped 4 pre-pod anchor(s): node_ready,
                 nodeclaim_created, nodeclaim_launched, nodeclaim_registered
```

Events that occurred before the pod was created are not part of that pod's startup
time. The same rule also applies to a cold run that reads a NodeClaim from a previous
run.

Pod 作成前に発生したイベントは、その Pod の起動時間には含まれません。この規則は、前回の
実行の NodeClaim を読んでしまった cold 実行にも同様に適用されます。

---

## Read the result / 結果の読み方

```bash
bin/report.py
```

```
  soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

The last figure is the portion of the cold measurement that a node which is already
running does not incur.

最後の数字は、cold の計測のうち、すでに動いているノードでは発生しない部分です。

---

## What the figures show / 数字から分かること

In the reference run, 96 of the 97 seconds was incurred once per node. Two things
follow from this.

参考計測では、97 秒のうち 96 秒がノード 1 台につき 1 回発生する分でした。ここから 2 点が
分かります。

1. The snapshot variant's improvement applies to the first pod on a node. It has no effect on a pod
   scheduled onto a node that already has the image. Comparing only cold figures would
   overstate how much of your total startup time it addresses.
   snapshot の改善はノードの 1 個目の Pod に適用されます。イメージを持つノードにスケジュール
   された Pod には効果がありません。cold の数字だけを比べると、起動時間全体に対して
   カバーする範囲を大きく見積もることになります。
2. If most pods in your workload are scheduled onto nodes that are already running, the
   mechanisms in steps 2 to 4 affect a small part of the total startup time. In that
   case node capacity policy — keeping nodes for longer, or provisioning them before
   they are needed — has more effect than image delivery.
   ワークロードの Pod の大半がすでに動いているノードにスケジュールされる場合、ステップ 2〜4
   の各方式が影響するのは起動時間全体の一部です。その場合、イメージ配送よりも、ノードの
   キャパシティ方針（ノードを長く保つ、必要になる前に起動しておく）の方が効果があります。

### What to check in your own environment / 自分の環境で確認すること

What proportion of pods are scheduled onto new nodes, and what proportion onto nodes
that are already running? This depends on your traffic pattern and autoscaling
configuration, so it cannot be determined from this workshop. It affects whether the
mechanisms in steps 2 to 4 are worth adopting.

Pod のうち新しいノードにスケジュールされる割合と、すでに動いているノードにスケジュール
される割合はどれくらいか。これはトラフィックのパターンとオートスケーリング設定に依存する
ため、本ワークショップからは分かりません。ステップ 2〜4 の方式を採用する価値があるかに
影響します。

---

Next / 次: [Step 6 — how the model weights reach GPU memory](06-weights.md)
