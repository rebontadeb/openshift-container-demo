#!/usr/bin/env bash
# FinanceFlow Workshop — Full Demo Deployment (Chapters 0–7)
#
# Run prepare-cluster.sh first (cluster-admin operator/console-plugin setup).
# This script creates the namespace and deploys everything else: builds,
# the app, networking, security, service mesh, CI/CD, and observability.
#
# Usage:
#   ./deploy-demo.sh          # pauses before every step
#   ./deploy-demo.sh -y       # no pauses, run straight through
#
# Env vars (all optional — you'll be prompted for anything missing):
#   NAMESPACE          (default: financeflow-workshop)
#   POSTGRES_PASSWORD  (generated with openssl if unset)
#   GITHUB_USERNAME    (needed for Chapter 6 — git push credentials)
#   GITHUB_PAT         (needed for Chapter 6 — token with repo scope)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NAMESPACE="${NAMESPACE:-financeflow-workshop}"

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

ok()   { echo "    ✓ $1"; }
wait_rollout() { oc rollout status "deployment/$1" -n "$NAMESPACE" --timeout=180s; }

# ──────────────────────────────────────────────────────────────────────────
# Chapter 0 — Namespace
# ──────────────────────────────────────────────────────────────────────────

step "Create the namespace ($NAMESPACE)"
if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace already exists"
else
  oc new-project "$NAMESPACE" --display-name="FinanceFlow Workshop"
fi
oc project "$NAMESPACE" >/dev/null

step "Create ServiceAccounts financeflow-app / financeflow-cicd"
# Pulled forward from Chapter 4: deployment-account-service.yaml,
# deployment-transaction-service.yaml, and deployment-portal.yaml all set
# serviceAccountName: financeflow-app directly in the committed spec. If
# Chapter 2's Deployments are created before this ServiceAccount exists,
# pod admission fails outright ("serviceaccount financeflow-app not found").
# The SCC/RBAC that actually grants this SA anything still happens at its
# normal Chapter 4 position below, followed by a rollout restart to pick it
# up — same as it played out live.
oc apply -f 04-security/manifests/serviceaccount-financeflow.yaml
oc apply -f 04-security/manifests/serviceaccount-cicd.yaml

# ──────────────────────────────────────────────────────────────────────────
# Chapter 1 — Builds
# ──────────────────────────────────────────────────────────────────────────

step "Create ImageStreams (account, transaction, portal)"
oc apply -f 01-builds/manifests/imagestream-account.yaml
oc apply -f 01-builds/manifests/imagestream-transaction.yaml
oc apply -f 01-builds/manifests/imagestream-portal.yaml

step "Create BuildConfigs (account, transaction, portal)"
oc apply -f 01-builds/manifests/buildconfig-account.yaml
oc apply -f 01-builds/manifests/buildconfig-transaction.yaml
oc apply -f 01-builds/manifests/buildconfig-portal-docker.yaml

step "Build and push financeflow-account:v1.0"
oc start-build financeflow-account --from-dir=../app/account-service --follow

step "Build and push financeflow-transaction:v1.0"
oc start-build financeflow-transaction --from-dir=../app/transaction-service --follow

step "Build and push financeflow-portal:v1.0"
oc start-build financeflow-portal --from-dir=../app/portal --follow

# ──────────────────────────────────────────────────────────────────────────
# Chapter 2 — Deployments
# ──────────────────────────────────────────────────────────────────────────

step "Create the postgres-credentials Secret"
if oc get secret postgres-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  ok "secret already exists"
else
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 24)}"
  oc create secret generic postgres-credentials \
    --namespace="$NAMESPACE" \
    --from-literal=POSTGRES_USER=financeflow \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=POSTGRES_DB=financeflow \
    --from-literal=DB_USER=financeflow \
    --from-literal=DB_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=DB_NAME=financeflow
  echo "    Generated postgres password (save this): $POSTGRES_PASSWORD"
fi

