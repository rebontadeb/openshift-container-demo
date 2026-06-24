#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 7 — OpenTelemetry & Observability  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH7="$REPO_ROOT/chapters/07-observability/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── PRE-CHECK ────────────────────────────────────────────────────────────────
say "Verify user-workload monitoring is enabled"
oc get pods -n openshift-user-workload-monitoring 2>/dev/null | grep -c Running || \
  echo "WARNING: enable user-workload monitoring first (Lab 7a Step 1)"

say "Verify OTel operator is installed"
oc get csv -n openshift-operators 2>/dev/null | grep -i opentelemetry || \
  echo "WARNING: install OpenTelemetry operator from OperatorHub"
pause

# ── DEMO 1: Show existing Prometheus metrics ──────────────────────────────────
# TALKING POINTS:
#   "The app already exports Prometheus metrics — we wrote them in Chapter 1.
#    All we need to do is tell Prometheus to scrape them. No code change."

say "Look at what /metrics already exposes"
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')
oc exec "$POD" -- python3 -c "
import urllib.request
r = urllib.request.urlopen('http://localhost:8080/metrics')
for line in r.read().decode().splitlines():
    if line.startswith(('http_requests', 'account_balance', 'transfer')):
        print(line)
" 2>&1 | head -15

say "Apply ServiceMonitors — Prometheus now knows to scrape these services"
oc apply -f "$CH7/servicemonitor-account-service.yaml"
oc apply -f "$CH7/servicemonitor-transaction-service.yaml"
oc get servicemonitor

say "View in Prometheus UI  [switch to browser]"
echo "Administrator → Observe → Metrics"
echo "Query: rate(http_requests_total{namespace=\"financeflow-workshop\"}[2m])"
pause

# ── DEMO 2: Deploy Tempo and the OTel Collector ───────────────────────────────
# TALKING POINTS:
#   "Tempo stores the traces — single binary, in-memory storage, good enough for a demo.
#    The Collector is the broker between our apps and the backends.
#    One YAML file defines the full pipeline: receive → process → export."

say "Deploy Tempo (TempoMonolithic, in-memory, Jaeger-compatible UI)"
oc apply -f "$CH7/tempo.yaml"
oc get pods -l app.kubernetes.io/managed-by=tempo-operator -w &
W=$!; sleep 20; kill $W 2>/dev/null || true

say "Deploy the OTel Collector"
oc apply -f "$CH7/otel-collector.yaml"
oc get pods -l app.kubernetes.io/component=opentelemetry-collector -w &
W=$!; sleep 20; kill $W 2>/dev/null || true

say "Collector creates a Service automatically"
oc get svc | grep collector

say "Show the collector pipeline config"
oc get opentelemetrycollector financeflow -o jsonpath='{.spec.config}' | \
  python3 -c "import sys; print(sys.stdin.read())" | grep -A 5 "service:"
pause

# ── DEMO 3: OTel SDK instrumentation ─────────────────────────────────────────
# TALKING POINTS:
#   "Now the OTel SDK. I'll show you the exact lines added to app.py.
#    FlaskInstrumentor wraps every route. SQLAlchemyInstrumentor wraps every query.
#    Our business logic is untouched."

say "Show the instrumentation additions"
cat "$CH7/otel-instrumentation-snippet.py" | grep -A 30 "ADD TO IMPORTS"
pause

say "ConfigMaps already updated with OTEL_EXPORTER_OTLP_ENDPOINT"
oc get configmap account-service-config -o jsonpath='{.data.OTEL_EXPORTER_OTLP_ENDPOINT}' \
  2>/dev/null || echo "Add OTEL_EXPORTER_OTLP_ENDPOINT=http://financeflow-collector:4317 to ConfigMap"

say "After rebuild and restart — generate a trace"
oc exec deployment/portal -- sh -c \
  "wget -qO- http://transaction-service:8080/api/transactions > /dev/null && echo sent"
pause

# ── DEMO 4: Tempo's Jaeger UI — distributed trace ─────────────────────────────
# TALKING POINTS:
#   "Here's where it gets exciting. One transfer request spans three services
#    and four database calls. Tempo's Jaeger-compatible UI shows it all as a
#    single waterfall — Tempo itself ships no UI, this is its jaegerui feature."

