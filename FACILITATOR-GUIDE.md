# Facilitator Guide / ファシリテーターガイド

For whoever runs this workshop in front of an audience. The [README](README.md) is
the runbook you hand over; this is the part you keep.

このワークショップを人前で実施する担当者向けです。[README](README.md) は参加者に渡す
手順書で、こちらは実施側が持つものです。

**Format: Show and Follow.** You prepare and run everything in your own AWS
account and share your screen. Participants then repeat the same steps in their own
Dev account using the runbook, which is where *their* numbers come from. There is
no Workshop Studio dependency and **participants do not need an account or GPU
quota on the day** — worth saying in the first minute, so nobody's missing
prerequisites derail the session.

**形式は Show and Follow です。** 実施側が自分の AWS アカウントで全て準備・実行し、
画面共有します。参加者は後日、手順書を使って自分の Dev アカウントで同じ手順を再実行し、
**そこで出る数字**が判断材料になります。Workshop Studio は不要で、**当日参加者側に
アカウントや GPU クォータは不要**です。これは冒頭 1 分で明示してください。参加者側の
前提不足で議論が止まるのを防げます。

---

## 0. Before the day / 前日までに

The single biggest determinant of whether the session goes well.

当日の成否を最も左右する部分です。

| # | Task / 作業 | Time | If skipped / 未了だと |
|---|---|---|---|
| 1 | `terraform apply` — build both clusters<br>クラスター 2 面を作る | 25–30 min | 30 minutes gone on the day<br>当日 30 分消える |
| 2 | `bin/bench.sh arm-a-baseline`, then `snapshot/snapshot-from-node.sh`<br>arm A 実行 → スナップショット作成 | 10 min | arm B cannot be demonstrated<br>arm B が実演できない |
| 3 | `snapshot/stage-model.sh` — weights to S3<br>ウェイトを S3 へ | 5–10 min | phase 2 cannot run<br>フェーズ 2 が動かない |
| 4 | `bin/prep.sh` — apply the arms<br>arm を適用 | 2 min | nothing runs<br>何も動かない |
| 5 | **Run all four arms, the warm run, and all three phase-2 variants once**<br>**4 arm + warm + phase 2 の 3 通りを 1 回ずつ通す** | 40–50 min | first-time execution on the day will bite<br>当日初回実行は事故る |
| 6 | `bin/check_runai.sh`<br>Run:ai の可用性確認 | 3 min | phase 2's two Run:ai variants may crash-loop live<br>Run:ai 系 2 本が実演中に落ちうる |
| 7 | GPU quota `L-DB2E81BA` ≥ 64 vCPU | 5 min | arms queue instead of launching<br>arm が起動せず待ちになる |
| 8 | Confirm the vLLM DLC tag still exists<br>vLLM DLC のタグ存在確認 | 2 min | `ImagePullBackOff`<br>同 |

**Step 5 matters most.** Keep those results — if the live run fails you can show
the previous day's real numbers and carry on. Treat the live demo as showing *how*
the numbers are made, not as the only chance to make them.

**5 が最重要です。** その結果を保存しておけば、ライブが転んでも前日の実測値を出して
議論を続けられます。ライブ実演は「数字の作り方を見せるもの」で、「数字を作る唯一の機会」
ではないと割り切ってください。

```bash
cp -r results results-dryrun-$(date +%Y%m%d)
```

---

## 1. Timing / 時間配分

Sixty minutes.

| Time | Content | Live? |
|---|---|---|
| 0:00–0:05 | Purpose and scope. State that custom AMI builds are out of scope.<br>目的とスコープ。カスタム AMI は対象外と明示 | slides |
| 0:05–0:15 | **Section 1: where the time goes.** Run arm A and wait.<br>時間がどこに消えるか。arm A を実行して待つ | live |
| 0:15–0:27 | **Section 2: two mechanisms, mutually exclusive.** Arms B and C.<br>2 方式とその排他性。arm B と C | live |
| 0:27–0:34 | **Section 3: Auto Mode.** Show the config diff first, then the number.<br>Auto Mode。先に設定差分、次に数字 | diff + prior numbers |
| 0:34–0:39 | **Warm scale-out.** Once-per-node cost.<br>warm スケールアウト。ノード 1 回コスト | live (1s) |
| 0:39–0:50 | **Section 4: weights, three variants, TTFT.**<br>ウェイト 3 通りと TTFT | prior numbers |
| 0:50–1:00 | **Section 5: what to adopt.** Discussion.<br>何を採用するか。議論 | discussion |

