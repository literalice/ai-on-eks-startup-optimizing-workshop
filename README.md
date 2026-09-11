# AI on EKS — Startup Time Optimizing Workshop

**English** | [日本語](#japanese)

This workshop measures how long a GPU inference pod takes to become ready on Amazon
EKS, breaks that time into stages, and then measures three methods of reducing it. Each
stage is calculated from timestamps that Kubernetes already records. The scripts that do
the measurement are included.

Out of scope: building custom Bottlerocket AMIs.

---

## What gets measured

There are four variants. The pod spec, instance type, VPC, subnets and container image
are the same in all four. The difference between them is how the container image reaches
the node.

| Variant | Node | Image mechanism | Configuration required |
|---|---|---|---|
| `baseline` | Karpenter + Bottlerocket | EBS data volume, containerd's default sequential pull | none |
| `snapshot` | Karpenter + Bottlerocket | data volume restored from an EBS snapshot that already holds the layers | build and maintain a snapshot per image version |
| `soci` | Karpenter + Bottlerocket | container storage on local NVMe, SOCI snapshotter in parallel pull/unpack mode | `instanceStorePolicy` and 6 lines of Bottlerocket settings |
| `automode` | EKS Auto Mode | local NVMe and parallel pull, both set up by the service | none |

Two constraints apply.

**`snapshot` and `soci` cannot both be used on the same node.** Both of them govern the
volume that Bottlerocket uses for container images. `snapshot` requires the images to be
on the volume restored from the snapshot. If you also set `instanceStorePolicy`,
container storage moves to local NVMe and the restored volume is no longer used. You
choose one of the two.

**The `snapshot` mechanism is not available on EKS Auto Mode.** Auto Mode's `NodeClass`
exposes `ephemeralStorage` with the fields `size`, `iops`, `throughput` and `kmsKeyID`.
There is no `snapshotID` field. A workload that needs pre-baked images cannot run on
Auto Mode.

Two further measurements follow the four variants.

- **Warm scale-out.** The same variant is run again on a node that is already running.
  The four variants above all measure the first pod on a new node.
- **How the model weights reach GPU memory.** Three variants, including Run:ai Model
  Streamer, with time to first token.

### How the numbers are produced

`bin/stages.py` reads the timestamps Kubernetes records and reports the interval between
each consecutive pair:

- Pod `creationTimestamp`, conditions, container and init-container states
- NodeClaim `creationTimestamp` and Karpenter's `Launched` and `Registered` conditions
- The Node's `Ready` condition
- kubelet `Pulling` and `Pulled` events, which also contain the pull duration and the
  compressed image size in their message text
- For phase 2, vLLM's log lines for weight load, `torch.compile` and engine warmup

The stages therefore add up to the total. No interval is left out and there is no
remainder category. Kubernetes records these timestamps to one-second resolution, so
differences below one second are not meaningful.

---

## The hands-on steps

If you are working through the workshop, start here. Each step gives the configuration:
which field, in which resource, the reason for it, what happens if it is missing, and
how to check that it took effect without relying on the timing figures.

To apply these to a cluster you already have, rather than building the environment here,
[EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) gives the same settings as commands and YAML with no
scripts involved, and covers keeping your existing workloads off the new node pools.

| Step | Configuration change |
|---|---|
| [0 — The environment](steps/00-environment.md) | What Terraform builds, and the decisions that make the later comparisons valid |
| [1 — Baseline](steps/01-baseline.md) | None. Provides the figures the later steps are compared against. |
| [2 — EBS snapshot](steps/02-snapshot.md) | One field: `snapshotID` on the data volume |
| [3 — NVMe + SOCI](steps/03-soci.md) | `instanceStorePolicy: RAID0` and 6 lines of Bottlerocket TOML |
| [4 — Auto Mode](steps/04-automode.md) | None. Compared against step 3 by looking at what is absent. |
| [5 — Warm scale-out](steps/05-warm.md) | No configuration change; the run command differs |
| [6 — Model weights](steps/06-weights.md) | Three vLLM command lines, including Run:ai Model Streamer |
| [7 — Compiled artifacts](steps/07-compile-cache.md) | One volume, mounted on vLLM's compile cache directory |

Two scripts display the configuration at the terminal. The demo calls both of them for
each variant.

```bash
bin/show_config.sh soci     # what changes and where, before you apply it
bin/verify_config.sh soci   # checks that it took effect, after you run it
```

`show_config.sh` diffs the rendered manifests against the baseline and removes comments
and lines that differ only by the variant's name, so the output contains only the
configuration that differs. It reads the rendered manifests rather than a separate copy,
so it stays consistent with what was applied.

`verify_config.sh` checks the mechanism itself: whether the volume came from the
snapshot, whether container storage moved to NVMe, and which loader vLLM started with.
Each check also states what it does not confirm, so that a check is not read as covering
more than it does.

---

## Reference results

One measured run is recorded in [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md). It is a
single measurement from a single account. Absolute figures depend on image size,
instance type, region and registry conditions, so your figures will differ.

---

## Prerequisites

- `aws`, `kubectl`, `terraform`, `python3`
- Credentials for an account in which you can create two EKS clusters
- **GPU quota.** All variants use one instance type, `gr6.8xlarge`, which is 32 vCPU.
  Running them one at a time needs 32 vCPU of *Running On-Demand G and VT instances*.
  Requesting 128 leaves room for re-runs.
  ```bash
  aws service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --region us-west-2
  ```

Check an account against all of this without creating anything:

```bash
bin/preflight.sh
```

[PREREQUISITES.md](PREREQUISITES.md) states the requirements in full and separately from the
rest of this document: the instance type and its constraints, the GPU quota and how it is
counted, GPU capacity, the permissions and resources involved, the cost and the duration.

### Cost and time

About USD 6–12 and about 2 hours in total. Most of that time is preparation that runs
without supervision. Two EKS clusters and a NAT gateway cost about USD 0.35 per hour
even when no GPU nodes are running, so run the teardown when you have finished.

### Why the instance type matters

`gr6.8xlarge` has one L4 GPU (24 GB), 32 vCPU, two 450 GB NVMe disks, and up to 25 Gbps of
network bandwidth. Three properties of it affect the result.

**Local NVMe is required**, because `soci` and `automode` both use it. A GPU type without
instance store makes both of those variants measure the same thing as `baseline`.

**Two disks rather than one**, so `instanceStorePolicy: RAID0` actually stripes.
Bottlerocket skips the array when there is only one disk, which is the case on `g6.4xlarge`
and most of the smaller G types: the policy still moves container storage to the instance
store, but nothing is striped. Check the count for your own type before reading anything
into a throughput figure.

```bash
aws ec2 describe-instance-types --instance-types "$GPU_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

**The vCPU count**, because SOCI's parallel unpack is CPU-bound. A `2xlarge` produces a
smaller improvement and a `12xlarge` a larger one than a typical inference node would.

Set `GPU_INSTANCE_TYPE` in `config.env` to the type you use, and expect the `soci` figure to
change with it. Also check that the type has capacity before a run, because a
capacity-starved offering is held unavailable by Karpenter for 3 minutes at a time and that
wait lands in the variant's total:

```bash
bin/check_capacity.sh
```

---

## Setup

### 1. Configure

```bash
$EDITOR config.env
```

Each value is written as `${VAR:-default}`, so a value already set in the environment
takes precedence. You can override one setting for a single run without editing the
file:

```bash
GPU_INSTANCE_TYPE=g6.8xlarge bin/bench.sh soci
```

Check that the workload image tag still exists. AWS Deep Learning Container tags are
updated over time, and a tag that no longer exists causes the run to fail at pull time:

```bash
aws ecr describe-images --region us-west-2 \
  --registry-id 763104351884 --repository-name vllm \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags'
```

The default image is a vLLM Deep Learning Container. It is large, GPU-enabled, and
readable by any AWS account, so no registry credentials and no build step are needed.

### 2. Build the environment

```bash
cd terraform
terraform init
terraform apply
cd ..
```

Then check what it built, before running any variant:

```bash
bin/verify_env.sh
```

Every check in it corresponds to something that fails later in a way that does not name its
cause. [Step 0](steps/00-environment.md) explains the decisions behind the environment and what
each check is guarding against.

This creates one shared VPC and two clusters:

- `<prefix>-karpenter` — self-managed Karpenter, used by `baseline`, `snapshot` and `soci`
- `<prefix>-automode` — EKS Auto Mode, used by `automode`

There are two clusters because self-managed Karpenter and Auto Mode both own the
`karpenter.sh` CRDs. The clusters share the VPC and subnets, so the image pull path is
the same in both and the figures remain comparable. The control plane is not the same,
which the generated report notes.

Kubernetes is set to 1.34 or above. The EKS-optimized Bottlerocket NVIDIA AMI includes
NVIDIA driver 580 from 1.34 onwards, and driver 580 is required for the CUDA 13 image
used here.

No NVIDIA device plugin is deployed in either cluster. The Bottlerocket NVIDIA AMI
contains the driver, the container toolkit and the Kubernetes device plugin, and Auto
Mode provides its own. The readiness probe runs `nvidia-smi` inside the container, so a
pod reaching Ready indicates the GPU is available to the container.

### 3. Build the snapshot

Build it with a dedicated builder instance:

```bash
IMAGE="$(grep WORKLOAD_IMAGE config.env | cut -d'"' -f2)" ./snapshot/build-snapshot.sh
```

This takes 10-20 minutes for a multi-GB image and needs no supervision. The snapshot ID is
written to `results/snapshot-id.txt` and to an SSM parameter, and `bin/prep.sh` reads it from
there.

> The builder stops `kubelet`, removes every image already present, pulls only the images you
> named, then **stops the instance** before snapshotting. That is what makes the snapshot
> filesystem-consistent and free of anything you did not ask for, and it is why this is the
> method to use in your own environment. The volume size is a parameter, so the snapshot is
> sized for the images rather than for some node's data volume, and the whole thing runs from
> an image tag with no cluster involved.
>
> `snapshot/snapshot-from-node.sh` takes it from a node in your own cluster instead, in a node
> pool created for building. Use it where a dedicated builder instance is not an option: the
> builder pulls with its instance role, so an image needing an `imagePullSecret` is a case only
> this covers. It snapshots a mounted volume, so the result is crash-consistent. See
> [`steps/02-snapshot.md`](steps/02-snapshot.md) for both.

The time this takes is part of the cost of the `snapshot` variant, and it recurs
whenever the image changes. Compare it against that variant's measured improvement in
the last section.

### 4. Apply the variants

```bash
./bin/prep.sh
```

This renders the manifests, applies each variant to the
appropriate cluster, and checks that the Bottlerocket AMI is at least 1.44.0. SOCI
parallel pull/unpack was added in 1.44.0. On an earlier version the snapshotter setting
is ignored without an error, the node boots and the pod runs, and `soci` measures the
same thing as `baseline`. The resulting figures would suggest that SOCI has no effect.

---

## Running it

Run one variant at a time. Each run deletes that variant's node first, so each
measurement starts from a cold node.

```bash
./bin/bench.sh baseline
./bin/bench.sh snapshot
./bin/bench.sh soci
./bin/bench.sh automode
```

Each step's figure is printed when that step completes, so the breakdown appears during
the run rather than only at the end:

```
  step                                         at   step took
  -------------------------------------- -------- -----------
  -> node ip-10-0-42-17
  Karpenter decided, NodeClaim created         1s          1s
  EC2 instance launched                        3s          2s
  node registered with the cluster            20s         17s
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
  container started                          126s          0s
  workload Ready                             127s          1s
  -------------------------------------- -------- -----------
  submit to Ready                            127s
```

`at` is measured from the pod's `creationTimestamp`, which is the same reference the
final table uses, so the live output and the report agree. `step took` is the duration of
each step.

When the variant finishes, `stages.py` prints the breakdown again together with the
node's instance type, availability zone and OS image, and the effective image
throughput. Throughput is the compressed image size divided by the observed pull
duration, so it includes both download and unpack. Throughput can be compared across
different images, which the elapsed figures cannot.

### Warm scale-out

```bash
./bin/bench.sh soci --warm
```

This deletes only the pod, keeps the NodeClaim, and submits the pod again. The pod is
deleted first because these instance types have one GPU, so two pods requesting a GPU
cannot run on the same node.

`report.py` then prints both figures:

```
  soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

The last figure is the portion that a node which is already running does not incur. If
that portion is large relative to the total, the mechanisms in this workshop affect most
of the startup time. If it is small, the startup time is mostly in the pod itself, and
node capacity policy has more effect than image delivery. Running this measurement also
shows how much of the `snapshot` variant's improvement applies only to the first pod on
a node.

### Phase 2 — how the weights reach GPU memory

Stage the weights once:

```bash
./snapshot/stage-model.sh
```

The bucket is found by its `Purpose` tag. Set `MODEL_BUCKET` in `config.env` to override it.

Then run three variants. The node, model and bytes are the same in all three, and only
the loader differs:

```bash
./bin/bench.sh weights s3-initcontainer   # copy S3 -> disk, vLLM default loader
./bin/bench.sh weights runai-local        # copy S3 -> disk, Run:ai Model Streamer
./bin/bench.sh weights runai-s3           # no copy: streamer reads S3 directly
```

The three variants separate two effects, which are reported individually:

- `s3-initcontainer` to `runai-local` changes the loader only. The bytes and the disk
  are the same, so the difference is the effect of concurrent tensor streaming.
- `runai-local` to `runai-s3` changes the delivery only. The init container is removed.

The second change also removes a property of the init container approach: kubelet pulls
the init image, runs the init container, and then pulls the workload image. The copy and
the image pull do not overlap. Because of this, moving weights out of the image can
increase start-to-Ready time even though the image is smaller. Reading from S3 directly
removes the copy step.

`runai-streamer` and its S3 backend are included in the AWS vLLM Deep Learning
Container base image, so no custom image build is needed. To check this on the tag you
configured, using a node that already has the image:

```bash
./bin/check_runai.sh
```

Credentials come from EKS Pod Identity, which Terraform binds to the `bench` service
account. The node role cannot be used: Karpenter sets the IMDS hop limit to 1, so a
container cannot reach instance metadata, and the AWS SDK reports `Unable to locate
credentials`. That hop limit prevents pods from using node permissions, and scoping a
role to a service account is the approach to use in production as well.

### Phase 3 — reusing vLLM's compiled artifacts

Phase 2 leaves engine initialisation as the largest stage, and vLLM reports how much of it
is compilation. Compiled artifacts can be reused, but vLLM writes them inside the
container's writable layer, so a replacement pod compiles again. This phase mounts that
directory from the node and measures the difference.

```bash
./bin/bench.sh compile cold   # a cache directory no run has used: compilation runs
./bin/bench.sh compile warm   # the same directory, pod replaced, node kept
```

`cold` records the directory it chose in `results/compile-cache-id.txt` and `warm` reads it
back, so both runs are looking at the same cache. Everything else is held constant: same
node, image, GPU, model, loader and vLLM arguments.

The mount is on `/root/.cache/vllm/torch_compile_cache` rather than on `/root/.cache/vllm`.
Run:ai Model Streamer caches the model under the same root, so mounting the whole root would
persist the weights as well and the warm run would skip the S3 read too. Compare the model
load figure in the two runs: if it is unchanged, the weights still came from S3 and the
difference belongs to compilation.

Whether the cache was used is read from vLLM's log rather than inferred from a short
compile time, and `bin/bench.sh` prints the verdict with the log lines it matched. A run
that reports `unknown` means vLLM logged neither a compile nor a reuse, which is what a
wording change in a new vLLM release looks like.

### Time to first token

A pod reaching Ready means vLLM responds to `/health`. It does not indicate how soon the
server produces a token. Phase 2 runs therefore also measure the interval from submit to
first token:

```
  time to first token after Ready  0.65s
  submit to first token            93.6s
```

The probe requests a streamed completion and stops timing at the first token that
contains text. Streaming is used because without it the measurable interval is total
latency, which depends on the number of tokens requested. The probe runs inside the pod
([bin/first_token.py](bin/first_token.py), loaded as a ConfigMap by `prep.sh`), so it
does not need a port-forward and does not require `curl` in the image.

### Resetting

```bash
./bin/reset.sh                 # all variants
./bin/reset.sh soci            # one variant
```

---

## Recording it

`bin/demo.sh` runs the whole sequence and prints English commentary between the
commands, so a recording can be followed without a voice track. `bin/record.sh` runs
that under asciinema and produces an mp4:

```bash
./bin/record.sh              # the full run
./bin/record.sh --quick      # skips the cold baseline, for a shorter video
./bin/record.sh --rehearse   # fixture data, no AWS calls
```

Output is written to `recording/`: a `.cast` file, which is small and can be
re-rendered, a `.gif`, and an `.mp4` at 1184x840.

> asciinema is given `--idle-time-limit`, which shortens periods of no output during
> playback. A 96-second image pull appears as a few seconds of video. The elapsed times
> shown on screen are the measured values and are not modified; only the waiting between
> them is shortened. Mention this when showing the video, because otherwise the playback
> speed can be read as the measurement.

The idle limit is set to the same value as the narration interval. A shorter limit would
also shorten the pauses that make the commentary readable.

`--rehearse` runs the same demo against fixture data, with a fake `kubectl` on `PATH`
and no AWS calls. It is intended for checking the narration timing and the recording
pipeline. `bench.sh`, `watch_stages.py`, `stages.py` and `report.py` all run unmodified
and only `kubectl` is replaced, so the tooling itself is exercised. The figures a
rehearsal produces are fixture values: `record.sh` includes `REHEARSAL` in the filename,
and rehearsal output is written to `rehearsal/.sandbox/` rather than `results/`.

`verify_config.sh` does not run in a rehearsal. Every check it performs reads real
cluster and EC2 state, and returning fixture values would report a configuration as
confirmed without checking it.

---

## Reading the result

`results/report.md` groups the stages into three categories:

- **Provisioning** — Karpenter's decision, the EC2 launch, boot, registration, node
  Ready and binding. In the reference run this was similar across all four variants. A
  large difference here usually indicates instance-type availability rather than
  configuration.
- **Image** — the pull and unpack. `snapshot`, `soci` and `automode` each address this
  differently.
- **Workload** — container start, and in phase 2 the weight download and model load.

`baseline` and `soci` differ by one mechanism, with the same provisioner, OS and
instance type, so their difference is attributable to that mechanism. `automode` also
runs on a different control plane, so its figures indicate what Auto Mode provides
without configuration rather than a direct comparison.

The report also lists the instance type, availability zone, OS image and runtime read
from each node, so the assumption that the variants ran on equivalent hardware can be
checked. If they did not all use the same instance type, the report says so.

### Limits of the figures

- Each variant was run once. Pull times vary with registry and network conditions.
  Differences below about 10% should be confirmed by a repeat run before being relied
  on. `report.py` retains earlier runs rather than replacing them.
- The time to build the snapshot is not in the table. It is the recurring cost of that
  mechanism.
- The `soci` variant's SOCI settings are the values AWS publishes as a starting point.
  Layer count, layer size and vCPU affect which values are appropriate.

---

## What to adopt

| If | Then | Because |
|---|---|---|
| Images change rarely and startup latency matters | `snapshot` | No pull occurs. A snapshot rebuild is needed per image version. |
| Images change often | `soci` | No per-image preparation, no build-pipeline change, image unchanged. |
| You do not want to maintain either | `automode` | The `soci` behaviour without its configuration. The `snapshot` mechanism and the SOCI settings are not available. |
| Weight loading takes longer than the pull | Stream from S3 | Reducing image size does not help if model load is the larger component. |
| Warm-node startup already dominates | None of these; node capacity policy | If the once-per-node cost is small relative to steady-state startup, image delivery is not the main factor. |

Two measurements determine most of this choice: how often your images change, and how
much of your startup time is incurred once per node. The warm scale-out run provides the
second.

---

## Teardown

```bash
./bin/reset.sh
cd terraform && terraform destroy
```

The snapshot and the staged weights are not managed by Terraform:

```bash
aws ec2 delete-snapshot --snapshot-id "$(cat results/snapshot-id.txt)" --region us-west-2
aws s3 rm "s3://$MODEL_BUCKET/$MODEL_PREFIX/" --recursive
```

---

## Layout

```
config.env                        settings; read by all the scripts
terraform/                        shared VPC, two clusters, model bucket, Pod Identity
manifests/
  karpenter/                      baseline, snapshot, soci  (EC2NodeClass + NodePool)
  automode/                       automode                  (NodeClass + NodePool)
  workload.yaml                   phase 1: the measured pod, cold and warm
  workload-weights.yaml           phase 2: one spec, three loader variants
  workload-compile.yaml           phase 3: the compile cache mounted from the node
  fragments/init-copy-weights.yaml  the S3-to-disk copy, used by two variants
  rendered/                       generated by prep.sh; what was applied
snapshot/
  build-snapshot.sh               snapshot preparation on a dedicated builder
  snapshot-from-node.sh           snapshot from a build-only node pool
  stage-model.sh                  phase 2 preparation, as a Job on the cluster
bin/
  preflight.sh                    account prerequisites, before terraform
  verify_env.sh                   what terraform built, before the first variant
  check_capacity.sh               GPU capacity, before a measurement run
  gpu_images.py                   which images the cluster's GPU pods run
  prep.sh                         render, apply, check versions
  discover.sh                     finds the node role and the bucket (sourced)
  bench.sh                        run one variant, collect, compute
  reset.sh                        return a variant to a cold state
  watch_stages.py                 prints each step's figure as it completes
  stages.py                       timestamps to stage breakdown
  report.py                       all runs to comparison and results/report.md
  first_token.py                  time to first token, runs inside the pod
  render_weights.py               phase 2 render (handles multi-line insertion)
  check_runai.sh                  checks the image supports Run:ai streaming
  assert_br_version.py            checks the Bottlerocket version for SOCI
  show_config.sh                  what a variant changes and where, before applying
  verify_config.sh                checks the setting took effect, after running
  demo.sh                         the narrated sequence, for recording
  record.sh                       asciinema to gif to mp4
  rehearse.sh                     demo.sh against fixtures, no AWS calls
steps/                            the hands-on steps, one per configuration change
rehearsal/                        fixture data and a fake kubectl
raw/                              per-run Kubernetes objects, kept for reference
results/                          per-run JSON and report.md
```

`raw/` contains the data behind each figure in the report, so the calculation can be
checked afterwards. Each run's directory also contains the manifest that was applied.

Placeholders in the manifests are written as `@LIKE_THIS@`. The delimiters prevent a
substitution from also replacing the token names where they appear in comments, and
prevent `@NODE_IAM_ROLE@` from matching inside `@KARPENTER_NODE_IAM_ROLE_NAME@`. The
templates are valid YAML before rendering, so editors and linters can parse them.

---

## References

- [Reduce container startup time on Amazon EKS with Bottlerocket data volume][blog]
- [EKS best practices: application scaling and performance][bp]
- [SOCI snapshotter parallel mode][soci]
- [Karpenter blueprint: SOCI snapshotter parallel pull/unpack][bpsoci]
- [Run:ai Model Streamer][runai] and [vLLM's integration][vllmrunai]
- [`aws-samples/bottlerocket-images-cache`][cache]

[blog]: https://aws.amazon.com/blogs/containers/reduce-container-startup-time-on-amazon-eks-with-bottlerocket-data-volume/
[bp]: https://docs.aws.amazon.com/eks/latest/best-practices/aiml-performance.html
[soci]: https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md
[bpsoci]: https://github.com/aws-samples/karpenter-blueprints/tree/main/blueprints/soci-snapshotter
[runai]: https://github.com/run-ai/runai-model-streamer
[vllmrunai]: https://docs.vllm.ai/en/latest/models/extensions/runai_model_streamer.html
[cache]: https://github.com/aws-samples/bottlerocket-images-cache

<br>

---
---

<a id="japanese"></a>

# AI on EKS — 起動時間最適化ワークショップ

[English](#ai-on-eks--startup-time-optimizing-workshop) | **日本語**

このワークショップでは、Amazon EKS 上で GPU 推論 Pod が Ready になるまでの時間を計測し、
段階に分解した上で、短縮方法を 3 つ計測します。各段階は Kubernetes が元から記録している
タイムスタンプから算出します。計測に使うスクリプトも同梱しています。

対象外: カスタム Bottlerocket AMI のビルド。

---

## 何を計測するか

variant は 4 つあります。Pod spec、インスタンスタイプ、VPC、サブネット、コンテナイメージは
4 つとも同じです。異なるのは、コンテナイメージがノードに届く方法です。

| Variant | ノード | イメージの届き方 | 必要な設定 |
|---|---|---|---|
| `baseline` | Karpenter + Bottlerocket | EBS データボリューム、containerd 既定の逐次 pull | なし |
| `snapshot` | Karpenter + Bottlerocket | イメージ層を含む EBS スナップショットからデータボリュームを復元 | イメージ版ごとにスナップショットを作成・維持 |
| `soci` | Karpenter + Bottlerocket | コンテナストレージをローカル NVMe に置き、SOCI snapshotter を parallel pull/unpack モードで使用 | `instanceStorePolicy` と Bottlerocket 設定 6 行 |
| `automode` | EKS Auto Mode | ローカル NVMe と並列 pull をサービスが設定 | なし |

制約が 2 つあります。

**`snapshot` と `soci` は同じノードで併用できません。** どちらも、Bottlerocket が
コンテナイメージに使うボリュームを対象にしています。`snapshot` はスナップショットから
復元したボリューム上にイメージがあることを前提にしていますが、`instanceStorePolicy` も
設定するとコンテナストレージはローカル NVMe に移り、復元したボリュームは使われなく
なります。どちらか一方を選ぶことになります。

**`snapshot` の方式は EKS Auto Mode では使えません。** Auto Mode の `NodeClass` が公開
する `ephemeralStorage` のフィールドは `size` / `iops` / `throughput` / `kmsKeyID` で、
`snapshotID` はありません。イメージの事前焼き込みが必要なワークロードは Auto Mode では
動かせません。

4 つの variant の後に、さらに 2 つの計測を行います。

- **warm スケールアウト。** 同じ variant を、すでに動いているノードに対して再実行します。
  上記 4 つはいずれも、新しいノードでの 1 個目の Pod を計測しています。
- **モデルウェイトが GPU メモリに届く経路。** Run:ai Model Streamer を含む 3 通りと、
  time to first token を計測します。

### 数字の算出方法

`bin/stages.py` は Kubernetes が記録しているタイムスタンプを読み、隣接する時刻の間隔を
報告します。

- Pod の `creationTimestamp`、condition、コンテナと init コンテナの状態
- NodeClaim の `creationTimestamp` と Karpenter の `Launched` / `Registered` condition
- Node の `Ready` condition
- kubelet の `Pulling` / `Pulled` イベント。メッセージ本文に pull の所要時間と圧縮
  イメージサイズも含まれます
- フェーズ 2 では、vLLM のログに出るウェイトロード、`torch.compile`、engine warmup の行

このため段階の合計は全体と一致します。除外される区間はなく、余りの分類もありません。
Kubernetes のタイムスタンプは秒単位なので、1 秒未満の差には意味がありません。

---

## ハンズオンのステップ

ワークショップを実際に進める場合は、ここから始めてください。各ステップに設定内容
（どのフィールドを、どのリソースに、なぜ入れるのか、無い場合に何が起きるのか、時間の
数字に頼らずに効いたことをどう確認するか）を記載しています。

ここで環境を構築するのではなく、既存クラスターに適用する場合は
[EXISTING-CLUSTER.md](EXISTING-CLUSTER.md) を参照してください。同じ設定をスクリプトなしの
コマンドと YAML で示し、既存ワークロードを新しい node pool に載せない方法も扱っています。

| ステップ | 設定変更 |
|---|---|
| [0 — 環境](steps/00-environment.md) | Terraform が構築するもの、および以降の比較を成立させる判断 |
| [1 — ベースライン](steps/01-baseline.md) | なし。以降のステップの比較対象となる数字を得る |
| [2 — EBS スナップショット](steps/02-snapshot.md) | 1 フィールド: データボリュームの `snapshotID` |
| [3 — NVMe + SOCI](steps/03-soci.md) | `instanceStorePolicy: RAID0` と Bottlerocket TOML 6 行 |
| [4 — Auto Mode](steps/04-automode.md) | なし。ステップ 3 と比べて何が無いかを見る |
| [5 — warm スケールアウト](steps/05-warm.md) | 設定変更なし。実行コマンドが異なる |
| [6 — モデルウェイト](steps/06-weights.md) | vLLM の引数 3 通り（Run:ai Model Streamer を含む） |
| [7 — コンパイル成果物](steps/07-compile-cache.md) | ボリューム 1 つ。vLLM のコンパイルキャッシュディレクトリにマウント |

設定を端末に表示するスクリプトが 2 つあります。デモは各 variant でこの両方を呼びます。

```bash
bin/show_config.sh soci     # 適用前に、何がどこで変わるか
bin/verify_config.sh soci   # 実行後に、効いたことを確認
```

`show_config.sh` は展開済みのマニフェストをベースラインと diff し、コメントと variant 名
だけが異なる行を除きます。そのため出力には異なる設定だけが残ります。別途用意したコピーでは
なく展開済みマニフェストを読むので、適用内容と一致した状態を保ちます。

`verify_config.sh` は仕組み自体を確認します。ボリュームがスナップショット由来か、コンテナ
ストレージが NVMe に移ったか、vLLM がどのローダーで起動したか、です。各確認は確認できて
いない範囲も併記しており、確認内容を実際より広く受け取らないようにしています。

---

## 参考計測値

計測結果 1 回分を [REFERENCE-RESULTS.md](REFERENCE-RESULTS.md) に記載しています。
1 アカウントでの 1 回の計測です。絶対値はイメージサイズ、インスタンスタイプ、リージョン、
レジストリの状況に依存するため、実行環境によって変わります。

---

## 前提

- `aws`, `kubectl`, `terraform`, `python3`
- EKS クラスターを 2 面作成できるアカウントの認証情報
- **GPU クォータ。** 全 variant が `gr6.8xlarge`（32 vCPU）を使います。逐次実行なら
  *Running On-Demand G and VT instances* の 32 vCPU で足りますが、128 を申請しておくと
  再実行の余地ができます。
  ```bash
  aws service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --region us-west-2
  ```

何も作成せずに、アカウントが上記を満たしているか確認できます。

```bash
bin/preflight.sh
```

[PREREQUISITES.md](PREREQUISITES.md) は必要条件を、本書とは独立した形で網羅しています。
インスタンスタイプとその制約、GPU クォータとその数え方、GPU 容量、関係する権限とリソース、
費用、所要時間です。

### 費用と時間

合計でおよそ 6〜12 USD、約 2 時間です。時間の大半は無人で進む準備作業です。GPU ノードが
動いていない状態でも EKS クラスター 2 面と NAT ゲートウェイで約 0.35 USD/時かかるため、
終了後は破棄手順を実行してください。

### インスタンスタイプについて

`gr6.8xlarge` は L4 GPU 1 基（24 GB）、32 vCPU、450 GB の NVMe が 2 本、ネットワーク帯域は
最大 25 Gbps です。結果に影響する性質が 3 つあります。

**ローカル NVMe は必須**です。`soci` と `automode` が使います。インスタンスストアを持たない
GPU タイプでは、この 2 つの variant が `baseline` と同じものを計測することになります。

**ディスクが 1 本ではなく 2 本**なので、`instanceStorePolicy: RAID0` が実際にストライピング
します。Bottlerocket は 1 本の場合アレイを省きます。`g6.4xlarge` や小さめの G 系がこれに
該当し、ポリシーはコンテナストレージをインスタンスストアに移しますが、ストライピングは
発生しません。スループットの数字から何かを読み取る前に、自身のタイプの本数を確認して
ください。

```bash
aws ec2 describe-instance-types --instance-types "$GPU_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

**vCPU 数**も影響します。SOCI の並列展開は CPU バウンドなので、`2xlarge` では一般的な推論
ノードより改善幅が小さく、`12xlarge` では大きく出ます。

`config.env` の `GPU_INSTANCE_TYPE` を実際に使う型に設定し、`soci` の数字がそれに応じて
変わることを前提にしてください。実行前に、そのタイプに容量があることも確認してください。
容量が枯渇した offering は Karpenter が 3 分間 unavailable に保持し、その待ち時間が variant
の合計に入ります。

```bash
bin/check_capacity.sh
```

---

## セットアップ

### 1. 設定

```bash
$EDITOR config.env
```

各値は `${VAR:-default}` の形式で書かれているため、環境変数が優先されます。ファイルを
編集せずに 1 回だけ上書きできます。

```bash
GPU_INSTANCE_TYPE=g6.8xlarge bin/bench.sh soci
```

ワークロードイメージのタグが存在するか確認してください。AWS Deep Learning Container の
タグは更新されるため、存在しないタグを指定すると pull 時に失敗します。

```bash
aws ecr describe-images --region us-west-2 \
  --registry-id 763104351884 --repository-name vllm \
  --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags'
```

既定のイメージは vLLM の Deep Learning Container です。サイズが大きく GPU 対応で、
どの AWS アカウントからも読めるため、レジストリ認証もビルド工程も不要です。

### 2. 環境構築

```bash
cd terraform
terraform init
terraform apply
cd ..
```

variant を実行する前に、構築されたものを確認します。

```bash
bin/verify_env.sh
```

含まれる各チェックは、後段で原因を示さない形で失敗する事象に対応しています。環境に関する判断と、
各チェックが何を防いでいるかは [ステップ 0](steps/00-environment.md) にあります。

共有 VPC 1 つとクラスター 2 面を作成します。

- `<prefix>-karpenter` — self-managed Karpenter。`baseline` / `snapshot` / `soci` が使用
- `<prefix>-automode` — EKS Auto Mode。`automode` が使用

クラスターを 2 面にしているのは、self-managed Karpenter と Auto Mode がどちらも
`karpenter.sh` の CRD を所有するためです。VPC とサブネットは共有するので、イメージ pull
の経路は同じで数字は比較できます。コントロールプレーンは同じではなく、この点は生成される
レポートにも記載されます。

Kubernetes は 1.34 以上にしています。EKS 最適化 Bottlerocket NVIDIA AMI が NVIDIA
ドライバ 580 を含むのは 1.34 以降で、ここで使う CUDA 13 イメージには 580 が必要です。

どちらのクラスターにも NVIDIA device plugin をデプロイしていません。Bottlerocket NVIDIA
AMI にドライバ、container toolkit、Kubernetes device plugin が含まれており、Auto Mode は
自前で用意します。readiness probe はコンテナ内で `nvidia-smi` を実行するため、Pod が
Ready になればコンテナから GPU が使える状態だと分かります。

### 3. スナップショットの作成

専用のビルダーインスタンスで作成します。

```bash
IMAGE="$(grep WORKLOAD_IMAGE config.env | cut -d'"' -f2)" ./snapshot/build-snapshot.sh
```

数 GB のイメージで 10〜20 分かかり、監視は不要です。スナップショット
ID は `results/snapshot-id.txt` と SSM パラメータに書かれ、`bin/prep.sh` がそこから
読み取ります。

> ビルダーは `kubelet` を停止し、既存イメージをすべて削除し、指定したイメージだけを pull し、
> **インスタンスを停止してから**スナップショットを取得します。これによりファイルシステムとして
> 整合し、指定していないものを含まない結果になります。自身の環境で使うべきなのはこちらです。
> ボリュームサイズはパラメータなので、どこかのノードのデータボリューム容量ではなくイメージに
> 見合ったサイズになり、クラスターを介さずイメージタグから実行できます。
>
> `snapshot/snapshot-from-node.sh` は代わりに、自分のクラスター内のビルド専用 node pool の
> ノードから取得します。専用ビルダーが選択できない場合に使ってください。ビルダーはインスタンス
> ロールで pull するため、`imagePullSecret` を要するイメージはこちらでしか扱えません。マウント中の
> ボリュームを取得するためクラッシュ整合です。両方の詳細は
> [`steps/02-snapshot.md`](steps/02-snapshot.md) にあります。

この所要時間は `snapshot` variant のコストの一部で、イメージが変わるたびに発生します。
最終セクションで、その variant の実測改善幅と比較してください。

### 4. variant の適用

```bash
./bin/prep.sh
```

マニフェストを展開して各 variant を該当クラスターに適用し、
Bottlerocket AMI が 1.44.0 以上であることを確認します。SOCI の parallel pull/unpack は
1.44.0 で追加されました。それより前のバージョンでは snapshotter の設定がエラーなしで
無視され、ノードは起動し Pod も動き、`soci` は `baseline` と同じものを計測します。その
結果の数字は SOCI に効果がないように見えます。

---

## 実行

variant は 1 つずつ実行します。各実行はまずその variant のノードを削除するため、毎回
コールドなノードから計測が始まります。

```bash
./bin/bench.sh baseline
./bin/bench.sh snapshot
./bin/bench.sh soci
./bin/bench.sh automode
```

各段階の数字はその段階が完了した時点で出力されるため、内訳は実行中に順次表示されます。

```
  step                                         at   step took
  -------------------------------------- -------- -----------
  -> node ip-10-0-42-17
  Karpenter decided, NodeClaim created         1s          1s
  EC2 instance launched                        3s          2s
  node registered with the cluster            20s         17s
  node Ready                                  29s          9s
  pod bound to the node                       29s          0s
  image pull started                          30s          1s
  image pull finished                        126s         96s
  container started                          126s          0s
  workload Ready                             127s          1s
  -------------------------------------- -------- -----------
  submit to Ready                            127s
```

`at` は Pod の `creationTimestamp` を起点としています。最終集計表と同じ起点なので、
実行中の出力とレポートの数字は一致します。`step took` が各段階の所要時間です。

variant が終了すると、`stages.py` がノードのインスタンスタイプ、AZ、OS イメージと
あわせて内訳を再表示し、実効イメージスループットを出力します。スループットは圧縮イメージ
サイズ ÷ 実測 pull 時間で、ダウンロードと展開の両方を含みます。経過時間と違い、
スループットはイメージが異なる環境間でも比較できます。

### warm スケールアウト

```bash
./bin/bench.sh soci --warm
```

Pod だけを削除し、NodeClaim は残して Pod を再投入します。これらのインスタンスタイプは
GPU が 1 基なので、GPU を要求する Pod は 2 つ同じノードで動かせません。そのため先に Pod を
削除します。

`report.py` は両方の数字を出力します。

```
  soci: cold 97s -> warm 1s (once-per-node cost 96s)
```

最後の数字は、すでに動いているノードでは発生しない部分です。この部分が全体に対して大きい
場合、本ワークショップの各方式が起動時間の大部分に影響します。小さい場合、起動時間の大半は
Pod 側にあり、イメージ配送よりノードのキャパシティ方針の方が効きます。この計測により、
`snapshot` variant の改善のうちノードの 1 個目の Pod にしか効かない分も分かります。

### フェーズ 2 — ウェイトが GPU メモリに届く経路

ウェイトを一度 S3 に配置します。

```bash
./snapshot/stage-model.sh
```

バケットは `Purpose` タグから特定されます。`config.env` の `MODEL_BUCKET` で上書きできます。

続いて 3 通りを実行します。ノード、モデル、バイト列は 3 つとも同じで、ローダーだけが
異なります。

```bash
./bin/bench.sh weights s3-initcontainer   # S3 からディスクへコピー、vLLM 既定ローダー
./bin/bench.sh weights runai-local        # 同じコピー、Run:ai Model Streamer
./bin/bench.sh weights runai-s3           # コピーなし、streamer が S3 を直接読む
```

3 つの variant は 2 つの効果を切り分けており、それぞれ別に報告されます。

- `s3-initcontainer` から `runai-local` はローダーのみの変更です。バイト列とディスクは
  同じなので、差は並列テンソルストリーミングの効果です。
- `runai-local` から `runai-s3` は配送のみの変更です。init コンテナが無くなります。

2 つ目の変更は、init コンテナ方式が持つ性質も取り除きます。kubelet は init イメージを
pull し、init コンテナを実行し、その後で本体イメージを pull します。コピーと pull は
重なりません。このため、イメージからウェイトを出してイメージが小さくなっても
start-to-Ready が伸びる場合があります。S3 から直接読む方式ではコピー工程が無くなります。

`runai-streamer` とその S3 バックエンドは AWS vLLM Deep Learning Container のベース
イメージに含まれているため、独自イメージのビルドは不要です。設定したタグについて、
イメージを持っているノードで確認するには次を実行します。

```bash
./bin/check_runai.sh
```

認証情報は EKS Pod Identity から取得し、Terraform が `bench` サービスアカウントに
紐付けます。ノードロールは使えません。Karpenter は IMDS の hop limit を 1 に設定するため
コンテナはインスタンスメタデータに到達できず、AWS SDK は `Unable to locate credentials`
を返します。この hop limit は Pod がノードの権限を使うことを防ぐもので、サービス
アカウント単位でロールを絞る方法は本番でも同様に使えます。

### フェーズ 3 — vLLM のコンパイル成果物を再利用する

フェーズ 2 の後、最大の段階として残るのは engine init で、そのうちどれだけがコンパイルかは
vLLM が報告します。コンパイル成果物は再利用できますが、vLLM はこれをコンテナの書き込み可能
レイヤ内に書くため、置き換わった Pod は再度コンパイルします。このフェーズではそのディレクトリを
ノードからマウントし、差を計測します。

```bash
./bin/bench.sh compile cold   # どの実行も使っていないキャッシュディレクトリ。コンパイルが走る
./bin/bench.sh compile warm   # 同じディレクトリ。Pod は置き換え、ノードは保持
```

`cold` は選んだディレクトリを `results/compile-cache-id.txt` に記録し、`warm` がそれを読み
戻すため、両者は同じキャッシュを見ます。それ以外は固定です。同じノード、イメージ、GPU、
モデル、ローダー、vLLM 引数です。

マウント先は `/root/.cache/vllm` ではなく `/root/.cache/vllm/torch_compile_cache` です。
Run:ai Model Streamer が同じルート配下にモデルをキャッシュするため、ルート全体をマウントすると
ウェイトも永続化され、warm 実行では S3 の読み込みまでスキップされます。2 回の実行の model load
の数字を比べてください。変わっていなければ、ウェイトは両方とも S3 から来ており、差はコンパイル
に帰属します。

キャッシュが使われたかどうかは、コンパイル時間の短さからの推測ではなく vLLM のログから読み
取ります。`bin/bench.sh` が判定と、一致したログ行を表示します。`unknown` と出た場合は、vLLM が
コンパイルも再利用も記録しなかったことを意味します。新しい vLLM リリースで文言が変わった場合に
これが起きます。

### time to first token

Pod が Ready になることは、vLLM が `/health` に応答することを意味します。トークンを
どれだけ早く出せるかは分かりません。そのためフェーズ 2 では submit から最初のトークンまで
も計測します。

```
  time to first token after Ready  0.65s
  submit to first token            93.6s
```

プローブはストリーミングで補完を要求し、テキストを含む最初のトークンで計測を止めます。
ストリーミングを使うのは、使わない場合に計測できるのが総レイテンシであり、要求トークン数に
依存するためです。プローブは Pod 内で動作するため
（[bin/first_token.py](bin/first_token.py)、`prep.sh` が ConfigMap として投入）、
port-forward は不要で、イメージに `curl` がある必要もありません。

### リセット

```bash
./bin/reset.sh                 # 全 variant
./bin/reset.sh soci            # 1 つの variant
```

---

## 録画

`bin/demo.sh` は一連の流れを実行し、コマンドの間に英語の解説を出力するため、録画物を
音声なしで追えます。`bin/record.sh` はそれを asciinema で収録して mp4 にします。

```bash
./bin/record.sh              # 全体
./bin/record.sh --quick      # コールドのベースラインを省略し短くする
./bin/record.sh --rehearse   # フィクスチャデータ、AWS 呼び出しなし
```

出力は `recording/` に置かれます。小さく再レンダリング可能な `.cast`、`.gif`、
1184x840 の `.mp4` です。

> asciinema には `--idle-time-limit` を指定しており、再生時に出力の無い期間を短縮します。
> 96 秒の pull は数秒の映像になります。画面に表示される経過時間は計測値そのままで、変更して
> いません。短縮しているのはその間の待ち時間だけです。動画を見せる際はこの点を説明して
> ください。説明がないと、再生速度が計測値として受け取られる場合があります。

idle の上限値は、ナレーションの間隔と同じ値にしています。これより短くすると、解説を読む
ための間も短縮されます。

`--rehearse` は、偽の `kubectl` を `PATH` に置き、AWS を呼ばずにフィクスチャデータで同じ
デモを実行します。ナレーションの尺と録画パイプラインの確認用です。`bench.sh` /
`watch_stages.py` / `stages.py` / `report.py` は本物がそのまま動き、差し替えるのは
`kubectl` だけなので、ツール自体の動作確認になります。リハーサルが出す数字はフィクスチャの
値です。`record.sh` はファイル名に `REHEARSAL` を入れ、出力は `results/` ではなく
`rehearsal/.sandbox/` に書かれます。

`verify_config.sh` はリハーサルでは実行されません。この確認はすべて実際のクラスターと EC2
の状態を読むため、フィクスチャの値を返すと、確認していない設定を確認済みとして報告して
しまいます。

---

## 結果の読み方

`results/report.md` は段階を 3 つに分類します。

- **プロビジョニング** — Karpenter の判断、EC2 起動、ブート、登録、ノード Ready、バインド。
  参考計測では 4 variant でほぼ同じでした。ここに大きな差がある場合、通常は設定ではなく
  インスタンスタイプの在庫が原因です。
- **イメージ** — pull と展開。`snapshot` / `soci` / `automode` がそれぞれ異なる方法で
  扱います。
- **ワークロード** — コンテナ起動、およびフェーズ 2 のウェイトダウンロードとモデルロード。

`baseline` と `soci` は、プロビジョナ・OS・インスタンスタイプが同じで、異なるのは 1 つの
方式だけなので、差はその方式に帰属できます。`automode` はコントロールプレーンも異なるため、
数字は直接比較ではなく、Auto Mode が設定なしで提供する内容を示すものとして読みます。

レポートには各ノードから読み取ったインスタンスタイプ、AZ、OS イメージ、ランタイムも記載
されるため、variant が同等のハードウェアで動いたという前提を確認できます。variant 間で
インスタンスタイプが揃わなかった場合はその旨が出力されます。

### 数字の限界

- 各 variant は 1 回の計測です。pull 時間はレジストリとネットワークの状況で変わります。
  10% 程度未満の差は、再実行で確認してから判断してください。`report.py` は以前の結果を
  置き換えずに残します。
- スナップショットの作成時間は表に含まれていません。この方式の継続的なコストです。
- `soci` の SOCI 設定は AWS が出発点として公開している値です。適切な値はレイヤ数、レイヤ
  サイズ、vCPU によって変わります。

---

## 何を採用するか

| 条件 | 選択 | 理由 |
|---|---|---|
| イメージ更新が稀で起動遅延が重要 | `snapshot` | pull が発生しない。イメージ版ごとに再作成が必要 |
| イメージ更新が頻繁 | `soci` | イメージ単位の準備もビルド変更も不要、イメージは無改変 |
| どちらも運用したくない | `automode` | `soci` の挙動を設定なしで得られる。`snapshot` の方式と SOCI の設定項目は使えない |
| pull よりウェイト読み込みが長い | S3 からストリーム | モデルロードの方が大きいならイメージ縮小は効かない |
| warm ノードの起動時間が既に大半 | いずれでもなく、ノードのキャパシティ方針 | ノード 1 回のコストが定常起動に比べ小さいなら、イメージ配送は主要因ではない |

この選択の大半は 2 つの計測で決まります。イメージの更新頻度と、起動時間のうちノード 1 回
あたりに発生する分です。後者は warm スケールアウトの計測で分かります。

---

## 破棄

```bash
./bin/reset.sh
cd terraform && terraform destroy
```

スナップショットと S3 上のウェイトは Terraform の管理外です。

```bash
aws ec2 delete-snapshot --snapshot-id "$(cat results/snapshot-id.txt)" --region us-west-2
aws s3 rm "s3://$MODEL_BUCKET/$MODEL_PREFIX/" --recursive
```

---

## 構成

```
config.env                        設定。全スクリプトが読む
terraform/                        共有 VPC、クラスター 2 面、モデル用バケット、Pod Identity
manifests/
  karpenter/                      baseline, snapshot, soci  (EC2NodeClass + NodePool)
  automode/                       automode                  (NodeClass + NodePool)
  workload.yaml                   フェーズ 1: 計測対象の Pod。cold と warm 共用
  workload-weights.yaml           フェーズ 2: 1 つの spec で 3 通りのローダー
  workload-compile.yaml           フェーズ 3: コンパイルキャッシュをノードからマウント
  fragments/init-copy-weights.yaml  S3 からディスクへのコピー。2 通りで使用
  rendered/                       prep.sh が生成。実際に適用した内容
snapshot/
  build-snapshot.sh               専用ビルダーでの snapshot 準備
  snapshot-from-node.sh           ビルド専用 node pool からスナップショット
  stage-model.sh                  フェーズ 2 の準備。クラスター上の Job として実行
bin/
  preflight.sh                    アカウントの前提条件。terraform の前
  verify_env.sh                   terraform が構築したもの。最初の variant の前
  check_capacity.sh               GPU 容量。計測実行の前
  gpu_images.py                   クラスターの GPU Pod が動かしているイメージ
  prep.sh                         展開、適用、バージョン確認
  discover.sh                     ノードロールとバケットを特定（source される）
  bench.sh                        1 つの variant を実行し、収集・算出
  reset.sh                        variant をコールド状態に戻す
  watch_stages.py                 各段階の数字を完了時に出力
  stages.py                       タイムスタンプから段階内訳を算出
  report.py                       全実行を比較し results/report.md を出力
  first_token.py                  time to first token。Pod 内で動作
  render_weights.py               フェーズ 2 の展開（複数行の挿入を扱う）
  check_runai.sh                  イメージが Run:ai streaming に対応しているか確認
  assert_br_version.py            SOCI に必要な Bottlerocket バージョンを確認
  show_config.sh                  適用前に、variant が何をどこで変えるか
  verify_config.sh                実行後に、設定が効いたことを確認
  demo.sh                         録画用の解説付き実行
  record.sh                       asciinema から gif、mp4 へ
  rehearse.sh                     フィクスチャでの demo.sh。AWS 呼び出しなし
steps/                            ハンズオンのステップ。設定変更ごとに 1 つ
rehearsal/                        フィクスチャデータと偽の kubectl
raw/                              実行ごとの Kubernetes オブジェクト
results/                          実行ごとの JSON と report.md
```

`raw/` にはレポートの各数字の元データが入っており、後から計算を確認できます。各実行の
ディレクトリには、適用したマニフェストも含まれます。

マニフェストのプレースホルダは `@LIKE_THIS@` 形式です。この区切り文字により、コメント内に
現れるトークン名まで置換されることを防ぎ、`@NODE_IAM_ROLE@` が
`@KARPENTER_NODE_IAM_ROLE_NAME@` の内部に一致することも防ぎます。テンプレートは展開前でも
妥当な YAML なので、エディタや linter で解析できます。

---

## 参考

- [Reduce container startup time on Amazon EKS with Bottlerocket data volume][blog]
- [EKS best practices: application scaling and performance][bp]
- [SOCI snapshotter parallel mode][soci]
- [Karpenter blueprint: SOCI snapshotter parallel pull/unpack][bpsoci]
- [Run:ai Model Streamer][runai] と [vLLM 側の統合][vllmrunai]
- [`aws-samples/bottlerocket-images-cache`][cache]
