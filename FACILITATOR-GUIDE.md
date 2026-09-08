# Facilitator Guide / ファシリテーターガイド

For the person running this workshop with an audience. The [README](README.md) is the
document participants use; this one is for the facilitator.

このワークショップを参加者向けに実施する担当者用の資料です。[README](README.md) は参加者が
使うもので、こちらは実施側の資料です。

Format: the facilitator prepares and runs everything in their own AWS account and shares
their screen. Participants then repeat the same steps in their own Dev account using the
README and the `steps/` documents. Participants do not need an AWS account or GPU quota
on the day. Stating this at the start avoids spending time on participants' missing
prerequisites.

形式: 実施側が自分の AWS アカウントで準備・実行し、画面共有します。参加者は後日、README と
`steps/` を使って自分の Dev アカウントで同じ手順を実行します。当日、参加者側に AWS
アカウントや GPU クォータは必要ありません。この点を冒頭で伝えると、参加者側の前提不足に
時間を取られずに進められます。

---

## 0. Before the day / 前日までに

| # | Task / 作業 | Time | If not done / 未実施の場合 |
|---|---|---|---|
| 1 | `terraform apply` to build both clusters<br>クラスター 2 面を作成 | 25–30 min | 30 minutes is spent on the day<br>当日に 30 分かかる |
| 2 | `bin/bench.sh baseline`, then `snapshot/snapshot-from-node.sh`<br>baseline 実行後にスナップショット作成 | 10 min | the snapshot variant cannot be run<br>snapshot が実行できない |
| 3 | `snapshot/stage-model.sh` to upload the weights<br>ウェイトを S3 にアップロード | 5–10 min | phase 2 cannot be run<br>フェーズ 2 が実行できない |
| 4 | `bin/prep.sh` to apply the variants<br>variant を適用 | 2 min | nothing can be run<br>何も実行できない |
| 5 | Run all four variants, the warm run, and all three phase-2 variants once<br>4 variant、warm 実行、フェーズ 2 の 3 通りを 1 回ずつ実行 | 40–50 min | the first execution happens during the session<br>初回実行が本番になる |
| 6 | `bin/check_runai.sh`<br>Run:ai の対応確認 | 3 min | the two Run:ai variants may fail during the session<br>Run:ai 系 2 本が本番で失敗しうる |
| 7 | Check GPU quota `L-DB2E81BA` is at least 64 vCPU | 5 min | variants wait for capacity instead of starting<br>variant が起動せず待ちになる |
| 8 | Check the vLLM DLC tag still exists<br>vLLM DLC のタグ存在確認 | 2 min | `ImagePullBackOff`<br>同 |

Keep the results from step 5. If a live run fails, the previous day's figures can be
shown instead and the session can continue. The live run demonstrates how the figures
are produced; it is not the only opportunity to produce them.

5 の結果は保存しておいてください。本番の実行が失敗した場合、前日の数字を出して進行を
続けられます。本番の実行は数字の作り方を示すもので、数字を得る唯一の機会ではありません。

```bash
cp -r results results-dryrun-$(date +%Y%m%d)
```

---

## 1. Timing / 時間配分

Sixty minutes.

| Time | Content | Live? |
|---|---|---|
| 0:00–0:05 | Purpose and scope. State that custom AMI builds are out of scope.<br>目的とスコープ。カスタム AMI は対象外と伝える | slides |
| 0:05–0:15 | Step 1: the baseline. Run the baseline variant.<br>ステップ 1: ベースライン。baseline を実行 | live |
| 0:15–0:27 | Steps 2 and 3: the two image mechanisms.<br>ステップ 2 と 3: イメージ配送の 2 方式 | live |
| 0:27–0:34 | Step 4: Auto Mode. Show the configuration diff, then the figures.<br>ステップ 4: Auto Mode。設定差分を見せてから数字 | diff and prior figures |
| 0:34–0:39 | Step 5: warm scale-out.<br>ステップ 5: warm スケールアウト | live (1s) |
| 0:39–0:50 | Step 6: weights, three variants, TTFT.<br>ステップ 6: ウェイト 3 通りと TTFT | prior figures |
| 0:50–1:00 | Section 5: what to adopt. Discussion.<br>セクション 5: 何を採用するか。議論 | discussion |