**Arm A's run leaves you a wait of a minute or two, and the screen does not go
blank** — `bench.sh` prints each step's number as it completes:

**arm A の実行で 1〜2 分の待ちができますが、画面は空白になりません。** `bench.sh` は
各段階の数字をその都度出します。

```
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s   <- stalls here
```

**That one stalling line is the argument.** Everything before it scrolls past in
half a minute; then nothing moves. Point at the silence:

**この 1 行で止まることが、そのまま主張です。** それ以前は 30 秒で流れ、そこから動かなく
なります。その沈黙を指して話してください。

> That is where we are now. The node was ready in about thirty seconds. What we are
> waiting for is the image.
>
> いま止まっているのがそれです。ノードは 30 秒程度でできています。待っているのは
> イメージです。

While it stalls, show the manifest diffs (keep these open in tabs):

止まっている間に、マニフェストの差分を見せてください（事前にタブで開いておく）。

```bash
diff -u manifests/rendered/10-arm-a-baseline.yaml manifests/rendered/12-arm-c-soci.yaml
diff -u manifests/rendered/12-arm-c-soci.yaml manifests/rendered/13-arm-d-automode.yaml
```

The second diff is the strongest single screen in the workshop. **Count the lines
present on the left and absent on the right.**

2 本目の差分が、このワークショップで最も効く 1 画面です。**左にあって右に無い行を
数えてもらってください。**

---

## 2. What to say / 話す内容

### Section 1 — where the time goes

Start `bin/bench.sh arm-a-baseline`, then talk while it runs.

> This is the baseline: Bottlerocket exactly as it ships. Every number after this is
> measured against it.
>
> ベースラインです。Bottlerocket を素のまま使っています。以降の数字はすべてこれとの
> 比較になります。

When it finishes:

> Provisioning was under half a minute. The image pull was roughly three times
> everything else put together. **The fix is not in how you provision nodes — it is
> in how the image gets to them.** Get that the wrong way round and you spend a
> sprint tuning Karpenter.
>
> プロビジョニングは 30 秒未満。イメージ pull はそれ以外の合計の約 3 倍でした。
> **改善すべきはノードの作り方ではなく、イメージの届け方です。** ここを取り違えると
> Karpenter の設定に無駄な時間を使います。

Establish credibility of the method in one sentence:

計測方法の信頼性を 1 文で担保します。

> This breakdown is not an estimate. It is the timestamps already in the Pod
> conditions, the NodeClaim conditions and the kubelet events, sorted and
> subtracted. **That is why the stages sum exactly to the total** — there is no
> unattributed time.
>
> この内訳は推定ではありません。Pod の condition、NodeClaim の condition、kubelet の
> イベントに元から入っている時刻を並べて差を取っただけです。**だから段階の合計は
> 全体と厳密に一致します。** 取りこぼした時間はありません。

Then read the throughput line — it is the bridge to arm C:

続いてスループットの行を読みます。arm C への導線になります。

> Nine gigabytes in ninety-six seconds is about a hundred megabytes a second. This
> instance can do far more than that. **We are not using the link we are paying
> for**, because layers are being unpacked one at a time.
>
> 9 GB を 96 秒、約 100 MB/秒です。このインスタンスはもっと出せます。**支払っている
> 帯域を使い切れていません。** レイヤを 1 つずつ順番に展開しているからです。

### Section 2 — two mechanisms, and you only get one

**Lead with the exclusivity**, before either number.

**先に排他性を言ってください。** 数字より前に。

> There are two approaches and **you can only have one of them.** You can write both
> sets of settings, but it is pointless, because they compete for the same volume —
> the one Bottlerocket uses for container images.
>
> 方法は 2 つあり、**どちらか一方しか選べません。** 両方の設定を書くことはできますが
> 無意味です。Bottlerocket がコンテナイメージに使う同じボリュームを取り合うからです。

Run arm B (fast, good live):

