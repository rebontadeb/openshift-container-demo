# Chapter 7
## OpenTelemetry & Observability

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. The three pillars of observability
2. OpenTelemetry — the vendor-neutral standard
3. OTel components: SDK, Collector, backends
4. Instrumenting FinanceFlow with the OTel SDK
5. Prometheus metrics + ServiceMonitor
6. Distributed tracing with Tempo (Jaeger-compatible UI)
7. Alerting with PrometheusRule
8. Grafana dashboards
9. Lab 7 walkthrough

---

## The Three Pillars

```
           METRICS                LOGS                 TRACES
        ┌──────────┐          ┌──────────┐          ┌──────────┐
        │ What is  │          │ What     │          │ Where    │
        │ happening│          │ happened │          │ did time │
        │ right    │          │ in       │          │ go?      │
        │ now?     │          │ detail?  │          │          │
        └──────────┘          └──────────┘          └──────────┘
        Prometheus            OpenShift             Tempo
        Grafana               Logging               (Jaeger-compatible UI)
                              (EFK stack)

All three are needed — metrics alert you, logs explain why, traces show where.
```

---

## OpenTelemetry

A **vendor-neutral, open standard** for instrumentation.

One SDK → many backends:

```
Your App
  │
  │ OTel SDK (traces + metrics)
  ▼
OTel Collector ──────────► Tempo  (traces)
                ──────────► Prometheus (metrics)
                ──────────► Any OTLP-compatible backend
```

No vendor lock-in. Swap the trace backend (e.g. Tempo → another OTLP vendor) by changing the collector config — zero app changes. That's exactly how this workshop moved from Jaeger to Tempo when OpenShift Service Mesh 3 dropped Jaeger.

---

## OTel Components

| Component | What it does | Where it lives |
|-----------|-------------|---------------|
| **SDK** | Generates telemetry inside the app | A few setup lines in `app.py` — this workshop uses manual SDK setup, not the Instrumentation-CR auto-injection approach |
| **Instrumentors** | `FlaskInstrumentor`/`SQLAlchemyInstrumentor` wrap routes and queries automatically once the SDK is set up | Your application code |
| **Collector** | Receives, processes, and exports telemetry | Kubernetes pod (Deployment) |
| **OTLP** | Wire protocol — gRPC (port 4317) or HTTP (port 4318) | Between SDK and Collector |

---

## Instrumenting Flask — Zero Business Logic Change

```python
# New imports
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

# Setup (before app = Flask)
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
if OTEL_ENDPOINT:
    provider = TracerProvider(resource=Resource.create({SERVICE_NAME: "account-service"}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT)))
    trace.set_tracer_provider(provider)

# Instrument (after app = Flask)
if OTEL_ENDPOINT:
    FlaskInstrumentor().instrument_app(app)
    SQLAlchemyInstrumentor().instrument()
```

`FlaskInstrumentor` creates a **span for every HTTP request** automatically.  
`SQLAlchemyInstrumentor` creates a **span for every SQL query** automatically.

---

## Manual Spans for Business Logic

Auto-instrumentation covers HTTP + SQL. Add manual spans for business events:

```python
tracer = trace.get_tracer("account-service")

@app.route("/api/accounts/<id>/balance", methods=["PATCH"])
def update_balance(id):
    with tracer.start_as_current_span("update-balance") as span:
        account = Account.query.get(id)
        span.set_attribute("account.id", id)
        span.set_attribute("account.type", account.account_type)
        span.set_attribute("balance.before", float(account.balance))

        # ... update logic ...

        span.set_attribute("balance.after", float(account.balance))
        span.set_attribute("balance.delta", float(delta))
    return jsonify(account.to_dict())
```

Now a transfer trace shows: Portal → Transaction → Account → SQL — with balance values on every hop.

---

## The OTel Collector

```yaml
receivers:
  otlp:              # receive from app SDKs
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  batch:             # buffer before export
    timeout: 5s
  memory_limiter:    # OOM protection
    limit_mib: 256

exporters:
  otlp/tempo:        # forward traces to Tempo
    endpoint: tempo-financeflow:4317
    tls: { insecure: true }
  prometheus:        # re-expose metrics
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, batch]
      exporters:  [debug, otlp/tempo]
```