The baseline run takes one to two minutes. During that time `bench.sh` prints each step's
figure as it completes:

baseline の実行には 1〜2 分かかります。その間、`bench.sh` は各段階の数字を完了時に出力します。

```
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
```

The output stops after "image pull started" and resumes when the pull completes. That
pause is the measurement the workshop is about, so it is worth describing while it
happens:

出力は "image pull started" の後で止まり、pull 完了時に再開します。この間の停止が
ワークショップの主題となる計測なので、その間に説明する価値があります。

> The node was ready in about thirty seconds. What we are waiting for now is the image.
>
> ノードは 30 秒程度でできています。いま待っているのはイメージです。

While waiting, show the configuration diffs. Keep these open in advance:

待っている間に設定差分を表示してください。事前に開いておきます。

```bash
bin/show_config.sh soci        # against the baseline
bin/show_config.sh automode    # against the SOCI variant
```

---

## 2. What to cover in each step / 各ステップで扱う内容

### Step 1 — the baseline

Start `bin/bench.sh baseline`, then describe what it is measuring.

> This is Bottlerocket with its default settings. The figures from this run are what the
> later variants are compared against.
>
> Bottlerocket を既定設定で動かしています。この実行の数字が、以降の variant の比較対象に
> なります。

When it finishes:

> Provisioning took about thirty seconds. The image pull took ninety-six. So the
> difference between the variants is going to come from how the image reaches the node, not
> from how the node is provisioned.
>
> プロビジョニングは約 30 秒、イメージ pull は 96 秒でした。したがって variant 間の差は、
> ノードの作り方ではなくイメージの届き方から生じます。

Cover how the breakdown is produced, because it determines whether the figures are worth
discussing:

内訳の算出方法にも触れてください。数字を議論に使えるかを決める部分です。

> These stages are the timestamps that are already in the Pod conditions, the NodeClaim
> conditions and the kubelet events, sorted and subtracted. That is why they add up to
> the total: no interval is left out.
>
> ここに出ている段階は、Pod の condition、NodeClaim の condition、kubelet のイベントに
> 元から入っている時刻を並べて差を取ったものです。だから合計が全体と一致します。除外して
> いる区間はありません。

Then read the throughput figure, which leads into step 3:

続いてスループットの数字を読みます。ステップ 3 への導入になります。

> Nine gigabytes in ninety-six seconds is about a hundred megabytes a second. This
> instance supports up to 25 Gbps, so the pull was not limited by the network. Layers
> are being downloaded and unpacked one at a time.
>
> 9 GB を 96 秒、約 100 MB/秒です。このインスタンスは最大 25 Gbps に対応するので、pull は
> ネットワークで律速されていません。レイヤを 1 つずつダウンロード・展開しています。

### Steps 2 and 3 — the two image mechanisms

State that the two cannot be combined before showing either set of figures.

どちらの数字を出す前に、2 つが併用できないことを伝えてください。

> There are two approaches, and they cannot both be applied to the same node. Both govern
> the volume Bottlerocket uses for container images, so setting up one means the other is
> not used.
>
> 方法は 2 つあり、同じノードには併用できません。どちらも Bottlerocket がコンテナ
> イメージに使うボリュームを対象にしているため、一方を設定するともう一方は使われません。

Show the snapshot configuration before running it. It is one field, which is worth displaying
rather than describing:

snapshot は実行前に設定を表示してください。1 フィールドなので、口頭で説明するより表示する
方が早いです。

```bash
bin/show_config.sh snapshot
```

After the run:

> There is no pull stage. kubelet reported the image as already present, so the registry
> was not contacted.
>
> pull の段階がありません。kubelet はイメージが既に存在すると報告しており、レジストリには
> 接続していません。

Then state the cost, before it is asked about:

続いて、質問される前にコストを伝えてください。

> Building that snapshot took several minutes, and it has to be rebuilt whenever the
> image changes. That is the figure to weigh against the improvement in section 5.
>
> このスナップショットの作成には数分かかり、イメージが変わるたびに作り直しが必要です。
> セクション 5 で改善幅と比較する数字はこれです。

For the SOCI variant, show the configuration and note that Bottlerocket takes TOML settings:

soci では設定を表示し、Bottlerocket が TOML 設定を取ることに触れてください。

> Two additions. A policy line, and Bottlerocket settings in TOML. Bottlerocket's
> userData is settings, not a shell script, which differs from Amazon Linux.
>
> 追加は 2 箇所です。ポリシー 1 行と、TOML の Bottlerocket 設定です。Bottlerocket の
> userData はシェルスクリプトではなく設定であり、この点は Amazon Linux と異なります。

> The baseline and SOCI variants differ by one mechanism, with the same provisioner, OS and instance
> type. That makes the difference between them attributable to that mechanism.
>
> baseline と soci は、プロビジョナ・OS・インスタンスタイプが同じで、異なるのは 1 つの方式
> だけです。このため両者の差はその方式に帰属できます。

### Step 4 — Auto Mode

Show the configuration diff before the figures.

数字より先に設定差分を表示してください。

```bash
bin/show_config.sh automode
```

> `instanceStorePolicy` is absent. The six lines of Bottlerocket settings are absent. The
> block device mappings are absent. On a GPU instance with local NVMe, Auto Mode formats
> the NVMe, places container storage on it, and pulls and unpacks in parallel.
>
> `instanceStorePolicy` がありません。Bottlerocket 設定 6 行もありません。ブロック
> デバイスの指定もありません。ローカル NVMe 付き GPU インスタンスでは、Auto Mode が NVMe を
> フォーマットし、コンテナストレージを配置し、並列で pull・展開します。

State the two options that are not available:

使えない選択肢を 2 点伝えてください。

> Two things are not available here. There is no `snapshotID` on the NodeClass, so step
> 2's mechanism cannot be used — a workload that needs pre-baked images cannot run on
> Auto Mode. And the SOCI settings are not exposed, so the service defaults apply.
>
> ここで使えないものが 2 点あります。NodeClass に `snapshotID` が無いため、ステップ 2 の
> 方式は使えません。イメージの事前焼き込みが必要なワークロードは Auto Mode では動きません。
> また SOCI の設定は露出しておらず、サービスの既定値が適用されます。

State the cluster difference:

クラスターが異なる点も伝えてください。

> The Auto Mode variant runs on a separate cluster, because self-managed Karpenter and Auto Mode both own
> the same CRDs. The VPC, subnets and instance type are the same, so the pull path is the
> same, but the control plane is not. And the timing difference between the SOCI and Auto Mode variants
> is within the run-to-run variation — the reference results have two runs where the
> ordering between them is different. The difference in configuration is consistent; the
> difference in timing is not.
>
> automode は別のクラスターで動きます。self-managed Karpenter と Auto Mode が同じ CRD を
> 所有するためです。VPC・サブネット・インスタンスタイプは同じで pull 経路も同じですが、
> コントロールプレーンは異なります。また soci と automode の時間差は実行ごとのばらつきの
> 範囲内です。参考計測には両者の順序が異なる 2 回分が入っています。設定量の差は一定ですが、
> 時間の差は一定ではありません。

### Step 5 — warm scale-out

Run this immediately after soci, while that node is still present. It takes about a
second.

soci の直後、そのノードが残っている間に実行してください。1 秒程度で終わります。