> The pull stage is gone. kubelet reports the image as already present on the
> machine. It never contacted the registry.
>
> pull の段が消えました。kubelet はイメージが既にマシン上にあると報告しています。
> レジストリには一度も行っていません。

**Then volunteer the cost, before anyone asks:**

**誰かに聞かれる前に、コストを自分から出してください。**

> That speed has a price. Building the snapshot took several minutes, and it has to
> be rebuilt every time the image changes. Hold that thought for section 5.
>
> この速さには値段があります。スナップショット作成に数分かかり、イメージを更新する
> たびに作り直します。セクション 5 まで覚えておいてください。

Then arm C:

> Instead of pre-baking, we move container storage to the instance's local NVMe and
> switch the snapshotter to SOCI in parallel pull/unpack mode. **The image is
> completely unmodified** — no index to build, no change to your build pipeline.
>
> 事前焼き込みの代わりに、コンテナストレージをインスタンスのローカル NVMe に移し、
> snapshotter を SOCI の parallel pull/unpack モードにします。**イメージは一切
> 変更しません。** index の作成もビルドパイプラインの変更も不要です。

> A against C is the honest comparison in this whole workshop: same provisioner,
> same OS, same instance type, one mechanism changed.
>
> A と C の比較が、このワークショップで最も厳密です。プロビジョナ、OS、インスタンス
> タイプが同一で、変えたのは 1 つの方式だけです。

### Section 3 — Auto Mode

**Show the diff before the number. Do not reverse this.**

**数字より先に差分を見せてください。順番を逆にしないこと。**

> Here is arm C's node class against arm D's. **Count what is on the left and not on
> the right.** `instanceStorePolicy` — gone. Six lines of Bottlerocket settings —
> gone. Block device mappings — gone.
>
> arm C と arm D の node class です。**左にあって右に無いものを数えてください。**
> `instanceStorePolicy` が無い。Bottlerocket の設定 6 行が無い。ブロックデバイスの
> 指定が無い。

> And yet on a GPU instance with local NVMe, Auto Mode formats the NVMe, puts
> container storage on it, and pulls and unpacks in parallel. **That is arm C's
> configuration, done by the service.**
>
> それでもローカル NVMe 付き GPU インスタンスでは、Auto Mode が NVMe をフォーマット
> し、コンテナストレージをそこに置き、並列で pull・展開します。**arm C で手で書いた
> 内容が、サービス側で入っています。**

**Volunteer both limitations yourself.** Concealing them costs more later.

**できないことを 2 点、自分から言ってください。** 隠すと後で高くつきます。

> Two things it cannot do. First, **there is no `snapshotID` on its NodeClass** —
> `ephemeralStorage` is size, IOPS, throughput and KMS key only. So **arm B's
> mechanism is not available on Auto Mode.** If pre-baked images are the right
> answer for a workload, that workload does not go here. Second, **the SOCI tuning
> knobs are not exposed**; you get the service defaults.
>
> できないことが 2 点あります。1 つ目、**NodeClass に `snapshotID` がありません。**
> `ephemeralStorage` は size / IOPS / throughput / KMS キーのみです。つまり
> **arm B の方式は Auto Mode では取れません。** あるワークロードの答えが事前焼き込み
> なら、それはここには乗りません。2 つ目、**SOCI のチューニング項目は露出していません。**
> サービスの既定値を使うことになります。

Also disclose the cluster difference:

クラスターが別である点も開示します。

> Arm D is measured on a separate cluster — self-managed Karpenter and Auto Mode own
> the same CRDs, so we did not co-locate them. Same VPC, subnets and instance type,
> so the pull path is identical, but the control plane is not. **Read A versus C as
> exact, and D as an indication of what you get for no configuration.**
>
> arm D は別クラスターで計測しています。self-managed Karpenter と Auto Mode が同じ
> CRD を持つため同居させませんでした。VPC・サブネット・インスタンスタイプは同一なので
> pull 経路は同じですが、コントロールプレーンは別です。**A と C の比較を厳密、
> D は「無設定で何が得られるか」の目安として読んでください。**

### Warm scale-out

Run it immediately after arm C, while that node is still up. It takes about a second.

arm C の直後、そのノードが残っているうちに実行してください。1 秒程度で終わります。

