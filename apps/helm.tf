# ══════════════════════════════════════════════════════════════════════════════
# Helm Releases — Stack de Observabilidade
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# GCE IngressClass — GKE doesn't always auto-create this object.
# Without it, spec.ingressClassName: gce is ignored by the GLBC controller.
# ──────────────────────────────────────────────────────────────────────────────
resource "kubernetes_ingress_class_v1" "gce" {
  metadata {
    name = "gce"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "true"
    }
  }
  spec {
    controller = "k8s.io/ingress-gce"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "69.3.1"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [file("${path.module}/values/values-kube-prometheus-stack.yaml")]
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Loki (SingleBinary + GCS backend)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.29.0"
  namespace  = "monitoring"

  values = [
    templatefile("${path.module}/values/values-loki.yaml", {
      loki_bucket_name = google_storage_bucket.loki.name
      loki_gsa_email   = google_service_account.loki.email
    })
  ]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Grafana Alloy (coleta de logs → Loki)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  namespace  = "monitoring"

  values = [file("${path.module}/values/values-alloy.yaml")]

  depends_on = [helm_release.loki]
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Tempo (tracing backend)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.14.0"
  namespace  = "monitoring"

  values = [file("${path.module}/values/values-tempo.yaml")]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. OpenTelemetry Operator (auto-instrumentação)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  values = [file("${path.module}/values/values-otel-operator.yaml")]

  depends_on = [helm_release.tempo]
}

# Aguarda CRDs do Operator serem registrados antes de criar Instrumentation CRs
resource "time_sleep" "otel_operator_ready" {
  create_duration = "30s"
  depends_on      = [helm_release.otel_operator]
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. otel-platform (Instrumentation CRDs compartilhados)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "otel_platform" {
  name      = "otel-platform"
  chart     = "${path.module}/charts/otel-platform-chart"
  namespace = "default"

  set = [
    {
      name  = "tempoEndpoint"
      value = "http://tempo.monitoring.svc.cluster.local:4318"
    },
    {
      name  = "chartHash"
      value = sha256(join("", [
        for f in sort(fileset("${path.module}/charts/otel-platform-chart", "**")) :
        file("${path.module}/charts/otel-platform-chart/${f}")
      ]))
    }
  ]

  depends_on = [time_sleep.otel_operator_ready]
}

# ──────────────────────────────────────────────────────────────────────────────
# GCE IngressClass — GKE doesn't always auto-create this object.
# The GLBC controller is running but needs the IngressClass to match
# Ingress resources that use spec.ingressClassName: gce
# ──────────────────────────────────────────────────────────────────────────────
resource "kubernetes_ingress_class_v1" "gce" {
  metadata {
    name = "gce"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "true"
    }
  }
  spec {
    controller = "k8s.io/ingress-gce"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. node-ws (app Node.js com auto-instrumentação OTLP)
# ──────────────────────────────────────────────────────────────────────────────
resource "helm_release" "node_ws" {
  name      = "node-ws"
  chart     = "${path.module}/charts/app-chart"
  namespace = "default"

  values = [file("${path.module}/charts/app-chart/values.yaml")]

  set = [
    {
      name  = "chartHash"
      value = sha256(join("", [
        for f in sort(fileset("${path.module}/charts/app-chart", "**")) :
        file("${path.module}/charts/app-chart/${f}")
      ]))
    }
  ]

  depends_on = [helm_release.otel_platform]
}
