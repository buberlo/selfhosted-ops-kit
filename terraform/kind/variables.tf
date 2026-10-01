variable "cluster_name" {
  description = "Name of the local kind cluster."
  type        = string
  default     = "ops-kit"
}

variable "node_image" {
  description = "kindest/node image (pin by digest for reproducibility). Empty = provider default."
  type        = string
  default     = ""
}

variable "worker_count" {
  description = "Number of worker nodes. Two workers let the HA profile demonstrate topology spread."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 5
    error_message = "worker_count must be between 0 and 5."
  }
}

variable "registry_mirror" {
  description = <<-EOT
    Optional containerd mirror endpoint for docker.io (for example http://registry.internal:5000).
    Lets the cluster pull without internet access when images are mirrored; see docs/runbooks/offline-install.md.
  EOT
  type        = string
  default     = ""
}

variable "app_namespace" {
  description = "Namespace prepared for the notes release."
  type        = string
  default     = "ops-demo"
}

variable "namespace_quota" {
  description = "ResourceQuota hard limits for the application namespace."
  type        = map(string)
  default = {
    "requests.cpu"           = "2"
    "requests.memory"        = "2Gi"
    "limits.memory"          = "4Gi"
    "persistentvolumeclaims" = "6"
    "requests.storage"       = "20Gi"
    "pods"                   = "30"
  }
}
