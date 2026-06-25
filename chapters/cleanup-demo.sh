#!/usr/bin/env bash
# FinanceFlow Workshop — Cleanup
#
# Reverses deploy-demo.sh: removes the app, mesh, CI/CD, and observability
# resources, plus the namespaces they live in (financeflow-workshop, grafana,
# istio-system, istio-cni) and the handful of cluster-scoped leftovers
# (SCC, ClusterRole, ClusterRoleBindings) that namespace deletion alone
# wouldn't catch.
#
# Does NOT uninstall the 6 cluster-wide operators from prepare-cluster.sh by
# default — they're slow to reinstall and other namespaces/workshops may
# still depend on them. Pass --with-operators to remove those too.
#
# Usage:
#   ./cleanup-demo.sh                       # pauses before every step
#   ./cleanup-demo.sh -y                    # no pauses, run straight through
#   ./cleanup-demo.sh -y --with-operators   # also uninstall the operators
#
set -uo pipefail   # no -e: deleting things that are already gone shouldn't abort the script

NAMESPACE="${NAMESPACE:-financeflow-workshop}"

PAUSE=true
WITH_OPERATORS=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--no-pause) PAUSE=false ;;
    --with-operators) WITH_OPERATORS=true ;;
  esac
done

STEP_NUM=0
step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo
  echo "════════════════════════════════════════════════════════════════════"
  printf "STEP %02d: %s\n" "$STEP_NUM" "$1"
  echo "════════════════════════════════════════════════════════════════════"
  if [ "$PAUSE" = true ]; then
    read -rp ">>> Press Enter to run this step (Ctrl+C to abort)... "
  fi
}

ok() { echo "    ✓ $1"; }

