output "region" {
  description = "Region both clusters were built in."
  value       = var.region
}

output "karpenter_cluster_name" {
  description = "Cluster carrying arms A, B and C."
  value       = module.eks_karpenter.cluster_name
}

output "automode_cluster_name" {
  description = "Cluster carrying arm D."
  value       = module.eks_automode.cluster_name
}

output "karpenter_node_iam_role_name" {
  description = "Substituted into the EC2NodeClass manifests as KARPENTER_NODE_IAM_ROLE_NAME."
  value       = module.karpenter.node_iam_role_name
}

output "model_bucket" {
  description = "Bucket the phase 2 weights are staged into by snapshot/stage-model.sh."
  value       = aws_s3_bucket.models.bucket
}

output "kubeconfig_commands" {
  description = "Run these to get both contexts locally."
  value = [
    "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_karpenter.cluster_name} --alias ${module.eks_karpenter.cluster_name}",
    "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_automode.cluster_name} --alias ${module.eks_automode.cluster_name}",
  ]
}
