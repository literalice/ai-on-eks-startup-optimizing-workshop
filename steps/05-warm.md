# Step 5 — Cold first pod versus warm scale-out
# ステップ 5 — cold な 1 個目と warm なスケールアウト

**Goal / 目的:** find out how much of the startup cost you pay **once per node**
rather than once per pod. This step can invalidate steps 2–4 for your workload, which
is why it is here.

起動コストのうち、Pod ごとではなく**ノード 1 台につき 1 回**払う分がどれだけかを調べます。
このステップはワークロードによってはステップ 2〜4 を無意味にしうるため、含めています。

---

## The idea / 考え方

Every measurement so far was **the first pod on a brand new node**. Real scale-out
usually is not that: it lands on a node that is already running, with the image
already in its cache.

これまでの計測はすべて**新しいノードの 1 個目の Pod**でした。実際のスケールアウトは通常
そうではなく、既に動いているノードに乗り、イメージはキャッシュ済みです。

---

## There is no configuration change / 設定変更はありません

This step changes **how you run**, not what you configure:

このステップで変わるのは**実行方法**で、設定ではありません。

```bash
bin/bench.sh arm-c-soci --warm
```

What `--warm` does differently / `--warm` の違い:

| Cold run (default) | Warm run (`--warm`) |
|---|---|
| Deletes the **NodeClaim**, terminating the instance and discarding its image cache<br>**NodeClaim** を削除。インスタンスを終了しイメージキャッシュを破棄 | Deletes **only the Pod**, keeping the NodeClaim and the node<br>**Pod だけ**を削除。NodeClaim とノードは維持 |
| Measures provisioning + pull + start<br>プロビジョニング + pull + 起動を計測 | Measures start only<br>起動のみを計測 |

> **Run it immediately after the cold run of the same arm**, while that node is still
> up. The NodePool's `consolidateAfter` is 30m, so you have time — but if the node is
> gone, `bench.sh` warns you that the result will not be a warm measurement.
>
> **同じ arm の cold 実行直後に、そのノードが残っているうちに実行してください。**
> NodePool の `consolidateAfter` は 30 分なので余裕はありますが、ノードが消えていれば
> `bench.sh` が「warm な計測にならない」と警告します。

**Why the Pod has to go first:** these instance types have one GPU. Two pods each
requesting `nvidia.com/gpu: 1` cannot share the node, so the second would trigger a
new node and you would measure a cold start by accident.

**Pod を先に消す理由:** これらのインスタンスタイプは GPU が 1 基です。`nvidia.com/gpu: 1`
を要求する Pod は 2 つ同居できないため、2 つ目は新しいノードを起動させ、意図せず cold を
計測してしまいます。

---

## A detail worth knowing / 知っておく価値のある実装上の点

On a warm run the NodeClaim was created **minutes before this Pod existed**. Its
`Launched` / `Registered` timestamps therefore predate the Pod, and a naive stage
calculation would sort them to the front of the chain and manufacture a large
nonsensical "provisioning" stage — or a negative one.

warm 実行では、NodeClaim はこの Pod が存在する**数分前**に作られています。その
`Launched` / `Registered` の時刻は Pod より前になるため、素朴に段階を計算すると
それらが先頭に並び、巨大で無意味な「プロビジョニング」段階（あるいは負の値）を
生み出します。

`stages.py` therefore **drops any anchor that predates the Pod's own
`creationTimestamp`** and says so:

そのため `stages.py` は **Pod 自身の `creationTimestamp` より前のアンカーをすべて破棄**し、
その旨を出力します。

```
  warm run       node already existed; dropped 4 pre-pod anchor(s): node_ready,
                 nodeclaim_created, nodeclaim_launched, nodeclaim_registered
```

Nothing that happened before the Pod was created can be part of that Pod's wait. The
rule is general, and it also protects a cold run that happens to pick up a stale
NodeClaim.

Pod 作成前に起きたことは、その Pod の待ち時間の一部にはなり得ません。この規則は一般的で、
古い NodeClaim を拾ってしまった cold 実行も保護します。

---

## Read the result / 結果の読み方

```bash
bin/report.py
```

```
  arm-c-soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

The last figure is the part a **pre-warmed or longer-lived node avoids entirely**.

最後の数字は、**事前ウォームや長寿命ノードなら完全に回避できる**部分です。

---

## What you should conclude / ここで得る結論

In the reference run **96 of 97 seconds was a once-per-node cost.** That has two
consequences, and the second is the uncomfortable one:

参考計測では **97 秒のうち 96 秒がノード 1 回あたりのコスト**でした。ここから 2 つの
帰結があり、2 つ目は耳の痛い話です。

1. **It stops step 2 being over-credited.** A snapshot helps the cold pod and does
   **nothing at all** for the warm one. If you compared only cold numbers you would
   overstate its value.
   **ステップ 2 の過大評価を防ぎます。** スナップショットが効くのは cold な 1 個目だけで、
   warm には**何もしません**。cold だけを比べると価値を過大に見積もります。
2. **It can invalidate this entire workshop for your workload.** If most of your
   scale-out lands on nodes that are already running, then **none of the three
   mechanisms in steps 2–4 is where your time goes.** The answer is capacity
   policy — keeping nodes longer, or warming them before you need them — not image
   delivery.
   **ワークロードによっては、このワークショップ全体が的外れになりえます。** スケール
   アウトの大半が既存ノードに乗るなら、**ステップ 2〜4 の 3 方式はどれも時間の使われ先
   ではありません。** 答えはイメージ配送ではなくキャパシティ方針（ノードを長く保つ、
   必要になる前に温める）です。

### The question to take away / 持ち帰る問い

> When your pods scale out, what fraction land on **new** nodes versus nodes that are
> **already running**?
>
> Pod が増えるとき、**新しい**ノードに乗る割合と**既存**ノードに乗る割合はどれくらいですか。

You cannot answer that from this workshop — it is a property of your traffic and your
autoscaling configuration. But it determines whether any of steps 2–4 is worth
adopting, so it is worth measuring before you commit to one.

これはこのワークショップからは答えられません。トラフィックとオートスケーリング設定の
性質です。しかしステップ 2〜4 のいずれかを採用する価値があるかを決めるので、
決める前に測る価値があります。

---

Next / 次: [Step 6 — how the model weights reach GPU memory](06-weights.md)
