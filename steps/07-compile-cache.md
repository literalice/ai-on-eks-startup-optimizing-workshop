# Step 7 — Reuse vLLM's compiled artifacts

**English** | [日本語](#japanese)

Phase 2 ended with engine initialisation as the largest remaining stage, and vLLM reports how
much of it is compilation. This step keeps the compiled artifacts on the node so a replacement
pod does not compile again, and measures what that is worth. Two runs differ only in whether
the cache directory already has contents.

---

## Where this comes from

Step 6 measured this, on the fastest of the three loaders:

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

Reading the weights was 0.30 seconds of an 84-second start-to-Ready. Compilation was 14.76.
Once the image and the weights stop being the bottleneck, this is the largest item left, and
neither the loader nor the delivery method touches it.

vLLM already supports reusing compiled artifacts, so this step adds no compilation code. The
change is a volume for the cache directory.

---

## Part A — where vLLM puts the cache

The engine log names the directory:

```
Using cache directory: /root/.cache/vllm/torch_compile_cache/fb53794fa6/rank_0_0/backbone for vLLM's torch.compile
```

That path is in the container's writable layer. A replacement pod gets a new writable layer,
so the directory is empty and compilation runs again. The change is a volume that outlives the
pod:

```yaml
  volumes:
    - name: compile-cache
      hostPath:
        path: "/var/lib/vllm-compile-cache/@CACHE_ID@"
        type: DirectoryOrCreate
  # ...
      volumeMounts:
        - name: compile-cache
          mountPath: /root/.cache/vllm/torch_compile_cache
```

### Why the mount is on the subdirectory and not on `/root/.cache/vllm`

Run:ai Model Streamer caches the model under the same root. The engine log shows it:

```
Initializing a V1 LLM engine (v0.22.0) with config: model='/root/.cache/vllm/assets/model_streamer/1e3cd6c5', ...
```

Mounting the whole root would persist the model as well, and the warm run would then skip the
S3 read too. The measurement would combine two effects and neither figure would be
attributable. Mounting only `torch_compile_cache` keeps the weights coming from S3 on both
runs, so compilation is the only thing that differs.

### Where that directory ends up on Bottlerocket

`/var/lib/vllm-compile-cache` is not in Bottlerocket's allow list of bindable directories, so
`instanceStorePolicy: RAID0` does not bind it to the instance store — it stays on the EBS data
volume. Either location outlives the pod, which is all this measurement needs. Neither
outlives the node.

---

## Part B — the two runs

```bash
bin/bench.sh soci            # a node with the image cached, if you do not have one
bin/bench.sh compile cold
bin/bench.sh compile warm
```

`compile cold` picks a cache subdirectory no run has used, records it in
`results/compile-cache-id.txt`, and compiles. `compile warm` reads that file and mounts the
same subdirectory, so the artifacts are already there. The pod is replaced between the two;
the node is not.

Everything else is held constant: same node, same image, same GPU, same model, same
`runai_streamer` loader with the same concurrency, same vLLM arguments. The cache directory is
the only difference.

---

## Verify

Confirm the cache was reused from the log, not from the timing. A short compile time is
consistent with a cache hit and also with a different compilation configuration, and the point
is to attribute the difference to the cache.

```bash
grep -E "Using cache directory|Compiling a graph|saved AOT|Directly load" \
  raw/compile-*/pod.log
```

On a miss vLLM logs that it compiled and saved:

```
Cache the graph of compile range (1, 2048) for later use
Compiling a graph for compile range (1, 2048) takes 7.22 s
saved AOT compiled function to /root/.cache/vllm/torch_compile_cache/torch_aot_compile/...
```

`bin/stages.py` reads the same markers and records `compile_cache` as `hit`, `miss` or
`unknown` in the run's JSON. It reports `unknown` rather than guessing when it finds neither,
because the wording of these lines has changed between vLLM releases.

The pod also lists the directory contents before starting the server, so the first lines of
the log show whether the cache was populated at mount time.

---

## What this can and cannot reduce

Measured here, reusing the artifacts took start-to-Ready from 82 seconds to 69: compilation
went from 14.78 seconds to 3.01, and the engine stage that contains it from 28.00 to 15.33.

A cache hit removes compilation and nothing else in that stage. Profiling, KV-cache creation
and warmup accounted for the remaining 12 seconds or so and did not move, and CUDA graph
capture stayed at 4 seconds. The most this change can remove is the compilation figure, which
is smaller than the engine figure.

The model load figure is the check that the mount is isolating the right thing: 2.62 seconds
cold and 2.65 warm, so the weights came from S3 in both runs.

The artifacts also do not survive a node replacement, which is the case that matters for
scale-out. That is the third test, and this workshop does not script it:

| Test | Starting condition | What it establishes |
|---|---|---|
| `compile-cold` | Image on the node, cache directory empty | The cost of compiling |
| `compile-warm` | Same node, same cache directory, pod replaced | Savings from reuse across pods |
| Not scripted here | Artifacts restored from S3 onto a new node | Whether the savings also apply during node scale-out |

For the third, the cache key covers the model, dtype, GPU architecture, vLLM version and
compilation configuration. Artifacts do not transfer across a change in any of those, so a
pipeline that pushes them to S3 has to key on the same things or it will serve artifacts that
are silently ignored.

---

## The question this raises for you

If most of your pods land on nodes that are already running, reuse across pods applies to you
and this is a saving available per pod. If your scale-out creates nodes, the artifacts do not
survive, and the third test is the one to run.

Step 5 raised the same question about the image, for the same reason: whether a mechanism
helps depends on how much of your startup cost is incurred once per node.

<br>

---
---

<a id="japanese"></a>

# ステップ 7 — vLLM のコンパイル成果物を再利用する

[English](#step-7--reuse-vllms-compiled-artifacts) | **日本語**

フェーズ 2 では engine init が残る最大の段階であり、そのうちどれだけがコンパイルかは vLLM が
報告しています。このステップではコンパイル成果物をノード上に残し、置き換わった Pod が再
コンパイルしないようにして、その価値を計測します。2 回の実行の違いは、キャッシュディレクトリに
既に内容があるかどうかだけです。

---

## この設定の背景

ステップ 6 では、3 つのローダーのうち最速のものでこう計測されました。

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

ウェイトの読み込みは start-to-Ready 84 秒のうち 0.30 秒でした。コンパイルは 14.76 秒です。
イメージとウェイトがボトルネックでなくなった後、これが残る最大の項目であり、ローダーも配送
方法もここには影響しません。

コンパイル成果物の再利用は vLLM が既に対応しているため、このステップでコンパイルのコードは
書きません。変更点はキャッシュディレクトリ用のボリュームです。

---

## パート A — vLLM がキャッシュを置く場所

engine のログにディレクトリが出ています。

```
Using cache directory: /root/.cache/vllm/torch_compile_cache/fb53794fa6/rank_0_0/backbone for vLLM's torch.compile
```

このパスはコンテナの書き込み可能レイヤ上にあります。置き換わった Pod は新しい書き込み可能
レイヤを得るため、ディレクトリは空になり、再度コンパイルが走ります。変更点は、Pod より
長く残るボリュームです。

```yaml
  volumes:
    - name: compile-cache
      hostPath:
        path: "/var/lib/vllm-compile-cache/@CACHE_ID@"
        type: DirectoryOrCreate
  # ...
      volumeMounts:
        - name: compile-cache
          mountPath: /root/.cache/vllm/torch_compile_cache
```

### マウント先を `/root/.cache/vllm` ではなくサブディレクトリにする理由

Run:ai Model Streamer は同じルート配下にモデルをキャッシュします。engine のログに出ています。

```
Initializing a V1 LLM engine (v0.22.0) with config: model='/root/.cache/vllm/assets/model_streamer/1e3cd6c5', ...
```

ルート全体をマウントするとモデルも永続化され、warm の実行では S3 の読み込みまでスキップされ
ます。計測は 2 つの効果が混ざり、どちらの数字も帰属先が定まりません。`torch_compile_cache`
だけをマウントすれば、どちらの実行でもウェイトは S3 から来るため、違いはコンパイルだけに
なります。

### Bottlerocket 上でこのディレクトリが置かれる場所

`/var/lib/vllm-compile-cache` は Bottlerocket のバインド可能ディレクトリ許可リストに入って
いないため、`instanceStorePolicy: RAID0` はこれをインスタンスストアにバインドせず、EBS データ
ボリューム上に残ります。この計測に必要なのは Pod より長く残ることだけなので、どちらの場所でも
成立します。いずれもノードより長くは残りません。

---

## パート B — 2 回の実行

```bash
bin/bench.sh soci            # イメージをキャッシュしたノードが無い場合
bin/bench.sh compile cold
bin/bench.sh compile warm
```

`compile cold` は、どの実行も使っていないキャッシュサブディレクトリを選び、
`results/compile-cache-id.txt` に記録してコンパイルします。`compile warm` はそのファイルを
読んで同じサブディレクトリをマウントするため、成果物が既に存在します。2 回の間で Pod は
置き換わり、ノードは置き換わりません。

それ以外は固定です。同じノード、同じイメージ、同じ GPU、同じモデル、同じ concurrency の
`runai_streamer` ローダー、同じ vLLM 引数です。違いはキャッシュディレクトリだけです。

---

## 検証

キャッシュが再利用されたことは、計測時間ではなくログで確認します。コンパイル時間が短いことは
キャッシュヒットと整合しますが、コンパイル設定が違う場合とも整合します。差をキャッシュに
帰属させることが目的です。

```bash
grep -E "Using cache directory|Compiling a graph|saved AOT|Directly load" \
  raw/compile-*/pod.log
```

ミスの場合、vLLM はコンパイルして保存したことを記録します。

```
Cache the graph of compile range (1, 2048) for later use
Compiling a graph for compile range (1, 2048) takes 7.22 s
saved AOT compiled function to /root/.cache/vllm/torch_compile_cache/torch_aot_compile/...
```

`bin/stages.py` は同じマーカーを読み、実行の JSON に `compile_cache` を `hit` / `miss` /
`unknown` として記録します。どちらも見つからない場合は推測せず `unknown` を報告します。
これらの行の文言は vLLM のリリース間で変わってきているためです。

Pod はサーバー起動前にディレクトリの内容も一覧します。ログの先頭数行で、マウント時点で
キャッシュが埋まっていたかどうかが分かります。

---

## 何を削減でき、何を削減できないか

ここでの実測では、成果物の再利用により start-to-Ready が 82 秒から 69 秒になりました。
コンパイルは 14.78 秒から 3.01 秒に、それを内包する engine 段階は 28.00 秒から 15.33 秒です。

キャッシュヒットが除去するのはコンパイルだけで、その段階の他のものは除去しません。profiling、
KV cache 作成、warmup は残りの約 12 秒を占めており、動いていません。CUDA graph capture も 4 秒
のままです。この変更で除去できるのは最大でコンパイルの数字までであり、これは engine の数字より
小さい値です。

マウントが正しい対象だけを切り出せているかの確認はモデルロードの数字です。cold で 2.62 秒、
warm で 2.65 秒なので、ウェイトは両方の実行で S3 から来ています。

成果物はノードの置き換えにも残りません。そしてスケールアウトで問題になるのはその場合です。
それが 3 つ目の試験で、本ワークショップではスクリプト化していません。

| 試験 | 開始条件 | 何が分かるか |
|---|---|---|
| `compile-cold` | イメージはノード上にあり、キャッシュディレクトリは空 | コンパイルのコスト |
| `compile-warm` | 同一ノード、同一キャッシュディレクトリ、Pod を置き換え | Pod 間の再利用による短縮 |
| ここでは未スクリプト化 | 新規ノードへ S3 から成果物を復元 | 同じ短縮がノードのスケールアウトでも得られるか |

3 つ目については、キャッシュキーがモデル、dtype、GPU アーキテクチャ、vLLM バージョン、
コンパイル設定を含みます。いずれかが変わると成果物は流用できないため、S3 へ push する
パイプラインは同じ項目でキーを作る必要があります。そうでなければ、黙って無視される成果物を
配ることになります。

---

## ここから出てくる問い

Pod の大半がすでに動いているノードに載るなら、該当するのは Pod 間の再利用であり、この短縮は
Pod ごとに得られます。スケールアウトがノードを作る形なら、成果物は残らないため、実行すべきは
3 つ目の試験です。

ステップ 5 はイメージについて同じ問いを、同じ理由で扱いました。ある機構が効くかどうかは、
起動コストのうちどれだけがノード 1 台につき 1 回発生する分かで決まります。
