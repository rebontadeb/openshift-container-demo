#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 0 — Prerequisites  |  TRAINER ONLY
# Cluster must be prepared in advance using lab/00-prerequisites.md.
# This script is the live opening presentation to students.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

# ── DEMO 1: Show the cluster ───────────────────────────────────────────────────
say "Who am I and what cluster am I on?"
oc whoami
oc cluster-info | head -3

say "OpenShift version"
oc get clusterversion version -o jsonpath='{.status.desired.version}' && echo ""

say "Cluster nodes"
oc get nodes -o wide
pause

# ── DEMO 2: Project vs Namespace ──────────────────────────────────────────────
say "OpenShift Projects wrap Kubernetes Namespaces"
oc get projects | head -10 || true
echo "..."

say "Create the workshop project"
  oc new-project financeflow-workshop --display-name="FinanceFlow Workshop" 2>/dev/null || \
  echo "Project already exists"

oc project financeflow-workshop

say "A Project object wraps the Namespace — both exist"
oc get project financeflow-workshop
oc get namespace financeflow-workshop -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
pause

# ── DEMO 3: oc vs kubectl ─────────────────────────────────────────────────────
say "oc and kubectl are interchangeable"
oc get pods || true
kubectl get pods  || true   # same output

say "oc adds OpenShift-specific commands"
oc get routes    || true    # OpenShift only
oc get imagestreams  || true # OpenShift only
oc get scc    || true         # OpenShift only — security context constraints
pause

# ── DEMO 4: Web Console tour ──────────────────────────────────────────────────
CONSOLE_URL=$(oc whoami --show-console)
say "Web Console: $CONSOLE_URL  [switch to browser]"
echo ""
echo "Show students:"
echo "  1. Developer perspective → Topology (empty now, fills as chapters progress)"
echo "  2. Administrator perspective → Operators → Installed Operators"
echo "  3. Administrator perspective → Compute → Nodes"
echo "  4. Help (?) → Command Line Tools (oc download link)"
pause

# ── DEMO 5: Internal registry ─────────────────────────────────────────────────
say "Internal image registry — where all builds land"
oc get route default-route -n openshift-image-registry 2>/dev/null && \
  REGISTRY=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}') && \
  echo "Registry: $REGISTRY" || \
  echo "Registry route not exposed — instructor: oc patch configs.imageregistry..."

say "ImageStreams — the OpenShift image catalog"
oc get imagestream -n openshift | head -8 || true
echo "..."
echo "These are the S2I builder images available in the cluster"
pause

# ── DEMO 6: Pre-flight check ──────────────────────────────────────────────────
say "Run the pre-flight check — this is what students should all see pass"
chmod +x "$REPO_ROOT/chapters/00-prerequisites/demo/cluster-preflight-check.sh"
"$REPO_ROOT/chapters/00-prerequisites/demo/cluster-preflight-check.sh" || true
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 0 complete — cluster is ready"
echo ""
oc project financeflow-workshop
oc get project financeflow-workshop
echo -e "${G}All students should now be logged in and in the financeflow-workshop project. Ready for Chapter 1 — Builds & Images.${R}"
