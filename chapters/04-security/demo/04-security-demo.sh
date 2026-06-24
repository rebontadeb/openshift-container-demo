#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 4 — Security & RBAC  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH4="$REPO_ROOT/chapters/04-security/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── DEMO 1: The problem with the default ServiceAccount ──────────────────────
# TALKING POINTS:
#   "Every pod has an identity. Right now all our pods share the same identity —
#    the 'default' service account. A compromised portal pod could call the API
#    with the same token as the database pod."

say "Show that all current pods run as the default SA"
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'
echo ""

say "Create dedicated service accounts"
oc apply -f "$CH4/serviceaccount-financeflow.yaml"
oc apply -f "$CH4/serviceaccount-cicd.yaml"
oc get serviceaccounts
pause

# ── DEMO 2: SCCs ──────────────────────────────────────────────────────────────
# TALKING POINTS:
#   "SCCs are OpenShift's admission gate. Before a pod starts,
#    the SCC controller checks: can this pod do what it's asking to do?
#    Let me show you what happens when it says no."

say "Show the SCC ladder — from most to least restrictive"
oc get scc --no-headers | awk '{print $1, $2, $6}' | column -t

say "Try to run a container as root — watch the SCC block it"
oc run root-test \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --command -- sleep 3600 \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' 2>&1 || true

say "Check which SCC our pods are actually using"
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'
echo ""
pause

say "Create the custom financeflow-scc"
oc apply -f "$CH4/scc-financeflow.yaml"

say "Compare to restricted — note: MustRunAsNonRoot vs MustRunAsRange"
echo "--- financeflow-scc ---"
oc get scc financeflow-scc -o jsonpath='{.runAsUser}'
echo ""
echo "--- restricted ---"
oc get scc restricted -o jsonpath='{.runAsUser}'
echo ""

say "Grant the SCC to financeflow-app service account"
oc apply -f "$CH4/clusterrole-use-financeflow-scc.yaml"
oc apply -f "$CH4/rolebinding-sa-use-scc.yaml"
pause

# ── DEMO 3: Patch deployments to use the app SA ───────────────────────────────
# TALKING POINTS:
#   "Now we wire the SA to our deployments. After this rollout,
#    each pod gets a token scoped to financeflow-app — not the shared default token."

say "Patch all application deployments to use financeflow-app SA"
for deploy in account-service transaction-service portal; do
  oc patch deployment $deploy --type=json -p \
    '[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"financeflow-app"}]'
  echo "Patched: $deploy"
done

say "Watch rollouts — all pods replace with new SA"
oc get pods -w &
W=$!; sleep 25; kill $W 2>/dev/null || true

say "Verify — all pods now use financeflow-app"
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'
pause

# ── DEMO 4: RBAC ──────────────────────────────────────────────────────────────
# TALKING POINTS:
#   "Now let's control what humans and service accounts can do.
#    Two roles: viewer for devs, deployer for CI/CD.
#    Critical: neither role can touch secrets."

say "Create viewer and deployer roles"
oc apply -f "$CH4/role-viewer.yaml"
oc apply -f "$CH4/role-deployer.yaml"

say "Bind them — developers group gets viewer, CI/CD SA gets deployer"
oc apply -f "$CH4/rolebinding-viewer.yaml"
oc apply -f "$CH4/rolebinding-deployer.yaml"

say "Test viewer — can read pods but not secrets"
oc auth can-i get pods \
  --as-group financeflow-developers --as fake-dev -n "$NAMESPACE" || true
echo "Can list pods (yes=0): $?"

oc auth can-i get secrets \
  --as-group financeflow-developers --as fake-dev -n "$NAMESPACE" || true
echo "Can get secrets (no=1): $?"
pause

say "Test deployer (CI/CD SA) — can update deployments but not secrets"
oc auth can-i update deployments \
  --as "system:serviceaccount:${NAMESPACE}:financeflow-cicd" || true
echo "CI/CD can update deployments (yes=0): $?"

oc auth can-i get secrets \
  --as "system:serviceaccount:${NAMESPACE}:financeflow-cicd" || true
echo "CI/CD can get secrets (no=1): $?"

say "Show everything the CI/CD SA is allowed to do"
oc auth can-i --list \
  --as "system:serviceaccount:${NAMESPACE}:financeflow-cicd" \
  -n "$NAMESPACE" | grep -v "^no$" | head -20
pause

# ── DEMO 5: Audit — who can do what ──────────────────────────────────────────
# TALKING POINTS:
#   "Before ending, let me show you the audit tools.
#    'who-can' answers: who in this cluster can perform this action?
#    This is how you check for privilege creep before it becomes a breach."

say "Who can delete pods in this namespace?"
oc policy who-can delete pods -n "$NAMESPACE"

say "Who can get secrets? (should be minimal)"
oc policy who-can get secrets -n "$NAMESPACE"

say "App SA can't call the Kubernetes API"
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')
oc exec "$POD" -- python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
req = urllib.request.Request(
  'https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets',
  headers={'Authorization': 'Bearer ' + token}
)
try:
    r = urllib.request.urlopen(req, context=ctx)
    print('ALLOWED (bad):', r.read(200))
except Exception as e:
    print('BLOCKED:', e)
" 2>&1 || true
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 4 complete"
oc get serviceaccounts
oc get scc financeflow-scc --no-headers
oc get roles
oc get rolebindings
echo -e "${G}FinanceFlow is running with dedicated identities and least-privilege RBAC. Ready for Chapter 5 — Service Mesh.${R}"
