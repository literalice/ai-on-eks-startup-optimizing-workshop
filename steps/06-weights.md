# Step 6 — How the model weights reach GPU memory

**English** | [日本語](#japanese)

Steps 1 to 4 made the image pull smaller. This step measures what is left once the pull is no
longer the largest stage, which for an inference server is the work of getting the model
weights into GPU memory. Three variants are run, one of which uses Run:ai Model Streamer, and
each run also measures the time until the server produces its first token.

---

## Preparation

```bash
snapshot/stage-model.sh
```

The bucket is found by its `Purpose` tag. Set `MODEL_BUCKET` in `config.env` to override it.

This submits a Job that downloads the model from Hugging Face and uploads it to S3, then
follows its log. The download and the upload happen on a node rather than on your machine, so
nothing has to be installed locally for it and the weights do not travel via your connection.
The Job skips the `.bin` files, because those hold the same weights in an older format and
would double the transfer for no benefit.

It runs under its own service account, `stage-model`, which is bound to a role that can write
to the bucket. The measured pods use `bench`, whose role is read-only. Keeping them apart means
a measured pod cannot write to the bucket it reads from.

> If you adapt this script, give each exclude pattern its own `--exclude` flag. The flag takes
> one value. When several values follow a single flag, the CLI reads the extra ones as names of
> files to download instead, prints "Ignoring `--exclude` since filenames have being explicitly
> set", and exits with status 0 having downloaded nothing. The exit code makes this easy to
> miss.

---

## The three variants

All three run on the same node, with the same pod spec, the same model and the same number of
bytes. Only the vLLM arguments change between them.

There are three variants rather than two because two independent things can be changed here.
One is the loader, meaning the code that reads the safetensors files. The other is the
delivery, meaning whether those files are copied to local disk first or read from S3 as the
loader needs them. Changing both at once would leave no way to tell which of the two moved the
result, so each variant changes one of them.

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

| Comparison | What changes | What it isolates |
|---|---|---|
| 1 to 2 | The loader only | The same bytes sit on the same disk in both, so any difference comes from reading them concurrently rather than one tensor at a time. |
| 2 to 3 | The delivery only | The copy step is removed, so any difference comes from where the loader reads from. |

The report keeps these two comparisons apart. If they were combined, an improvement from
removing the copy could be read as evidence that the loader is faster, or the other way
around.

---

## Two things about the configuration that are easy to get wrong

### 1. Credentials come from Pod Identity, not from the node role

```yaml
spec:
  serviceAccountName: bench     # bound to an IAM role by EKS Pod Identity
```

The obvious approach is to give the node role access to the bucket and let the container pick
up credentials from instance metadata. That does not work on a Karpenter node, because
Karpenter sets the IMDS hop limit to 1. With a hop limit of 1, a request from inside a
container is one hop too far, so the container cannot reach the metadata service and the AWS
SDK reports `Unable to locate credentials`.

The hop limit is worth keeping. It is what stops a pod from borrowing the node's permissions.
Binding a role to a service account instead is both what makes this work here and what to do
in production. The binding is `aws_eks_pod_identity_association` in
[`terraform/main.tf`](../terraform/main.tf).

### 2. The init container delays the workload image pull

kubelet does these in order: it pulls the init container's image, runs the init container to
completion, and only then pulls the workload image. The copy and the image pull never overlap.

This has a consequence worth stating plainly, because it runs against the usual reasoning.
Moving the weights out of the container image makes the image smaller, and a smaller image
pulls faster. But if the weights are then fetched by an init container, the time saved on the
pull is spent before the pull starts, and start-to-Ready can come out higher than it was with
the weights baked in. Variant 3 avoids this by removing the init container: vLLM reads the
weights itself, while the workload image has already been pulled.

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

There is nothing to install for this. `runai-streamer` and its S3 backend are already in the
AWS vLLM Deep Learning Container base image, and the project is Apache-2.0 licensed, so no
licence is needed either. `check_runai.sh` confirms it is present in the specific tag you
configured, and it runs against a node that already has the image so that the check takes
seconds rather than a multi-gigabyte pull.

---

## Verify

```bash
bin/verify_config.sh weights
```

This reads back three things from the run rather than assuming them: which loader the pod
actually started with, whether the model came from `/models` or straight from `s3://`, and the
startup timings that vLLM itself logged.

---

## What the figures show

| Variant | Ready | TTFT after Ready | Submit to first token |
|---|---:|---:|---:|
| `s3-initcontainer` | 95s | 0.66s | 95.7s |
| `runai-local` | 92s | 0.66s | 92.7s |
| `runai-s3` | 84s | 0.66s | 84.7s |

### Changing the loader did not change the total

Variants 1 and 2 produced the same total. vLLM's log gives the reason:

```
Loading weights took 0.30 seconds
Model loading took 2.98 GiB memory and 0.616735 seconds
torch.compile took 14.75 s in total
Graph capturing finished in 4 secs
init engine (profile, create kv cache, warmup model) took 28.01 s (compilation: 14.75 s)
```

Reading the weights took 0.30 seconds of a 95-second startup. A loader that reads them faster
has only those 0.30 seconds to work with, so there was very little for it to improve.

This is why the log lines matter more than the total here. On the totals alone, the result
looks like a claim that Run:ai Model Streamer does not help. The log shows something different:
at this model size the loader was never the constraint, and the same change on a model where
weight reading takes tens of seconds could look quite different.

### Changing the delivery reduced the total

Variant 3 removed the init container, and the total came down from 95 seconds to 84.

The saving did not come from reading the weights faster. It came from removing a step. In fact
the model load time went up, from 0.62 seconds to 2.71, because reading from S3 is slower per
tensor than reading from a local disk. What disappeared was the copy, which took around 11
seconds and, as described above, ran before the workload image pull rather than alongside it.

### Engine initialisation was the largest component

Engine initialisation took 28.0 of the 84 seconds.

Read that figure carefully, because the log lines above are nested rather than additive. vLLM
states the nesting on the line itself:

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

The 14.76 seconds of `torch.compile` and the 4 seconds of graph capture happen inside those
28.0 seconds. They are not three stages to add together, and adding them would count
compilation twice.

Nothing in this step affects that stage. Neither loader touches it and neither delivery method
touches it. Reusing compiled artifacts affects part of it, up to the 14.76 seconds of
compilation, and leaves the profiling, KV-cache creation and warmup that account for the
remainder. That makes compilation the largest item still open at the end of this step, and
[step 7](07-compile-cache.md) measures it.

### At a larger model size

The model used here is 1.5B parameters, about 2.9 GB. Run:ai's published benchmarks use a
15 GB model, where the loader accounts for a larger share of the startup time. Set
`MODEL_HF_REPO` in `config.env` to a larger model to measure that case. If the models you
run are large, the result may differ from the one above.

### How the weights get to the node

One part of the path is set up by Terraform rather than by anything in this step, and it is
worth knowing it is there before reading the download figures.

The VPC has private subnets and a single NAT gateway, and it also has an S3 Gateway VPC
endpoint. The endpoint adds a route for the regional S3 prefix list to the private route
tables. That route is more specific than the default route, so it wins, and S3 traffic does not
go through NAT. This applies to the weights here, and also to the container image layers in the
earlier steps, because ECR stores layers in S3.

What it removes is the NAT data-processing charge and the dependency on NAT.

It does not promise a faster download. At the rate a single node pulls here, NAT was never close
to its limit, and the case where the endpoint matters is many nodes scaling out through one NAT
gateway at the same time. It also does not change an unencrypted connection into an encrypted
one, since both paths can use HTTPS.

If the goal is to take the image pull off NAT completely, the gateway endpoint is not
sufficient on its own. It covers the layer download, but the registry API calls do not go to
S3. Those need `ecr.api` and `ecr.dkr` interface endpoints, which are billed per hour and per
GB, unlike the gateway endpoint which is free.

---

## Time to first token

A pod reaching Ready means vLLM responds to `/health`. It does not indicate how soon the
server produces a token. Each phase 2 run also measures the interval from submit to first
token.

The probe ([`bin/first_token.py`](../bin/first_token.py)) requests a streamed completion and
stops timing at the first token containing text. Streaming is used because without it the
measurable interval is total latency, which depends on the number of tokens requested. The
probe runs inside the pod, loaded as a ConfigMap, so it does not require a port-forward or
`curl` in the image.

---

Back to: [README](../README.md#what-to-adopt)

<br>

---
---

<a id="japanese"></a>

# ステップ 6 — モデルウェイトが GPU メモリに届く経路

[English](#step-6--how-the-model-weights-reach-gpu-memory) | **日本語**

ステップ 1 から 4 でイメージ pull は小さくなりました。このステップでは、pull が最大の段階で
なくなった後に何が残るかを計測します。推論サーバーの場合、それはモデルウェイトを GPU メモリに
載せるまでの作業です。3 通りの構成を実行し、そのうち 1 つで Run:ai Model Streamer を使います。
また各実行では、サーバーが最初のトークンを出すまでの時間も計測します。

---

## 事前準備

```bash
snapshot/stage-model.sh
```

バケットは `Purpose` タグから特定されます。`config.env` の `MODEL_BUCKET` で上書きできます。

Hugging Face からモデルを取得して S3 にアップロードする Job を投入し、そのログを追跡します。
ダウンロードとアップロードは手元のマシンではなくノード上で行われるため、このためにローカルに
インストールするものはなく、ウェイトが手元の回線を通ることもありません。Job は `.bin` ファイルを
除外します。同じウェイトの旧形式であり、含めても転送量が倍になるだけで得るものがないためです。

Job は専用のサービスアカウント `stage-model` で動き、これはバケットへ書き込めるロールに紐付いて
います。計測対象の Pod が使う `bench` のロールは読み取り専用です。分けておくことで、計測対象の
Pod が自分が読むバケットに書き込めない状態を保てます。

> このスクリプトを流用する場合、除外パターンは 1 つごとに `--exclude` を付けてください。この
> フラグが取る値は 1 つです。1 つのフラグの後に値を複数並べると、CLI は 2 つ目以降をダウンロード
> 対象のファイル名として読み、"Ignoring `--exclude` since filenames have being explicitly set"
> を出力して、何もダウンロードせずステータス 0 で終了します。終了コードが 0 なので気づきにくい
> 失敗です。

---

## 3 通りの構成

3 つとも同じノード上で、同じ Pod spec、同じモデル、同じバイト数で実行します。変わるのは vLLM
の引数だけです。

構成が 2 つではなく 3 つあるのは、ここで変えられるものが独立に 2 つあるためです。1 つはローダー、
つまり safetensors ファイルを読むコードです。もう 1 つは配送、つまりそのファイルを先にローカル
ディスクへコピーするか、ローダーが必要とするタイミングで S3 から読むかです。両方を同時に変えると
どちらが結果を動かしたのか判別できなくなるため、各構成では片方だけを変えます。

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

### variant 2 — `runai-local`（variant 1 とローダーだけが異なる）

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

### variant 3 — `runai-s3`（variant 2 と配送だけが異なる）

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
| 1 から 2 | ローダーだけ | 同じバイト列が同じディスク上にあるため、差はテンソルを 1 つずつではなく並列に読むことから生じます。 |
| 2 から 3 | 配送だけ | コピー工程が無くなるため、差はローダーがどこから読むかから生じます。 |

レポートはこの 2 つの比較を分けて出します。まとめてしまうと、コピー工程を無くしたことによる短縮を
ローダーが速いことの根拠と読んでしまう、あるいはその逆が起こります。

---

## 設定で間違えやすい 2 点

### 1. 認証情報はノードロールではなく Pod Identity から取得する

```yaml
spec:
  serviceAccountName: bench     # EKS Pod Identity で IAM ロールに紐付け
```

思いつきやすいのは、ノードロールにバケットへのアクセスを与え、コンテナがインスタンスメタデータ
から認証情報を取得する方法です。しかし Karpenter のノードではこれが動きません。Karpenter が IMDS
の hop limit を 1 に設定するためです。hop limit が 1 の場合、コンテナ内からのリクエストは 1 hop
超過となり、メタデータサービスに到達できず、AWS SDK は `Unable to locate credentials` を返します。

この hop limit は維持する価値があります。Pod がノードの権限を借用することを防いでいるのがこれ
です。代わりにサービスアカウントにロールを紐付けるのが、ここで動作させる方法であり、本番でも
そうすべき方法です。紐付けは [`terraform/main.tf`](../terraform/main.tf) の
`aws_eks_pod_identity_association` です。

### 2. init コンテナは本体イメージの pull を遅らせる

kubelet はこの順で処理します。init コンテナのイメージを pull し、init コンテナを完了まで
実行し、その後で本体イメージを pull します。コピーと pull が重なることはありません。

ここから、通常の考え方に反する帰結が出るので明示します。コンテナイメージからウェイトを出すと
イメージは小さくなり、小さいイメージは速く pull できます。しかしウェイトを init コンテナで
取得すると、pull で削れた時間が pull の開始前に消費されるため、start-to-Ready はウェイトを
イメージに含めていたときより長くなることがあります。variant 3 は init コンテナを無くすことで
これを回避します。本体イメージの pull が済んだ状態で、vLLM 自身がウェイトを読みます。

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

このためにインストールするものはありません。`runai-streamer` とその S3 バックエンドは AWS vLLM
Deep Learning Container のベースイメージに既に含まれており、Apache-2.0 ライセンスなのでライセンス
取得も不要です。`check_runai.sh` は、設定した具体的なタグにそれが含まれていることを確認します。
イメージを既に持っているノードに対して実行するため、数 GB の pull ではなく数秒で終わります。

---

## 検証

```bash
bin/verify_config.sh weights
```

次の 3 つを、前提として扱うのではなく実行結果から読み戻します。Pod が実際にどのローダーで
起動したか、モデルが `/models` から来たのか `s3://` から直接来たのか、そして vLLM 自身が記録した
起動時間の内訳です。

---

## 数字から分かること

| Variant | Ready | Ready 後の TTFT | submit から最初のトークンまで |
|---|---:|---:|---:|
| `s3-initcontainer` | 95s | 0.66s | 95.7s |
| `runai-local` | 92s | 0.66s | 92.7s |
| `runai-s3` | 84s | 0.66s | 84.7s |

### ローダーを変えても合計は変わらなかった

variant 1 と 2 の合計は同じでした。理由は vLLM のログに出ています。

```
Loading weights took 0.30 seconds
Model loading took 2.98 GiB memory and 0.616735 seconds
torch.compile took 14.75 s in total
Graph capturing finished in 4 secs
init engine (profile, create kv cache, warmup model) took 28.01 s (compilation: 14.75 s)
```

ウェイトの読み込みは、95 秒の起動のうち 0.30 秒でした。より速く読むローダーに与えられている
のはこの 0.30 秒だけで、改善する余地がほとんどありません。

ここで合計よりログ行が重要になる理由がこれです。合計だけを見ると、Run:ai Model Streamer は効果が
ないという主張に見えます。ログが示しているのは別のことです。このモデルサイズではローダーが制約
だったことはなく、ウェイトの読み込みに数十秒かかるモデルで同じ変更を行えば、結果は違って見える
可能性があります。

### 配送を変えると合計が短縮された

variant 3 は init コンテナを無くし、合計は 95 秒から 84 秒になりました。

短縮はウェイトを速く読んだことによるものではありません。工程を 1 つ無くしたことによるものです。
実際にはモデルロード時間は 0.62 秒から 2.71 秒に増えています。S3 からの読み込みはテンソル単位で
はローカルディスクより遅いためです。無くなったのはコピーで、これは約 11 秒かかり、前述のとおり
本体イメージの pull と並行してではなくその前に実行されていました。

### 最大の要素は engine init だった

engine init が 84 秒のうち 28.0 秒でした。

この数字は注意して読んでください。上記のログ行は加算するものではなく入れ子です。vLLM はその行
自体で入れ子を明示しています。

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

`torch.compile` の 14.76 秒と graph capture の 4 秒は、この 28.0 秒の**内側**で起きています。
足し合わせる 3 つの段階ではなく、足すとコンパイル時間を二重に数えることになります。

このステップで変えたものは、いずれもこの段階に影響しません。どちらのローダーも影響せず、どちらの
配送方法も影響しません。コンパイル成果物の再利用はその一部に影響し、上限はコンパイルの 14.76 秒
です。残りを占める profiling、KV cache 作成、warmup は残ります。したがってこのステップの終わりで
未解決の最大項目はコンパイルであり、それを[ステップ 7](07-compile-cache.md) で計測します。

### モデルが大きい場合

ここで使うモデルは 1.5B パラメータ、約 2.9 GB です。Run:ai の公開ベンチマークは 15 GB の
モデルを使っており、そちらではローダーが起動時間に占める割合が大きくなります。その場合を
計測するには `config.env` の `MODEL_HF_REPO` を大きいモデルに設定してください。運用する
モデルが大きい場合、結果は上記と異なる可能性があります。

### ウェイトがノードに届く経路

この経路のうち 1 箇所は、このステップの設定ではなく Terraform が用意しています。ダウンロードの
数字を読む前に、それが存在することを把握しておく価値があります。

VPC にはプライベートサブネットと NAT ゲートウェイ 1 つがあり、加えて S3 Gateway VPC エンド
ポイントがあります。エンドポイントは、リージョンの S3 プレフィックスリスト向けのルートを
プライベートルートテーブルに追加します。このルートはデフォルトルートより具体的なため優先され、
S3 の通信は NAT を通りません。これはここでのウェイトにも、前のステップのコンテナイメージの
レイヤにも当てはまります。ECR がレイヤを S3 に保存しているためです。

取り除かれるのは NAT のデータ処理料金と、NAT への依存です。

ダウンロードが速くなることは保証しません。ここで 1 台のノードが取得する速度では NAT は能力の限界に
近づいておらず、エンドポイントが効いてくるのは多数のノードが 1 つの NAT ゲートウェイを通じて同時に
スケールアウトする場合です。また非暗号の接続を暗号化するものでもありません。どちらの経路でも
HTTPS を使えます。

イメージ pull を完全に NAT から外すことが目的の場合、ゲートウェイエンドポイントだけでは足りま
せん。レイヤのダウンロードはカバーしますが、レジストリの API 呼び出しは S3 宛てではありません。
こちらには `ecr.api` と `ecr.dkr` のインターフェイスエンドポイントが必要で、無料のゲートウェイ
エンドポイントと違い、時間課金とデータ課金が発生します。

---

## time to first token

Pod が Ready になることは vLLM が `/health` に応答することを意味し、トークンをどれだけ早く
出せるかは示しません。フェーズ 2 の各実行では submit から最初のトークンまでも計測します。

プローブ（[`bin/first_token.py`](../bin/first_token.py)）はストリーミングで補完を要求し、
テキストを含む最初のトークンで計測を止めます。ストリーミングを使うのは、使わない場合に計測
できるのが総レイテンシで、要求トークン数に依存するためです。プローブは ConfigMap として Pod
内で動くため、port-forward もイメージ内の `curl` も不要です。

---

戻る: [README](../README.md#何を採用するか)
