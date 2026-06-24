# Lab 7 — OpenTelemetry & Observability

**Chapter:** 7 | **Duration:** 60 min | **Complexity:** 🔴 Advanced

---

## Objectives

By the end of this lab you will:
- Enable user-workload monitoring so OpenShift's built-in Prometheus scrapes your namespace
- Deploy an OTel Collector and route telemetry to Jaeger and Prometheus
- Instrument FinanceFlow services with the OTel SDK (traces)
- Apply ServiceMonitors and verify metrics appear in the Prometheus UI
- Apply alerting rules and trigger a test alert
- Navigate a distributed trace from portal through transaction-service to the database

---

## Prerequisites

- Chapters 1–4 complete — all pods Running
- Chapter 5 complete — Tempo Operator installed and user-workload monitoring
  enabled (Lab 5a, Step 4)
- Cluster-admin access (for operator install)

---

## Lab 7a — User-Workload Monitoring (already enabled in Chapter 5)

Kiali's traffic graphs need this same Thanos/Prometheus metrics pipeline, so
user-workload monitoring was already enabled back in Chapter 5 (Lab 5a, Step
4) — along with the `view` role grant for the monitoring SA and the
`istio-sidecar-metrics` PodMonitor. There's nothing to do here; verify it's
still in place:

```bash
oc get pods -n openshift-user-workload-monitoring
```

```
NAME                                  READY   STATUS    RESTARTS
prometheus-user-workload-0            6/6     Running   0
prometheus-user-workload-1            6/6     Running   0
thanos-ruler-user-workload-0          4/4     Running   0
```

If you're running Chapter 7 standalone (skipped Chapter 5), go back and run
Lab 5a Step 4 first — the ServiceMonitors applied later in this chapter
(Lab 7d) depend on the same enablement.

---

## Lab 7b — Install OTel Operator and Deploy Collector

### Step 1 — Install the OpenTelemetry Operator

**Administrator → OperatorHub → search "OpenTelemetry"**  
Select **Red Hat build of OpenTelemetry** → Install → keep defaults.

```bash
oc get csv -n openshift-operators | grep opentelemetry
# Red Hat build of OpenTelemetry  ...  Succeeded
```

### Step 2 — Deploy Tempo (trace storage and query)

The Tempo Operator was installed in Chapter 5. Deploy a `TempoMonolithic` instance — a single-binary Tempo good for demos, with in-memory trace storage (no object storage/S3 needed) and a Jaeger-compatible query UI:

```bash
oc apply -f chapters/07-observability/manifests/tempo.yaml
oc get pods -l app.kubernetes.io/instance=financeflow -l app.kubernetes.io/managed-by=tempo-operator
```

Wait for the `tempo-financeflow` pod to reach `Running`, then confirm the Jaeger-compatible UI route:

```bash
oc get route tempo-financeflow-jaegerui
```

### Step 3 — Deploy the OTel Collector

The Collector's `otlp/tempo` exporter (see `otel-collector.yaml`) sends traces to `tempo-financeflow:4317` — deploy Tempo first so the Collector has somewhere to send them:

```bash
oc apply -f chapters/07-observability/manifests/otel-collector.yaml
```

Wait for the collector pod:
```bash
oc get pods -l app.kubernetes.io/component=opentelemetry-collector
```

Inspect the collector's pipeline configuration:
```bash
oc describe opentelemetrycollector financeflow
```

### Step 4 — Verify the collector is reachable

```bash
# Collector should have a Service created automatically
oc get svc | grep financeflow-collector

# Test the OTLP gRPC port from inside the namespace
oc exec deployment/account-service -- sh -c \
  "timeout 3 bash -c 'echo > /dev/tcp/financeflow-collector/4317' && echo REACHABLE || echo UNREACHABLE"
```

---

## Lab 7c — Instrument the Services with OTel SDK

### Step 1 — Update requirements.txt for each service

Add these packages to `app/account-service/requirements.txt` and `app/transaction-service/requirements.txt`:

```
opentelemetry-sdk>=1.20.0
opentelemetry-exporter-otlp-proto-grpc>=1.20.0
opentelemetry-instrumentation-flask>=0.41b0
opentelemetry-instrumentation-sqlalchemy>=0.41b0
opentelemetry-instrumentation-requests>=0.41b0
```