> Everything so far measured the first pod on a new node. When a deployment scales out,
> some pods are scheduled onto nodes that are already running. This is the same variant with
> the node kept.
>
> ここまではすべて、新しいノードでの 1 個目の Pod を計測しています。Deployment が
> スケールアウトすると、一部の Pod はすでに動いているノードにスケジュールされます。これは
> 同じ variant を、ノードを残して実行したものです。

> Ninety-six of the ninety-seven seconds was incurred once per node, not once per pod.
> Two things follow. First, the snapshot variant's improvement applies to the first pod on a node and
> not to this one. Second, if most of your pods land on nodes that are already running,
> the three mechanisms we just measured affect a small part of your total startup time,
> and node capacity policy affects more of it.
>
> 97 秒のうち 96 秒が、Pod ごとではなくノード 1 台につき 1 回発生する分でした。ここから
> 2 点が言えます。1 つ目、snapshot の改善はノードの 1 個目の Pod に効き、この Pod には効きません。
> 2 つ目、Pod の大半がすでに動いているノードに乗る場合、いま計測した 3 方式が影響するのは
> 起動時間全体の一部で、ノードのキャパシティ方針の方が影響が大きくなります。

Question to put to participants:

参加者への質問:

> What proportion of your pods are scheduled onto new nodes, and what proportion onto
> nodes that are already running?
>
> Pod のうち、新しいノードにスケジュールされる割合と、すでに動いているノードに
> スケジュールされる割合はどれくらいですか。

### Step 6 — weights, and why there are three variants

Explain the two variables before showing any figures.

数字を出す前に、変数が 2 つあることを説明してください。

> Three variants. The node, model and bytes are the same in all three, and the vLLM
> arguments differ. There are three rather than two because the loader and the delivery
> method are separate variables. The first-to-second comparison changes only the loader.
> The second-to-third changes only the delivery.
>
> 3 通りです。ノード、モデル、バイト列は 3 つとも同じで、vLLM の引数が異なります。3 つある
> のは、ローダーと配送方法が別の変数だからです。1 つ目から 2 つ目はローダーのみ、2 つ目から
> 3 つ目は配送のみが変わります。

Point at the vLLM timings in the output:

出力に含まれる vLLM の内訳を指してください。

> These lines come from vLLM's log. Reading the weights took 0.31 seconds out of
> ninety-six. Compiling and warming the engine took about forty-two. A faster loader can
> only affect the 0.31 seconds.
>
> この行は vLLM のログです。ウェイトの読み込みは 96 秒中 0.31 秒でした。コンパイルと
> エンジンのウォームアップで約 42 秒です。より速いローダーが影響できるのは 0.31 秒の側
> だけです。

When the loader-only variant shows no change:

ローダーのみの variant で差が出なかった場合:

> The total did not change. At this model size reading the weights was already a small
> part of the startup time, so a faster way of reading them had little to affect. Without
> the vLLM log lines, this result would only show that the total did not change, without
> indicating why.
>
> 合計は変わりませんでした。このモデルサイズではウェイトの読み込みが元から起動時間のごく
> 一部であり、速く読む手段が影響できる範囲が小さかったためです。vLLM のログが無ければ、
> この結果は合計が変わらなかったことしか示さず、理由は分かりません。

For the S3-direct variant:

S3 直読みの variant では:

> This one reduced the total, from ninety-six to eighty-two seconds. The model load time
> went up, from 0.63 to 3.36 seconds, so reading from S3 is slower per tensor than
> reading from local disk. The reduction comes from removing the copy step. At a larger
> model size the loader would account for more of the time.
>
> こちらは合計を 96 秒から 82 秒に短縮しました。モデルロード時間は 0.63 秒から 3.36 秒に
> 増えており、S3 からの読み込みはテンソル単位ではローカルディスクより遅くなっています。
> 短縮分はコピー工程が無くなったことによります。モデルが大きければ、ローダーが占める割合も
> 大きくなります。

