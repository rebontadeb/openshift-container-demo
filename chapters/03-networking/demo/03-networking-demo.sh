#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 3 — Networking & Routing  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH3="$REPO_ROOT/chapters/03-networking/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── DEMO 1: The problem with pod IPs ─────────────────────────────────────────
# TALKING POINTS:
#   "Before we create Services, let me show you what the pod network looks like.
#    Every pod has its own IP — but watch what happens when a pod restarts."

say "Show pod IPs — notice each pod has its own IP"
oc get pods -o wide

say "Pods have IPs — but they change on restart. Watch:"
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')
OLD_IP=$(oc get pod "$POD" -o jsonpath='{.status.podIP}')
echo "Current pod: $POD  IP: $OLD_IP"

say "Delete the pod — Deployment recreates it with a NEW IP"
oc delete pod "$POD"
sleep 8
oc get pods -o wide -l tier=account-service
pause

# ── DEMO 2: Services ─────────────────────────────────────────────────────────
# TALKING POINTS:
#   "Services give us a stable ClusterIP and DNS name.
#    The pod IP changed — the Service IP never does."
#   "These four Services were already created back in Chapter 2, right
#    alongside their Deployments — that's what let those pods reach Ready."

say "Show ClusterIPs — created in Chapter 2"
oc get svc

say "Show Service details — selector connects Service to pods"
oc describe svc account-service | grep -E "Selector|Endpoints|IP:"

say "Show Endpoints — these update dynamically as pods come and go"
oc get endpoints account-service
pause

# ── DEMO 3: DNS ───────────────────────────────────────────────────────────────
# TALKING POINTS:
#   "Every Service gets a DNS name. Short name works within the same namespace.
#    This is how transaction-service finds account-service — no config needed."

say "Exec into portal pod — test DNS resolution"
oc exec -it deployment/portal -- sh -c "
  echo '=== Short DNS name ==='
  wget -qO- http://account-service:8080/health/ready

  echo '=== Full DNS name ==='
  wget -qO- http://account-service.financeflow-workshop.svc.cluster.local:8080/health/ready

  echo '=== nslookup ==='
  nslookup account-service || true
"
pause

# ── DEMO 4: Route ─────────────────────────────────────────────────────────────
# TALKING POINTS:
#   "A Route exposes a Service externally through the HAProxy router.
#    TLS edge termination — the router handles the certificate, the app sees plain HTTP."

say "Create the Route with TLS edge termination"
oc apply -f "$CH3/route-portal.yaml"

say "Show the assigned hostname"
oc get route portal

ROUTE_URL="https://$(oc get route portal -o jsonpath='{.spec.host}')"
echo -e "${G}FinanceFlow is live at: $ROUTE_URL${R}"

say "Verify HTTP → HTTPS redirect"
HTTP_URL="http://$(oc get route portal -o jsonpath='{.spec.host}')"
curl -sI "$HTTP_URL" | grep -E "HTTP|Location"
pause

say "Open in browser  [switch to browser]"
echo "URL: $ROUTE_URL"
pause

# ── DEMO 5: NetworkPolicy — Default Deny ──────────────────────────────────────
# TALKING POINTS:
#   "Right now any pod can reach any other pod.
#    Let me apply a deny-all policy and watch what breaks."

say "Confirm portal can currently reach account-service (no policies yet)"
oc exec deployment/portal -- sh -c \
  "wget -qO- --timeout=5 http://account-service:8080/health/ready && echo OK"

say "Apply deny-all NetworkPolicy"
oc apply -f "$CH3/networkpolicy-deny-all.yaml"

say "Wait 15s for policy to propagate..."
sleep 15

say "Test again — portal can no longer reach account-service"
oc exec deployment/portal -- sh -c \
  "wget -qO- --timeout=5 http://account-service:8080/health/ready || echo BLOCKED"

say "The FinanceFlow UI now shows errors — refresh the browser  [switch to browser]"
pause

# ── DEMO 6: Restore connectivity step by step ────────────────────────────────
# TALKING POINTS:
#   "Watch how we restore only the paths that need to exist.
#    Portal → postgres stays blocked — that's intentional."

say "Allow router → portal (UI loads again)"
oc apply -f "$CH3/networkpolicy-allow-portal.yaml"
sleep 5
echo "Refresh browser — UI loads but accounts/transactions still fail"
pause

say "Allow portal → account-service and transaction-service"
oc apply -f "$CH3/networkpolicy-allow-account-service.yaml"
oc apply -f "$CH3/networkpolicy-allow-transaction-service.yaml"
sleep 5
echo "Refresh browser — accounts load now"
pause

say "Allow services → postgres (transactions now work)"
oc apply -f "$CH3/networkpolicy-allow-postgres.yaml"
oc apply -f "$CH3/networkpolicy-allow-monitoring.yaml"
sleep 5
echo "Refresh browser — full app working"
pause

# ── DEMO 7: Verify the allow matrix ──────────────────────────────────────────
# TALKING POINTS:
#   "Portal can reach account-service but not postgres directly.
#    That's a security boundary — even a compromised portal can't dump the DB."

say "Verify: portal → account-service (ALLOWED)"
oc exec deployment/portal -- wget -qO- http://account-service:8080/health/ready

say "Verify: portal → postgres port 5432 (BLOCKED)"
oc exec deployment/portal -- sh -c \
  "wget -qO- --timeout=5 http://postgres:5432 2>&1 | head -2 || echo BLOCKED — network policy is working"

say "Show all NetworkPolicies"
oc get networkpolicies
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 3 complete"
oc get svc
oc get route
oc get networkpolicies
echo -e "${G}FinanceFlow is externally accessible and zero-trust locked. Ready for Chapter 4 — Security & RBAC.${R}"