### Step 2 — Add OTel instrumentation to app.py

Open `app/account-service/app.py`. Add the following blocks:

**After existing imports:**
```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
```

**Before `app = Flask(__name__)`:**
```python
SERVICE_NAME_VALUE = os.environ.get("OTEL_SERVICE_NAME", "account-service")
OTEL_ENDPOINT      = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")

if OTEL_ENDPOINT:
    resource = Resource.create({SERVICE_NAME: SERVICE_NAME_VALUE})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(provider)

tracer = trace.get_tracer(SERVICE_NAME_VALUE)
```

**After `app = Flask(__name__)`:**
```python
if OTEL_ENDPOINT:
    FlaskInstrumentor().instrument_app(app)
    SQLAlchemyInstrumentor().instrument()
```

Repeat the same changes for `app/transaction-service/app.py`, and also add:
```python
from opentelemetry.instrumentation.requests import RequestsInstrumentor
# ... and after app = Flask:
if OTEL_ENDPOINT:
    RequestsInstrumentor().instrument()
```

The full snippet with explanations is in:  
`chapters/07-observability/manifests/otel-instrumentation-snippet.py`

### Step 3 — Add OTel environment variables to ConfigMaps

Update `chapters/02-deployments/manifests/configmap-account-service.yaml`:

```yaml
data:
  # ... existing keys ...
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://financeflow-collector:4317"
  OTEL_SERVICE_NAME: "account-service"
  OTEL_PROPAGATORS: "tracecontext,baggage"
```

Update `chapters/02-deployments/manifests/configmap-transaction-service.yaml`:

```yaml
data:
  # ... existing keys ...
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://financeflow-collector:4317"
  OTEL_SERVICE_NAME: "transaction-service"
  OTEL_PROPAGATORS: "tracecontext,baggage"
```

### Step 4 — Rebuild and redeploy

```bash
# Rebuild the images with OTel packages
oc start-build financeflow-account --from-dir=app/account-service/ --follow
oc start-build financeflow-transaction --from-dir=app/transaction-service/ --follow

# Apply the updated ConfigMaps
oc apply -f chapters/02-deployments/manifests/configmap-account-service.yaml
oc apply -f chapters/02-deployments/manifests/configmap-transaction-service.yaml

# Restart to pick up new images and config
oc rollout restart deployment/account-service deployment/transaction-service
oc rollout status deployment/account-service
oc rollout status deployment/transaction-service
```

---

## Lab 7d — Prometheus Metrics

### Step 1 — Apply ServiceMonitors

```bash
oc apply -f chapters/07-observability/manifests/servicemonitor-account-service.yaml
oc apply -f chapters/07-observability/manifests/servicemonitor-transaction-service.yaml
oc apply -f chapters/07-observability/manifests/servicemonitor-otel-collector.yaml
oc get servicemonitor
```

### Step 2 — Verify scraping in the Prometheus UI

**Administrator → Observe → Metrics**

Run these queries in the Prometheus expression browser:

```promql
# Request rate per service
rate(http_requests_total{namespace="financeflow-workshop"}[2m])

# Current account balances
account_balance_dollars

# Transfer success rate
rate(transfer_requests_total{status="success"}[5m])
  /
rate(transfer_requests_total[5m])

# P99 request latency
histogram_quantile(0.99,
  rate(http_request_duration_seconds_bucket{namespace="financeflow-workshop"}[5m])
)
```

### Step 3 — Generate load to populate metrics

```bash
# Run 100 requests in the background
oc exec deployment/portal -- sh -c \
  "for i in \$(seq 1 100); do
     wget -qO- http://account-service:8080/api/accounts > /dev/null
     wget -qO- http://transaction-service:8080/api/transactions > /dev/null
     sleep 0.5
   done" &

echo "Load running — check Prometheus in 60 seconds"
```

---

## Lab 7e — Alerting with PrometheusRule

### Step 1 — Apply the alerting rules

```bash
oc apply -f chapters/07-observability/manifests/prometheusrule-financeflow.yaml
oc get prometheusrule
```

### Step 2 — View rules in the Alerting UI

**Administrator → Observe → Alerting → Alerting Rules**

