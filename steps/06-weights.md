# Step 6 — How the model weights reach GPU memory

**English** | [日本語](#japanese)

Steps 1 to 4 made the image pull smaller. This step measures what is left after that. For an
inference server, the remaining work is getting the model weights into GPU memory. Three
variants are run, one of them with Run:ai Model Streamer. Each run also measures the time until
the server produces its first token.

---

## Preparation

```bash
snapshot/stage-model.sh
```

The bucket is found by its `Purpose` tag. Set `MODEL_BUCKET` in `config.env` to override it.

This submits a Job that downloads the model from Hugging Face and uploads it to S3, then
follows its log. The download and the upload run on a node. Nothing has to be installed on your
machine, and the weights do not travel over your connection. The Job skips the `.bin` files.
Those hold the same weights in an older format, so including them would double the transfer.

The Job runs under its own service account, `stage-model`, which is bound to a role that can
write to the bucket. The measured pods use `bench`, whose role is read-only. A measured pod
therefore cannot write to the bucket it reads from.

> If you adapt this script, give each exclude pattern its own `--exclude` flag. The flag takes
> one value. If several values follow one flag, the CLI treats the extra ones as names of files
> to download, prints "Ignoring `--exclude` since filenames have being explicitly set", and
> exits with status 0 having downloaded nothing. The status of 0 makes the failure easy to miss.

---

## The three variants

All three run on the same node, with the same pod spec, the same model and the same number of
bytes. Only the vLLM arguments change.

Two things can be changed independently here. One is the loader, the code that reads the
safetensors files. The other is where the loader reads from: a local disk that the files were
copied to first, or S3. Each variant changes one of the two. A difference between two variants
can then be attributed to the one thing that differs.

| Variant | Loader | Reads from | Init container |
|---|---|---|---|
| `s3-initcontainer` | vLLM default | `/models` on local disk | yes |
| `runai-local` | Run:ai Model Streamer | `/models` on local disk | yes |
| `runai-s3` | Run:ai Model Streamer | `s3://BUCKET/PREFIX` | no |

Variants 1 and 2 have the same init container and both read from local disk. The only difference
is `--load-format`. Read the variant names against this table. `s3-initcontainer` is named after
how the weights arrive, and the other two are named after the loader, so the names sit on
different axes.

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

### Variant 2 — `runai-local` (a different loader from variant 1)

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

### Variant 3 — `runai-s3` (a different source from variant 2)

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

| Comparison | What changes | What it isolates |
|---|---|---|
| 1 to 2 | The loader | The same bytes are on the same disk in both. A difference comes from reading them concurrently. |
| 2 to 3 | Where the loader reads from | The copy step is gone. A difference comes from reading over the network. |

The report keeps the two comparisons apart. Combined, the saving from removing the copy would
look like evidence that the loader is faster.

---

## Configuration that is easy to get wrong

### 1. Credentials come from Pod Identity

```yaml
spec:
  serviceAccountName: bench     # bound to an IAM role by EKS Pod Identity
```

The obvious approach is to give the node role access to the bucket and let the container read
credentials from instance metadata. That fails on a Karpenter node. Karpenter sets the IMDS hop
limit to 1, a request from inside a container is one hop too far, and the AWS SDK reports
`Unable to locate credentials`.

Keep the hop limit at 1. It prevents a pod from using the node's permissions. Bind an IAM role
to a service account instead. That is also the approach to use in production. The binding is
`aws_eks_pod_identity_association` in [`terraform/main.tf`](../terraform/main.tf).

### 2. The init container delays the workload image pull

kubelet pulls the init container's image, runs the init container to completion, and then pulls
the workload image. The copy and the workload image pull never overlap.

The usual reasoning says that moving the weights out of the container image makes the image
smaller, and that a smaller image pulls faster. Both are true. But if an init container then
fetches the weights, that fetch happens before the workload pull begins, and start-to-Ready can
come out higher than it was with the weights in the image. Variant 3 has no init container, so
vLLM reads the weights after the workload image has already been pulled.

---

## Apply and run

```bash
bin/check_runai.sh                          # checks the image supports it
bin/show_config.sh weights
bin/bench.sh weights s3-initcontainer
bin/bench.sh weights runai-local
bin/bench.sh weights runai-s3
bin/report.py
```

Nothing needs installing. `runai-streamer` and its S3 backend are already in the AWS vLLM Deep
Learning Container base image, and the project is Apache-2.0 licensed. `check_runai.sh`
confirms it is present in the tag you configured. It runs against a node that already has the
image, so the check takes seconds.

---

## Verify

```bash
bin/verify_config.sh weights
```

It checks three things against the run:

- which loader vLLM started with
- whether the weights came from `/models` or from `s3://`
- the startup timings in vLLM's own log

---

## What the figures show

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` | 95s | 0.66s | 95.7s |
| `runai-local` | 92s | 0.66s | 92.7s |
| `runai-s3` | 84s | 0.66s | 84.7s |

### Changing the loader moved the total by 3 seconds

Variants 1 and 2 came out at 95 and 92 seconds. That gap is inside the run-to-run variation
described in [REFERENCE-RESULTS.md](../REFERENCE-RESULTS.md), so it is not a result on its own.
vLLM's log gives the reason there was so little to gain:

```
Loading weights took 0.30 seconds
Model loading took 2.98 GiB memory and 0.616735 seconds
torch.compile took 14.75 s in total
Graph capturing finished in 4 secs
init engine (profile, create kv cache, warmup model) took 28.01 s (compilation: 14.75 s)
```

Reading the weights took 0.30 seconds of a 95-second startup. A faster loader can only reduce
those 0.30 seconds.

On the totals alone, this reads as Run:ai Model Streamer having no effect. The log adds that at
this model size the loader was not the constraint. On a model where reading the weights takes
tens of seconds, the same change could produce a different result.

### Changing the source reduced the total

Variant 3 removed the init container, and the total came down from 95 seconds to 84.

What disappeared was the copy step. It took around 11 seconds, and it ran before the workload
image pull. Reading the weights itself got slower: the model load time went from 0.62 seconds
to 2.71, because reading from S3 is slower per tensor than reading from a local disk.

### Engine initialisation was the largest component

Engine initialisation took 28.0 of the 84 seconds.

The log lines above are nested. vLLM says so on the line itself:

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

The 14.76 seconds of `torch.compile` and the 4 seconds of graph capture happen inside those
28.0 seconds. Adding all three would count compilation twice.

Nothing in this step affects engine initialisation. Reusing compiled artifacts affects part of
it, up to the 14.76 seconds of compilation. The profiling, KV-cache creation and warmup that
make up the rest remain. Compilation is the largest item still open at the end of this step,
and [step 7](07-compile-cache.md) measures it.

### At a larger model size

The model used here is 1.5B parameters, about 2.9 GB. Run:ai's published benchmarks use a
15 GB model, where the loader accounts for a larger share of the startup time. Set
`MODEL_HF_REPO` in `config.env` to a larger model to measure that case. If the models you
run are large, your result may differ from the one above.

### How the weights get to the node

One part of the path is set up by Terraform. The download figures assume it is there.

The VPC has private subnets and a single NAT gateway, and it also has an S3 Gateway VPC
endpoint. The endpoint adds a route for the regional S3 prefix list to the private route
tables. That route is more specific than the default route, so S3 traffic takes it and does not
go through NAT. This applies to the weights here and to the container image layers in the
earlier steps, because ECR stores layers in S3.

The endpoint removes the NAT data-processing charge and the dependency on NAT.

It does not make the download faster. At the rate one node pulls here, NAT was far from its
limit. The endpoint matters when many nodes scale out through a single NAT gateway at the same
time. It does not change anything about encryption either, because both paths can use HTTPS.

Taking the image pull off NAT completely needs more than the gateway endpoint. The endpoint
covers the layer download, but the registry API calls do not go to S3. Those need `ecr.api` and
`ecr.dkr` interface endpoints, which are billed per hour and per GB. The gateway endpoint is
free.

---

## Time to first token

A pod reaching Ready means vLLM responds to `/health`. It does not tell you how soon the server
produces a token. Each phase 2 run also measures the interval from submit to first token.

The probe ([`bin/first_token.py`](../bin/first_token.py)) requests a streamed completion and
stops timing at the first token containing text. Without streaming, the measurable interval is
total latency, which depends on the number of tokens requested. The probe runs inside the pod,
loaded as a ConfigMap, so it needs no port-forward and no `curl` in the image.

---

Back to: [README](../README.md#what-to-adopt)

<br>

---
---

<a id="japanese"></a>

# ステップ 6 — モデルウェイトが GPU メモリに届く経路

[English](#step-6--how-the-model-weights-reach-gpu-memory) | **日本語**

ステップ 1 から 4 でイメージ pull は小さくなりました。このステップでは、その後に何が残るかを
計測します。推論サーバーの場合、残る作業はモデルウェイトを GPU メモリに載せることです。3 通りの
構成を実行し、そのうち 1 つで Run:ai Model Streamer を使います。各実行では、サーバーが最初の
トークンを出すまでの時間も計測します。

---

## 事前準備

```bash
snapshot/stage-model.sh
```

バケットは `Purpose` タグから特定されます。`config.env` の `MODEL_BUCKET` で上書きできます。

Hugging Face からモデルを取得して S3 にアップロードする Job を投入し、そのログを追跡します。
ダウンロードとアップロードはノード上で動きます。手元のマシンに何かをインストールする必要はなく、
ウェイトが手元の回線を通ることもありません。Job は `.bin` ファイルを除外します。これは同じウェイト
の旧形式なので、含めると転送量が倍になります。

Job は専用のサービスアカウント `stage-model` で動きます。これはバケットへ書き込めるロールに紐付いて
います。計測対象の Pod は `bench` を使い、そのロールは読み取り専用です。したがって計測対象の Pod は、
自分が読むバケットに書き込めません。

> このスクリプトを流用する場合、除外パターンは 1 つごとに `--exclude` を付けてください。この
> フラグが取る値は 1 つです。1 つのフラグの後に値を複数並べると、CLI は 2 つ目以降をダウンロード
> 対象のファイル名として扱い、"Ignoring `--exclude` since filenames have being explicitly set"
> を出力し、何もダウンロードせずステータス 0 で終了します。ステータスが 0 なので、この失敗は
> 気づきにくいです。

---

## 3 通りの構成

3 つとも同じノード上で、同じ Pod spec、同じモデル、同じバイト数で実行します。変わるのは vLLM
の引数だけです。

ここで変えられるものは独立に 2 つあります。1 つはローダー、つまり safetensors ファイルを読む
コードです。もう 1 つはローダーがどこから読むかで、先にファイルをコピーしたローカルディスクか、
S3 かです。各構成では 2 つのうち片方だけを変えます。そうすると、構成間の差を、異なっている 1 点に
帰属できます。

| variant | ローダー | 読み出し元 | init コンテナ |
|---|---|---|---|
| `s3-initcontainer` | vLLM 既定 | ローカルディスクの `/models` | あり |
| `runai-local` | Run:ai Model Streamer | ローカルディスクの `/models` | あり |
| `runai-s3` | Run:ai Model Streamer | `s3://BUCKET/PREFIX` | なし |

variant 1 と 2 は init コンテナも同じで、どちらもローカルディスクから読みます。違いは
`--load-format` だけです。variant 名はこの表と合わせて見てください。`s3-initcontainer` は
ウェイトの届き方を名前にしており、他の 2 つはローダーを名前にしています。名前の付け方の軸が
揃っていません。

### variant 1 — `s3-initcontainer`

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
      args: ["... --model /models ..."]        # vLLM 既定の safetensors ローダー
```

### variant 2 — `runai-local`（variant 1 とローダーが異なる）

```yaml
  initContainers: <変更なし>
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

### variant 3 — `runai-s3`（variant 2 と読み出し元が異なる）

```yaml
  # initContainers なし
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

| 比較 | 変わるもの | 切り分けられること |
|---|---|---|
| 1 から 2 | ローダー | どちらも同じバイト列が同じディスク上にあります。差は、テンソルを並列に読むことから生じます。 |
| 2 から 3 | ローダーの読み出し元 | コピー工程が無くなります。差は、ネットワーク越しに読むことから生じます。 |

レポートはこの 2 つの比較を分けて出します。まとめると、コピー工程を無くしたことによる短縮が、
ローダーが速いことの根拠に見えてしまいます。

---

## 設定で間違えやすいところ

### 1. 認証情報は Pod Identity から取得する

```yaml
spec:
  serviceAccountName: bench     # EKS Pod Identity で IAM ロールに紐付け
```

思いつきやすいのは、ノードロールにバケットへのアクセスを与え、コンテナがインスタンスメタデータ
から認証情報を取得する方法です。これは Karpenter のノードでは動きません。Karpenter が IMDS の
hop limit を 1 に設定し、コンテナ内からのリクエストは 1 hop 超過になり、AWS SDK は
`Unable to locate credentials` を返します。

hop limit は 1 のままにしてください。これは Pod がノードの権限を使うことを防いでいます。代わりに
IAM ロールをサービスアカウントに紐付けます。本番でもこの方法を使います。紐付けは
[`terraform/main.tf`](../terraform/main.tf) の `aws_eks_pod_identity_association` です。

### 2. init コンテナは本体イメージの pull を遅らせる

kubelet は init コンテナのイメージを pull し、init コンテナを完了まで実行し、それから本体イメージ
を pull します。コピーと本体イメージの pull が重なることはありません。

通常の考え方では、コンテナイメージからウェイトを出すとイメージは小さくなり、小さいイメージは速く
pull できます。どちらも正しいです。ただし init コンテナでウェイトを取得すると、その取得は本体の
pull が始まる前に行われるため、start-to-Ready はウェイトをイメージに含めていたときより長くなる
ことがあります。variant 3 には init コンテナがないので、vLLM は本体イメージの pull が済んだ状態で
ウェイトを読みます。

---

## 適用と実行

```bash
bin/check_runai.sh                          # イメージが対応しているか確認
bin/show_config.sh weights
bin/bench.sh weights s3-initcontainer
bin/bench.sh weights runai-local
bin/bench.sh weights runai-s3
bin/report.py
```

インストールは不要です。`runai-streamer` とその S3 バックエンドは AWS vLLM Deep Learning
Container のベースイメージに含まれており、Apache-2.0 ライセンスです。`check_runai.sh` は、設定した
タグにそれが含まれていることを確認します。イメージを既に持っているノードに対して実行するので、
数秒で終わります。

---

## 検証

```bash
bin/verify_config.sh weights
```

実行結果に対して 3 点を確認します。

- vLLM がどのローダーで起動したか
- ウェイトが `/models` から来たか、`s3://` から来たか
- vLLM 自身のログに出ている起動時間の内訳

---

## 数字から分かること

| Variant | Ready | Ready 後の TTFT | submit から最初のトークンまで |
|---|---:|---:|---:|
| `s3-initcontainer` | 95s | 0.66s | 95.7s |
| `runai-local` | 92s | 0.66s | 92.7s |
| `runai-s3` | 84s | 0.66s | 84.7s |

### ローダーを変えても合計は 3 秒しか動かなかった

variant 1 と 2 の合計は 95 秒と 92 秒でした。この差は
[REFERENCE-RESULTS.md](../REFERENCE-RESULTS.md) に書いてある実行ごとのばらつきの範囲内なので、
これ自体は結果になりません。得られる余地が小さかった理由は vLLM のログに出ています。

```
Loading weights took 0.30 seconds
Model loading took 2.98 GiB memory and 0.616735 seconds
torch.compile took 14.75 s in total
Graph capturing finished in 4 secs
init engine (profile, create kv cache, warmup model) took 28.01 s (compilation: 14.75 s)
```

ウェイトの読み込みは、95 秒の起動のうち 0.30 秒でした。より速いローダーが短縮できるのは、この
0.30 秒だけです。

合計だけを見ると、Run:ai Model Streamer には効果がないと読めます。ログから分かるのは、この
モデルサイズではローダーが制約になっていなかったことです。ウェイトの読み込みに数十秒かかる
モデルなら、同じ変更で結果は変わりえます。

### 読み出し元を変えると合計が短縮された

variant 3 は init コンテナを無くし、合計は 95 秒から 84 秒になりました。

無くなったのはコピー工程です。これは約 11 秒かかり、本体イメージの pull より前に実行されて
いました。ウェイトの読み込み自体は遅くなっており、モデルロード時間は 0.62 秒から 2.71 秒に
増えています。S3 からの読み込みは、テンソル単位ではローカルディスクより遅いためです。

### 最大の要素は engine init だった

engine init が 84 秒のうち 28.0 秒でした。

上記のログ行は入れ子になっています。vLLM がその行自体に書いています。

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

`torch.compile` の 14.76 秒と graph capture の 4 秒は、この 28.0 秒の内側で起きています。3 つを
足すと、コンパイル時間を二重に数えます。

このステップで変えたものは、engine init に影響しません。コンパイル成果物の再利用は、その一部で
あるコンパイルの 14.76 秒までに影響します。残りを占める profiling、KV cache 作成、warmup は
そのままです。このステップの終了時点で最大の未解決項目はコンパイルであり、
[ステップ 7](07-compile-cache.md) で計測します。

### モデルが大きい場合

ここで使うモデルは 1.5B パラメータ、約 2.9 GB です。Run:ai の公開ベンチマークは 15 GB の
モデルを使っており、そちらではローダーが起動時間に占める割合が大きくなります。その場合を
計測するには `config.env` の `MODEL_HF_REPO` を大きいモデルに設定してください。運用する
モデルが大きい場合、結果は上記と異なる可能性があります。

### ウェイトがノードに届く経路

この経路のうち 1 箇所は Terraform が用意しています。ダウンロードの数字はこれを前提にしています。

VPC にはプライベートサブネットと NAT ゲートウェイ 1 つがあり、加えて S3 Gateway VPC エンド
ポイントがあります。エンドポイントは、リージョンの S3 プレフィックスリスト向けのルートを
プライベートルートテーブルに追加します。このルートはデフォルトルートより具体的なので、S3 の通信は
こちらを通り、NAT を通りません。これはここでのウェイトにも、前のステップのコンテナイメージの
レイヤにも当てはまります。ECR がレイヤを S3 に保存しているためです。

エンドポイントによって、NAT のデータ処理料金がかからなくなり、NAT への依存も無くなります。

ダウンロードは速くなりません。ここで 1 台のノードが取得する速度では、NAT は能力の
限界からかなり離れています。エンドポイントが効くのは、多数のノードが 1 つの NAT ゲートウェイを
通って同時にスケールアウトする場合です。暗号化についても変わりません。どちらの経路でも HTTPS を
使えます。

イメージ pull を完全に NAT から外すには、ゲートウェイエンドポイントだけでは足りません。
エンドポイントはレイヤのダウンロードをカバーしますが、レジストリの API 呼び出しは S3 宛てでは
ありません。こちらには `ecr.api` と `ecr.dkr` のインターフェイスエンドポイントが必要で、これは
時間課金とデータ課金が発生します。ゲートウェイエンドポイントは無料です。

---

## time to first token

Pod が Ready になることは、vLLM が `/health` に応答することを意味します。トークンをどれだけ早く
出せるかは分かりません。フェーズ 2 の各実行では、submit から最初のトークンまでも計測します。

プローブ（[`bin/first_token.py`](../bin/first_token.py)）はストリーミングで補完を要求し、
テキストを含む最初のトークンで計測を止めます。ストリーミングを使わない場合、計測できるのは
総レイテンシで、これは要求トークン数に依存します。プローブは ConfigMap として Pod 内で動くので、
port-forward もイメージ内の `curl` も不要です。

---

戻る: [README](../README.md#何を採用するか)
