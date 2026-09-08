# Step 6 — How the model weights reach GPU memory
# ステップ 6 — モデルウェイトが GPU メモリに届く経路

**Goal / 目的:** once the image stops being the bottleneck, find out what is. Includes
Run:ai Model Streamer and time to first token.

イメージがボトルネックでなくなった後、何がボトルネックかを調べます。Run:ai Model
Streamer と time to first token を含みます。

---

## Pre-work / 事前準備

```bash
# put MODEL_BUCKET from `terraform output -raw model_bucket` into config.env
snapshot/stage-model.sh
```

Downloads the model from Hugging Face and uploads it to S3. Safetensors only —
`--exclude "*.bin"` skips the duplicate older-format weights.

Hugging Face からモデルを取得し S3 へアップロードします。safetensors のみで、
`--exclude "*.bin"` により旧形式の重複ウェイトを除外します。

> **One `--exclude` per pattern.** The flag takes a single value; stacking several
> values after one flag makes the CLI read them as *filenames to download*. It then
> prints "Ignoring `--exclude` since filenames have being explicitly set", **exits 0,
> and downloads nothing** — a silent no-op that looks like success.
>
> **`--exclude` は 1 パターンにつき 1 フラグです。** 値を複数並べると CLI はそれらを
> *ダウンロード対象のファイル名*と解釈します。その結果
> "Ignoring `--exclude` since filenames have being explicitly set" を表示し、
> **exit 0 で何もダウンロードしません。** 成功に見える無音の no-op です。

---

## The three variants / 3 通り

Same pod spec, same node, same model, same bytes. **Only the vLLM arguments differ.**
There are three rather than two because **the effect splits into two independent
parts**.

Pod spec・ノード・モデル・バイト列は同一で、**変えるのは vLLM の引数だけ**です。
2 つでなく 3 つあるのは、**効果が独立した 2 つに分かれる**からです。

### Variant 1 — `s3-initcontainer` (the obvious implementation)

```yaml
  initContainers:
    - name: fetch-weights
      image: public.ecr.aws/aws-cli/aws-cli:latest
      command: ["bash", "-c"]
      args:
        - |
          aws s3 cp "s3://BUCKET/PREFIX/" /models/ --recursive --only-show-errors
      env:
        - name: AWS_MAX_CONCURRENT_REQUESTS
          value: "32"
      volumeMounts:
        - { name: models, mountPath: /models }
  containers:
    - name: vllm
      args: ["... --model /models ..."]        # vLLM's default safetensors loader
```

### Variant 2 — `runai-local` (change ONLY the loader)

```yaml
  initContainers: <unchanged>
  containers:
    - name: vllm
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model /models \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":16}' \
            ...
```

### Variant 3 — `runai-s3` (change ONLY the delivery)

```yaml
  # initContainers: REMOVED ENTIRELY
  containers:
    - name: vllm
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model s3://BUCKET/PREFIX \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":32}' \
            ...
```

| Comparison | Isolates / 切り分けるもの |
|---|---|
| 1 → 2 | **The loader only.** Identical bytes on identical disk, so the difference is what concurrent tensor streaming is worth on its own.<br>**ローダーのみ。** 同じディスクの同じバイト列なので、差は並列テンソルストリーミング単体の効果です。 |
| 2 → 3 | **The delivery only.** The copy step disappears.<br>**配送のみ。** コピー工程が消えます。 |

**Reporting them separately is what stops one effect being credited to the other.**

**別々に報告することが、一方の効果をもう一方の功績にしないための仕組みです。**

---

## Two things that will bite you / 必ず踏む 2 点

### 1. Credentials: use Pod Identity, not the node role

```yaml
spec:
  serviceAccountName: bench     # bound to an IAM role by EKS Pod Identity
```

Karpenter sets the IMDS **hop limit to 1**, so a container cannot reach instance
metadata at all. Using the node role fails with `Unable to locate credentials`.

Karpenter は IMDS の **hop limit を 1** にするため、コンテナはインスタンスメタデータに
到達できません。ノードロールを使うと `Unable to locate credentials` で失敗します。

**That default is correct — keep it.** Pods should not silently inherit node
permissions. Scoping a role to one service account is both the thing that works and
the thing to do in production. See `aws_eks_pod_identity_association` in
[`terraform/main.tf`](../terraform/main.tf).

**この既定は正しいので維持してください。** Pod がノードの権限を暗黙に継承すべきでは
ありません。サービスアカウント単位でロールを絞ることが、動く方法であり本番でも正しい方法です。

### 2. The init container serialises ahead of the image pull

kubelet pulls the init image, runs the init container, and **only then** pulls the
workload image. The copy and the image pull are **not overlapped**.

kubelet は init イメージを pull し、init コンテナを実行し、**その後で**本体イメージを
pull します。コピーと pull は**重なりません**。

**So moving weights out of the image can push start-to-Ready up even though the image
got smaller.** Variant 3 deletes that step rather than optimising it.

**つまりイメージからウェイトを出しても、イメージが小さくなったのに start-to-Ready が
伸びることがあります。** variant 3 はこの工程を最適化するのではなく削除します。

---

## Apply and run / 適用と実行

```bash
bin/check_runai.sh                          # confirm the image can do it at all
bin/show_config.sh weights
bin/bench.sh weights s3-initcontainer
bin/bench.sh weights runai-local
bin/bench.sh weights runai-s3
bin/report.py
```