step "Apply PVC, ConfigMaps, Postgres Deployment + Service"
oc apply -f 02-deployments/manifests/pvc-postgres.yaml
oc apply -f 02-deployments/manifests/configmap-account-service.yaml
oc apply -f 02-deployments/manifests/configmap-transaction-service.yaml
oc apply -f 02-deployments/manifests/configmap-portal-nginx.yaml
oc apply -f 02-deployments/manifests/configmap-postgres-init.yaml
oc apply -f 02-deployments/manifests/deployment-postgres.yaml
oc apply -f 02-deployments/manifests/service-postgres.yaml
wait_rollout postgres

step "Apply account-service Deployment + Service"
# BuildConfig already outputs directly to financeflow-account:v1.0 — no
# retagging needed.
oc apply -f 02-deployments/manifests/deployment-account-service.yaml
oc apply -f 02-deployments/manifests/service-account-service.yaml
wait_rollout account-service

step "Apply transaction-service Deployment + Service"
oc apply -f 02-deployments/manifests/deployment-transaction-service.yaml
oc apply -f 02-deployments/manifests/service-transaction-service.yaml
wait_rollout transaction-service

step "Apply portal Deployment + Service"
oc apply -f 02-deployments/manifests/deployment-portal.yaml
oc apply -f 02-deployments/manifests/service-portal.yaml
wait_rollout portal

step "Apply the account-service HPA"
oc apply -f 02-deployments/manifests/hpa-account-service.yaml

# ──────────────────────────────────────────────────────────────────────────
# Chapter 3 — Networking
# ──────────────────────────────────────────────────────────────────────────

step "Apply the portal Route"
oc apply -f 03-networking/manifests/route-portal.yaml

step "Apply NetworkPolicies (deny-all + allow-lists)"
oc apply -f 03-networking/manifests/networkpolicy-deny-all.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-postgres.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-account-service.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-transaction-service.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-portal.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-monitoring.yaml

step "Verify the app is reachable through the Route"
PORTAL_HOST=$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "    portal: HTTP %{http_code}\n" "https://$PORTAL_HOST/health" || true

# ──────────────────────────────────────────────────────────────────────────
# Chapter 4 — Security
# ──────────────────────────────────────────────────────────────────────────

step "Apply the SCC, ClusterRole, Roles, and RoleBindings"
oc apply -f 04-security/manifests/scc-financeflow.yaml
oc apply -f 04-security/manifests/clusterrole-use-financeflow-scc.yaml
oc apply -f 04-security/manifests/role-viewer.yaml
oc apply -f 04-security/manifests/role-deployer.yaml
oc apply -f 04-security/manifests/rolebinding-viewer.yaml
oc apply -f 04-security/manifests/rolebinding-deployer.yaml
oc apply -f 04-security/manifests/rolebinding-sa-use-scc.yaml

step "Restart account-service/transaction-service/portal to pick up financeflow-scc"
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
wait_rollout account-service
wait_rollout transaction-service
wait_rollout portal

# ──────────────────────────────────────────────────────────────────────────
# Chapter 5 — Service Mesh
# ──────────────────────────────────────────────────────────────────────────

step "Create the Istio control plane (Sail Operator) — this can take a few minutes"
oc apply -f 05-service-mesh/manifests/smcp.yaml

