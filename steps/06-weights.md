# Step 6 — How the model weights reach GPU memory
# ステップ 6 — モデルウェイトが GPU メモリに届く経路

**Goal / 目的:** measure what determines startup time once the image pull is no longer
the largest stage. Includes Run:ai Model Streamer and time to first token.

イメージ pull が最大の段階でなくなった後、起動時間を決めるものを計測します。Run:ai Model
Streamer と time to first token を含みます。

---

## Preparation / 事前準備

```bash
# put MODEL_BUCKET from `terraform output -raw model_bucket` into config.env
snapshot/stage-model.sh
```

This downloads the model from Hugging Face and uploads it to S3, excluding the
`.bin` files, which are the same weights in an older format.

Hugging Face からモデルを取得して S3 にアップロードします。`.bin` ファイルは同じ
ウェイトの旧形式なので除外します。

> Use one `--exclude` flag per pattern. The flag takes a single value. If several
> values follow one flag, the CLI treats them as filenames to download, prints
> "Ignoring `--exclude` since filenames have being explicitly set", exits with status 0
> and downloads nothing.
>
> `--exclude` は 1 パターンごとに 1 つ指定してください。このフラグは値を 1 つ取ります。
> 1 つのフラグの後に値を複数並べると、CLI はそれらをダウンロード対象のファイル名として
> 扱い、"Ignoring `--exclude` since filenames have being explicitly set" を出力し、
> 終了ステータス 0 で何もダウンロードしません。

---

## The three variants / 3 通りの構成

The pod spec, node, model and bytes are the same in all three. The vLLM arguments
differ. There are three rather than two because the loader and the delivery method are
separate variables.

Pod spec、ノード、モデル、バイト列は 3 つとも同じで、vLLM の引数が異なります。3 つある
のは、ローダーと配送方法が別々の変数だからです。

### Variant 1 — `s3-initcontainer`

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

### Variant 2 — `runai-local` (the loader differs from variant 1)

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

### Variant 3 — `runai-s3` (the delivery differs from variant 2)

```yaml
  # no initContainers
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

| Comparison | What it isolates / 切り分ける対象 |
|---|---|
| 1 to 2 | The loader. The bytes and the disk are the same, so the difference is the effect of concurrent tensor streaming.<br>ローダー。バイト列とディスクは同じなので、差は並列テンソルストリーミングの効果です。 |
| 2 to 3 | The delivery. The copy step is removed.<br>配送。コピー工程が無くなります。 |

Reporting the two comparisons separately shows which of the two changes produced any
difference in the total.

2 つの比較を別に報告することで、合計の差がどちらの変更によるものかが分かります。

---

## Two configuration details / 設定上の 2 点

### 1. Credentials come from Pod Identity

```yaml
spec:
  serviceAccountName: bench     # bound to an IAM role by EKS Pod Identity
```

Karpenter sets the IMDS hop limit to 1, so a container cannot reach instance metadata.
Using the node role results in `Unable to locate credentials`. The hop limit prevents
pods from using node permissions, and binding a role to a service account is the
approach to use in production. See `aws_eks_pod_identity_association` in
[`terraform/main.tf`](../terraform/main.tf).

Karpenter は IMDS の hop limit を 1 に設定するため、コンテナはインスタンスメタデータに
到達できません。ノードロールを使うと `Unable to locate credentials` になります。この
hop limit は Pod がノードの権限を使うことを防ぐもので、サービスアカウントにロールを紐付ける
方法は本番でも使えます。

### 2. The init container runs before the image pull

kubelet pulls the init image, runs the init container, and then pulls the workload
image. The copy and the image pull do not overlap.

kubelet は init イメージを pull し、init コンテナを実行し、その後で本体イメージを pull
します。コピーと pull は重なりません。

Because of this, moving weights out of the image can increase start-to-Ready time even
though the image is smaller. Variant 3 removes the copy step.

このため、イメージからウェイトを出してイメージが小さくなっても start-to-Ready が伸びる
場合があります。variant 3 はコピー工程を無くします。

---

## Apply and run / 適用と実行

```bash
bin/check_runai.sh                          # checks the image supports it
bin/show_config.sh weights
bin/bench.sh weights s3-initcontainer
bin/bench.sh weights runai-local
bin/bench.sh weights runai-s3
bin/report.py
```

`runai-streamer` and its S3 backend are included in the AWS vLLM Deep Learning
Container base image. It is Apache-2.0 licensed, so no installation or licence is
required. `check_runai.sh` checks the tag you configured, using a node that already has
the image.

`runai-streamer` とその S3 バックエンドは AWS vLLM Deep Learning Container のベース
イメージに含まれています。Apache-2.0 ライセンスで、インストールもライセンス取得も不要です。
`check_runai.sh` は、イメージを持っているノードを使って、設定したタグを確認します。

---

## Verify / 検証

```bash
bin/verify_config.sh weights
```

This reports which loader the pod started with, whether the model was read from
`/models` or from `s3://`, and the startup timings from vLLM's log.