Cover serialisation and credentials:

直列化と認証情報についても触れてください。

> kubelet pulls the init image, runs the init container, and then pulls the workload
> image. Those do not overlap, so moving weights out of the image can increase
> start-to-Ready even though the image is smaller.
>
> kubelet は init イメージを pull し、init コンテナを実行し、その後で本体イメージを pull
> します。これらは重ならないため、イメージからウェイトを出してイメージが小さくなっても
> start-to-Ready が伸びる場合があります。

> Credentials come from EKS Pod Identity rather than the node role. Karpenter sets the
> IMDS hop limit to 1, so containers cannot reach instance metadata. That prevents pods
> from using node permissions, and binding a role to a service account is what to use in
> production.
>
> 認証情報はノードロールではなく EKS Pod Identity から取得します。Karpenter は IMDS の
> hop limit を 1 に設定するため、コンテナはインスタンスメタデータに到達できません。これは
> Pod がノードの権限を使うことを防ぐもので、サービスアカウントにロールを紐付ける方法は
> 本番でも使えます。

### Section 5 — what to adopt

Display the decision table and leave time for discussion.

判断表を表示し、議論の時間を残してください。

> What you take away is the repository and the measurement method. The figures to base a
> decision on are the ones from your own account.
>
> 持ち帰るのはリポジトリと計測方法です。判断に使う数字は、自分のアカウントで出る数字です。

> Two measurements determine most of the choice: how often your images change, which is
> what decides between the snapshot and SOCI variants; and how much of your startup time is incurred once
> per node, which decides whether any of these mechanisms affects most of it.
>
> 選択の大半は 2 つの計測で決まります。イメージの更新頻度（snapshot と soci のどちらを選ぶかを
> 決める）と、起動時間のうちノード 1 回あたりに発生する分（これらの方式が全体の大部分に
> 影響するかを決める）です。

---

## 3. When something fails / 失敗した場合

| Symptom / 症状 | Cause / 原因 | Action / 対応 |
|---|---|---|
| The node does not launch<br>ノードが起動しない | GPU quota or capacity<br>クォータか在庫 | Use `results-dryrun-*` with `bin/report.py` and say the figures are from the previous day<br>`results-dryrun-*` を `bin/report.py` で表示し、前日の数字と伝える |
| `ImagePullBackOff` | The DLC tag has changed<br>DLC のタグが変わった | Update `WORKLOAD_IMAGE` in `config.env`. Task 8 prevents this.<br>`config.env` の `WORKLOAD_IMAGE` を更新。作業 8 で防げる |
| soci's figures match the baseline's<br>soci が baseline と同じ | Bottlerocket earlier than 1.44.0, so the SOCI setting is ignored<br>Bottlerocket が 1.44.0 より前で SOCI 設定が無視された | `prep.sh` checks this beforehand. If it occurs, the version dependency can be shown as part of the session.<br>`prep.sh` が事前に確認。発生した場合はバージョン依存の例として扱える |
| snapshot's pod stays Pending<br>snapshot の Pod が Pending | No snapshot, so the node class was not applied<br>スナップショットが無く node class が未適用 | Check `results/snapshot-id.txt`. Use the previous day's figures for it.<br>`results/snapshot-id.txt` を確認。snapshot は前日の数字で |
| The pod never becomes Ready and `nvidia-smi` fails<br>Ready にならず `nvidia-smi` が失敗 | Kubernetes earlier than 1.34 with a CUDA 13 image<br>Kubernetes が 1.34 未満で CUDA 13 イメージ | Check this before the day.<br>前日に確認 |
| The Run:ai variants fail to start<br>Run:ai 系が起動しない | `runai-streamer` missing, S3 permissions, or region unset<br>`runai-streamer` 不在、S3 権限、region 未設定 | Show `runai-local` only; the loader comparison still works.<br>`runai-local` のみ表示。ローダー比較は成立する |
| The TTFT probe fails<br>TTFT プローブが失敗 | The ConfigMap was not created<br>ConfigMap が未作成 | `bin/prep.sh` creates it. Use the Ready figures.<br>`bin/prep.sh` が作成。Ready までの数字で進める |
| Running late<br>時間が押している | — | Reduce phase 2 from three variants to two, the first and third. Keep section 5.<br>フェーズ 2 を 1 つ目と 3 つ目の 2 本に減らす。セクション 5 は残す |

