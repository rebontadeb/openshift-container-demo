#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 5 — Service Mesh  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH5="$REPO_ROOT/chapters/05-service-mesh/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── PRE-CHECK ────────────────────────────────────────────────────────────────
say "Verify Istio control plane is ready (OSSM v3 / Sail operator)"
oc get istio -n istio-system
oc get namespace financeflow-workshop --show-labels | grep istio
pause

# ── DEMO 1: Before the mesh — pods talk in plain text ─────────────────────────
# TALKING POINTS:
#   "Before we enable mTLS, all traffic between pods is plain HTTP.
#    I can sit between two pods and read everything.
#    Watch how the mesh changes this — with zero code changes."

say "Current pods — notice 1/1 containers (no sidecar yet)"
oc get pods

say "Restart deployments — Envoy sidecar gets injected into every new pod"
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal
oc rollout status deployment/account-service
oc rollout status deployment/transaction-service

say "Now pods show 2/2 — app + Envoy proxy"
oc get pods
pause

# ── DEMO 2: Kiali — the mesh topology ────────────────────────────────────────
# TALKING POINTS:
#   "Kiali gives us a live service graph. No instrumentation, no code changes —
#    all metrics come from the sidecar. Let me generate some traffic first."

say "Generate traffic to populate the Kiali graph"
oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 60); do wget -qO- http://account-service:8080/api/accounts > /dev/null; done" &
LOAD_PID=$!

KIALI_URL="https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || oc get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || echo 'kiali-route-not-yet-available')"
echo -e "${G}Kiali: $KIALI_URL${R}"
echo "Navigate to Graph → Namespace: financeflow-workshop"
wait $LOAD_PID
pause

# ── DEMO 3: Enforce mTLS ─────────────────────────────────────────────────────
# TALKING POINTS:
#   "Currently mTLS is PERMISSIVE — Envoy accepts both encrypted and plain traffic.
#    Let me switch to STRICT. Any pod without a sidecar gets rejected."

say "Apply STRICT mTLS policy (namespace-wide STRICT + portal PERMISSIVE for HAProxy router)"
# The portal gets a workload-specific PERMISSIVE policy because the OpenShift HAProxy
# router has no Envoy sidecar — it sends plain HTTP to the backend.
# Workload-level policy overrides the namespace-level STRICT for portal ingress only.
oc apply -f "$CH5/peerauthentication-mtls.yaml"

say "Try connecting WITHOUT a sidecar — should be rejected"
oc run mtls-test --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --annotations='sidecar.istio.io/inject=false' \
  --restart=Never \
  --command -- sh -c \
  "curl -sv http://account-service:8080/health/ready 2>&1 | tail -5"

sleep 8
oc logs mtls-test || true
oc delete pod mtls-test --ignore-not-found

say "Kiali: all edges now show a closed padlock — STRICT mTLS  [switch to browser]"
pause

# ── DEMO 4: Canary deployment ─────────────────────────────────────────────────
# TALKING POINTS:
#   "Now the important bit — canary deployments with zero deployment changes.
#    I'll add a version label, deploy one canary pod, then shift traffic with a weight."

say "Label existing pods as version v1.0"
oc patch deployment account-service --type=json -p \
  '[{"op":"add","path":"/spec/template/metadata/labels/version","value":"v1.0"}]'
oc rollout status deployment/account-service

say "Deploy the canary — 1 replica of v1.1 alongside 2 replicas of v1.0"
oc apply -f "$CH5/deployment-account-service-v11.yaml"
oc rollout status deployment/account-service-v11

say "Show we now have 3 account-service pods — 2×v1.0, 1×v1.1"
oc get pods -l tier=account-service --show-labels
pause

say "Apply DestinationRule (defines v1-0 and v1-1 subsets)"
oc apply -f "$CH5/destinationrule-account-service.yaml"

say "Apply VirtualService — 90% to v1.0, 10% to v1.1"
oc apply -f "$CH5/virtualservice-account-service.yaml"

say "Generate load — watch Kiali show the split  [switch to browser]"
oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 150); do wget -qO- http://account-service:8080/api/accounts > /dev/null; sleep 0.2; done" &
LOAD_PID=$!
echo "Kiali graph → click account-service → see 90/10 traffic distribution"
wait $LOAD_PID
pause

say "Shift to 50/50"
oc patch virtualservice account-service --type=json -p \
  '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
    {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'

oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 60); do wget -qO- http://account-service:8080/api/accounts > /dev/null; sleep 0.2; done" &
LOAD_PID=$!
echo "Kiali shows 50/50  [switch to browser]"
wait $LOAD_PID
pause

say "Full cutover to v1.1"
oc patch virtualservice account-service --type=json -p \
  '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":0},
    {"op":"replace","path":"/spec/http/0/route/1/weight","value":100}]'

say "Instant rollback — one file apply, traffic returns to v1.0"
oc apply -f "$CH5/virtualservice-account-service-stable.yaml"
echo "100% back on v1.0 — canary pod still running, traffic fully redirected"
pause

# ── DEMO 5: Circuit breaking ──────────────────────────────────────────────────
# TALKING POINTS:
#   "Last demo — circuit breaking. If a pod keeps failing, the mesh ejects it
#    from the pool automatically. No code changes — just outlier detection config."

say "Apply DestinationRule for transaction-service with outlier detection"
oc apply -f "$CH5/destinationrule-transaction-service.yaml"

say "Break transaction-service readiness — simulate a failing pod"
oc patch deployment transaction-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/broken"}]'

say "Watch: Kiali ejects the unhealthy pod after 3 failures  [switch to browser]"
oc get pods -w -l tier=transaction-service &
W=$!; sleep 40; kill $W 2>/dev/null || true

say "Restore"
oc patch deployment transaction-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/ready"}]'
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 5 complete"
oc get pods
oc get istio -n istio-system
oc get peerauthentication
oc get destinationrule
oc get virtualservice
echo -e "${G}Mesh is live: mTLS enforced, canary routing active. Ready for Chapter 6 — CI/CD.${R}"