> That was **the first pod on a new node.** Real scale-out usually is not that. It
> lands on a node that is already running. Same arm, node kept this time.
>
> いまのは**新しいノードの 1 個目の Pod**です。実際のスケールアウトは通常そうでは
> ありません。すでに動いているノードに乗ります。同じ arm を、ノードを消さずにもう一度。

> Nearly all of the cold number was a **once-per-node** cost, not once-per-pod.
> I am showing you this for one specific reason: **it stops the snapshot being
> over-credited.** A snapshot helps the cold pod and does nothing at all for the
> warm one.
>
> cold の数字のほぼ全部が**ノード 1 台につき 1 回だけ**のコストで、Pod ごとでは
> ありません。これを見せる理由は 1 つで、**スナップショットを過大評価しないため**です。
> スナップショットが効くのは cold な 1 個目だけで、warm には何もしません。

**Then ask the question that reframes everything:**

**そして全体を再定義する問いを投げてください。**

> When your pods scale out, what fraction land on new nodes versus nodes that are
> already running? If it is mostly the latter, **none of the three mechanisms we
> just measured is where your time goes** — the answer is capacity policy instead.
>
> Pod が増えるとき、新しいノードに乗る割合と既存ノードに乗る割合はどれくらいですか。
> 後者が大半なら、**いま計測した 3 方式はどれもあなたの時間の使われ先ではありません。**
> 答えはキャパシティ方針になります。

### Section 4 — weights, and why there are three variants

**State the two-effect split before any number.**

**数字の前に、効果が 2 段に分かれていることを説明してください。**

> Three variants. Same node, same model, same bytes. **Only the loader differs** —
> and there are three rather than two because **the effect splits in two.**
>
> 3 通りです。ノード・モデル・バイト列は同一で、**変えたのはローダーだけ**。3 つある
> 理由は、**効果が 2 段に分かれるから**です。

> First to second changes **only the loader** — identical bytes on identical disk, so
> that difference is what concurrent tensor streaming is worth on its own. Second to
> third changes **only the delivery** — the copy step disappears. Reporting them
> separately is what stops one effect being credited to the other.
>
> 1 つ目から 2 つ目は**ローダーのみ**の変更です。同じディスクの同じバイト列なので、
> その差は並列ストリーミング単体の効果です。2 つ目から 3 つ目は**配送のみ**の変更で、
> コピー工程が消えます。分けて報告するのは、**一方の効果をもう一方の功績にしない**ためです。

**Point at the vLLM timings.** This is the part most likely to be misread:

**vLLM の内訳を指してください。** ここが最も誤読されやすい部分です。

> Look under "workload becomes Ready". These lines are from vLLM's own log.
> **Reading the weights is a fraction of a second. Compiling and warming the engine
> is tens of seconds.** A faster loader can only touch the fraction of a second.
>
> 「workload becomes Ready」の下を見てください。これは vLLM 自身のログです。
> **ウェイトの読み込みは 1 秒未満。コンパイルとエンジンのウォームアップが数十秒です。**
> ローダーの高速化が触れるのは 1 秒未満の側だけです。

If the loader-only variant shows no gain, **say so plainly — it is the useful
result**:

ローダーのみの変更で差が出なかった場合、**そのまま言ってください。それが有用な結果です。**

> Essentially nothing changed, and that is worth more than a win would have been. At
> this model size **the weights were never the bottleneck**, so a faster way of
> reading them had nothing to win. Had we shown only a before-and-after total, we
> would have concluded the tool does not work. The vLLM timings show it was never
> given anything to do.
>
> ほぼ変わりませんでした。これは改善が出るより価値があります。このモデルサイズでは
> **ウェイトが最初からボトルネックではなかった**ので、速く読む手段に取り分が
> ありませんでした。前後の合計だけ見ていたら「このツールは効かない」と結論していたはずです。
> vLLM の内訳が、そもそも仕事を与えられていなかったことを示しています。

For the S3-direct variant, be precise about where the gain comes from:

S3 直読みでは、短縮の出所を正確に言ってください。

> That one does move — but not by loading faster. Streaming from S3 is slightly
> slower per tensor than reading local disk. **The gain is from deleting a step**,
> not from doing it faster. On a larger model the loader would matter too; at this
> size, only the delivery does.
>
> こちらは動きます。ただしロードが速いからではありません。S3 ストリーミングは
> テンソル単位ではローカルディスクより僅かに遅いです。**短縮の出所は工程の削除**で、
> 高速化ではありません。大きいモデルならローダーも効きますが、このサイズでは配送だけです。

