# Applying this to a cluster you already have

**English** | [日本語](#japanese)

Every mechanism this workshop measures is an `EC2NodeClass` and a `NodePool`. Neither requires a
new cluster. This document gives the commands and the YAML directly, without the scripts in
`bin/`, so that each step can be run and read one at a time on a cluster that already exists.

The scripts in `bin/` do the same things and also compute the stage breakdown. Use them if you
want the breakdown. Use this document to apply the settings.

---

## What the cluster needs

| | |
|---|---|
| Karpenter | Self-managed, with the `karpenter.k8s.aws/v1` API. `kubectl get crd ec2nodeclasses.karpenter.k8s.aws` |
| Subnet and security group tags | `karpenter.sh/discovery: <cluster>`, which the standard Karpenter install already sets |
| Node IAM role | The role Karpenter's existing node classes use. `kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}'` |
| Kubernetes | 1.34 or above if you use the CUDA 13 image in this workshop, which needs NVIDIA driver 580. Your own image may not |
| Bottlerocket | 1.44.0 or above for the SOCI settings in step 3. `bottlerocket@latest` resolves to a current one |
| GPU instance type | With local NVMe instance store. Two or more disks if you want RAID0 to stripe |

Nothing here is added to an existing NodePool. Each step creates a new one, so the nodes your
workloads run on are not touched.

### Keeping your workloads off these node pools

This matters if you already run workloads with Karpenter, and the usual GPU taint is not enough
on its own.

Karpenter considers every NodePool when it has a pending pod, and it will provision from any pool
whose taints that pod tolerates. A GPU workload you run today almost certainly tolerates
`nvidia.com/gpu`, since that is what gets it onto a GPU node in the first place. A Bottlerocket
pool tainted only with `nvidia.com/gpu` is therefore a pool your existing pods can be placed on.

Every NodePool below therefore carries a second taint that nothing existing tolerates:

```yaml
      taints:
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
```

Only the test pods in this document tolerate `br-test`, and they tolerate it by key and value.
Change `br-test` to something unused in your cluster if that name is taken.

Before you start, you can check whether anything in the cluster would tolerate the new taint:

```bash
# any pod with a blanket toleration, which would land anywhere
kubectl get pods -A -o json \
  | python3 -c 'import json,sys
for p in json.load(sys.stdin)["items"]:
    for t in p["spec"].get("tolerations") or []:
        if t.get("operator") == "Exists" and not t.get("key"):
            print(p["metadata"]["namespace"], p["metadata"]["name"])'

# and after applying, which pods actually landed on a test node
kubectl get pods -A -o wide --field-selector spec.nodeName=<the new node>
```

The first command lists pods that tolerate any taint. Those are usually DaemonSets, which is
expected: they will run on the new nodes as they do on every node. A workload pod in that list is
something to check before you continue.

### Values used throughout

Pick a prefix that will not collide with an existing NodePool in the cluster.

```bash
export CLUSTER=<your cluster name>
export NODE_ROLE=<the node IAM role Karpenter already uses>
export REGION=<your region>
export GPU_TYPE=gr6.8xlarge          # or another type with instance store
export PREFIX=br-test                # prefixes the NodePool and EC2NodeClass names
```

If Karpenter already runs in this cluster, three fields of the node class below can usually be
copied from a node class you already have: `role`, `securityGroupSelectorTerms` and
`subnetSelectorTerms`. The nodes it launches join the same cluster and sit in the same subnets,
so the same values apply.

```bash
kubectl get ec2nodeclass -o jsonpath='{range .items[*]}{"\n=== "}{.metadata.name}{"\nrole: "}{.spec.role}{"\nsecurityGroupSelectorTerms: "}{.spec.securityGroupSelectorTerms}{"\nsubnetSelectorTerms: "}{.spec.subnetSelectorTerms}{"\n"}{end}'
```

```
=== gpu-workers
role: my-cluster-karpenter-node
securityGroupSelectorTerms: [{"tags":{"karpenter.sh/discovery":"my-cluster"}}]
subnetSelectorTerms: [{"tags":{"karpenter.sh/discovery":"my-cluster"}}]
```

Check the subnets before reusing them. If an existing node class is restricted to a subset of
subnets, that restricts which Availability Zones the GPU type can be launched in, and a type
with no capacity in those zones leaves the pod `Pending`.

---

## Step 1. A baseline node class, with no optimization

This is Bottlerocket as it ships. Apply it first, because the later steps only mean
something against a figure from this one.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: br-test-baseline
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest      # resolves the -nvidia variant for GPU types
  role: "<NODE_ROLE>"
  blockDeviceMappings:
    - deviceName: /dev/xvda           # the OS. Small, because Bottlerocket is immutable
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
    - deviceName: /dev/xvdb           # the data volume: container images and logs
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000              # gp3 maximum, so the volume is not the limit
        iops: 16000
        encrypted: true
        deleteOnTermination: true
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  # If you hold an On-Demand Capacity Reservation or a Capacity Block for the GPU type,
  # name it here and the NodePool below can draw from it. By ID:
  # capacityReservationSelectorTerms:
  #   - id: cr-0123456789abcdef0
  # Or by tag, which picks up reservations added later without editing this:
  # capacityReservationSelectorTerms:
  #   - tags:
  #       purpose: gpu-inference
  #     ownerID: "<account ID>"          # required when the reservation is shared with you
  # An ODCR that expires or is cancelled does not terminate the node. Karpenter relabels it
  # karpenter.sh/capacity-type: on-demand and it keeps running. A Capacity Block does not
  # behave that way: EC2 terminates those instances at the end of the block, and Karpenter
  # starts draining them 10 minutes before.
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: br-test-baseline
spec:
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m
  limits:
    nvidia.com/gpu: "4"
  template:
    metadata:
      labels:
        br-test: baseline             # what a test pod selects on
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: br-test-baseline
      taints:
        # Two taints. nvidia.com/gpu is the usual one for a GPU pool. br-test is what keeps
        # your existing workloads off, because they already tolerate the GPU taint.
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["<GPU_TYPE>"]      # one type, so hardware is not a variable
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
          # Add "reserved" to let Karpenter use a capacity reservation named in the node
          # class. "reserved" means On-Demand Capacity Reservations and Capacity Blocks.
          # It does not mean Reserved Instances. Karpenter prioritises reserved, then
          # spot, then on-demand, and keeping on-demand in this list is what gives it
          # somewhere to fall back to when the reservation has nothing available:
          # values: ["reserved", "on-demand"]
```

`alias: bottlerocket@latest` resolves the `aws-k8s-<version>-nvidia` variant for GPU instance
types. That AMI already contains the NVIDIA driver, the container toolkit and the Kubernetes
device plugin, so no device plugin needs deploying. It also means the AMI is not pinned: a node
pool that can select non-GPU instance types must not have the NVIDIA variant pinned, because
that AMI does not finish booting without a GPU.

`iops` and `throughput` at the gp3 maximum are there so that a difference between the steps is
not caused by volume performance. Keep them the same in every node class you compare.

The two taints keep anything without both tolerations off these nodes, which on a cluster that
already runs GPU workloads takes the `br-test` one as well as the GPU one.

### A pod to measure with

Use an image your GPU workloads already run, so the figures are about your image rather than a
sample one. To read them off the cluster:

```bash
kubectl get pods -A -o json | python3 -c 'import json,sys
seen = {}
for p in json.load(sys.stdin)["items"]:
    for c in (p["spec"].get("containers") or []) + (p["spec"].get("initContainers") or []):
        r = c.get("resources") or {}
        if any("gpu" in k for s in ("limits", "requests") for k in (r.get(s) or {})):
            seen[c["image"]] = seen.get(c["image"], 0) + 1
for image, n in sorted(seen.items(), key=lambda kv: -kv[1]):
    print(n, image)'
```

It prints a pod count and an image for every container that requests a GPU resource. The
workshop repository has the same thing as `bin/gpu_images.py`, which also falls back to the pods
running on GPU-capable nodes when nothing requests the resource.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: br-test-baseline
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    br-test: baseline
  tolerations:
    # Matching both taints on the node pool. Without the first, this pod stays Pending.
    - key: br-test
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: app
      image: <your GPU image>
      command: ["sleep", "3600"]
      readinessProbe:
        exec:
          command: ["nvidia-smi"]     # Ready then means the GPU is usable from the container
        initialDelaySeconds: 5
        periodSeconds: 2
        failureThreshold: 300
      resources:
        limits:
          nvidia.com/gpu: 1
```

### The stage timings

The stages are timestamps Kubernetes already records.

```bash
# when the pod was created, and when it became Ready
kubectl get pod br-test-baseline \
  -o jsonpath='{.metadata.creationTimestamp}{"\n"}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}'

# the pull, from kubelet's own events. The message carries the duration and the image size
kubectl get events --field-selector involvedObject.name=br-test-baseline \
  --sort-by=.lastTimestamp -o wide | grep -E "Pulling|Pulled"

# the node's own stages, as seconds from when Karpenter created the NodeClaim.
# The second column is the elapsed total, the third is that step.
kubectl get nodeclaim -l karpenter.sh/nodepool=br-test-baseline -o json | python3 -c '
import json, sys
from datetime import datetime
def t(s): return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
for nc in json.load(sys.stdin)["items"]:
    base = t(nc["metadata"]["creationTimestamp"])
    rows = [("NodeClaim created", base)] + [
        (c["type"], t(c["lastTransitionTime"])) for c in nc["status"]["conditions"]
        if c["type"] in ("Launched", "Registered", "Initialized", "Ready")]
    rows.sort(key=lambda r: r[1])
    prev = base
    print(nc["metadata"]["name"])
    for name, ts in rows:
        print(f"  {name:<18}{(ts-base).total_seconds():>6.0f}s{(ts-prev).total_seconds():>6.0f}s")
        prev = ts
'
```

```
br-test-baseline-s7bhn
  NodeClaim created      0s     0s
  Launched               2s     2s
  Registered            19s    17s
  Initialized           36s    17s
  Ready                 36s     0s
```

Start with the `Pulled` event. Its message states how long the pull took and how many bytes the
image was, which together give the throughput the later steps change.

---

## Step 2. Pre-bake the image into an EBS snapshot

The layers go into a snapshot ahead of time, and the node restores its data volume from it. On a
node built this way, kubelet reports the image as already present and does not contact the
registry.

### Building the snapshot from a node pool that exists only to build

Do not snapshot a node that runs workloads. Its data volume carries everything that node has
ever pulled, and the snapshot inherits the volume's size, so every node restored from it gets a
volume that large. A node pool created for building gives a snapshot whose contents you chose
and whose size you set.

It also pulls the way your workloads do, with the cluster's `imagePullSecret` if the image needs
one. A tool that launches its own instance outside the cluster pulls with that instance's role,
so a private registry needing a pull secret is a case this covers and that one does not.

Four pieces: a node class, a node pool, a pod that does the pulling, and the snapshot itself.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: br-test-builder
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: "<NODE_ROLE>"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true, deleteOnTermination: true }
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 40Gi                # sized for the images, not for a workload node
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  # If you hold an On-Demand Capacity Reservation or a Capacity Block for the GPU type,
  # name it here and the NodePool below can draw from it. By ID:
  # capacityReservationSelectorTerms:
  #   - id: cr-0123456789abcdef0
  # Or by tag, which picks up reservations added later without editing this:
  # capacityReservationSelectorTerms:
  #   - tags:
  #       purpose: gpu-inference
  #     ownerID: "<account ID>"          # required when the reservation is shared with you
  # An ODCR that expires or is cancelled does not terminate the node. Karpenter relabels it
  # karpenter.sh/capacity-type: on-demand and it keeps running. A Capacity Block does not
  # behave that way: EC2 terminates those instances at the end of the block, and Karpenter
  # starts draining them 10 minutes before.
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: br-test-builder
spec:
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m             # the volume has to outlive the snapshot, below
  template:
    metadata:
      labels:
        br-test: builder
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: br-test-builder
      taints:
        # The same two-taint scheme as step 1, for the same reason: your existing GPU pods
        # already tolerate the GPU taint, so that one alone would not keep them off.
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["<GPU_TYPE>"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
          # Add "reserved" to let Karpenter use a capacity reservation named in the node
          # class. "reserved" means On-Demand Capacity Reservations and Capacity Blocks.
          # It does not mean Reserved Instances. Karpenter prioritises reserved, then
          # spot, then on-demand, and keeping on-demand in this list is what gives it
          # somewhere to fall back to when the reservation has nothing available:
          # values: ["reserved", "on-demand"]
```

The builder does not need the GPU to pull layers. Pinning the same instance type as your
workload nodes keeps the AMI variant the same as the nodes the snapshot will be restored onto,
which is one difference fewer to reason about.

Then a pod whose only purpose is to make kubelet pull the image. It does not request a GPU, so
it does not wait on the device plugin:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: br-test-pull
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    br-test: builder
  tolerations:
    - key: br-test
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: pull
      image: <your GPU image>          # more than one? add a container per image
      command: ["sleep", "3600"]
```

```bash
kubectl wait --for=condition=Ready pod/br-test-pull --timeout=15m
```

`Ready` means the pull finished. Then four commands:

```bash
# 1. the instance behind the builder node
INSTANCE=$(kubectl get nodeclaim -l karpenter.sh/nodepool=br-test-builder \
  -o jsonpath='{.items[0].status.providerID}' | sed 's|.*/||')
echo "$INSTANCE"

# 2. its data volume. /dev/xvdb, not /dev/xvda: the OS volume holds no images
VOLUME=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId | [0]" \
  --output text)
echo "$VOLUME"

# 3. snapshot it
SNAPSHOT=$(aws ec2 create-snapshot --region "$REGION" --volume-id "$VOLUME" \
  --description "Bottlerocket data volume with the image pre-pulled" \
  --query SnapshotId --output text)
echo "$SNAPSHOT"

# 4. wait. Three to five minutes for a 9 GB image
aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAPSHOT"
```

Then remove the builder, so its node is not left running:

```bash
kubectl delete pod br-test-pull
kubectl delete nodepool br-test-builder
kubectl delete ec2nodeclass br-test-builder
```

Two things this does not give you. The volume is mounted while it is snapshotted, so the result
is crash-consistent rather than clean; the pull itself has finished by the time the pod is
`Ready`, and a partially written layer would be discarded and pulled again, but that is a
property of an image cache rather than a general guarantee. And any DaemonSet with a blanket
toleration lands on the builder too, and its images go into the snapshot — which is the same
check the taint section above asks you to run.

Stopping the instance first would fix the consistency point, but Karpenter would see the node as
unhealthy and replace it. [`aws-samples/bottlerocket-images-cache`][cache] does that safely by
launching its own instance outside the cluster, stopping kubelet, removing the images already
present, pulling only the ones you name and stopping the instance before it snapshots. Use it
when you want the snapshot built from a tag by a pipeline with no cluster involved. Use the node
pool above when the pull needs credentials the cluster holds, or when launching an ad-hoc
instance outside the cluster is not something your account permits.

[cache]: https://github.com/aws-samples/bottlerocket-images-cache

### Applying it

One field differs from step 1: `snapshotID` on the data volume.

```yaml
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true, deleteOnTermination: true }
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi              # at least the snapshot's size
        volumeType: gp3
        throughput: 1000
        iops: 16000
        snapshotID: "<SNAPSHOT>"
        deleteOnTermination: true
