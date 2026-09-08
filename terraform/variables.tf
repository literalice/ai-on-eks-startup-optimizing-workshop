variable "region" {
  description = "Region to build the workshop environment in. Must have quota for the GPU family in var.gpu_instance_types."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Prefix for both clusters and the shared VPC."
  type        = string
  default     = "br-startup"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version for both clusters.

    Keep this at 1.34 or above. The EKS-optimized Bottlerocket NVIDIA AMI ships
    NVIDIA driver 580 only for Kubernetes 1.34+, and driver 580 is required for
    CUDA 13 images -- which the default vLLM Deep Learning Container in
    manifests/ is built against (cu130).
  EOT
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR for the shared VPC. Both clusters live here so that every variant pulls over an identical network path."
  type        = string
  default     = "10.0.0.0/16"
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version for the self-managed cluster."
  type        = string
  default     = "1.14.1"
}

variable "tags" {
  description = "Tags applied to everything. Keep the Purpose tag -- teardown greps for it."
  type        = map(string)
  default = {
    Purpose = "bottlerocket-startup-workshop"
  }
}