Filter by namespace `financeflow-workshop`. You should see:
- `AccountServiceDown`
- `TransactionServiceDown`
- `HighTransferErrorRate`
- `HighAPIErrorRate`
- `SlowAccountLookup`
- `SlowTransferProcessing`
- `PodMemoryNearLimit`

All should be in `Inactive` state — good, the system is healthy.

### Step 3 — Trigger a test alert

Make `account-service` temporarily unreachable:

```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/replicas","value":0}]'
```

Wait 90 seconds, then check **Administrator → Observe → Alerting → Alerts**:

```
AccountServiceDown   Firing   critical
```

Restore:
```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/replicas","value":2}]'
oc rollout status deployment/account-service
```

---

## Lab 7f — Distributed Tracing with Tempo

Tempo has no UI of its own — Lab 7b enabled its Jaeger-compatible query UI (`jaegerui.enabled: true` in `tempo.yaml`), so the workflow below looks identical to a native Jaeger UI.

### Step 1 — Get the Tempo Jaeger UI URL

```bash
oc get route tempo-financeflow-jaegerui -o jsonpath='{.spec.host}'
```

### Step 2 — Generate a trace

Make a transfer request through the portal:

```bash
PORTAL_URL="https://$(oc get route portal -o jsonpath='{.spec.host}')"
curl -sk -X POST "$PORTAL_URL/api/transactions/transfer" \
  -H "Content-Type: application/json" \
  -d '{
    "from_account_id": "<account-id>",
    "to_account_id": "<account-id>",
    "amount": 100.00,
    "description": "Lab 7 test transfer"
  }'
```

Substitute real account IDs from:
```bash
curl -sk "$PORTAL_URL/api/accounts" | python3 -m json.tool | grep '"id"'
```

### Step 3 — Find the trace in Jaeger

1. Open the Jaeger UI
2. **Service**: `transaction-service`
3. **Operation**: `POST /api/transactions/transfer`
4. **Lookback**: Last 15 minutes
5. Click **Find Traces**

Click on a trace to see the full waterfall:
```
transaction-service: POST /api/transactions/transfer     [120ms]
  └─ transaction-service: SELECT accounts WHERE id=...    [8ms]
  └─ account-service: PATCH /api/accounts/.../balance    [45ms]
        └─ account-service: UPDATE accounts SET balance   [12ms]
  └─ transaction-service: INSERT INTO transactions        [15ms]
```

Every database call, every inter-service HTTP call, with exact timings.

### Step 4 — Identify the slowest span

In Jaeger, click **Sort: Longest First**. The longest span is the bottleneck.  
Click that span — examine the tags for `db.statement`, `http.url`, and any custom attributes.

---

## Lab 7g — Grafana Dashboard

### Step 0 — Install the Grafana Operator and wire up the datasource

Full commands are in `chapters/apply-order.txt` (Steps 7b/7c) — summary:

```bash
# Operator (cluster-admin)
oc apply -f chapters/07-observability/manifests/grafana/namespace.yaml
oc apply -f chapters/07-observability/manifests/grafana/operatorgroup.yaml
oc apply -f chapters/07-observability/manifests/grafana/subscription.yaml
oc apply -f chapters/07-observability/manifests/grafana/serviceaccount.yaml
oc wait --for=condition=Ready pods -l control-plane=controller-manager -n grafana --timeout=120s

# Bearer token for the Thanos datasource
TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
oc create secret generic grafana-thanos-bearer-token \
  --from-literal=BEARER_TOKEN="Bearer $TOKEN" \
  -n grafana --dry-run=client -o yaml | oc apply -f -

# Grafana instance + datasource
oc apply -f chapters/07-observability/manifests/grafana/grafana.yaml
oc wait --for=condition=GrafanaReady grafana/financeflow-grafana -n grafana --timeout=120s
oc apply -f chapters/07-observability/manifests/grafana/datasource.yaml
oc apply -f chapters/07-observability/manifests/grafana/route.yaml
```