```

`encrypted` is not set on the second volume. A volume restored from a snapshot inherits the
snapshot's encryption, and the snapshot came from an encrypted volume.

**Do not also set `instanceStorePolicy: RAID0` here.** That is step 3, and the two cannot be
combined. Step 3 covers why.

### Confirming it worked

```bash
# the volume the node booted from should carry your snapshot ID
aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" \
  --output text \
  | xargs -I{} aws ec2 describe-volumes --region "$REGION" --volume-ids {} \
      --query 'Volumes[0].SnapshotId' --output text

# and kubelet should say the image was already present
kubectl get events --field-selector involvedObject.name=br-test-snapshot | grep -i pull
```

The second command is the one that matters. `Container image ... already present on machine`
means the registry was not contacted.

The cost of this mechanism is that the snapshot has to be rebuilt whenever the image changes.
Weigh that against the improvement rather than against zero.

---

## Step 3. Local NVMe and the SOCI snapshotter

containerd's default snapshotter downloads and unpacks layers one at a time. The SOCI
snapshotter in parallel pull/unpack mode opens several connections per layer and decompresses
several layers at once. It buffers on disk while downloading, which is why the instance store is
used.

The image is not modified and no SOCI index is built. Your build pipeline does not change.

Two additions to the step 1 node class:

```yaml
spec:
  instanceStorePolicy: RAID0                 # addition 1

  userData: |                                # addition 2. TOML, not a shell script
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true
```

### What `instanceStorePolicy: RAID0` does

Karpenter turns that one line into a Bottlerocket bootstrap command:

```toml
[settings.bootstrap-commands.000-mount-instance-storage]
commands = [
  ["apiclient", "ephemeral-storage", "init"],
  ["apiclient", "ephemeral-storage", "bind"],
]
essential = true
mode = "always"
```

`init` prepares the instance-store disks and mounts them at `/mnt`. `bind` then runs
`mount --rbind` from that mount onto `/var/lib/containerd`, `/var/lib/kubelet`,
`/var/log/pods` and `/var/lib/soci-snapshotter`. Nothing is moved and no symlink is made: those
paths are covered by a mount, so reads and writes below them land on the instance store.

Whether an array is actually built depends on the disk count.

| Disks | What happens |
|---|---|
| 2 or more | `mdadm --create --level=0 --chunk=256`, then XFS on the array |
| 1 | No array. The device is formatted XFS directly |
| 0 | `init` logs that it found no ephemeral disks and exits successfully. Nothing is bound, and this node class behaves like step 1 |

Check your type before you judge a figure:

```bash
aws ec2 describe-instance-types --region "$REGION" --instance-types "$GPU_TYPE" \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