JAEGER_URL="https://$(oc get route tempo-financeflow-jaegerui -o jsonpath='{.spec.host}' 2>/dev/null || \
  echo 'tracing-not-yet-configured')"
echo -e "${G}Trace UI: $JAEGER_URL${R}"

say "Generate a transfer to trace  [then find it in Jaeger]"
PORTAL_URL="https://$(oc get route portal -o jsonpath='{.spec.host}')"
ACCOUNT_IDS=$(curl -sk "$PORTAL_URL/api/accounts" | \
  python3 -c "import sys, json; accts=json.load(sys.stdin); [print(a['id']) for a in accts[:2]]" 2>/dev/null || true)

if [ -n "$ACCOUNT_IDS" ]; then
  FROM=$(echo "$ACCOUNT_IDS" | head -1)
  TO=$(echo "$ACCOUNT_IDS" | tail -1)
  curl -sk -X POST "$PORTAL_URL/api/transactions/transfer" \
    -H "Content-Type: application/json" \
    -d "{\"from_account_id\":\"$FROM\",\"to_account_id\":\"$TO\",\"amount\":50}" \
    | python3 -m json.tool
else
  echo "Use the portal UI to make a transfer, then find it in Jaeger"
fi

say "In Jaeger: Service=transaction-service → Find Traces → click the transfer  [switch to browser]"
echo "Look for spans: transaction-service → account-service → DB queries"
pause

# ── DEMO 5: PrometheusRule alerts ─────────────────────────────────────────────
# TALKING POINTS:
#   "Alerting is also code. PrometheusRule defines PromQL expressions.
#    Let me apply the rules, then trigger one deliberately."

say "Apply alerting rules"
oc apply -f "$CH7/prometheusrule-financeflow.yaml"
oc get prometheusrule

say "View rules in Alerting UI  [switch to browser]"
echo "Administrator → Observe → Alerting → Alerting Rules"
echo "Filter by namespace: financeflow-workshop"
pause

say "Trigger AccountServiceDown — scale to zero replicas"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/replicas","value":0}]'
echo "Waiting 90s for alert to fire (for: 1m)..."
sleep 95
echo "Check: Administrator → Observe → Alerting → Alerts  [switch to browser]"
pause

say "Restore account-service"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/replicas","value":2}]'
oc rollout status deployment/account-service
pause

# ── DEMO 6: Grafana dashboard ─────────────────────────────────────────────────
# TALKING POINTS:
#   "Finally — a business dashboard. Not just infra metrics.
#    Transfer volume in dollars, account balances, success rate."

say "Apply the Grafana dashboard ConfigMap"
oc apply -f "$CH7/grafana-dashboard-configmap.yaml"

GRAFANA_URL="https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}' 2>/dev/null || \
  oc get route grafana -o jsonpath='{.spec.host}' 2>/dev/null || \
  echo 'grafana-not-yet-configured')"
echo -e "${G}Grafana: $GRAFANA_URL${R}"

say "Generate sustained load — panels come alive  [switch to browser]"
oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 120); do
     wget -qO- http://account-service:8080/api/accounts > /dev/null
     wget -qO- http://transaction-service:8080/api/transactions > /dev/null
     sleep 0.5
   done" &
LOAD_PID=$!

echo "Grafana → Dashboards → FinanceFlow — Service Dashboard"
echo "Watch: Request Rate, P99 Latency, Transfer Volume panels populate"
wait $LOAD_PID
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 7 — Workshop complete"
echo ""
oc get servicemonitor
oc get prometheusrule
oc get opentelemetrycollector
echo ""
echo "Three pillars in place:"
echo "  Metrics  → Prometheus + ServiceMonitor + PrometheusRule"
echo "  Traces   → OTel SDK + Collector → Tempo (Jaeger-compatible UI)"
echo "  Dashboards → Grafana"
echo ""
echo -e "${G}FinanceFlow: built → secured → networked → meshed → automated → observable.${R}"
echo -e "${G}Workshop complete.${R}"