step "Wait for Istio to report Healthy"
for i in $(seq 1 20); do
  state=$(oc get istio default -n istio-system -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  [ "$state" = "Healthy" ] && { ok "Istio Healthy"; break; }
  echo "    ... state=$state"
  sleep 15
done

step "Enroll the namespace in the mesh (istio-injection label)"
oc apply -f 05-service-mesh/manifests/smmr.yaml

step "Restart workloads to inject Envoy sidecars"
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
wait_rollout account-service
wait_rollout transaction-service
wait_rollout portal

step "Apply mTLS policy, DestinationRules, and the canary VirtualService"
oc apply -f 05-service-mesh/manifests/peerauthentication-mtls.yaml
oc apply -f 05-service-mesh/manifests/destinationrule-account-service.yaml
oc apply -f 05-service-mesh/manifests/destinationrule-transaction-service.yaml
oc apply -f 05-service-mesh/manifests/virtualservice-account-service.yaml

step "Deploy the account-service canary (v1.1) — reuses the v1.0 image, just demonstrates traffic splitting"
oc tag "$NAMESPACE/financeflow-account:v1.0" "$NAMESPACE/financeflow-account:v1.1"
oc apply -f 05-service-mesh/manifests/deployment-account-service-v11.yaml

step "Deploy Kiali and grant it cluster-monitoring-view"
oc apply -f 05-service-mesh/manifests/kiali.yaml
oc apply -f 05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml

step "Ensure user-workload monitoring is enabled (prepare-cluster.sh should have done this — re-checked here since a missing ConfigMap fails silently otherwise)"
if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  oc patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type=merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}'
else
  oc create configmap cluster-monitoring-config -n openshift-monitoring \
    --from-literal=config.yaml="enableUserWorkload: true"
fi
for i in $(seq 1 20); do
  status=$(oc get pods -n openshift-user-workload-monitoring 2>&1)
  if echo "$status" | grep -q "prometheus-user-workload" && ! echo "$status" | grep -qv "Running\|NAME"; then
    ok "user-workload monitoring is up"
    break
  fi
  echo "    ... waiting for prometheus-user-workload / thanos-ruler-user-workload"
  sleep 10
done

step "Grant the monitoring SA permission to scrape this namespace, apply the istio-sidecar-metrics PodMonitor"
oc adm policy add-role-to-user \
  view \
  system:serviceaccount:openshift-user-workload-monitoring:prometheus-user-workload \
  -n "$NAMESPACE"
oc apply -f 05-service-mesh/manifests/podmonitor-istio-sidecar.yaml

step "Wait for the Kiali dashboard to come up"
oc rollout status deployment/kiali -n istio-system --timeout=180s
KIALI_HOST=""
for i in $(seq 1 18); do
  KIALI_HOST=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$KIALI_HOST" ]; then
    CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$KIALI_HOST/" || true)
    # auth strategy is "openshift" — a redirect to the OAuth login is expected,
    # not a 200; "000" is the only real failure (route not yet reachable)
    if [ "$CODE" != "000" ]; then
      ok "Kiali dashboard reachable at https://$KIALI_HOST (HTTP $CODE)"
      break
    fi
  fi
  echo "    ... waiting for Kiali route ($i/18)"
  sleep 10
done

step "Generate traffic so the mesh has something to report"
oc exec deployment/portal -n "$NAMESPACE" -- sh -c \
  "for i in \$(seq 1 60); do wget -qO- http://account-service:8080/api/accounts >/dev/null 2>&1; sleep 0.2; done"

step "Verify istio_requests_total metrics reached Thanos (the same data Kiali's graph reads)"
KIALI_TOKEN=$(oc create token kiali-service-account -n istio-system --duration=10m)
METRIC_RESULT=$(oc exec deployment/portal -n "$NAMESPACE" -- wget -qO- \
  --no-check-certificate \
  --header="Authorization: Bearer $KIALI_TOKEN" \
  "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091/api/v1/query?query=istio_requests_total%7Bdestination_service_name%3D%22account-service%22%2Cdestination_service_namespace%3D%22$NAMESPACE%22%7D" 2>/dev/null || true)
if echo "$METRIC_RESULT" | grep -q '"result":\[{'; then
  ok "istio_requests_total samples found for account-service — Kiali's graph will show traffic"
else
  echo "    ⚠ No istio_requests_total samples yet for account-service."
  echo "      Scrape interval is 15s — wait ~30-60s and re-check before assuming the PodMonitor/RBAC steps above failed."
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 6 — CI/CD
# ──────────────────────────────────────────────────────────────────────────