### Why this and step 2 cannot be combined

The snapshot puts the layers in `/local/var/lib/containerd` on the EBS data volume, which is
where `/var/lib/containerd` resolves to on an unmodified node. The bind mount covers that path
with an empty directory on the instance store, so kubelet cannot reach the pre-baked layers and
pulls the image again. The snapshot is still restored and the layers are still on the volume;
the path no longer resolves there.

### What each SOCI setting does

| Setting | Effect |
|---|---|
| `snapshotter = "soci"` | Selects SOCI as containerd's snapshotter. Without this the rest has no effect |
| `pull-mode = "parallel-pull-unpack"` | Selects the parallel mode. SOCI also has lazy-loading modes, which this is not |
| `max-concurrent-downloads-per-image = 20` | HTTP connections per layer |
| `concurrent-download-chunk-size = "16mb"` | The size large layers are split into for parallel download |
| `max-concurrent-unpacks-per-image = 12` | Layers decompressed at once. Decompression is CPU-bound, which is why the instance's vCPU count changes the result |
| `discard-unpacked-layers = true` | Frees the compressed copy of each layer after unpacking |

These are the values AWS publishes as a starting point. Layer count, layer size and vCPU decide
what suits a given image.

### Version requirement

SOCI parallel pull/unpack was added in Bottlerocket 1.44.0. On an earlier version
`snapshotter = "soci"` is ignored **without an error**: the node boots, the pod runs, and this
node class measures the same thing as step 1. Check the version before you accept a result:

```bash
kubectl get nodes -l br-test=soci -o jsonpath='{.items[0].status.nodeInfo.osImage}'
```

### Confirming it worked

Bottlerocket has no shell, so there is no logging in to look. Two things can be checked from
outside.

```bash
# container storage moved to the instance store: allocatable ephemeral-storage now reflects
# the NVMe rather than the 100 GiB EBS volume
kubectl get node -l br-test=soci \
  -o jsonpath='{.items[0].status.capacity.ephemeral-storage}{"\n"}'

# the settings reached the node class
kubectl get ec2nodeclass br-test-soci -o jsonpath='{.spec.userData}'
```

Neither proves SOCI ran. The evidence for that is the pull duration and the size in the
`Pulled` event: if the setting were being ignored, the throughput would match step 1.

---

## Step 4. The same pod on a node that is already running

Everything above measures the first pod on a new node. Most scale-out events do not look like
that.

```bash
# delete the pod, keep the node
kubectl delete pod br-test-soci
kubectl apply -f pod.yaml            # the same pod spec
```

The node survives because `consolidateAfter` is 30m. Compare start-to-Ready with the cold run.

Whatever the difference is, that is the part of your startup cost that is incurred once per node
rather than once per pod. If most of your pods land on nodes that are already running, the three
mechanisms above affect a small share of your total startup time, and node capacity policy
affects more of it. The thing to find out is what fraction of your pods land on new nodes.

---

## Step 5. Model loading, for an inference workload

