#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# FinanceFlow Workshop — Cluster Pre-flight Check  |  TRAINER ONLY
# Run this 24 h before and again 1 h before the workshop.
# Zero FAIL items required before students arrive.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; R_='\033[0;31m'; B='\033[0;34m'; R='\033[0m'
PASS=0; FAIL=0; WARN=0

ok()   { echo -e "${G}  ✔ $*${R}";  ((++PASS)); }
fail() { echo -e "${R_}  ✗ $*${R}"; ((++FAIL)); }
warn() { echo -e "${Y}  ⚠ $*${R}";  ((++WARN)); }
hdr()  { echo -e "\n${B}── $* ──${R}"; }

# ── 1. CLI tools ──────────────────────────────────────────────────────────────
hdr "Local tools"
if command -v oc &>/dev/null; then
  OC_VER=$(oc version --client 2>/dev/null | awk 'NR==1{print $NF}')
  ok "oc CLI found: ${OC_VER}"
else
  fail "oc CLI not found — install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
fi
command -v git   &>/dev/null && ok "git found: $(git --version)"                         || fail "git not found"
command -v podman &>/dev/null && ok "podman found: $(podman --version)"                   || warn "podman not found — needed for local testing only"
command -v python3 &>/dev/null && ok "python3 found: $(python3 --version)"                || warn "python3 not found — some verification steps need it"

# ── 2. Cluster connectivity ───────────────────────────────────────────────────
hdr "Cluster access"
oc whoami &>/dev/null && ok "Logged in as: $(oc whoami)" || fail "Not logged in — run: oc login <cluster-api-url>"

OCP_VERSION=$(oc version -o json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("openshiftVersion","unknown"))' 2>/dev/null || echo "unknown")
[[ "$OCP_VERSION" == unknown ]] && warn "Could not determine OCP version" || \
  { MINOR=$(echo "$OCP_VERSION" | cut -d. -f2); [[ $MINOR -ge 18 ]] && ok "OCP version: $OCP_VERSION (≥ 4.18 required)" || fail "OCP version $OCP_VERSION is below the required 4.18"; }

# ── 3. Cluster admin check ────────────────────────────────────────────────────
hdr "Permissions"
oc auth can-i create projects --all-namespaces &>/dev/null && \
  ok "cluster-admin or sufficient permissions" || \
  warn "Limited permissions — SCCs and operator installs require cluster-admin"

# ── 4. Workshop namespace ─────────────────────────────────────────────────────
hdr "Namespace"
if oc get project financeflow-workshop &>/dev/null; then
  ok "Project 'financeflow-workshop' exists"
else
  warn "Project 'financeflow-workshop' does not exist — create with: oc new-project financeflow-workshop"
fi

# ── 5. Required operators ─────────────────────────────────────────────────────
hdr "Operators"
check_operator() {
  local name="$1" label="$2"
  oc get csv -A --no-headers 2>/dev/null | grep -qi "$label" && ok "$name operator installed" || warn "$name operator NOT found — install from OperatorHub before the relevant chapter"
}
check_operator "OpenShift Pipelines"      "openshift-pipelines"
check_operator "OpenShift GitOps"         "openshift-gitops"
check_operator "OpenShift Service Mesh"   "servicemesh"
check_operator "Tempo (distributed tracing)" "tempo"
check_operator "Kiali"                    "kiali"
check_operator "OpenTelemetry"            "opentelemetry"

# ── 6. Cluster capacity ───────────────────────────────────────────────────────
hdr "Cluster capacity"
NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)
[[ $NODES -ge 1 ]] && ok "Cluster has $NODES nodes" || warn "Only $NODES node(s) — workshop recommends ≥ 3 worker nodes"

NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l || true)
[[ $NOT_READY -eq 0 ]] && ok "All nodes Ready" || fail "$NOT_READY node(s) not Ready"

# ── 7. Storage ────────────────────────────────────────────────────────────────
hdr "Storage"
DEFAULT_SC=$(oc get storageclass --no-headers 2>/dev/null | grep "(default)" | awk '{print $1}')
[[ -n "$DEFAULT_SC" ]] && ok "Default StorageClass: $DEFAULT_SC" || fail "No default StorageClass — PVCs will fail without one"

# ── 8. Internal registry ──────────────────────────────────────────────────────
hdr "Internal registry"
oc get route default-route -n openshift-image-registry &>/dev/null && \
  ok "Internal registry route exposed" || \
  warn "Internal registry route not exposed — expose with: oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{\"spec\":{\"defaultRoute\":true}}'"

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo -e "  ${G}PASS: $PASS${R}  ${Y}WARN: $WARN${R}  ${R_}FAIL: $FAIL${R}"
echo "────────────────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
  echo -e "${R_}  Fix failing checks before starting the workshop.${R}"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo -e "${Y}  Warnings indicate missing optional components. Check before the relevant chapter.${R}"
else
  echo -e "${G}  All checks passed — cluster is workshop-ready.${R}"
fi
