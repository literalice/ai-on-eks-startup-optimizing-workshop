################################################################################
# Bottlerocket startup-time workshop -- environment
#
# One shared VPC, two clusters:
#
#   <prefix>-karpenter  self-managed Karpenter. Carries the baseline,
#                       B (EBS snapshot data volume) and C (local NVMe + SOCI).
#                       Each variant is an EC2NodeClass, so all three differ only in
#                       the image mechanism.
#
#   <prefix>-automode   EKS Auto Mode. Carries automode. Auto Mode configures NVMe
#                       and parallel image pull on GPU instances without being
#                       configured to.
#
# Two clusters rather than one because self-managed Karpenter and Auto Mode both
# own the karpenter.sh CRDs. They share the VPC and subnets, so the image pull path
# is the same in both and the figures remain comparable.
################################################################################

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = module.eks_karpenter.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_karpenter.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_karpenter.cluster_name, "--region", var.region]
    }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

locals {
  karpenter_cluster_name = "${var.name_prefix}-karpenter"
  automode_cluster_name  = "${var.name_prefix}-automode"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

################################################################################
# Shared VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name_prefix
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Self-managed Karpenter discovers subnets by this tag
    "karpenter.sh/discovery" = local.karpenter_cluster_name
  }

  tags = var.tags
}

################################################################################
# Cluster 1 -- self-managed Karpenter (baseline, snapshot, soci)
################################################################################

module "eks_karpenter" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = local.karpenter_cluster_name
  kubernetes_version = var.kubernetes_version

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Small on-demand group for CoreDNS and the Karpenter controller only. No
  # workload lands here -- every variant is taint-free but pinned by nodeSelector.
  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m6i.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = merge(var.tags, {
    "karpenter.sh/discovery" = local.karpenter_cluster_name
  })

  tags = var.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = module.eks_karpenter.cluster_name

  # The EC2NodeClass manifests reference this role by name, so pin it.
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.karpenter_cluster_name
  create_pod_identity_association = true

  # The generated controller policy is larger than the 6144-character quota for a
  # standard managed IAM policy, so apply fails with
  # `LimitExceeded: Cannot exceed quota for PolicySize: 6144`.
  # An inline role policy allows 10240, which it fits inside.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    # SSM is how you get a shell-free look inside a Bottlerocket node
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    # Phase 2 reads model weights from S3. Node role for workshop expedience --
    # in production this belongs on a service account via EKS Pod Identity.
    ModelWeightsRead = aws_iam_policy.model_weights_read.arn
  }

  tags = var.tags
}

################################################################################
# Model weights bucket (phase 2 / section 4)
################################################################################

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "models" {
  bucket        = "${var.name_prefix}-models-${random_id.suffix.hex}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket = aws_s3_bucket.models.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

################################################################################
# Pod Identity for the phase 2 workload
#
# The pods need to read the weights bucket. They cannot use the node role: Karpenter
# defaults the IMDS hop limit to 1, so a container cannot reach instance metadata at
# all, and `aws s3 cp` fails with "Unable to locate credentials". That default is
# correct and worth keeping -- pods should not silently inherit node permissions.
#
# So credentials come from EKS Pod Identity, scoped to one service account in one
# namespace. This is also what the workshop recommends for production, which means
# the demo now shows the recommended pattern rather than a shortcut with a caveat
# attached.
################################################################################

resource "aws_iam_role" "bench_pods" {
  name = "${var.name_prefix}-bench-pods"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "bench_pods_models" {
  role       = aws_iam_role.bench_pods.name
  policy_arn = aws_iam_policy.model_weights_read.arn
}

resource "aws_eks_pod_identity_association" "bench" {
  cluster_name    = module.eks_karpenter.cluster_name
  namespace       = "bench"
  service_account = "bench"
  role_arn        = aws_iam_role.bench_pods.arn

  tags = var.tags
}

resource "aws_iam_policy" "model_weights_read" {
  name        = "${var.name_prefix}-model-weights-read"
  description = "Read-only access to the workshop model weights bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.models.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.models.arn]
      },
    ]
  })

  tags = var.tags
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"

  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  chart   = "karpenter"
  version = var.karpenter_chart_version
  wait    = false

  values = [yamlencode({
    nodeSelector = {
      "karpenter.sh/controller" = "true"
    }
    dnsPolicy = "Default"
    settings = {
      clusterName       = module.eks_karpenter.cluster_name
      clusterEndpoint   = module.eks_karpenter.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    webhook = {
      enabled = false
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
  })]
}

################################################################################
# Cluster 2 -- EKS Auto Mode (automode)
#
# node_pools includes "system" so CoreDNS has somewhere to land. The GPU variant
# uses a custom NodeClass applied from manifests/, which needs the node IAM role
# of the built-in "default" NodeClass -- bin/prep.sh reads it off the cluster
# rather than plumbing it through Terraform.
################################################################################

module "eks_automode" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = local.automode_cluster_name
  kubernetes_version = var.kubernetes_version

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true

  compute_config = {
    enabled    = true
    node_pools = ["system"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}