# Delete a namespace and actually wait for it to disappear. If it's still
# Terminating after a grace period, the cause is almost always a CR that's
# still carrying an operator's finalizer (e.g. operator.grafana.com/finalizer)
# after that operator's own pod/CSV has already been removed as part of the
# same teardown — nothing is left to process the finalizer, so the namespace
# would otherwise hang forever. Scan for and clear any such finalizers, then
# give it one more grace period before giving up.
force_delete_namespace() {
  local ns="$1"
  oc delete namespace "$ns" --ignore-not-found
  for i in $(seq 1 12); do
    oc get namespace "$ns" >/dev/null 2>&1 || { ok "$ns namespace gone"; return 0; }
    echo "    ... $ns still terminating"
    sleep 10
  done

  echo "    $ns still terminating after 120s — checking for stuck finalizers"
  local cleared=false
  for gvk in $(oc api-resources --verbs=list --namespaced -o name 2>/dev/null); do
    for name in $(oc get "$gvk" -n "$ns" -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      echo "    clearing finalizers on $gvk/$name in $ns"
      oc patch "$gvk" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null && cleared=true
    done
  done
  [ "$cleared" = false ] && echo "    no resources with finalizers found — namespace may just need more time"

  for i in $(seq 1 12); do
    oc get namespace "$ns" >/dev/null 2>&1 || { ok "$ns namespace gone"; return 0; }
    sleep 10
  done
  echo "    ⚠ $ns namespace still present — inspect manually: oc get namespace $ns -o yaml"
}

# ── Destructive-action gate (separate from the per-step pause) ─────────────
echo "════════════════════════════════════════════════════════════════════"
echo " This will DELETE the FinanceFlow workshop deployment:"
echo "   - Namespace: $NAMESPACE (app, builds, pipelines, networking, security, mesh resources)"
echo "   - Namespace: grafana"
echo "   - Namespace: istio-system, istio-cni"
echo "   - Cluster-scoped: financeflow-scc, use-financeflow-scc, and related ClusterRoleBindings"
echo "   - ArgoCD AppProject/Application (in openshift-gitops)"
if [ "$WITH_OPERATORS" = true ]; then
  echo "   - The 6 operators installed by prepare-cluster.sh (--with-operators was passed)"
fi
echo "════════════════════════════════════════════════════════════════════"
read -rp "Type DELETE to confirm: " CONFIRM
[ "$CONFIRM" = "DELETE" ] || { echo "Aborted — input did not match DELETE."; exit 1; }

# ──────────────────────────────────────────────────────────────────────────
# ArgoCD first — its selfHeal would otherwise fight every other deletion
# below by recreating resources out from under you.
# ──────────────────────────────────────────────────────────────────────────

step "Delete the ArgoCD Application and AppProject (openshift-gitops)"
oc delete application financeflow -n openshift-gitops --ignore-not-found
oc delete appproject financeflow -n openshift-gitops --ignore-not-found

# ──────────────────────────────────────────────────────────────────────────
# Service mesh control plane — deleted before its namespaces, so the
# operator's own finalizers get a chance to clean up gracefully instead of
# the namespace deletion hanging on them.
# ──────────────────────────────────────────────────────────────────────────

step "Delete the Kiali instance and its cluster-monitoring-view binding"
oc delete kiali kiali -n istio-system --ignore-not-found
oc delete clusterrolebinding kiali-cluster-monitoring-view --ignore-not-found

step "Delete the Istio control plane (Sail Operator)"
oc delete istio default -n istio-system --ignore-not-found
oc delete istiocni default -n istio-cni --ignore-not-found

step "Wait for Istio/IstioCNI to fully terminate before removing their namespaces"
for i in $(seq 1 20); do
  remaining=$(oc get istio -n istio-system --no-headers 2>/dev/null | wc -l)
  [ "$remaining" -eq 0 ] && { ok "Istio control plane gone"; break; }
  echo "    ... still terminating"
  sleep 10
done

step "Delete the istio-system and istio-cni namespaces"
force_delete_namespace istio-system
force_delete_namespace istio-cni

# ──────────────────────────────────────────────────────────────────────────
# Observability
# ──────────────────────────────────────────────────────────────────────────

step "Delete the grafana namespace (Grafana instance, datasource, dashboards, operator subscription)"
force_delete_namespace grafana

# ──────────────────────────────────────────────────────────────────────────
# The main app namespace — cascades through almost everything else:
# Deployments, Services, ConfigMaps, Secrets, PVCs, Routes, NetworkPolicies,
# ServiceAccounts, BuildConfigs/Builds, Tekton Pipelines/Tasks/PipelineRuns,
# the EventListener, and the HPA.
# ──────────────────────────────────────────────────────────────────────────

step "Delete the $NAMESPACE namespace (and wait for it to fully terminate)"
force_delete_namespace "$NAMESPACE"

# ──────────────────────────────────────────────────────────────────────────
# Cluster-scoped leftovers — not owned by any namespace, so namespace
# deletion above never touches these.
# ──────────────────────────────────────────────────────────────────────────

step "Delete cluster-scoped SCC, ClusterRole, and remaining ClusterRoleBindings"
oc delete scc financeflow-scc --ignore-not-found
oc delete clusterrole use-financeflow-scc --ignore-not-found
oc delete clusterrolebinding financeflow-cicd-triggers-clusterroles --ignore-not-found
oc delete clusterrolebinding financeflow-cicd-clustertriggerbindings-view --ignore-not-found

# ──────────────────────────────────────────────────────────────────────────
# Optional: cluster-wide operators (prepare-cluster.sh)
# ──────────────────────────────────────────────────────────────────────────

if [ "$WITH_OPERATORS" = true ]; then
  step "Uninstall the 6 cluster-wide operators (Pipelines, GitOps, Service Mesh 3, Tempo, Kiali, OpenTelemetry)"
  for sub in openshift-pipelines-operator-rh openshift-gitops-operator servicemeshoperator3 tempo-product kiali-ossm opentelemetry-product; do
    csv=$(oc get subscription "$sub" -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    oc delete subscription "$sub" -n openshift-operators --ignore-not-found
    [ -n "$csv" ] && oc delete csv "$csv" -n openshift-operators --ignore-not-found
  done

  step "Disable the Pipelines and GitOps console plugins"
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op": "remove", "path": "/spec/plugins"}]' 2>/dev/null || true
  echo "    (re-run prepare-cluster.sh's plugin steps if other workloads still need them)"
else
  echo
  echo "Skipping operator removal (default) — pass --with-operators to also uninstall"
  echo "Pipelines/GitOps/Service Mesh 3/Tempo/Kiali/OpenTelemetry."
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Cleanup complete."
echo "════════════════════════════════════════════════════════════════════"
echo " Manual steps this script can't do for you:"
echo "   - Remove the GitHub webhook from your repo (Settings → Webhooks) —"
echo "     it points at a Route that no longer exists, GitHub will just see"
echo "     delivery failures until you delete it."
echo "   - User-workload monitoring (enableUserWorkload) and the console"
echo "     plugins were left enabled — harmless to leave on, low cost either way."
echo "════════════════════════════════════════════════════════════════════"