step "Ensure the Pipelines and GitOps console plugins are enabled (prepare-cluster.sh should have done this — re-checked here since a missed/lost patch leaves the Pipelines tab and ArgoCD apps silently absent from the console, with no error anywhere)"
plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || true)
if echo "$plugins" | grep -q "pipelines-console-plugin"; then
  ok "pipelines-console-plugin already enabled"
else
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
fi
plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || true)
if echo "$plugins" | grep -q "gitops-plugin"; then
  ok "gitops-plugin already enabled"
else
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
fi

step "Grant financeflow-cicd permission to push images and run buildah"
oc adm policy add-role-to-user \
  registry-editor \
  "system:serviceaccount:$NAMESPACE:financeflow-cicd"
oc adm policy add-scc-to-user pipelines-scc \
  -z financeflow-cicd \
  -n "$NAMESPACE"

step "Create the GitHub webhook Secret"
if oc get secret github-webhook-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  ok "secret already exists"
else
  WEBHOOK_SECRET=$(openssl rand -hex 20)
  oc create secret generic github-webhook-secret \
    --from-literal=secret="$WEBHOOK_SECRET" \
    -n "$NAMESPACE"
  echo "    Webhook secret (register this in GitHub): $WEBHOOK_SECRET"
fi

step "Create git push credentials for the pipeline and link them to financeflow-cicd"
if oc get secret git-credentials-cicd -n "$NAMESPACE" >/dev/null 2>&1; then
  ok "secret already exists"
else
  GITHUB_USERNAME="${GITHUB_USERNAME:-}"
  GITHUB_PAT="${GITHUB_PAT:-}"
  [ -z "$GITHUB_USERNAME" ] && read -rp "    GitHub username: " GITHUB_USERNAME
  [ -z "$GITHUB_PAT" ] && read -rsp "    GitHub PAT (repo scope, input hidden): " GITHUB_PAT && echo
  oc create secret generic git-credentials-cicd \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$GITHUB_USERNAME" \
    --from-literal=password="$GITHUB_PAT" \
    -n "$NAMESPACE"
  oc annotate secret git-credentials-cicd tekton.dev/git-0=https://github.com -n "$NAMESPACE"
  oc secrets link financeflow-cicd git-credentials-cicd -n "$NAMESPACE"
fi

step "Label the namespace for ArgoCD (oc label, never oc apply -f a full Namespace object here)"
oc label namespace "$NAMESPACE" argocd.argoproj.io/managed-by=openshift-gitops --overwrite

step "Apply the Tekton Pipeline, Tasks, and the pipeline-source PVC"
oc apply -f 06-cicd/manifests/pvc-pipeline-source.yaml
oc apply -f 06-cicd/manifests/task-run-tests.yaml
oc apply -f 06-cicd/manifests/task-update-manifest.yaml
oc apply -f 06-cicd/manifests/pipeline-financeflow.yaml

step "Apply the webhook Trigger chain (TriggerBinding, TriggerTemplate, EventListener, Route)"
oc apply -f 06-cicd/manifests/triggerbinding-github.yaml
oc apply -f 06-cicd/manifests/triggertemplate-financeflow.yaml
oc apply -f 06-cicd/manifests/eventlistener.yaml
oc apply -f 06-cicd/manifests/route-eventlistener.yaml
oc apply -f 06-cicd/manifests/networkpolicy-allow-router-to-webhook.yaml
oc apply -f 06-cicd/manifests/peerauthentication-webhook-ingress-permissive.yaml

step "Apply the ArgoCD AppProject and Application (into openshift-gitops)"
oc apply -f 06-cicd/manifests/argocd-project.yaml -n openshift-gitops
oc apply -f 06-cicd/manifests/argocd-app-financeflow.yaml -n openshift-gitops

step "Trigger a manual PipelineRun for account-service (proves the pipeline before relying on the webhook)"
oc create -f 06-cicd/manifests/pipelinerun-account-service.yaml

step "Trigger a manual PipelineRun for transaction-service"
oc create -f 06-cicd/manifests/pipelinerun-transaction-service.yaml

