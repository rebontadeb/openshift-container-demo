#!/usr/bin/env bash
# FinanceFlow Workshop — Cluster Preparation
#
# Cluster-admin, one-time setup: operators, user-workload monitoring, and the
# two OpenShift console plugins (Pipelines/GitOps) that the operators install
# but don't enable themselves. Run this once per cluster, before
# deploy-demo.sh.
#
# Usage:
#   ./prepare-cluster.sh          # pauses before every step
#   ./prepare-cluster.sh -y       # no pauses, run straight through
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PAUSE=true
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--no-pause) PAUSE=false ;;
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

# ── Step: verify login ───────────────────────────────────────────────────────
step "Verify oc login and cluster-admin access"
oc whoami
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
  && ok "cluster-admin confirmed" \
  || { echo "    ✗ Not cluster-admin — this script needs it (operators, console plugins, monitoring config)."; exit 1; }

# ── Step: install operators ──────────────────────────────────────────────────
step "Install missing operators (Pipelines, GitOps, Service Mesh 3, Tempo, Kiali, OpenTelemetry)"
oc apply -k 00-prerequisites/manifests/missing-operators/

step "Wait for all 6 operator CSVs to reach Succeeded"
for i in $(seq 1 30); do
  pending=$(oc get csv -n openshift-operators -o json 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
names=['pipelines','gitops','servicemeshoperator3','tempo','kiali','opentelemetry']
pending=[i['metadata']['name'] for i in d['items']
         if any(n in i['metadata']['name'].lower() for n in names)
         and i.get('status',{}).get('phase')!='Succeeded']
print('\n'.join(pending))
")
  if [ -z "$pending" ]; then
    ok "all operator CSVs Succeeded"
    break
  fi
  echo "    ... still installing: $(echo "$pending" | tr '\n' ' ')"
  sleep 15
done
oc get csv -n openshift-operators | grep -iE "pipelines|gitops|servicemesh|tempo|kiali|opentelemetry"

# ── Step: user-workload monitoring ───────────────────────────────────────────
step "Enable user-workload monitoring (needed by Kiali's traffic graphs and Chapter 7's ServiceMonitors)"
if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  oc patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type=merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}'
else
  oc create configmap cluster-monitoring-config -n openshift-monitoring \
    --from-literal=config.yaml="enableUserWorkload: true"
fi

step "Wait for prometheus-user-workload / thanos-ruler-user-workload pods"
for i in $(seq 1 20); do
  status=$(oc get pods -n openshift-user-workload-monitoring 2>&1)
  if echo "$status" | grep -q "prometheus-user-workload" && ! echo "$status" | grep -qv "Running\|NAME"; then
    ok "user-workload monitoring is up"
    break
  fi
  echo "    ... waiting"
  sleep 10
done
oc get pods -n openshift-user-workload-monitoring

# ── Step: console plugins ────────────────────────────────────────────────────
step "Enable the Pipelines console plugin (operator installs the pod but doesn't enable it)"
plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}')
if echo "$plugins" | grep -q "pipelines-console-plugin"; then
  ok "already enabled"
else
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
fi

step "Enable the GitOps console plugin (same gap, same fix — ArgoCD apps show nothing in-console otherwise)"
plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}')
if echo "$plugins" | grep -q "gitops-plugin"; then
  ok "already enabled"
else
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
fi

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Cluster preparation complete. Run deploy-demo.sh next."
echo "════════════════════════════════════════════════════════════════════"
