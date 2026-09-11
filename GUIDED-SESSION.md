# Run sheet: guided session on an existing cluster

**English** | [日本語](#japanese)

For a session with a team that already runs GPU workloads on EKS with Karpenter and wants the
Bottlerocket startup optimizations in the cluster they have. The facilitator demonstrates the
measurements from their own account, then guides the team through applying a node class in
theirs.

This is a different shape from [FACILITATOR-GUIDE.md](FACILITATOR-GUIDE.md), which is for
running the full workshop including building the environment. Nothing is built in the team's
account here beyond one node pool and one node class.

Sixty minutes. The demo is the first third; the rest is their cluster.

---

## Before the session

In your own account:

```bash
bin/check_capacity.sh      # GPU capacity changes within minutes
bin/verify_env.sh          # includes the Karpenter controller check
kubectl get nodeclaims     # expect no output, so the demo starts cold
```

The Karpenter controller check is the one that has cost a run before. If the managed node group
carrying it has scaled to zero, the controller sits `Pending`, nothing provisions, and every
pod waits out the full timeout with nothing saying why.

Have `results/report.md` open as a fallback. If a live run fails, the figures from the last run
are still on screen and the session continues.

Ask the team to have ready:

| | |
|---|---|
| A cluster | Not production. Self-managed Karpenter, `karpenter.k8s.aws/v1` |
| The node IAM role | `kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}'` |
| GPU quota | One node's worth of the type they pick, in vCPU |
| Someone with kubectl access | They drive; you guide |

They do not need to prepare a cluster to attend. If nothing is ready, the session becomes the
demo plus a walkthrough of [EXISTING-CLUSTER.md](EXISTING-CLUSTER.md).

---

## Timing

| Time | Part | Where |
|---|---|---|
| 0:00 to 0:05 | Why startup time, and what the stages are | slides |
| 0:05 to 0:18 | The measurements | your account, live |
| 0:18 to 0:22 | Which mechanism suits them, and why two of them conflict | discussion |
| 0:22 to 0:50 | Applying a node class in their cluster | their account |
| 0:50 to 0:60 | What to measure next, and cleanup | discussion |

If time runs short, drop the model loading part of the demo and keep the image part. The image
figures are what motivate the node class they are about to apply.

---

## Part 1. The demo, 13 minutes

Run one cold variant live and show the rest from the last run. A cold `baseline` takes about
two and a half minutes on the reference environment, most of it the image pull.

```bash
bin/show_config.sh baseline    # nothing is configured. This is the comparison point
bin/bench.sh baseline
```

While the pull runs, the output stops. That pause is the subject of the session, so say what is
happening rather than filling the silence:

> The node was ready in about thirty seconds. What we are waiting for now is the image.

Then the figure that sets up everything else:

> The image pull was 124 of the 157 seconds. So the difference between the approaches is going
> to come from how the image reaches the node, not from how the node is provisioned.

Say how the breakdown is produced, because it decides whether the numbers are worth anything:

> These stages are timestamps that Kubernetes already records. Pod conditions, NodeClaim
> conditions, kubelet events. Sorted and subtracted. That is why they add up to the total with
> nothing left over.

Then the throughput, which leads into the mechanisms:

> Nine gigabytes in 124 seconds is 75 megabytes a second. This instance supports up to 25
> Gbps, so the network was not the limit. Layers are being downloaded and unpacked one at a
> time.

### The three mechanisms, from the last run

Show the configuration before each figure. The configuration is what they are going to apply;
the figure is why.

```bash
bin/show_config.sh snapshot     # one field
bin/show_config.sh soci         # a policy line and six lines of TOML
bin/report.py results
```

| Approach | Image stage | Start to Ready | What it costs |
|---|---:|---:|---|
| Baseline | 124s | 157s | nothing |
| EBS snapshot | 0s | 61s | rebuild the snapshot whenever the image changes |
| NVMe and SOCI | 35s | 66s | one policy line and six settings |
| Auto Mode | 35s | 78s | not applicable to their cluster |

Two points to make while this is on screen.

The snapshot removes the pull because kubelet finds the image already present. The cost is that
it has to be rebuilt for every image change, and that cost recurs.

SOCI reached 267 MB/s against 75, with the image unmodified and no change to their build
pipeline. Say that explicitly, because "does this need us to rebuild our images" is the first
question.

Auto Mode is in the table because it reached the same image stage as SOCI without any of the
configuration. It is context rather than something they will apply, since they have a cluster
already.

### The measurement that reframes the rest

Run this live. It takes about a second.

```bash
bin/bench.sh soci --warm
```

> 65 of those 66 seconds was incurred once per node, not once per pod. That has two
> consequences for you. The snapshot only helps the first pod on a node. And if most of your
> pods land on nodes that are already running, none of these three mechanisms is where your
> startup time is going.

Then put the question to them and wait for an answer:

> What fraction of your pods get scheduled onto new nodes?

Their answer decides whether the rest of the session is worth their time, so it is worth asking
before spending it.

### Model loading, if there is time

```bash
bin/report.py results
```

| | Ready | Submit to first token |
|---|---:|---:|
| Copy to disk, default loader | 95s | 95.7s |
| Copy to disk, Run:ai Model Streamer | 92s | 92.7s |
| No copy, streamer reads S3 | 84s | 84.7s |
| Compile cache empty | 82s | 82.7s |
| Compile cache populated | 69s | 69.7s |

The finding worth their attention is not the ranking:

> Reading the weights was 0.30 seconds of 84. The loader had almost nothing to improve. What
> the third row saved was the copy step, not the read. And the largest single item left is
> compilation, at 14.8 seconds, which is what the last two rows address.

---

## Part 2. Their cluster, 28 minutes

Switch to [EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) and have them drive.

### Before anything is applied

Say these three things, in this order, before any YAML goes in.

**Nothing existing is modified.** Every step creates a new node pool and a new node class.
Their current pools are untouched.

**Their GPU pods already tolerate the GPU taint.** So a Bottlerocket pool tainted only with
`nvidia.com/gpu` is a pool their existing workloads can land on, and Karpenter will use it to
satisfy a pending pod. That is why the node pool carries a second taint that nothing existing
tolerates.

**Check for blanket tolerations first.** The command is in the runbook. DaemonSets appearing is
expected. A workload pod appearing is worth stopping for.

### The order

| | What | Watch for |
|---|---|---|
| 1 | Baseline node class and node pool, and a pod | The pod stays `Pending` if the toleration does not match both taints |
| 2 | Read the stages from `kubectl get events` | The `Pulled` event carries the duration and the image size |
| 3 | A build-only node pool, a pod to pull the image, snapshot its `/dev/xvdb`, apply `snapshotID` | Three to five minutes for the snapshot. Delete the builder pool afterwards |
| 4 | Or instead, `instanceStorePolicy: RAID0` and the SOCI settings | Not both. Step 3 of the runbook says why |
| 5 | Delete the pod, reapply it, compare | The node survives because `consolidateAfter` is 30m |

Have them pick between 3 and 4 rather than doing both. The choice follows from one question:

> How often do your images change?

Rarely, and the snapshot is the stronger option. Often, and maintaining a snapshot per image
version is the thing that will stop being done after a month.

### Two things that will come up

**`Pending` with no message.** Check the toleration against both taints first. Then check
whether Karpenter created a NodeClaim at all: if it did not, the instance type may have no
capacity in the zones their subnets cover, and Karpenter holds a refused offering unavailable
for three minutes at a time.

**A number that looks wrong.** Bottlerocket below 1.44.0 ignores `snapshotter = "soci"`
without an error, so the node boots, the pod runs, and the figures match the baseline. The
runbook has the command to check the version.

---

## Part 3. Closing, 10 minutes

Leave them with the choice rather than a recommendation, since the inputs are theirs.

| If | Then |
|---|---|
| Images change rarely and latency matters | EBS snapshot |
| Images change often | NVMe and SOCI |
| Most pods land on nodes already running | Node capacity policy, before any of the above |
| Weight loading is longer than the pull | Stream from S3, then look at the compile cache |

Then the cleanup, while everyone is still on the call:

```bash
kubectl delete pod <the test pods> --ignore-not-found
kubectl delete nodepool <the test pools> --ignore-not-found
kubectl delete ec2nodeclass <the test node classes> --ignore-not-found
kubectl get nodeclaims        # confirm none of theirs are left
aws ec2 delete-snapshot --snapshot-id <the snapshot>
```

Deleting the node pool terminates its nodes. Doing this together means a GPU node is not left
running on their account, which is easy to leave behind: Karpenter keeps a node for 30 minutes
after its last pod.

Send them [EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) and
[REFERENCE-RESULTS.md](REFERENCE-RESULTS.md). The first is what they repeat on their own; the
second is what their figures can be read against, with the caveat that it is one run in one
account.

<br>

---
---

<a id="japanese"></a>

# 進行メモ: 既存クラスターでのガイド付きセッション

[English](#run-sheet-guided-session-on-an-existing-cluster) | **日本語**

EKS 上で Karpenter を使って GPU ワークロードを既に動かしており、既存クラスターに Bottlerocket の
起動時間最適化を入れたいチームとのセッション用です。実施者が自身のアカウントで計測結果を実演し、
その後チームが自身のクラスターに node class を適用するのをガイドします。

[FACILITATOR-GUIDE.md](FACILITATOR-GUIDE.md) は環境構築を含むフルワークショップ用で、形式が
異なります。こちらでは、チームのアカウントに作るものは node pool 1 つと node class 1 つだけです。

60 分。デモは最初の 3 分の 1 で、残りは相手のクラスターです。

---

## セッション前

自身のアカウントで:

```bash
bin/check_capacity.sh      # GPU 容量は分単位で変わる
bin/verify_env.sh          # Karpenter コントローラの確認を含む
kubectl get nodeclaims     # 何も出ないこと。デモを cold から始めるため
```

Karpenter コントローラの確認は、過去に実行 3 本を失った箇所です。コントローラが載る
マネージドノードグループが 0 台になると、コントローラは `Pending` のままで、何もプロビジョニング
されず、全 Pod がタイムアウトまで待ちます。しかもその理由はどこにも表示されません。

`results/report.md` を開いておいてください。ライブ実行が失敗しても、前回の数字が画面にあれば
セッションは続けられます。

チームに用意を依頼するもの:

| | |
|---|---|
| クラスター | 本番以外。自己管理 Karpenter、`karpenter.k8s.aws/v1` |
| ノード IAM ロール | `kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}'` |
| GPU クォータ | 選ぶタイプのノード 1 台分。vCPU 単位 |
| kubectl を操作できる人 | 操作は相手、ガイドは実施者 |

参加のためにクラスターを準備する必要はありません。何も用意が無い場合、セッションはデモと
[EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) の読み合わせになります。

---

## 時間配分

| 時刻 | パート | 場所 |
|---|---|---|
| 0:00〜0:05 | なぜ起動時間か、段階とは何か | スライド |
| 0:05〜0:18 | 計測 | 自身のアカウント、ライブ |
| 0:18〜0:22 | どの機構が向くか、2 つが併用できない理由 | ディスカッション |
| 0:22〜0:50 | 相手のクラスターへの node class 適用 | 相手のアカウント |
| 0:50〜0:60 | 次に計測すべきこと、後片付け | ディスカッション |

時間が足りない場合、デモのモデルロード部分を落としてイメージ部分を残します。これから適用する
node class の動機になるのはイメージの数字です。

---

## パート 1. デモ、13 分

cold の variant を 1 つライブで実行し、残りは前回の結果を見せます。参考環境で cold の
`baseline` は約 2 分半、その大半がイメージ pull です。

```bash
bin/show_config.sh baseline    # 何も設定しない。これが比較の基準
bin/bench.sh baseline
```

pull 中は出力が止まります。この空白がセッションの主題なので、沈黙を埋めるのではなく何が起きて
いるかを言ってください。

> ノードは約 30 秒で Ready になりました。いま待っているのはイメージです。

そして以降すべての前提になる数字:

> イメージ pull が 157 秒のうち 124 秒でした。つまり方式間の差は、ノードのプロビジョニング方法
> ではなく、イメージがノードに届く経路から生まれます。

内訳の作り方も述べてください。数字に意味があるかを決めるのはここです。

> これらの段階は Kubernetes が既に記録しているタイムスタンプです。Pod の condition、NodeClaim の
> condition、kubelet のイベント。それを並べて差を取っています。だから合計と一致し、取りこぼしが
> ありません。

次にスループット。これが機構の話への導入になります。

> 9 GB を 124 秒なので毎秒 75 MB です。このインスタンスは最大 25 Gbps なので、ネットワークが
> 制約ではありません。レイヤを 1 つずつダウンロードして展開しています。

### 3 つの機構、前回の結果から

各数字の前に設定を見せてください。設定はこれから相手が適用するもので、数字はその理由です。

```bash
bin/show_config.sh snapshot     # フィールド 1 つ
bin/show_config.sh soci         # ポリシー 1 行と TOML 6 行
bin/report.py results
```

| 方式 | イメージ段階 | start to Ready | コスト |
|---|---:|---:|---|
| ベースライン | 124s | 157s | なし |
| EBS スナップショット | 0s | 61s | イメージが変わるたびに作り直し |
| NVMe と SOCI | 35s | 66s | ポリシー 1 行と設定 6 行 |
| Auto Mode | 35s | 78s | 相手のクラスターには適用外 |

画面に出ている間に触れる点が 2 つあります。

スナップショットが pull を無くすのは、kubelet がイメージを既に存在すると判断するためです。コストは
イメージ変更ごとの作り直しで、これは繰り返し発生します。

SOCI は 75 に対して 267 MB/s に達しました。イメージは未変更で、ビルドパイプラインの変更も
ありません。これは明示してください。「イメージのビルドを変える必要があるのか」が最初に来る質問です。

Auto Mode を表に入れているのは、設定を一切せずに SOCI と同じイメージ段階に達したからです。相手は
既にクラスターを持っているので、適用対象ではなく文脈として扱ってください。

### 残りの見方を変える計測

これはライブで実行してください。約 1 秒です。

```bash
bin/bench.sh soci --warm
```

> 66 秒のうち 65 秒は、Pod ごとではなくノード 1 台につき 1 回発生していた分です。ここから 2 つ
> 帰結があります。スナップショットが効くのはノードの 1 個目の Pod だけです。そして Pod の大半が
> すでに動いているノードに載るなら、起動時間が消えているのはこの 3 つの機構のどこでもありません。

そのうえで相手に問いを投げ、答えを待ってください。

> 御社の Pod のうち、新しいノードにスケジュールされるのはどれくらいの割合ですか。

この答えが、以降のセッションが相手の時間に見合うかを決めます。時間を使う前に聞く価値があります。

### 時間があればモデルロード

```bash
bin/report.py results
```

| | Ready | submit から最初のトークンまで |
|---|---:|---:|
| ディスクへコピー、既定ローダー | 95s | 95.7s |
| ディスクへコピー、Run:ai Model Streamer | 92s | 92.7s |
| コピーなし、streamer が S3 を読む | 84s | 84.7s |
| コンパイルキャッシュ空 | 82s | 82.7s |
| コンパイルキャッシュあり | 69s | 69.7s |

注目に値するのは順位ではありません。

> ウェイトの読み込みは 84 秒のうち 0.30 秒でした。ローダーに改善の余地はほぼありません。3 行目が
> 短縮したのはコピー工程で、読み込みではありません。そして残っている最大の単一項目はコンパイルの
> 14.8 秒で、下 2 行がそこに対応しています。

---

## パート 2. 相手のクラスター、28 分

[EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) に切り替え、操作は相手に任せます。

### 何かを適用する前に

YAML を入れる前に、この 3 点をこの順で伝えてください。

**既存のものは何も変更しません。** 各ステップは新しい node pool と node class を作ります。現在の
pool には触れません。

**相手の GPU Pod は既に GPU taint を tolerate しています。** したがって `nvidia.com/gpu` だけを
taint に持つ Bottlerocket の pool は、既存ワークロードが載りうる pool であり、Karpenter は Pending
Pod を満たすためにそれを使います。だから node pool には、既存のどれも tolerate しない 2 つ目の
taint を付けます。

**無条件 toleration を先に確認します。** コマンドは runbook にあります。DaemonSet が出るのは
想定どおりです。ワークロードの Pod が出たら、そこで止まる価値があります。

### 手順の順序

| | 内容 | 注意点 |
|---|---|---|
| 1 | ベースライン node class と node pool、そして Pod | toleration が 2 つの taint 両方に一致しないと Pod は `Pending` のまま |
| 2 | `kubectl get events` から段階を読む | `Pulled` イベントに所要時間とイメージサイズが入っている |
| 3 | ビルド専用 node pool と pull 用 Pod を作り、その `/dev/xvdb` をスナップショットして `snapshotID` を適用 | スナップショットに 3〜5 分。終わったら builder pool を削除 |
| 4 | あるいは代わりに `instanceStorePolicy: RAID0` と SOCI 設定 | 両方は不可。理由は runbook のステップ 3 |
| 5 | Pod を削除して再適用し、比較 | `consolidateAfter` が 30m なのでノードは残る |

3 と 4 は両方やらせず、どちらかを選ばせてください。選択は 1 つの問いから決まります。

> イメージはどれくらいの頻度で変わりますか。

稀ならスナップショットが有力です。頻繁なら、イメージバージョンごとのスナップショット維持は
1 か月後にやらなくなる作業です。

### 出てくる問題

**メッセージのない `Pending`。** まず toleration が taint 2 つの両方に一致しているか確認します。
次に Karpenter が NodeClaim を作ったかを見ます。作っていない場合、そのインスタンスタイプが相手の
サブネットの AZ で容量不足の可能性があります。Karpenter は拒否された offering を 3 分間 unavailable に
保持します。

**数字がおかしいとき。** Bottlerocket が 1.44.0 未満だと `snapshotter = "soci"` はエラーなく
無視されます。ノードは起動し Pod も動き、数字はベースラインと一致します。バージョン確認の
コマンドは runbook にあります。

---

## パート 3. 締め、10 分

推奨ではなく選択肢を渡してください。判断の入力は相手が持っています。

| 条件 | 選択 |
|---|---|
| イメージが稀に変わり、レイテンシが重要 | EBS スナップショット |
| イメージが頻繁に変わる | NVMe と SOCI |
| Pod の大半がすでに動いているノードに載る | 上記より前にノードのキャパシティ方針 |
| ウェイトの読み込みが pull より長い | S3 からのストリーミング、次にコンパイルキャッシュ |

そして全員がまだ通話にいる間に後片付けを行います。

```bash
kubectl delete pod <テスト Pod> --ignore-not-found
kubectl delete nodepool <テスト pool> --ignore-not-found
kubectl delete ec2nodeclass <テスト node class> --ignore-not-found
kubectl get nodeclaims        # 相手のものが残っていないこと
aws ec2 delete-snapshot --snapshot-id <スナップショット>
```

node pool の削除はそのノードを終了させます。一緒にやることで、相手のアカウントに GPU ノードが
残りません。これは残りやすい類のもので、Karpenter は最後の Pod が消えてから 30 分ノードを保持します。

[EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) と [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md) を
渡してください。前者は相手が自分で繰り返すもの、後者は自分の数字と比べる相手です。ただし 1
アカウントでの 1 回の計測である点は添えてください。