Pod がどのローダーで起動したか、モデルを `/models` から読んだか `s3://` から読んだか、
および vLLM のログに出ている起動時間の内訳を報告します。

---

## What the figures show / 数字から分かること

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` | 96s | 0.65s | 96.6s |
| `runai-local` | 93s | 0.65s | 93.6s |
| `runai-s3` | 82s | 0.65s | 82.6s |

### Changing the loader did not change the total

Variants 1 and 2 produced the same total. vLLM's log gives the reason:

variant 1 と 2 の合計は同じでした。理由は vLLM のログに出ています。

```
Loading weights took 0.31 seconds
torch.compile took 14.8 s in total
init engine (profile, create kv cache, warmup) took 28.2 s
Graph capturing finished in 4 secs
```

Reading the weights took 0.31 seconds out of 96. A loader that reads them faster can
only affect that 0.31 seconds. Without these log lines the comparison would show only
that the total did not change, which does not indicate whether the loader was slow or
whether reading the weights was already a small part of the startup time.

ウェイトの読み込みは 96 秒中 0.31 秒でした。より速く読むローダーが影響できるのはこの
0.31 秒だけです。このログが無ければ、比較から分かるのは合計が変わらなかったことだけで、
ローダーが遅いのか、ウェイト読み込みが元から起動時間のごく一部なのかは判別できません。

### Changing the delivery reduced the total

Variant 3 removed the init container and the total went from 96 to 82 seconds. The model
load time increased from 0.63 to 3.36 seconds, so reading from S3 is slower per tensor
than reading from local disk. The reduction comes from removing the copy step, which
took about 10 seconds.

variant 3 は init コンテナを無くし、合計は 96 秒から 82 秒になりました。モデルロード時間は
0.63 秒から 3.36 秒に増えており、S3 からの読み込みはテンソル単位ではローカルディスクより
遅くなっています。短縮分は、約 10 秒かかっていたコピー工程が無くなったことによります。

### Compilation and warmup were the largest components

`torch.compile` at 14.7 seconds, engine init at 27.9 seconds and graph capture at 4
seconds account for about 47 of the 82 seconds. Neither the loader nor the delivery
method affects these. Caching compiled artifacts would.

`torch.compile` が 14.7 秒、engine init が 27.9 秒、graph capture が 4 秒で、82 秒のうち
約 47 秒を占めます。ローダーも配送方法もこれには影響しません。影響するのはコンパイル
成果物のキャッシュです。

### At a larger model size / モデルが大きい場合

The model used here is 1.5B parameters, about 2.9 GB. Run:ai's published benchmarks use
a 15 GB model, where the loader accounts for a larger share of the startup time. Set
`MODEL_HF_REPO` in `config.env` to a larger model to measure that case. If the models
you run are large, the result may differ from the one above.

ここで使うモデルは 1.5B パラメータ、約 2.9 GB です。Run:ai の公開ベンチマークは 15 GB の
モデルを使っており、そちらではローダーが起動時間に占める割合が大きくなります。その場合を
計測するには `config.env` の `MODEL_HF_REPO` を大きいモデルに設定してください。運用する
モデルが大きい場合、結果は上記と異なる可能性があります。

---

## Time to first token / TTFT

A pod reaching Ready means vLLM responds to `/health`. It does not indicate how soon the
server produces a token. Each phase 2 run also measures the interval from submit to
first token.

Pod が Ready になることは vLLM が `/health` に応答することを意味し、トークンをどれだけ
早く出せるかは示しません。フェーズ 2 の各実行では submit から最初のトークンまでも計測
します。

The probe ([`bin/first_token.py`](../bin/first_token.py)) requests a streamed completion
and stops timing at the first token containing text. Streaming is used because without
it the measurable interval is total latency, which depends on the number of tokens
requested. The probe runs inside the pod, loaded as a ConfigMap, so it does not require
a port-forward or `curl` in the image.

プローブ（[`bin/first_token.py`](../bin/first_token.py)）はストリーミングで補完を要求し、
テキストを含む最初のトークンで計測を止めます。ストリーミングを使うのは、使わない場合に
計測できるのが総レイテンシで、要求トークン数に依存するためです。プローブは ConfigMap として
Pod 内で動くため、port-forward もイメージ内の `curl` も不要です。

---

Back to / 戻る: [README](../README.md#section-5--what-to-adopt--何を採用するか)
