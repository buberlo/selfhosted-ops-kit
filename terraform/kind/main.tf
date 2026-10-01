# Local, free, disposable "customer cluster": kind in Docker, plus the
# namespace baseline a platform team would hand over before an app install.
#
# Ownership split (deliberate): Terraform owns the cluster and namespace
# guardrails; the application release is owned by Helm (scripts/ and
# docs/runbooks/), because day-2 operations (upgrade, rollback, history) are
# Helm's job. See docs/architecture.md.

locals {
  containerd_patches = var.registry_mirror == "" ? [] : [
    <<-TOML
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["${var.registry_mirror}"]
    TOML
  ]
}

resource "kind_cluster" "this" {
  name           = var.cluster_name
  node_image     = var.node_image == "" ? null : var.node_image
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    containerd_config_patches = local.containerd_patches

    node {
      role = "control-plane"
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace
    labels = {
      # Enforce the "restricted" Pod Security Standard: the chart must comply.
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "app.kubernetes.io/part-of"                  = "selfhosted-ops-kit"
    }
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  metadata {
    name      = "app-quota"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    hard = var.namespace_quota
  }
}

# Defaults for containers that forget requests/limits (the quota requires them).
resource "kubernetes_limit_range_v1" "app" {
  metadata {
    name      = "app-defaults"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "256Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "64Mi"
      }
    }
  }
}