---

## 4. Points to state accurately / 正確に伝えるべき点

- Custom AMI builds are out of scope. If asked, the answer is to wait for the upstream
  release and raise the roadmap question separately.
  カスタム AMI ビルドは対象外です。聞かれた場合は、上流のリリースを待ち、ロードマップの
  質問は別途扱う、が回答になります。
- The automode variant runs on a different control plane, and its timing difference from soci is within
  the run-to-run variation. Present it as what Auto Mode provides without configuration,
  not as a faster result.
  automode はコントロールプレーンが異なり、soci との時間差は実行ごとのばらつきの範囲内です。
  速いという結果ではなく、Auto Mode が設定なしで提供する内容として提示してください。
- The SOCI settings are the values AWS publishes as a starting point. They are not fitted
  to any particular layer profile.
  SOCI の設定値は AWS が出発点として公開しているものです。特定のレイヤ構成に合わせた値では
  ありません。
- Each variant was measured once. Differences below about 10% need a repeat run before being
  relied on.
  各 variant は 1 回の計測です。10% 程度未満の差は、再実行で確認してから判断してください。
- If you cite Run:ai's published benchmark figures for scale, state the source and the
  model size, and keep them separate from the figures measured here.
  規模感のために Run:ai の公開ベンチマーク値を引用する場合は、出典とモデルサイズを述べ、
  ここで計測した数字とは分けてください。
- Run:ai Model Streamer is Apache-2.0 licensed and is included in the AWS vLLM DLC base
  image. No additional licence or installation is involved.
  Run:ai Model Streamer は Apache-2.0 ライセンスで、AWS vLLM DLC のベースイメージに
  含まれています。追加のライセンスやインストールは発生しません。
- If you show the recording, state that idle time is compressed in playback and that the
  elapsed times shown on screen are the measured values.
  録画を見せる場合、再生時に待ち時間が短縮されていること、画面に出ている経過時間は計測値
  そのままであることを伝えてください。

---

## 5. Have open / 開いておくもの

1. Two terminals: one for `bench.sh`, one running
   `watch kubectl get pod,nodeclaim -A`
   ターミナル 2 枚（`bench.sh` 用と `watch` 用）
2. `bin/show_config.sh soci` and `bin/show_config.sh automode`
3. `results-dryrun-*/report.md`, in case a live run fails
   本番の実行が失敗した場合用
4. The section 5 decision table from the README
   README のセクション 5 判断表
5. [Auto Mode NodeClass reference](https://docs.aws.amazon.com/eks/latest/userguide/create-node-class.html),
   for questions about `snapshotID`
   `snapshotID` について質問が出た場合用

---

## 6. After the session / 終了後

- Hand over `results/report.md` unchanged. It contains the measured figures.
  `results/report.md` はそのまま渡してください。計測した数字が入っています。
- Hand over the repository. This guide is for the facilitator.
  リポジトリを渡してください。このガイドは実施側用です。
- Agree a date by which participants will run the steps in their own account. Without
  that, the session does not produce figures they can use.
  参加者が自分のアカウントで手順を実行する期限を決めてください。決めないと、参加者が
  使える数字が出ません。
- Run `terraform destroy`, then delete the snapshot and the staged weights, which are
  outside Terraform. See [README](README.md#teardown--破棄).
  `terraform destroy` を実行し、その後 Terraform 管理外のスナップショットと S3 のウェイトを
  削除してください。