The pipeline is **composable** — swapping the trace backend is a one-line exporter change, no app redeploy.

---

## Prometheus — Metrics Collection

FinanceFlow already exports Prometheus metrics at `/metrics`.  
A `ServiceMonitor` tells the cluster Prometheus to scrape them:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: account-service
spec:
  selector:
    matchLabels:
      tier: account-service     # matches the Service label
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

OpenShift's user-workload Prometheus auto-discovers ServiceMonitors in the namespace.  
No Prometheus config files to edit — just apply the CRD.

---

## FinanceFlow Metrics (already in app.py)

```python
# Counters
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"]
)
TRANSFER_COUNT = Counter(
    "transfer_requests_total",
    "Transfer operations",
    ["status"]
)

# Histograms (auto-produces _bucket, _sum, _count)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency",
    ["endpoint"]
)
TRANSFER_AMOUNT = Histogram(
    "transfer_amount_dollars",
    "Transfer amounts in USD",
    buckets=[10, 50, 100, 500, 1000, 5000, 10000]
)

# Gauge
ACCOUNT_BALANCE = Gauge(
    "account_balance_dollars",
    "Current account balance",
    ["account_id", "account_type"]
)
```

---

## PrometheusRule — Alerting

```yaml
groups:
  - name: financeflow.errors
    rules:
      - alert: HighTransferErrorRate
        expr: |
          rate(transfer_requests_total{status="error"}[5m])
          /
          rate(transfer_requests_total[5m]) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Transfer error rate above 5%"
```

**`for: 2m`** — alert must stay true for 2 minutes before firing (prevents flapping).  
Alerts appear in the OpenShift **Alerting** UI and can route to PagerDuty, Slack, or email via Alertmanager.

---

## Distributed Trace — A Transfer Request

```
portal (nginx)
  │ HTTP POST /api/transactions/transfer
  │ Trace-ID: abc123  ← propagated via W3C traceparent header
  ▼
transaction-service                [span: POST /api/transactions/transfer, 120ms]
  │  └─ [span: SELECT account, 8ms]
  │  └─ [span: update-balance (account-service), 45ms]
  │          │
  │          ▼
  │  account-service               [span: PATCH /api/accounts/.../balance, 40ms]
  │          └─ [span: UPDATE accounts SET balance, 12ms]
  │
  └─ [span: INSERT transactions, 15ms]
```

One request = one trace = every hop visible in Tempo's Jaeger-compatible UI.  
Click the slow span → see the SQL query, the account ID, the balance delta.

---

## Kiali + Tempo Integration

From the Kiali service graph:

1. Click any service node → **Traces** tab
2. See all recent traces passing through that service
3. Click a trace → opens Tempo's Jaeger-compatible UI with the full span waterfall
4. Filter by: min duration, HTTP status, service name

For a payment SLA violation — open Kiali, click the slow edge, jump to the trace waterfall — under 60 seconds from alert to root cause.

---

## Lab 7 — Your Turn

1. Enable user-workload monitoring in OpenShift
2. Install OTel Operator → deploy Tempo (`TempoMonolithic`) → deploy the Collector
3. Add OTel SDK to account-service and transaction-service
4. Apply ServiceMonitors — verify in Prometheus
5. Generate load — query metrics in the Prometheus UI
6. Import the Grafana dashboard — explore the panels
7. Apply PrometheusRule — trigger a test alert
8. View an end-to-end trace in Tempo's Jaeger-compatible UI

**Estimated time:** 60 min  
**Lab guide:** `chapters/07-observability/lab/07-observability.md`

---

## Chapter 7 — Summary

| Concept | Key Point |
|---------|-----------|
| OTel SDK | Auto-instruments Flask + SQLAlchemy — no business logic changes |
| OTel Collector | Vendor-neutral pipeline: receive → process → export to any backend |
| `ServiceMonitor` | CRD that tells Prometheus what to scrape — no config files |
| `PrometheusRule` | Alerting rules as code — `for: 2m` prevents flapping |
| Distributed trace | One `Trace-ID` follows a request across all services |
| Kiali → Tempo | Click from service graph directly into trace waterfall (Jaeger-compatible UI) |

**Workshop complete.** FinanceFlow is built, secured, meshed, automated, and observable.