Serialisation is worth naming explicitly:

直列化は明示的に言う価値があります。

> One structural point: kubelet pulls the init image, runs the init container, and
> **only then** pulls the workload image. Those are serialised. **So moving weights
> out of the image can push start-to-Ready up even though the image got smaller.**
> The S3-direct variant deletes that step rather than optimising it.
>
> 構造的な点を 1 つ。kubelet は init イメージを pull し、init コンテナを実行し、
> **その後で**本体イメージを pull します。直列です。**つまりイメージからウェイトを
> 出しても、イメージが小さくなったのに start-to-Ready が伸びることがあります。**
> S3 直読みはこの工程を最適化するのではなく削除します。

Mention TTFT and credentials in a line each:

> Ready only means vLLM answers its health endpoint. **Submit to first token is the
> number a user would feel.**
>
> Ready は vLLM が health に応答することしか意味しません。**submit から最初のトークン
> までが、利用者が体感する数字です。**

> Credentials come from **EKS Pod Identity**, not the node role. Karpenter sets the
> IMDS hop limit to 1, so containers cannot reach instance metadata — which is the
> correct default. Scoping a role to one service account is both what works and what
> to do in production.
>
> 認証情報は**ノードロールではなく EKS Pod Identity** から取得します。Karpenter は
> IMDS の hop limit を 1 にするため、コンテナはメタデータに到達できません。これは
> 正しい既定です。サービスアカウント単位でロールを絞ることが、動く方法であり本番でも
> 正しい方法です。

### Section 5 — what to adopt

Put the decision table on screen and talk less. This is discussion time.

判断表を画面に出し、話す量を減らしてください。議論の時間です。

> What you take away is the runbook and the method. **The numbers that matter are
> the ones from your own Dev account.**
>
> 持ち帰るのは手順書と計測方法です。**判断に使える数字は、あなたの Dev アカウントで
> 出る数字です。**

> Two questions decide most of it, and neither is a matter of opinion. **How often do
> your images change** — that is the fork between B and C. And **how much of your
> startup cost is once-per-node** — that is whether any of this is the right thing
> to optimise at all.
>
> 大半を決めるのは 2 つの問いで、どちらも意見の問題ではありません。**イメージの更新
> 頻度** — B と C の分かれ目です。そして**起動コストのうちノード 1 回あたりの割合** —
> そもそもこれが最適化すべき対象かどうかを決めます。

---

## 3. When it breaks / 転んだとき

| Symptom / 症状 | Cause / 原因 | On the spot / その場の対応 |
|---|---|---|
| Node will not launch<br>ノードが立たない | GPU quota or capacity<br>クォータか在庫 | Switch to `results-dryrun-*` and run `bin/report.py` on it. **Do not apologise** — say "these are yesterday's measurements".<br>前日結果に切替。**謝らず**「前日の実測です」と言う |
| `ImagePullBackOff` | DLC tag moved<br>タグが変わった | Replace `WORKLOAD_IMAGE` in `config.env`. Will not happen if step 8 was done.<br>`config.env` を差し替え。前日確認済みなら起きない |
| Arm C matches arm A<br>arm C が arm A と同じ | Bottlerocket < 1.44.0, SOCI silently off<br>SOCI が無効 | `prep.sh` blocks this beforehand. If it happens anyway, **use it** — it shows the version dependency.<br>`prep.sh` が事前に止める。起きたら**それ自体を材料に** |
| Arm B pod Pending | No snapshot, node class not applied<br>スナップショット未作成 | Check `results/snapshot-id.txt`. Skip arm B live and use prior numbers.<br>確認し、arm B は前日の数字で |
| Pod never Ready, `nvidia-smi` fails<br>Ready にならない | Kubernetes < 1.34 with a CUDA 13 image<br>版不一致 | Pre-day check. Nothing to do live.<br>前日確認事項 |
| Run:ai variants crash-loop | `runai-streamer` missing, S3 permissions, region unset<br>不足・権限・region 未設定 | Show `runai-local` only — the loader-only effect still lands.<br>`runai-local` だけ見せる |
| TTFT probe fails | ConfigMap missing<br>ConfigMap 未作成 | `bin/prep.sh` creates it. Fall back to Ready-only numbers.<br>Ready までの数字で話す |
| Running late<br>時間が押している | — | Cut phase 2 from three variants to two (first and third). **Never cut section 5** — without it the session ends as "we watched a demo".<br>phase 2 を 1 つ目と 3 つ目の 2 本に削る。**セクション 5 は削らない** |