Once the image stops being the largest stage, the weights are next. Three variations, in the
order to try them.

### Weights in an init container, and the defect in it

```yaml
  initContainers:
    - name: fetch-weights
      image: public.ecr.aws/aws-cli/aws-cli:latest
      command: ["bash", "-c"]
      args: ["aws s3 cp s3://BUCKET/PREFIX/ /models/ --recursive --only-show-errors"]
      env:
        - name: AWS_MAX_CONCURRENT_REQUESTS
          value: "32"
      volumeMounts:
        - { name: models, mountPath: /models }
```

kubelet pulls the init image, runs the init container to completion, and only then pulls the
workload image. The copy and the pull never overlap. So moving weights out of the image makes
the image smaller and can still make start-to-Ready longer.

### Run:ai Model Streamer reading from disk

```yaml
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model /models \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":16}'
```

`runai-streamer` is already in the AWS vLLM Deep Learning Container and is Apache-2.0, so
nothing is installed and no licence is needed. This changes the loader only, with the same bytes
on the same disk.

### The streamer reading S3 directly, with no copy step

```yaml
      # no initContainers
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model s3://BUCKET/PREFIX \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":32}'
```

### What the log says

```bash
kubectl logs <pod> | grep -E "Loading weights took|Model loading took|torch.compile took|init engine"
```

At a 1.5B model on an L4, reading the weights was 0.30 seconds of an 84-second start-to-Ready.
The loader had very little to improve. What the third variation reduced was the copy step, not
the read.

This line names its own nesting:

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

Compilation and CUDA graph capture happen **inside** engine initialisation. They are not
separate stages to add up. At this model size the engine stage was the largest item, and no
loader affects it.

Whether that holds for you depends on model size. Measure it rather than assuming either way.

### Credentials

On a Karpenter node the node role is not usable from inside a pod. Karpenter sets the IMDS hop
limit to 1, so a request from a container is one hop too far and the AWS SDK reports
`Unable to locate credentials`. Use EKS Pod Identity, or IRSA:

```bash
aws eks create-pod-identity-association --region "$REGION" --cluster-name "$CLUSTER" \
  --namespace default --service-account <sa> --role-arn <role that can read the bucket>
```

Keep the hop limit. It is what stops a pod from using the node's permissions.

---

## Step 6. Reusing vLLM's compiled artifacts

Compilation was 14.76 of those 84 seconds. vLLM can reuse the artifacts, but it writes them
inside the container's writable layer, so a replacement pod compiles again.

```bash
kubectl logs <pod> | grep "Using cache directory"
# Using cache directory: /root/.cache/vllm/torch_compile_cache/<hash>/rank_0_0/backbone
```

Give that directory somewhere that outlives the pod:

```yaml
  volumes:
    - name: compile-cache
      hostPath:
        path: /var/lib/vllm-compile-cache/<any stable name>
        type: DirectoryOrCreate
  # ...
      volumeMounts:
        - name: compile-cache
          mountPath: /root/.cache/vllm/torch_compile_cache
```

**Mount the subdirectory, not `/root/.cache/vllm`.** Run:ai Model Streamer caches the model
under the same root, so mounting the whole root would persist the weights too. The second pod
would then skip the S3 read as well, and the saving could not be attributed to compilation.

To confirm which happened, read the log rather than the timing. A short compile time is also
what a changed compilation configuration looks like.

```bash
# a miss compiled and saved
kubectl logs <pod> | grep -E "Compiling a graph|saved AOT compiled function"

# a hit reused
kubectl logs <pod> | grep "Directly load"
# Directly load the compiled graph(s) for compile range (1, 2048) from the cache, took 0.996 s
```

Measured on `gr6.8xlarge`: 82 seconds with an empty cache, 69 with a populated one.
`torch.compile` went from 14.78 seconds to 3.01. Model load stayed at 2.6 seconds in both,
which is how we know the weights still came from S3 and the saving belongs to compilation.

A hit removes compilation and nothing else in that stage. Profiling, KV-cache creation and
warmup accounted for the remaining 12 seconds and did not move.

The artifacts live on the node, so they do not survive a node replacement. Restoring them from
S3 onto a new node is a further step, and the cache key covers the model, dtype, GPU
architecture, vLLM version and compilation configuration, so artifacts do not transfer across a
change in any of those.

---

## Cleaning up

```bash
kubectl delete pod br-test-baseline br-test-snapshot br-test-soci br-test-pull --ignore-not-found
kubectl delete nodepool br-test-baseline br-test-snapshot br-test-soci br-test-builder --ignore-not-found
kubectl delete ec2nodeclass br-test-baseline br-test-snapshot br-test-soci br-test-builder --ignore-not-found
aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT"
```

Deleting the NodePool terminates its nodes. Check that none are left:

```bash
kubectl get nodeclaims
```

<br>

---
---

<a id="japanese"></a>

# 既存クラスターへの適用