# ──────────────────────────────────────────────────────────────────────────
# Chapter 7 — Observability
# ──────────────────────────────────────────────────────────────────────────

step "Install the Grafana Operator"
oc apply -f 07-observability/manifests/grafana/namespace.yaml
oc apply -f 07-observability/manifests/grafana/operatorgroup.yaml
oc apply -f 07-observability/manifests/grafana/subscription.yaml
oc apply -f 07-observability/manifests/grafana/serviceaccount.yaml
oc wait --for=condition=Ready pods -l control-plane=controller-manager -n grafana --timeout=180s

step "Generate the Thanos bearer token Secret for Grafana"
TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
oc create secret generic grafana-thanos-bearer-token \
  --from-literal=BEARER_TOKEN="Bearer $TOKEN" \
  -n grafana --dry-run=client -o yaml | oc apply -f -

step "Deploy the Grafana instance"
oc apply -f 07-observability/manifests/grafana/grafana.yaml
oc wait --for=condition=GrafanaReady grafana/financeflow-grafana -n grafana --timeout=180s

step "Apply the Grafana datasource CR"
oc apply -f 07-observability/manifests/grafana/datasource.yaml

step "Verify the datasource authenticates (secureJsonData uses \${BEARER_TOKEN} + spec.valuesFrom — no manual patch needed)"
GRAFANA_POD=$(oc get pod -n grafana -l app=financeflow-grafana -o jsonpath='{.items[0].metadata.name}')
DS_UID=$(oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['uid'])")
oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources/uid/$DS_UID/health"
echo

step "Apply the Grafana Route and the Service Mesh dashboard"
oc apply -f 07-observability/manifests/grafana/route.yaml
oc apply -f 07-observability/manifests/grafana/dashboard-service-mesh.yaml

step "Apply ServiceMonitors and the PrometheusRule for app metrics/alerting"
oc apply -f 07-observability/manifests/servicemonitor-account-service.yaml
oc apply -f 07-observability/manifests/servicemonitor-transaction-service.yaml
oc apply -f 07-observability/manifests/prometheusrule-financeflow.yaml

step "Deploy Tempo (TempoMonolithic) and its mTLS/NetworkPolicy exceptions"
oc apply -f 07-observability/manifests/tempo.yaml
oc apply -f 07-observability/manifests/peerauthentication-tempo-ingress-permissive.yaml
oc apply -f 07-observability/manifests/networkpolicy-allow-collector-to-tempo.yaml
for i in $(seq 1 20); do
  oc get pod tempo-financeflow-0 -n "$NAMESPACE" 2>/dev/null | grep -q "Running" && { ok "Tempo Running"; break; }
  sleep 10
done

step "Deploy the OTel Collector"
oc apply -f 07-observability/manifests/otel-collector.yaml

step "Apply the FinanceFlow overview dashboard (GrafanaDashboard CR, not a sidecar-discovered ConfigMap)"
oc apply -f 07-observability/manifests/dashboard-financeflow-overview.yaml

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Deployment complete."
echo "════════════════════════════════════════════════════════════════════"
echo " Portal:    https://$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
echo " Kiali:     https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null)"
echo " Grafana:   https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}' 2>/dev/null)  (admin/financeflow)"
echo " Jaeger UI: https://$(oc get route tempo-financeflow-jaegerui -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
echo " ArgoCD:    https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
echo "   ArgoCD admin password: $(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null)"
echo
echo " Still needed for the full CI/CD webhook loop:"
echo "   1. Register the GitHub webhook (Settings → Webhooks) on your repo:"
echo "      Payload URL: https://$(oc get route financeflow-webhook -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
echo "      Secret:      $(oc get secret github-webhook-secret -n "$NAMESPACE" -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d)"
echo "      Events:      just 'push'"
echo "   2. chapters/05-service-mesh/manifests/kiali.yaml's Grafana URL is hardcoded to"
echo "      whatever cluster it was last edited on — update it to match the Grafana"
echo "      route printed above if it doesn't match."
echo "════════════════════════════════════════════════════════════════════"