`runai-streamer` and its S3 backend **already ship in the AWS vLLM Deep Learning
Container base image** — Apache-2.0, nothing to install, no licence to buy.
`check_runai.sh` verifies it in the tag you actually configured, on a node that
already has the image.

`runai-streamer` とその S3 バックエンドは **AWS vLLM Deep Learning Container の
ベースイメージに既に含まれています**（Apache-2.0、インストール不要、ライセンス購入不要）。
`check_runai.sh` は、実際に設定したタグについて、イメージを持つノード上で確認します。

---

## Verify / 検証

```bash
bin/verify_config.sh weights
```

It reads back which loader the pod actually started with, whether the model came from
`/models` or straight from `s3://`, **and the timing breakdown from vLLM's own log** —
which is the part that makes this step answerable.

Pod が実際にどのローダーで起動したか、モデルが `/models` からか `s3://` 直かを読み戻し、
**さらに vLLM 自身のログから内訳**を出します。この内訳がこのステップを答えの出るものに
しています。

---

## What you should conclude / ここで得る結論

The reference run produced a result that **contradicts the obvious expectation**, and
it is the most useful thing in this step.

参考計測は**素朴な期待に反する結果**を出しました。そしてそれがこのステップで最も有用な点です。

### Changing only the loader achieved nothing / ローダーだけの変更では何も起きなかった

Variant 1 → 2 did not move the total. The reason is in vLLM's log:

variant 1 → 2 で合計は動きませんでした。理由は vLLM のログにあります。

```
Loading weights took 0.31 seconds
torch.compile took 14.8 s in total
init engine (profile, create kv cache, warmup) took 28.2 s
Graph capturing finished in 4 secs
```

**Reading the weights was 0.31 seconds out of 96.** A faster way of reading them had
nothing to win.

**ウェイトの読み込みは 96 秒中 0.31 秒でした。** 速く読む手段に取り分がありませんでした。

> Shown as a before-and-after total alone, this would have read as "the tool does not
> work". The vLLM timings show it was **never given anything to do.** That distinction
> is worth more than a win would have been — it tells you *when* the tool would help.
>
> 前後の合計だけを見せていたら「このツールは効かない」と読めます。vLLM の内訳は
> **そもそも仕事が与えられていなかった**ことを示します。この区別は改善が出るより価値が
> あります。ツールが*いつ*効くのかが分かるからです。

### Changing the delivery did work, for a specific reason / 配送の変更は効いた、理由は明確

Variant 3 removed the init container: 96s → 82s. But note the model load went **up**,
0.63s → 3.36s — streaming from S3 is slower *per tensor* than reading local disk.

variant 3 は init コンテナを削除し 96 → 82 秒。ただしモデルロードは 0.63 → 3.36 秒と
**増えています**。S3 ストリーミングはテンソル単位ではローカルディスクより遅いのです。

**The gain is from deleting a step, not from doing it faster.**

**短縮の出所は工程の削除であり、高速化ではありません。**

### At this model size, compilation dominates / このサイズではコンパイルが支配的

`torch.compile` 14.7s + engine init 27.9s + graph capture 4s ≈ 47 of the 82 seconds.
**Neither a faster loader nor faster delivery touches any of that** — caching compiled
artifacts would.

`torch.compile` 14.7 秒 + engine init 27.9 秒 + graph capture 4 秒で、82 秒のうち約 47 秒。
**ローダーの高速化も配送の変更もここには触れません。** 効くのはコンパイル成果物の
キャッシュです。

### On a larger model this changes / 大きいモデルでは変わる

A 1.5B model is roughly a tenth of the 15 GB models Run:ai's own published benchmarks
use, where the loader does matter substantially. **Raise `MODEL_HF_REPO` in
`config.env` if you want to see the loader effect** — and if your real models are
large, expect your conclusion to differ from the reference run's.

1.5B モデルは Run:ai の公開ベンチマークが使う 15 GB 級の約 1/10 で、そちらではローダーが
明確に効きます。**ローダーの効果を見たい場合は `config.env` の `MODEL_HF_REPO` を
上げてください。** 実際のモデルが大きい場合、結論は参考計測と異なると想定してください。

---

## Time to first token / TTFT

`Ready` only means vLLM answers `/health`. It does not mean the server will produce a
token promptly. Each phase-2 run therefore also measures **submit to first token**:

`Ready` は vLLM が `/health` に応答することしか意味せず、速やかにトークンを出せることは
意味しません。そのため各実行では **submit から最初のトークンまで**も計測します。

```
  time to first token after Ready  0.65s
  submit to first token            82.6s   <- the number a user would feel
```

The probe ([`bin/first_token.py`](../bin/first_token.py)) streams a completion and
stops the clock on the first token carrying text. **Streaming matters:** without it the
only measurable thing is total latency, which is dominated by how many tokens you
asked for. It runs *inside* the pod via a ConfigMap, so there is no port-forward to be
flaky and no assumption about `curl` being in the image.

プローブはストリーミングで補完を要求し、テキストを含む最初のトークンで時計を止めます。
**ストリーミングが重要です。** 使わないと計測できるのは総レイテンシだけで、それは要求
トークン数に支配されます。ConfigMap 経由で Pod の**内側**で動くため、不安定な
port-forward も `curl` がイメージにある前提も不要です。

---

Back to / 戻る: [README](../README.md#section-5--what-to-adopt--何を採用するか)
