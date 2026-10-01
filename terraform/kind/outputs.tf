output "cluster_name" {
  description = "kind cluster name (use with `kind load docker-image --name`)."
  value       = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "Path of the kubeconfig written by kind."
  value       = kind_cluster.this.kubeconfig_path
}

output "kube_context" {
  description = "kubectl context of the cluster."
  value       = "kind-${kind_cluster.this.name}"
}

output "app_namespace" {
  description = "Namespace prepared for the notes release."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}