> **Getting the bearer token into the datasource was trickier than it looks.**
> `datasource.yaml` uses `secureJsonData.httpHeaderValue1: "${BEARER_TOKEN}"`
> together with `spec.valuesFrom.secretKeyRef` — the Operator substitutes
> the `${BEARER_TOKEN}` placeholder with the Secret's value at apply time.
> That `${...}` token is load-bearing, not decoration: an earlier version of
> this file had a plain string there instead, which silently never got
> substituted (no error, no log — `valuesFrom` just had no `${...}` pattern
> to act on). A PATCH-via-API workaround "fixed" it temporarily, but wasn't
> durable: the Operator periodically reconciles this CR against the live
> Grafana instance and overwrites any out-of-band change with whatever's
> declared here — so the workaround silently broke again later. Verify it's
> actually working:
> ```bash
> GRAFANA_POD=$(oc get pod -n grafana -l app=financeflow-grafana -o jsonpath='{.items[0].metadata.name}')
> DS_UID=$(oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
>   "http://localhost:3000/api/datasources" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['uid'])")
> oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
>   "http://localhost:3000/api/datasources/uid/$DS_UID/health"
> # expect: {"status":"OK", message: "Successfully queried the Prometheus API"}
> ```

### Step 1 — Apply the dashboard ConfigMap

```bash
oc apply -f chapters/07-observability/manifests/grafana-dashboard-configmap.yaml
```

### Step 2 — Access Grafana

```bash
oc get route grafana -n grafana
```

### Step 3 — Import the dashboard

If the Grafana sidecar discovers the ConfigMap automatically (label `grafana_dashboard: "true"`), the dashboard appears under **Dashboards → FinanceFlow — Service Dashboard**.

If not, import manually:
1. Grafana → **Dashboards → Import**
2. Copy the JSON content from `grafana-dashboard-configmap.yaml` (the value of `financeflow-dashboard.json`)
3. Click **Import**

### Step 4 — Explore the dashboard

With load running, the dashboard shows:
- **Request Rate** — requests/second per service
- **Error Rate** — percentage of 5xx responses
- **P99 Latency** — tail latency with P50 comparison
- **Transfer Volume** — dollars transferred per minute
- **Active Account Balances** — total balance across all accounts
- **Transfer Success Rate** — gauge showing current success percentage

---

## Checkpoint

```bash
# User workload monitoring enabled
oc get pods -n openshift-user-workload-monitoring | grep Running

# Tempo running, Jaeger UI route available
oc get pods -l app.kubernetes.io/managed-by=tempo-operator
oc get route tempo-financeflow-jaegerui

# OTel Collector running
oc get opentelemetrycollector financeflow
oc get pods -l app.kubernetes.io/component=opentelemetry-collector

# ServiceMonitors applied
oc get servicemonitor

# PrometheusRule applied
oc get prometheusrule

# Metrics visible (run in Prometheus UI)
# rate(http_requests_total{namespace="financeflow-workshop"}[2m])
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| No metrics in Prometheus | User-workload monitoring not enabled | Apply the cluster-monitoring-config patch |
| ServiceMonitor exists but no data | SA lacks view permission on namespace | `oc adm policy add-role-to-user view <prometheus-sa> -n financeflow-workshop` |
| OTel Collector pod CrashLoopBackOff | Tempo endpoint unreachable | Check Tempo pod: `oc get pods -l app.kubernetes.io/managed-by=tempo-operator` |
| No traces in Tempo/Jaeger UI | OTEL_EXPORTER_OTLP_ENDPOINT not set or wrong, or Tempo not deployed yet | Verify ConfigMap: `oc get configmap account-service-config -o yaml`; verify `oc get tempomonolithic financeflow` |
| PrometheusRule not firing | Missing `openshift.io/prometheus-rule-evaluation-scope` label | Add the label and re-apply |
| Alert stuck in `Pending` | `for:` duration not elapsed yet | Wait for the configured duration |

---

## Key Takeaways

- `FlaskInstrumentor` and `SQLAlchemyInstrumentor` add traces with **zero changes to business logic** — just setup code
- The OTel Collector decouples the app from the backend — change exporters without touching the app
- `ServiceMonitor` is the Prometheus scrape config as code — no prometheus.yml editing
- `PrometheusRule` + `for: 2m` prevents alert flapping on transient spikes
- A distributed trace shows the full request path with per-hop timing — the fastest path from alert to root cause for a financial SLA breach

---

*Workshop complete. FinanceFlow is built, secured, meshed, automated, and observable.*

*See [WORKSHOP.md](../../../WORKSHOP.md) for the full chapter index and appendices.*
