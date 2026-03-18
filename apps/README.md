# apps

Camada de aplicações do cluster GKE. Instala todos os workloads Kubernetes no cluster produzido pela camada `infra/`. Tudo é implantado via Helm releases ou recursos nativos do Kubernetes. O stack forma uma plataforma completa de observabilidade (métricas, logs, traces) com auto-instrumentação OTLP via OpenTelemetry Operator.

## 🏗️ Visão Geral da Arquitetura

```
              ┌──────────────────────────────────────────┐
              │                 Grafana                   │  ← interface única para todos os sinais
              └───────────┬──────────────────────────────┘
                          │
           ┌──────────────┼──────────────┐
           ▼              ▼              ▼
      Prometheus         Loki          Tempo
      (métricas)         (logs)       (traces)
           ▲              ▲              ▲
           │           Alloy             │  OTLP HTTP direto
           │        (DaemonSet)          │
           │              │              │
           └──────────────┘           node-ws
                                (OTel Operator SDK)
```

O tráfego da internet chega nas aplicações e no Grafana através do **GKE Ingress Controller** nativo, que provisiona Google Cloud HTTP(S) Load Balancers a partir de recursos `Ingress`.

---

## 🧭 Decisões de Arquitetura

### Por que não usar um OTel Collector?

No projeto irmão [sl-eks](https://github.com/v-63fcav/sl-eks), um **OpenTelemetry Collector** atua como gateway central entre as aplicações e os backends de observabilidade. Lá ele é necessário porque:

1. **Tradução de protocolo** — o sl-eks possui duas aplicações com protocolos diferentes: `fake-service` envia spans via **Zipkin**, enquanto `node-ws` envia via **OTLP**. O Collector aceita ambos e normaliza tudo para OTLP antes de encaminhar ao Tempo.
2. **Fan-out para múltiplos backends** — o Collector recebe os três sinais (traces, métricas, logs) em um único endpoint e distribui para Tempo, Prometheus e Loki respectivamente. As aplicações só precisam conhecer um endereço.
3. **Processamento intermediário** — pipelines de `memory_limiter` e `batch` protegem os backends contra picos de telemetria.

Neste projeto (sl-gke), **nenhuma dessas justificativas se aplica**:

- Usamos **apenas auto-instrumentação OTLP** (sem Zipkin) → não há tradução de protocolo.
- Traces são o único sinal que passa por este caminho (Alloy coleta logs, Prometheus faz scrape de métricas) → não há fan-out.
- O Tempo aceita OTLP nativamente nas portas `:4317` (gRPC) e `:4318` (HTTP) → o SDK injetado pelo Operator fala o mesmo protocolo.

O resultado é um pipeline mais simples: **App → Tempo direto**, sem um Deployment intermediário consumindo memória e adicionando latência.

**Quando reintroduzir o Collector:**
- Se uma nova aplicação usar **Zipkin, Jaeger ou outro protocolo** que o Tempo não aceita nativamente.
- Se for necessário **tail-based sampling** (manter apenas traces lentos ou com erro).
- Se múltiplas aplicações precisarem enviar **traces + métricas + logs** por um único endpoint.
- Se for necessário **enriquecer spans** com atributos extras (ex: informações do cluster, tags de ambiente) antes de armazenar.

---

## 📦 Serviços

### 📈 kube-prometheus-stack

| Parâmetro | Valor |
|---|---|
| Chart | `prometheus-community/kube-prometheus-stack` v69.3.1 |
| Namespace | `monitoring` |
| Values | [values/values-kube-prometheus-stack.yaml](values/values-kube-prometheus-stack.yaml) |

Chart guarda-chuva que instala:

- **Prometheus** — coleta métricas de todos os recursos `ServiceMonitor` e `PodMonitor` no cluster. Retenção: 15 dias / 40 GiB. Storage: 50 GiB standard-rwo.
- **Grafana** — pré-carregado com datasources Loki e Tempo (com correlação trace→log). Exposto via GKE Ingress na porta 80. Credenciais padrão: `admin / changeme`.
- **Alertmanager** — recebe alertas disparados pelo Prometheus. Storage: 10 GiB standard-rwo.
- **Prometheus Operator** — observa CRDs `ServiceMonitor`/`PodMonitor` e configura os targets de scrape do Prometheus dinamicamente.
- **Node Exporter** — DaemonSet; expõe métricas de nível de host (CPU, memória, disco, rede) de cada node.
- **kube-state-metrics** — expõe métricas de estado de objetos Kubernetes (reinicializações de pod, réplicas de deployment, etc.).

**Como usar:**
1. Obtenha o IP do Load Balancer do Grafana: `kubectl get ingress -n monitoring`
2. Abra no navegador e faça login com `admin / changeme`.
3. Para adicionar um target de scrape para seu próprio serviço, crie um `ServiceMonitor` em qualquer namespace — o Prometheus os descobre em todo lugar (`serviceMonitorSelectorNilUsesHelmValues: false`).

---

### 📋 Loki

| Parâmetro | Valor |
|---|---|
| Chart | `grafana/loki` v6.29.0 |
| Namespace | `monitoring` |
| Values | [values/values-loki.yaml](values/values-loki.yaml) |
| Storage | GCS bucket `sl-gke-loki-chunks-cavi` |

Backend de agregação de logs. Implantado no modo **SingleBinary** (todos os componentes em um pod). Schema: TSDB v13. O armazenamento de chunks é feito em **GCS** via Workload Identity — a KSA `loki` no namespace `monitoring` é vinculada à GSA `sl-gke-loki-sa`.

O Loki é um backend passivo — ele apenas armazena logs que são enviados para ele. A coleta de logs é feita pelo **Grafana Alloy**.

**Como usar:**
1. Abra Grafana → Explore → selecione o datasource **Loki**.
2. Filtre por namespace: `{namespace="default"}`
3. Filtre por pod: `{pod=~"node-ws.*"}`
4. Combine com busca por texto: `{namespace="monitoring"} |= "error"`

---

### 🔍 Grafana Alloy

| Parâmetro | Valor |
|---|---|
| Chart | `grafana/alloy` |
| Namespace | `monitoring` |
| Values | [values/values-alloy.yaml](values/values-alloy.yaml) |

DaemonSet que roda em cada node e coleta logs de contêiner de `/var/log/pods/`. Substitui o Promtail com uma configuração em **River** (linguagem nativa do Alloy). Anexa automaticamente labels Kubernetes (`namespace`, `pod`, `container`, `node`) como labels de stream do Loki.

Logs são enviados para: `http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push` (gateway nginx do Loki chart v6.x, porta 80).

> **Nota — `local.file_match` é obrigatório no Alloy:**
> Diferente do Promtail, o componente `loki.source.file` do Alloy **não expande globs** — ele tenta abrir o `__path__` literalmente. Para coletar logs de pods, o pipeline River precisa de três estágios:
> 1. `discovery.relabel` — constrói o `__path__` com glob (ex: `.../<container>/*.log`)
> 2. `local.file_match` — expande o glob em arquivos reais (`0.log`, `1.log`, etc.)
> 3. `loki.source.file` — faz tail dos arquivos concretos

**Como usar:** nenhuma configuração necessária por aplicação — todo stdout/stderr de todos os namespaces é coletado automaticamente assim que o Alloy está rodando.

---

### ⏱️ Tempo

| Parâmetro | Valor |
|---|---|
| Chart | `grafana/tempo` v1.14.0 |
| Namespace | `monitoring` |
| Values | [values/values-tempo.yaml](values/values-tempo.yaml) |

Backend de tracing distribuído. Recebe traces via **OTLP gRPC (:4317)** e **OTLP HTTP (:4318)**. Retenção: 24 horas. Storage: 20 GiB standard-rwo.

As aplicações enviam traces **diretamente** para o Tempo via OTLP HTTP (:4318) — sem necessidade de um OTel Collector intermediário. Como usamos apenas auto-instrumentação OTLP (sem Zipkin), o SDK fala nativamente o mesmo protocolo que o Tempo aceita.

O datasource Tempo no Grafana é pré-configurado com **correlação trace→log**: clicar em um span pula automaticamente para os logs Loki correspondentes daquele pod e janela de tempo.

**Como usar:**
1. Abra Grafana → Explore → selecione o datasource **Tempo**.
2. Busque por nome de serviço, trace ID ou use a aba **Search** para filtrar por duração, status ou tags.
3. Clique em qualquer span para inspecionar atributos e saltar para os logs Loki correlacionados.

---

### 🤖 OpenTelemetry Operator

| Parâmetro | Valor |
|---|---|
| Chart | `open-telemetry/opentelemetry-operator` |
| Namespace | `opentelemetry-operator-system` |
| Values | [values/values-otel-operator.yaml](values/values-otel-operator.yaml) |

Operator Kubernetes que habilita **auto-instrumentação zero-code** via webhook de admissão mutante. Quando um pod é criado com uma anotação de injeção, o operator faz o patch na spec para adicionar um init container que baixa o OTel SDK específico da linguagem e define `NODE_OPTIONS` para que o SDK carregue automaticamente em runtime.

Linguagens suportadas: Node.js, Java, Python, Go, .NET.

Não requer cert-manager — o operator gera seu próprio certificado de webhook autoassinado via `autoGenerateCert`.

**Como instrumentar uma aplicação:**
1. Garanta que um `Instrumentation` CR correspondente exista no mesmo namespace (veja otel-platform abaixo).
2. Adicione a anotação no pod:
   ```yaml
   instrumentation.opentelemetry.io/inject-nodejs: "nodejs"
   ```
3. Defina `OTEL_SERVICE_NAME` como variável de ambiente no pod — isso é específico da aplicação e não faz parte do CR compartilhado.

---

### 🧩 otel-platform

| Parâmetro | Valor |
|---|---|
| Chart | local `./charts/otel-platform-chart` |
| Namespace | `default` |
| Values | [charts/otel-platform-chart/values.yaml](charts/otel-platform-chart/values.yaml) |

Implanta `Instrumentation` CRs compartilhados por todas as aplicações no namespace `default`. Desacoplado dos charts individuais das aplicações para que adicionar uma nova app não exija mudanças na camada de plataforma.

| Nome do CR | Linguagem | Referenciado por |
|---|---|---|
| `nodejs` | Node.js | anotação `inject-nodejs: "nodejs"` |

`OTEL_SERVICE_NAME` **não** é definido no CR — cada aplicação o define como variável de ambiente no pod, dando a cada serviço um nome distinto no Tempo sem precisar de um CR separado por app.

---

### 🖥️ node-ws

| Parâmetro | Valor |
|---|---|
| Chart | local `./charts/app-chart` |
| Namespace | `default` |
| Values | [charts/app-chart/values.yaml](charts/app-chart/values.yaml) |

Servidor web Node.js mínimo (`node:20-alpine`) auto-instrumentado pelo OTel Operator. Exposto via GKE Ingress.

- 1 réplica, HTTP na porta 3000
- Resource requests: 100m CPU / 128Mi memória; limits: 500m CPU / 256Mi memória
- Traces visíveis em Grafana → Tempo → `service.name = node-ws`

O `app-chart` é agnóstico à aplicação — o nome da app, nome do serviço e imagem são todos configurados via `values.yaml`. Para implantar uma segunda app Node.js, copie o bloco `helm_release` em [helm.tf](helm.tf) e sobrescreva `nameOverride` e `otel.serviceName`.

---

## 🔗 Recursos GCP

| Recurso | Arquivo | Finalidade |
|---|---|---|
| `google_storage_bucket.loki` | [gcs.tf](gcs.tf) | Bucket GCS para chunks do Loki (lifecycle: 30 dias) |
| `google_service_account.loki` | [workload-identity.tf](workload-identity.tf) | GSA com `storage.objectAdmin` no bucket |
| Workload Identity binding | [workload-identity.tf](workload-identity.tf) | Vincula GSA ↔ KSA `loki` no namespace `monitoring` |

---

## 🚦 Deploy

```bash
# 1. Infraestrutura — VPC + GKE
cd infra && terraform apply

# 2. Aplicações — Helm releases + GCS + Workload Identity
cd ../apps
terraform init
terraform apply
```

Após o `terraform apply`:
1. `kubectl get ingress -n default` — obtenha o IP do Load Balancer do node-ws
2. `kubectl get ingress -n monitoring` — obtenha o IP do Load Balancer do Grafana
3. Faça login no Grafana (`admin / changeme`) e verifique se os três datasources (Prometheus, Loki, Tempo) estão verdes
4. Verifique os targets do Prometheus: Grafana → Explore → Prometheus → `up` — todos os targets devem ser `1`
5. Envie requisições para o Load Balancer do node-ws para gerar traces, depois pesquise em Grafana → Explore → Tempo

---

## 📊 Auto-Instrumentação OTLP

Este cluster usa o **OTel Operator** para instrumentação zero-code. O fluxo completo:

```
Usuário / curl
    │  HTTP :80 (GKE LB)
    ▼
┌─────────────────────────────────────────────────────┐
│  node-ws  (node:20-alpine)                          │
│  namespace: default                                 │
│                                                     │
│  anotação:                                          │
│    instrumentation.opentelemetry.io/inject-nodejs:  │
│    "nodejs"   ← referencia o CR compartilhado       │
│                                                     │
│  env: OTEL_SERVICE_NAME=node-ws  ← definido por app │
│                                                     │
│  Na inicialização do pod, o webhook do Operator:    │
│    1. Vê a anotação no pod                          │
│    2. Lê o Instrumentation CR "nodejs"              │
│       (implantado pelo otel-platform-chart)         │
│    3. Injeta um init container que baixa            │
│       o OTel SDK do Node.js                         │
│    4. Add NODE_OPTIONS=--require @opentelemetry/..  │
│       para que o SDK instrumente http, dns, etc.    │
│                                                     │
│  Em runtime, o SDK:                                 │
│    1. Intercepta toda requisição http.createServer  │
│    2. Cria um span com method, url, status          │
│    3. Exporta via OTLP HTTP direto para o Tempo     │
└────────────────────────┬────────────────────────────┘
                         │  OTLP/HTTP :4318
                         ▼
                       Tempo
```

### 🚦 Ordem de deploy (Terraform)

```
kube_prometheus_stack
    ├→ loki → alloy
    └→ tempo
        └→ otel_operator
            └→ time_sleep (30s — aguarda registro do CRD + webhook)
                └→ otel_platform  ← cria Instrumentation CR "nodejs"
                    └→ node_ws    ← pods agendados, webhook dispara, SDK injetado ✓
```

---

## 🔌 Referência de Portas

| Serviço | Porta | Protocolo | Finalidade |
|---|---|---|---|
| Tempo | 4317 | gRPC (OTLP) | Receber spans via OTLP gRPC |
| Tempo | 4318 | HTTP (OTLP) | Receber spans das apps auto-instrumentadas |
| Tempo | 3100 | HTTP | API de consulta usada pelo Grafana |
| Prometheus | 9090 | HTTP | Receber métricas via remote write |
| Loki (gateway) | 80 | HTTP | Ponto de entrada para push/query (nginx → singleBinary) |
| Loki (singleBinary) | 3100 | HTTP | API interna (acessada via gateway) |
| node-ws | 3000 | HTTP | Endpoint da aplicação |
| GKE LB (node-ws) | 80 | HTTP | Ponto de entrada público para o node-ws |

---

## ✅ Como Testar

### 🖥️ node-ws

```bash
# Obter o IP do Load Balancer
kubectl get ingress node-ws -n default \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Gerar traces
LB_IP=<ip-acima>
for i in $(seq 1 20); do curl -s http://$LB_IP/ > /dev/null; done

# Ver no Grafana: Explore → Tempo → Service Name: node-ws
```

### ✅ Verificar se a injeção funcionou

```bash
# Init container deve estar presente
kubectl describe pod -n default -l app.kubernetes.io/name=node-ws \
  | grep -A5 'Init Containers'

# Variável de ambiente do SDK deve estar definida
kubectl exec -n default deploy/node-ws -- env | grep NODE_OPTIONS

# CR compartilhado deve existir no namespace
kubectl get instrumentation -n default
```

### 💚 Verificar se o pipeline está saudável

```bash
# Tempo ingeriu os spans
kubectl logs -n monitoring -l app.kubernetes.io/name=tempo --tail=20

# Operator está rodando e webhook está registrado
kubectl get pods -n opentelemetry-operator-system
kubectl get mutatingwebhookconfiguration | grep opentelemetry

# Alloy está coletando logs
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20
```