---

## 4. Do not overstate / 言い過ぎないこと

- **Custom AMI builds are out of scope.** If asked, the honest answer is usually
  "wait for the upstream release; take the roadmap question up separately".
  **カスタム AMI ビルドは対象外です。** 聞かれたら「上流のリリースを待つのが安く、
  ロードマップの話は別途」が誠実な答えです。
- **Do not present arm D as a like-for-like delta against A or C.** Different
  control plane. Present it as an indication.
  **arm D を A や C との like-for-like の差分として出さないこと。** コントロール
  プレーンが別です。目安として提示してください。
- **Do not present the SOCI tuning values as a recommendation.** They are AWS's
  published starting point, not values fitted to anyone's layer profile.
  **SOCI のチューニング値を推奨として出さないこと。** AWS が公開する出発点であって、
  誰かのレイヤ構成に合わせた値ではありません。
- **Do not present one run as settled.** Under ~10% is noise. Re-running is cheap.
  **1 回の計測を確定値として出さないこと。** 10% 未満はノイズです。再実行は安価です。
- **Do not present published third-party benchmarks as your measurement.** If you
  cite Run:ai's own figures for order-of-magnitude context, name the source and the
  model, and keep them visibly separate from your numbers.
  **第三者の公開ベンチマークを自分の実測として出さないこと。** 桁の目安として
  Run:ai 公開値を引くなら、出典とモデルを述べ、自分の数字と明確に分けてください。
- **Do not frame Run:ai Model Streamer as adding a vendor product.** It is
  Apache-2.0 and already present in the AWS vLLM DLC base image — no extra licence,
  no install.
  **Run:ai Model Streamer を「ベンダー製品の追加導入」として説明しないこと。**
  Apache-2.0 で、AWS の vLLM DLC ベースイメージに既に含まれています。追加ライセンスも
  インストールも不要です。
- **If you show the recording, say that its pace is not the measurement.** Idle time
  is compressed in playback; the printed elapsed times are real.
  **録画を見せる場合、再生速度は計測値ではないと必ず言うこと。** 再生上の待ち時間は
  圧縮されており、表示されている経過秒数が本物です。

---

## 5. Have open / 開いておくもの

1. Two terminals — one running `bench.sh`, one running
   `watch kubectl get pod,nodeclaim -A`
   ターミナル 2 枚（`bench.sh` 実行用と `watch` 用）
2. The two `diff` commands from section 1
   セクション 1 の `diff` 2 本
3. `results-dryrun-*/report.md` — for when the live run fails
   ライブが転んだとき用
4. The section 5 decision table from the README
   README のセクション 5 判断表
5. [Auto Mode NodeClass reference](https://docs.aws.amazon.com/eks/latest/userguide/create-node-class.html)
   — to show when someone asks about `snapshotID`
   `snapshotID` を聞かれたとき示す

---

## 6. Afterwards / 終わったあと

- **Hand over `results/report.md` as it is. Do not add to it.** Its value is that it
  contains only what was measured.
  **`results/report.md` はそのまま渡し、書き足さないこと。** 測ったものだけが入っている
  ことが価値です。
- Hand over the repository. **Keep this guide.**
  リポジトリを渡し、**このガイドは渡さないこと。**
- **Agree a date for the Follow half.** When will participants re-run this in their
  own account? Without that date the workshop does not produce a deliverable.
  **Follow 側の期限を決めること。** 参加者が自分のアカウントで再実行するのはいつまでか。
  ここを決めないとワークショップが成果物になりません。
- `terraform destroy`, then delete the snapshot and the staged weights — they are
  outside Terraform. See [README](README.md#teardown--破棄).
  `terraform destroy` の後、Terraform 管理外のスナップショットと S3 のウェイトを削除。