[English](#applying-this-to-a-cluster-you-already-have) | **日本語**

本ワークショップが計測する機構はすべて `EC2NodeClass` と `NodePool` です。どちらも新しい
クラスターを必要としません。この文書では `bin/` のスクリプトを使わず、コマンドと YAML を直接
示します。既存クラスター上で 1 ステップずつ実行し、内容を確認できる形にしています。

`bin/` のスクリプトは同じことを行い、さらに段階ごとの内訳を算出します。内訳が必要ならスクリプトを、
設定を適用したいだけならこの文書を使ってください。

---

## クラスターに必要なもの

| | |
|---|---|
| Karpenter | 自己管理で、`karpenter.k8s.aws/v1` API。`kubectl get crd ec2nodeclasses.karpenter.k8s.aws` |
| サブネットとセキュリティグループのタグ | `karpenter.sh/discovery: <cluster>`。標準的な Karpenter 導入で設定済み |
| ノード IAM ロール | 既存の node class が使っているロール。`kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}'` |
| Kubernetes | 本ワークショップの CUDA 13 イメージを使う場合は 1.34 以上（NVIDIA ドライバ 580 が必要）。自社イメージなら不問 |
| Bottlerocket | ステップ 3 の SOCI 設定には 1.44.0 以上。`bottlerocket@latest` は現行版に解決されます |
| GPU インスタンスタイプ | ローカル NVMe インスタンスストア付き。RAID0 でストライピングさせるなら 2 本以上 |

既存の NodePool には何も追加しません。各ステップは新しい NodePool を作るので、既存ワークロードが
動いているノードには触れません。

### 既存ワークロードをこの node pool に載せない

既に Karpenter でワークロードを動かしている場合、これは重要です。そして通常の GPU taint だけでは
不十分です。

Karpenter は Pending の Pod があると全 NodePool を検討し、**その Pod が tolerate する taint を持つ
pool から**ノードを起動します。現在動かしている GPU ワークロードは、ほぼ確実に `nvidia.com/gpu` を
tolerate しています。そもそもそれが GPU ノードに載るための条件だからです。したがって
`nvidia.com/gpu` だけを taint に持つ Bottlerocket の pool は、既存 Pod が載りうる pool です。

そのため以下の NodePool はすべて、既存のどの Pod も tolerate しない 2 つ目の taint を持ちます。

```yaml
      taints:
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
```

この文書のテスト Pod だけが `br-test` を tolerate し、それもキーと値の両方で一致させています。
クラスター内で `br-test` が既に使われている場合は、未使用の名前に変えてください。

開始前に、新しい taint を tolerate してしまうものがクラスター内にあるか確認できます。

```bash
# 無条件の toleration を持つ Pod。どこにでも載りうる
kubectl get pods -A -o json \
  | python3 -c 'import json,sys
for p in json.load(sys.stdin)["items"]:
    for t in p["spec"].get("tolerations") or []:
        if t.get("operator") == "Exists" and not t.get("key"):
            print(p["metadata"]["namespace"], p["metadata"]["name"])'

# 適用後、テスト用ノードに実際に載った Pod
kubectl get pods -A -o wide --field-selector spec.nodeName=<新しいノード>
```

1 つ目のコマンドは、任意の taint を tolerate する Pod を列挙します。通常は DaemonSet で、これは
想定どおりです。他の全ノードと同様に新しいノードでも動きます。この一覧にワークロードの Pod が
含まれる場合は、続ける前に中身を確認してください。

### 以下で使う値

既存の NodePool と衝突しない prefix を選んでください。

```bash
export CLUSTER=<クラスター名>
export NODE_ROLE=<Karpenter が既に使っているノード IAM ロール>
export REGION=<リージョン>
export GPU_TYPE=gr6.8xlarge          # またはインスタンスストア付きの別のタイプ
export PREFIX=br-test                # NodePool と EC2NodeClass 名の prefix
```

このクラスターで既に Karpenter が動いている場合、以下の node class のうち 3 つのフィールドは、
既存の node class からそのまま使える場合が多いです。`role`、`securityGroupSelectorTerms`、
`subnetSelectorTerms` です。起動するノードは同じクラスターに join し、同じサブネットに置かれる
ので、同じ値が当てはまります。

```bash
kubectl get ec2nodeclass -o jsonpath='{range .items[*]}{"\n=== "}{.metadata.name}{"\nrole: "}{.spec.role}{"\nsecurityGroupSelectorTerms: "}{.spec.securityGroupSelectorTerms}{"\nsubnetSelectorTerms: "}{.spec.subnetSelectorTerms}{"\n"}{end}'
```

```
=== gpu-workers
role: my-cluster-karpenter-node
securityGroupSelectorTerms: [{"tags":{"karpenter.sh/discovery":"my-cluster"}}]
subnetSelectorTerms: [{"tags":{"karpenter.sh/discovery":"my-cluster"}}]
```

サブネットは流用前に確認してください。既存の node class が一部のサブネットに限定されている場合、
GPU タイプを起動できる AZ もその範囲に限定されます。その AZ に容量がないタイプだと Pod は
`Pending` のままになります。

---

## ステップ 1. 最適化なしのベースライン node class

Bottlerocket をそのまま使う構成です。以降のステップはこの数字と比べて初めて意味を持つので、
最初に適用してください。

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: br-test-baseline
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest      # GPU 型では -nvidia variant が解決される
  role: "<NODE_ROLE>"
  blockDeviceMappings:
    - deviceName: /dev/xvda           # OS 用。Bottlerocket はイミュータブルなので小容量
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
    - deviceName: /dev/xvdb           # データボリューム。コンテナイメージとログ
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000              # gp3 の最大値。ボリュームが制約にならないように
        iops: 16000
        encrypted: true
        deleteOnTermination: true
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  # GPU タイプの On-Demand Capacity Reservation または Capacity Block を持っている場合、
  # ここで指定すると下の NodePool がそこから確保できます。ID 指定:
  # capacityReservationSelectorTerms:
  #   - id: cr-0123456789abcdef0
  # タグ指定。後から追加した予約も、ここを編集せずに対象になります:
  # capacityReservationSelectorTerms:
  #   - tags:
  #       purpose: gpu-inference
  #     ownerID: "<アカウント ID>"        # 予約が共有されている場合は必須
  # ODCR が期限切れやキャンセルになってもノードは終了しません。Karpenter が
  # karpenter.sh/capacity-type: on-demand に付け替え、そのまま動き続けます。Capacity Block は
  # 違います。ブロック終了時に EC2 がインスタンスを終了し、Karpenter はその 10 分前から
  # drain を始めます。
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: br-test-baseline
spec:
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m
  limits:
    nvidia.com/gpu: "4"
  template:
    metadata:
      labels:
        br-test: baseline             # テスト Pod が選択するラベル
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: br-test-baseline
      taints:
        # taint は 2 つ。nvidia.com/gpu は GPU pool の通例。br-test が既存ワークロードを
        # 排除する役割で、既存 Pod は GPU taint を既に tolerate しているため必要になる
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["<GPU_TYPE>"]      # 1 タイプに固定。ハードウェアを変数にしない
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
          # node class で指定した capacity reservation を使う場合は "reserved" を追加します。
          # "reserved" は On-Demand Capacity Reservation と Capacity Block を指します。
          # Reserved Instances ではありません。Karpenter の優先順は reserved、spot、
          # on-demand で、予約に空きがないときの退避先になるのがこの on-demand です:
          # values: ["reserved", "on-demand"]
```

`alias: bottlerocket@latest` は、GPU インスタンスタイプに対して `aws-k8s-<version>-nvidia`
variant を解決します。この AMI には NVIDIA ドライバ、container toolkit、Kubernetes device
plugin が含まれるため、device plugin のデプロイは不要です。また AMI が固定されないことも意味
します。GPU 以外のインスタンスタイプを選択しうる node pool で NVIDIA variant を固定してはいけません。
その AMI は GPU なしでは boot が完了しないためです。

`iops` と `throughput` を gp3 の最大値にしているのは、ステップ間の差がボリューム性能に起因しない
ようにするためです。比較する node class 間では同じ値にしてください。

2 つの taint は、両方の toleration を持たないものをこのノードから排除します。既に GPU
ワークロードを動かしているクラスターでは、GPU の taint に加えて `br-test` の方も必要になります。

### 計測用の Pod

すでに GPU ワークロードで使っているイメージを指定してください。そうすると数字がサンプルの
イメージではなく自分のイメージについてのものになります。クラスターから取得するには次のようにします。

```bash
kubectl get pods -A -o json | python3 -c 'import json,sys
seen = {}
for p in json.load(sys.stdin)["items"]:
    for c in (p["spec"].get("containers") or []) + (p["spec"].get("initContainers") or []):
        r = c.get("resources") or {}
        if any("gpu" in k for s in ("limits", "requests") for k in (r.get(s) or {})):
            seen[c["image"]] = seen.get(c["image"], 0) + 1
for image, n in sorted(seen.items(), key=lambda kv: -kv[1]):
    print(n, image)'
```

GPU リソースを要求している各コンテナについて、Pod 数とイメージを出力します。ワークショップ
リポジトリには同じものが `bin/gpu_images.py` として入っており、要求しているものが無い場合は
GPU 容量を持つノード上の Pod にフォールバックします。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: br-test-baseline
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    br-test: baseline
  tolerations:
    # node pool の 2 つの taint に対応。1 つ目が無いとこの Pod は Pending のままになる
    - key: br-test
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: app
      image: <GPU イメージ>
      command: ["sleep", "3600"]
      readinessProbe:
        exec:
          command: ["nvidia-smi"]     # Ready = コンテナから GPU が使える状態
        initialDelaySeconds: 5
        periodSeconds: 2
        failureThreshold: 300
      resources:
        limits:
          nvidia.com/gpu: 1
```

### 段階ごとの所要時間

各段階は Kubernetes が既に記録しているタイムスタンプです。

```bash
# Pod の作成時刻と Ready になった時刻
kubectl get pod br-test-baseline \
  -o jsonpath='{.metadata.creationTimestamp}{"\n"}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}'

# pull。kubelet 自身のイベント。メッセージに所要時間とイメージサイズが入っている
kubectl get events --field-selector involvedObject.name=br-test-baseline \
  --sort-by=.lastTimestamp -o wide | grep -E "Pulling|Pulled"

# ノード側の段階。Karpenter が NodeClaim を作った時点からの秒数。
# 2 列目が経過の累計、3 列目がその段階の所要時間。
kubectl get nodeclaim -l karpenter.sh/nodepool=br-test-baseline -o json | python3 -c '
import json, sys
from datetime import datetime
def t(s): return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
for nc in json.load(sys.stdin)["items"]:
    base = t(nc["metadata"]["creationTimestamp"])
    rows = [("NodeClaim created", base)] + [
        (c["type"], t(c["lastTransitionTime"])) for c in nc["status"]["conditions"]
        if c["type"] in ("Launched", "Registered", "Initialized", "Ready")]
    rows.sort(key=lambda r: r[1])
    prev = base
    print(nc["metadata"]["name"])
    for name, ts in rows:
        print(f"  {name:<18}{(ts-base).total_seconds():>6.0f}s{(ts-prev).total_seconds():>6.0f}s")
        prev = ts
'
```

```
br-test-baseline-s7bhn
  NodeClaim created      0s     0s
  Launched               2s     2s
  Registered            19s    17s
  Initialized           36s    17s
  Ready                 36s     0s
```

最初に見るのは `Pulled` イベントです。pull の所要時間とイメージのバイト数が書かれており、
この 2 つから以降のステップが変えるスループットが出ます。

---

## ステップ 2. イメージを EBS スナップショットに焼き込む

レイヤを事前にスナップショットへ入れ、ノードはそこからデータボリュームを復元します。この方式の
ノードでは kubelet がイメージを既に存在すると報告し、レジストリに接続しません。

### ビルド専用の node pool から作る

ワークロードが動いているノードをスナップショットしないでください。そのデータボリュームには
そのノードが pull した全てが入っており、スナップショットはボリュームのサイズを継承するため、
そこから復元する全ノードがその容量になります。ビルドのために作った node pool なら、内容も
サイズも自分で決められます。

pull の経路もワークロードと同じになり、イメージに `imagePullSecret` が必要ならそれが使われます。
クラスター外に自前のインスタンスを起動するツールはそのインスタンスのロールで pull するため、
pull secret が必要なプライベートレジストリはこちらでしか扱えません。

必要なものは 4 つです。node class、node pool、pull を行う Pod、そしてスナップショットです。

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: br-test-builder
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: "<NODE_ROLE>"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true, deleteOnTermination: true }
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 40Gi                # ワークロードノードではなくイメージに合わせる
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "<CLUSTER>"
  # GPU タイプの On-Demand Capacity Reservation または Capacity Block を持っている場合、
  # ここで指定すると下の NodePool がそこから確保できます。ID 指定:
  # capacityReservationSelectorTerms:
  #   - id: cr-0123456789abcdef0
  # タグ指定。後から追加した予約も、ここを編集せずに対象になります:
  # capacityReservationSelectorTerms:
  #   - tags:
  #       purpose: gpu-inference
  #     ownerID: "<アカウント ID>"        # 予約が共有されている場合は必須
  # ODCR が期限切れやキャンセルになってもノードは終了しません。Karpenter が
  # karpenter.sh/capacity-type: on-demand に付け替え、そのまま動き続けます。Capacity Block は
  # 違います。ブロック終了時に EC2 がインスタンスを終了し、Karpenter はその 10 分前から
  # drain を始めます。
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: br-test-builder
spec:
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m             # 後述のスナップショットが終わるまでボリュームを残す
  template:
    metadata:
      labels:
        br-test: builder
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: br-test-builder
      taints:
        # ステップ 1 と同じ 2 つの taint。理由も同じで、既存の GPU Pod は GPU の taint を
        # すでに tolerate しているため、それだけでは排除できません。
        - key: br-test
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["<GPU_TYPE>"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
          # node class で指定した capacity reservation を使う場合は "reserved" を追加します。
          # "reserved" は On-Demand Capacity Reservation と Capacity Block を指します。
          # Reserved Instances ではありません。Karpenter の優先順は reserved、spot、
          # on-demand で、予約に空きがないときの退避先になるのがこの on-demand です:
          # values: ["reserved", "on-demand"]
```

レイヤの pull に GPU は不要です。それでもワークロードノードと同じインスタンスタイプを指定するのは、
スナップショットを復元する先のノードと AMI variant を揃え、考慮すべき差異を 1 つ減らすためです。

次に、kubelet にイメージを pull させるためだけの Pod です。GPU を要求しないので、device plugin を
待ちません。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: br-test-pull
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    br-test: builder
  tolerations:
    - key: br-test
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: pull
      image: <GPU イメージ>              # 複数ある場合はイメージごとに container を追加
      command: ["sleep", "3600"]
```

```bash
kubectl wait --for=condition=Ready pod/br-test-pull --timeout=15m
```

`Ready` は pull が完了したことを意味します。ここからコマンドは 4 つです。

```bash
# 1. builder ノードの実体であるインスタンス
INSTANCE=$(kubectl get nodeclaim -l karpenter.sh/nodepool=br-test-builder \
  -o jsonpath='{.items[0].status.providerID}' | sed 's|.*/||')
echo "$INSTANCE"

# 2. そのデータボリューム。/dev/xvda ではなく /dev/xvdb。OS ボリュームにイメージは無い
VOLUME=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId | [0]" \
  --output text)
echo "$VOLUME"

# 3. スナップショットを取る
SNAPSHOT=$(aws ec2 create-snapshot --region "$REGION" --volume-id "$VOLUME" \
  --description "Bottlerocket data volume with the image pre-pulled" \
  --query SnapshotId --output text)
echo "$SNAPSHOT"

# 4. 待つ。9 GB のイメージで 3〜5 分
aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAPSHOT"
```

終わったら builder を片付けます。ノードを起動したままにしないためです。

```bash
kubectl delete pod br-test-pull
kubectl delete nodepool br-test-builder
kubectl delete ec2nodeclass br-test-builder
```

これで得られないものが 2 つあります。ボリュームはマウントされた状態で取得するため、結果は整合では
なくクラッシュ整合です。pull 自体は Pod が `Ready` になった時点で完了しており、書き込み途中の
レイヤは破棄されて再 pull されますが、これはイメージキャッシュの性質であり一般的な保証では
ありません。もう 1 つは、無条件 toleration を持つ DaemonSet は builder にも載るため、そのイメージが
スナップショットに入ることです。これは上の taint の節で確認を求めているものと同じです。

インスタンスを先に停止すれば整合性の点は解決しますが、Karpenter はそのノードを unhealthy と見なして
置き換えます。[`aws-samples/bottlerocket-images-cache`][cache] はクラスター外に自前のインスタンスを
起動し、kubelet を停止し、既存イメージを削除し、指定したイメージだけを pull し、インスタンスを
停止してからスナップショットを取ることで、これを安全に行います。クラスターを介さずパイプラインが
タグからスナップショットを作る場合はこちらを使ってください。pull にクラスターが持つ資格情報が必要な
場合、あるいはクラスター外にアドホックなインスタンスを起動することがアカウントの方針で許されない
場合は、上の node pool を使ってください。

### 適用する

ステップ 1 との差はデータボリュームの `snapshotID` 1 フィールドです。

```yaml
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 4Gi, volumeType: gp3, encrypted: true, deleteOnTermination: true }
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi              # スナップショットのサイズ以上
        volumeType: gp3
        throughput: 1000
        iops: 16000
        snapshotID: "<SNAPSHOT>"
        deleteOnTermination: true
```

2 番目のボリュームに `encrypted` を設定していません。スナップショットから復元したボリュームは
スナップショットの暗号化を継承し、そのスナップショットは暗号化されたボリュームから取得したものです。

**ここに `instanceStorePolicy: RAID0` を併せて設定しないでください。** それはステップ 3 で、
2 つは併用できません。理由はステップ 3 に書いています。

### 効果を確認する

```bash
# ノードが起動したボリュームに、作成したスナップショット ID が付いているはず
aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" \
  --output text \
  | xargs -I{} aws ec2 describe-volumes --region "$REGION" --volume-ids {} \
      --query 'Volumes[0].SnapshotId' --output text

# そして kubelet がイメージは既に存在すると言っているはず
kubectl get events --field-selector involvedObject.name=br-test-snapshot | grep -i pull
```

重要なのは 2 番目です。`Container image ... already present on machine` はレジストリに接続して
いないことを意味します。

この機構のコストは、イメージが変わるたびにスナップショットを作り直す必要があることです。改善幅は
このコストと比べて判断してください。

---

## ステップ 3. ローカル NVMe と SOCI snapshotter

containerd の既定 snapshotter はレイヤを 1 つずつダウンロードして展開します。SOCI snapshotter の
parallel pull/unpack モードは、レイヤごとに複数の接続を開き、複数のレイヤを同時に展開します。
ダウンロード中はディスクにバッファするため、インスタンスストアを使います。

イメージは変更せず、SOCI index も作りません。ビルドパイプラインは変わりません。

ステップ 1 の node class への追加は 2 つです。

```yaml
spec:
  instanceStorePolicy: RAID0                 # 追加 1

  userData: |                                # 追加 2。シェルスクリプトではなく TOML
    [settings.container-runtime]
    snapshotter = "soci"

    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"

    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true
```

### `instanceStorePolicy: RAID0` が行うこと

Karpenter はこの 1 行を Bottlerocket の bootstrap command に変換します。

```toml
[settings.bootstrap-commands.000-mount-instance-storage]
commands = [
  ["apiclient", "ephemeral-storage", "init"],
  ["apiclient", "ephemeral-storage", "bind"],
]
essential = true
mode = "always"
```

`init` がインスタンスストアのディスクを準備して `/mnt` にマウントし、`bind` がそこから
`/var/lib/containerd`、`/var/lib/kubelet`、`/var/log/pods`、`/var/lib/soci-snapshotter` へ
`mount --rbind` します。移動もせず symlink も作りません。これらのパスがマウントで覆われるため、
その下への読み書きがインスタンスストアに向きます。

実際にアレイが作られるかはディスク本数で決まります。

| ディスク | 動作 |
|---|---|
| 2 本以上 | `mdadm --create --level=0 --chunk=256`、アレイを XFS でフォーマット |
| 1 本 | アレイなし。デバイスを直接 XFS でフォーマット |
| 0 本 | `init` は ephemeral disk が無いと記録して正常終了。何もバインドされず、この node class はステップ 1 と同じ挙動になる |

数字を判断する前に、自身のタイプを確認してください。

```bash
aws ec2 describe-instance-types --region "$REGION" --instance-types "$GPU_TYPE" \
  --query 'InstanceTypes[0].InstanceStorageInfo.Disks'
```

### ステップ 2 と併用できない理由

スナップショットはレイヤを EBS データボリューム上の `/local/var/lib/containerd` に置きます。
未変更のノードでは `/var/lib/containerd` がそこに解決されます。bind mount はそのパスを
インスタンスストア上の空ディレクトリで覆うため、kubelet は焼き込んだレイヤに到達できず、イメージを
再度 pull します。スナップショットは復元されており、レイヤもボリューム上にあります。パスの解決先が
そこでなくなるだけです。

### 各 SOCI 設定の意味

| 設定 | 効果 |
|---|---|
| `snapshotter = "soci"` | containerd の snapshotter として SOCI を選択。これが無いと以下は効かない |
| `pull-mode = "parallel-pull-unpack"` | 並列モードを選択。SOCI には lazy-load 系もあるが、これはそれではない |
| `max-concurrent-downloads-per-image = 20` | レイヤあたりの HTTP 接続数 |
| `concurrent-download-chunk-size = "16mb"` | 並列ダウンロードのためにレイヤを分割する単位 |
| `max-concurrent-unpacks-per-image = 12` | 同時に展開するレイヤ数。展開は CPU バウンドなので、インスタンスの vCPU 数が結果を変える |
| `discard-unpacked-layers = true` | 展開後に各レイヤの圧縮コピーを解放 |

これらは AWS が出発点として公開している値です。適切な値はレイヤ数、レイヤサイズ、vCPU で決まります。

### バージョン要件

SOCI の parallel pull/unpack は Bottlerocket 1.44.0 で追加されました。それより前のバージョンでは
`snapshotter = "soci"` が**エラーなく無視されます。** ノードは起動し、Pod も動き、この node class は
ステップ 1 と同じものを計測します。結果を信じる前に確認してください。

```bash
kubectl get nodes -l br-test=soci -o jsonpath='{.items[0].status.nodeInfo.osImage}'
```

### 効果を確認する

Bottlerocket にシェルは無いので、ログインして見ることはできません。外から確認できるものが 2 つ
あります。

```bash
# コンテナストレージがインスタンスストアに移った。allocatable ephemeral-storage が
# 100 GiB の EBS ボリュームではなく NVMe を反映するようになる
kubectl get node -l br-test=soci \
  -o jsonpath='{.items[0].status.capacity.ephemeral-storage}{"\n"}'

# 設定が node class に届いている
kubectl get ec2nodeclass br-test-soci -o jsonpath='{.spec.userData}'
```

どちらも SOCI が動作したことの証明にはなりません。その根拠は `Pulled` イベントの pull 所要時間と
サイズです。設定が無視されていれば、スループットはステップ 1 と一致します。

---

## ステップ 4. すでに動いているノードに同じ Pod を載せる

上記はすべて新しいノードへの 1 個目の Pod を計測しています。スケールアウトの大半はそうではありません。

```bash
# Pod を削除し、ノードは残す
kubectl delete pod br-test-soci
kubectl apply -f pod.yaml            # 同じ Pod spec
```

`consolidateAfter` が 30m なのでノードは残ります。start-to-Ready を cold の実行と比較してください。

その差が、起動コストのうち Pod ごとではなく**ノード 1 台につき 1 回**発生している分です。Pod の
大半がすでに動いているノードに載るなら、上記 3 つの機構が影響するのは起動時間全体のごく一部で、
ノードのキャパシティ方針の方が大きく影響します。確認すべきことは、自社の Pod の何割が新しい
ノードに載っているかです。

---

## ステップ 5. 推論ワークロードのモデルロード

イメージが最大の段階でなくなると、次はウェイトです。試す価値のある順に 3 通りです。

### init コンテナでウェイトを取得する場合の欠点

```yaml
  initContainers:
    - name: fetch-weights
      image: public.ecr.aws/aws-cli/aws-cli:latest
      command: ["bash", "-c"]
      args: ["aws s3 cp s3://BUCKET/PREFIX/ /models/ --recursive --only-show-errors"]
      env:
        - name: AWS_MAX_CONCURRENT_REQUESTS
          value: "32"
      volumeMounts:
        - { name: models, mountPath: /models }
```

kubelet は init イメージを pull し、init コンテナを完了まで実行し、その後で本体イメージを pull
します。コピーと pull は重なりません。したがって、イメージからウェイトを出すとイメージは小さく
なりますが、start-to-Ready は伸びることがあります。

### Run:ai Model Streamer がディスクから読む

```yaml
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model /models \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":16}'
```

`runai-streamer` は AWS vLLM Deep Learning Container に既に含まれており Apache-2.0 なので、
インストールもライセンスも不要です。これはローダーだけを変え、バイト列とディスクは同じです。

### streamer が S3 を直接読む（コピー工程なし）

```yaml
      # initContainers なし
      args:
        - |
          python3 -m vllm.entrypoints.openai.api_server \
            --model s3://BUCKET/PREFIX \
            --load-format runai_streamer \
            --model-loader-extra-config '{"concurrency":32}'
```

### ログに何が出るか

```bash
kubectl logs <pod> | grep -E "Loading weights took|Model loading took|torch.compile took|init engine"
```

L4 上の 1.5B モデルでは、ウェイトの読み込みは start-to-Ready 84 秒のうち 0.30 秒でした。ローダーに
改善の余地はほとんどありません。3 番目の方式はコピー工程を無くしたことで短縮しました。読み込み自体は速くなっていません。

見るべき行はこれです。自身の入れ子構造を明記しています。

```
init engine (profile, create kv cache, warmup model) took 27.98 s (compilation: 14.76 s)
```

コンパイルと CUDA graph capture は engine init の**内側**で起きています。足し合わせる別の段階では
ありません。このモデルサイズでは engine 段階が最大の項目で、どのローダーもここには影響しません。

これが自社に当てはまるかはモデルサイズで変わります。どちらとも仮定せず計測してください。

### 認証情報

Karpenter のノードでは、ノードロールを Pod 内から使えません。Karpenter が IMDS の hop limit を
1 に設定するため、コンテナからのリクエストは 1 hop 超過となり、AWS SDK は
`Unable to locate credentials` を返します。EKS Pod Identity または IRSA を使ってください。

```bash
aws eks create-pod-identity-association --region "$REGION" --cluster-name "$CLUSTER" \
  --namespace default --service-account <sa> --role-arn <バケットを読めるロール>
```

hop limit はそのままにしてください。これが Pod にノードの権限を使わせない仕組みです。

---

## ステップ 6. vLLM のコンパイル成果物を再利用する

先の 84 秒のうちコンパイルは 14.76 秒でした。vLLM は成果物を再利用できますが、コンテナの
書き込み可能レイヤ内に書くため、置き換わった Pod は再度コンパイルします。

```bash
kubectl logs <pod> | grep "Using cache directory"
# Using cache directory: /root/.cache/vllm/torch_compile_cache/<hash>/rank_0_0/backbone
```

このディレクトリに、Pod より長く残る場所を与えます。

```yaml
  volumes:
    - name: compile-cache
      hostPath:
        path: /var/lib/vllm-compile-cache/<任意の安定した名前>
        type: DirectoryOrCreate
  # ...
      volumeMounts:
        - name: compile-cache
          mountPath: /root/.cache/vllm/torch_compile_cache
```

**マウントするのはサブディレクトリで、`/root/.cache/vllm` ではありません。** Run:ai Model Streamer
が同じルート配下にモデルをキャッシュするため、ルート全体をマウントするとウェイトも永続化されます。
2 個目の Pod は S3 の読み込みもスキップし、短縮分をコンパイルに帰属させられなくなります。

どちらが起きたかはログで確認してください。コンパイル時間が短いという結果は、コンパイル設定が
変わった場合にも同じように見えます。

```bash
# ミス: コンパイルして保存した
kubectl logs <pod> | grep -E "Compiling a graph|saved AOT compiled function"

# ヒット: 再利用した
kubectl logs <pod> | grep "Directly load"
# Directly load the compiled graph(s) for compile range (1, 2048) from the cache, took 0.996 s
```

`gr6.8xlarge` での実測では、キャッシュが空で 82 秒、埋まっている状態で 69 秒でした。
`torch.compile` は 14.78 秒から 3.01 秒になりました。モデルロードは両方 2.6 秒のままで、これが
ウェイトが両方とも S3 から来ており、短縮がコンパイルに帰属することの根拠です。

ヒットが除去するのはコンパイルだけで、その段階の他のものは除去しません。profiling、KV cache
作成、warmup が残りの約 12 秒を占めており、動いていません。

成果物はノード上にあるため、ノードの置き換えには残りません。新規ノードへ S3 から復元するのは
さらに別の手順で、キャッシュキーはモデル、dtype、GPU アーキテクチャ、vLLM バージョン、コンパイル
設定を含むため、いずれかが変わると成果物は流用できません。

---

## 後片付け

```bash
kubectl delete pod br-test-baseline br-test-snapshot br-test-soci br-test-pull --ignore-not-found
kubectl delete nodepool br-test-baseline br-test-snapshot br-test-soci br-test-builder --ignore-not-found
kubectl delete ec2nodeclass br-test-baseline br-test-snapshot br-test-soci br-test-builder --ignore-not-found
aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT"
```

NodePool を削除すると、そのノードも終了します。残っていないことを確認してください。

```bash
kubectl get nodeclaims
```
