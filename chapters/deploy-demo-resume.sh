#!/usr/bin/env bash
# FinanceFlow Workshop — Full Demo Deployment, resumable (Chapters 0–7)
#
# Same deployment as deploy-demo.sh, restructured so any step can be used as
# a starting point — for picking up after a crash without redoing builds,
# CI/CD setup, etc. Keep deploy-demo.sh as the canonical straight-through
# script; this one is for resuming mid-deployment.
#
# Run prepare-cluster.sh first (cluster-admin operator/console-plugin setup).
#
# Usage:
#   ./deploy-demo-resume.sh                       # runs all 51 steps, pauses before each
#   ./deploy-demo-resume.sh -y                     # no pauses, run straight through
#   ./deploy-demo-resume.sh --list                 # print all step numbers/titles, exit
#   ./deploy-demo-resume.sh --from 44              # start at step 44, skip 1-43
#   ./deploy-demo-resume.sh --from "Thanos bearer" # start at the step whose title
#                                                   # contains this text (case-insensitive)
#   ./deploy-demo-resume.sh -y --from 44           # combine freely
#
# Steps before the start point are NOT executed — only resume from a point
# where every earlier step has already succeeded against this cluster.
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
FROM_ARG=""
LIST_ONLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes|--no-pause) PAUSE=false ;;
    --list) LIST_ONLY=true ;;
    --from) FROM_ARG="${2:-}"; shift ;;
    --from=*) FROM_ARG="${1#--from=}" ;;
  esac
  shift
done

# ── Step titles, in order — index 1..N matches deploy-demo.sh's STEP NN ────
TITLES=(
  "Create the namespace (\$NAMESPACE)"
  "Create ServiceAccounts financeflow-app / financeflow-cicd"
  "Create ImageStreams (account, transaction, portal)"
  "Create BuildConfigs (account, transaction, portal)"
  "Build and push financeflow-account:v1.0"
  "Build and push financeflow-transaction:v1.0"
  "Build and push financeflow-portal:v1.0"
  "Pin Chapter 2 manifests to the freshly-built :v1.0 tag"
  "Create the postgres-credentials Secret"
  "Apply PVC, ConfigMaps, Postgres Deployment + Service"
  "Apply account-service Deployment + Service"
  "Apply transaction-service Deployment + Service"
  "Apply portal Deployment + Service"
  "Apply the account-service HPA"
  "Apply the portal Route"
  "Apply NetworkPolicies (deny-all + allow-lists)"
  "Verify the app is reachable through the Route"
  "Apply the SCC, ClusterRole, Roles, and RoleBindings"
  "Restart account-service/transaction-service/portal to pick up financeflow-scc"
  "Create the Istio control plane (Sail Operator) — this can take a few minutes"
  "Wait for Istio to report Healthy"
  "Enroll the namespace in the mesh (istio-injection label)"
  "Restart workloads to inject Envoy sidecars"
  "Apply mTLS policy, DestinationRules, and the canary VirtualService"
  "Deploy the account-service canary (v1.1) — reuses the v1.0 image, just demonstrates traffic splitting"
  "Deploy Kiali and grant it cluster-monitoring-view"
  "Ensure user-workload monitoring is enabled"
  "Grant the monitoring SA permission to scrape this namespace, apply the istio-sidecar-metrics PodMonitor"
  "Wait for the Kiali dashboard to come up"
  "Generate traffic so the mesh has something to report"
  "Verify istio_requests_total metrics reached Thanos"
  "Ensure the Pipelines and GitOps console plugins are enabled"
  "Grant financeflow-cicd permission to push images and run buildah"
  "Create the GitHub webhook Secret"
  "Create git push credentials for the pipeline and link them to financeflow-cicd"
  "Label the namespace for ArgoCD"
  "Apply the Tekton Pipeline, Tasks, and the pipeline-source PVC"
  "Apply the webhook Trigger chain (TriggerBinding, TriggerTemplate, EventListener, Route)"
  "Apply the ArgoCD AppProject and Application (into openshift-gitops)"
  "Trigger a manual PipelineRun for account-service"
  "Trigger a manual PipelineRun for transaction-service"
  "Install the Grafana Operator"
  "Generate the Thanos bearer token Secret for Grafana"
  "Deploy the Grafana instance"
  "Apply the Grafana datasource CR"
  "Verify the datasource authenticates"
  "Apply the Grafana Route and the Service Mesh dashboard"
  "Apply ServiceMonitors and the PrometheusRule for app metrics/alerting"
  "Deploy Tempo (TempoMonolithic) and its mTLS/NetworkPolicy exceptions"
  "Deploy the OTel Collector"
  "Apply the FinanceFlow overview dashboard"
  "Print final summary"
)
TOTAL_STEPS=${#TITLES[@]}

if [ "$LIST_ONLY" = true ]; then
  for i in "${!TITLES[@]}"; do
    printf "%02d  %s\n" "$((i + 1))" "${TITLES[$i]}"
  done
  exit 0
fi

START_AT=1
if [ -n "$FROM_ARG" ]; then
  if echo "$FROM_ARG" | grep -qE '^[0-9]+$'; then
    START_AT="$FROM_ARG"
  else
    START_AT=0
    for i in "${!TITLES[@]}"; do
      if echo "${TITLES[$i]}" | grep -qi -- "$FROM_ARG"; then
        START_AT=$((i + 1))
        break
      fi
    done
    if [ "$START_AT" -eq 0 ]; then
      echo "No step title matches \"$FROM_ARG\". Run with --list to see all step numbers/titles."
      exit 1
    fi
  fi
fi
if [ "$START_AT" -lt 1 ] || [ "$START_AT" -gt "$TOTAL_STEPS" ]; then
  echo "Invalid --from value: resolved to step $START_AT, but there are only $TOTAL_STEPS steps."
  exit 1
fi

STEP_NUM=0
step() {
  STEP_NUM=$((STEP_NUM + 1))
  if [ "$STEP_NUM" -lt "$START_AT" ]; then
    return 1   # caller skips this step's body
  fi
  echo
  echo "════════════════════════════════════════════════════════════════════"
  printf "STEP %02d/%02d: %s\n" "$STEP_NUM" "$TOTAL_STEPS" "${TITLES[$((STEP_NUM - 1))]}"
  echo "════════════════════════════════════════════════════════════════════"
  if [ "$PAUSE" = true ]; then
    read -rp ">>> Press Enter to run this step (Ctrl+C to abort)... "
  fi
  return 0
}

ok()   { echo "    ✓ $1"; }
wait_rollout() { oc rollout status "deployment/$1" -n "$NAMESPACE" --timeout=180s; }

if [ "$START_AT" -gt 1 ]; then
  echo "Resuming at step $START_AT/$TOTAL_STEPS: ${TITLES[$((START_AT - 1))]}"
  echo "(steps 1-$((START_AT - 1)) assumed already done on this cluster — not executed)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 0 — Namespace
# ──────────────────────────────────────────────────────────────────────────

if step "namespace"; then
  if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    ok "namespace already exists"
  else
    oc new-project "$NAMESPACE" --display-name="FinanceFlow Workshop"
  fi
  oc project "$NAMESPACE" >/dev/null
fi

if step "service accounts"; then
  # Pulled forward from Chapter 4: deployment-account-service.yaml,
  # deployment-transaction-service.yaml, and deployment-portal.yaml all set
  # serviceAccountName: financeflow-app directly in the committed spec. If
  # Chapter 2's Deployments are created before this ServiceAccount exists,
  # pod admission fails outright ("serviceaccount financeflow-app not found").
  oc apply -f 04-security/manifests/serviceaccount-financeflow.yaml
  oc apply -f 04-security/manifests/serviceaccount-cicd.yaml
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 1 — Builds
# ──────────────────────────────────────────────────────────────────────────

if step "imagestreams"; then
  oc apply -f 01-builds/manifests/imagestream-account.yaml
  oc apply -f 01-builds/manifests/imagestream-transaction.yaml
  oc apply -f 01-builds/manifests/imagestream-portal.yaml
fi

if step "buildconfigs"; then
  oc apply -f 01-builds/manifests/buildconfig-account.yaml
  oc apply -f 01-builds/manifests/buildconfig-transaction.yaml
  oc apply -f 01-builds/manifests/buildconfig-portal-docker.yaml
fi

if step "build account"; then
  oc start-build financeflow-account --from-dir=../app/account-service --follow
fi

if step "build transaction"; then
  oc start-build financeflow-transaction --from-dir=../app/transaction-service --follow
fi

if step "build portal"; then
  oc start-build financeflow-portal --from-dir=../app/portal --follow
fi

if step "pin chapter 2"; then
  # CI's update-manifest task (Chapter 6) rewrites these two files to a full
  # git-SHA tag on every webhook-triggered build. That SHA only ever exists
  # in the registry of whatever cluster built it — on a fresh cluster the
  # tag is gone. Force both back to :v1.0 (what was just built, above) and
  # push immediately, so git matches the live cluster before Chapter 6
  # creates the ArgoCD Application.
  sed -i "s|image: financeflow-account:.*|image: financeflow-account:v1.0|" \
    02-deployments/manifests/deployment-account-service.yaml
  sed -i "s|image: financeflow-transaction:.*|image: financeflow-transaction:v1.0|" \
    02-deployments/manifests/deployment-transaction-service.yaml
  if ! git -C .. diff --quiet -- chapters/02-deployments/manifests/deployment-account-service.yaml \
                                    chapters/02-deployments/manifests/deployment-transaction-service.yaml; then
    git -C .. add chapters/02-deployments/manifests/deployment-account-service.yaml \
                  chapters/02-deployments/manifests/deployment-transaction-service.yaml
    git -C .. commit -m "ci: pin account/transaction-service to v1.0 for fresh-cluster deploy [skip ci]"
    git -C .. push origin HEAD:refs/heads/main
    ok "pinned to v1.0 and pushed — git now matches what was just built"
  else
    ok "manifests already pinned to v1.0"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 2 — Deployments
# ──────────────────────────────────────────────────────────────────────────

if step "postgres secret"; then
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
fi

if step "postgres deployment"; then
  oc apply -f 02-deployments/manifests/pvc-postgres.yaml
  oc apply -f 02-deployments/manifests/configmap-account-service.yaml
  oc apply -f 02-deployments/manifests/configmap-transaction-service.yaml
  oc apply -f 02-deployments/manifests/configmap-portal-nginx.yaml
  oc apply -f 02-deployments/manifests/configmap-postgres-init.yaml
  oc apply -f 02-deployments/manifests/deployment-postgres.yaml
  oc apply -f 02-deployments/manifests/service-postgres.yaml
  wait_rollout postgres
fi

if step "account-service deployment"; then
  # BuildConfig already outputs directly to financeflow-account:v1.0 — no
  # retagging needed.
  oc apply -f 02-deployments/manifests/deployment-account-service.yaml
  oc apply -f 02-deployments/manifests/service-account-service.yaml
  wait_rollout account-service
fi

if step "transaction-service deployment"; then
  oc apply -f 02-deployments/manifests/deployment-transaction-service.yaml
  oc apply -f 02-deployments/manifests/service-transaction-service.yaml
  wait_rollout transaction-service
fi

if step "portal deployment"; then
  oc apply -f 02-deployments/manifests/deployment-portal.yaml
  oc apply -f 02-deployments/manifests/service-portal.yaml
  wait_rollout portal
fi

if step "account-service hpa"; then
  oc apply -f 02-deployments/manifests/hpa-account-service.yaml
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 3 — Networking
# ──────────────────────────────────────────────────────────────────────────

if step "portal route"; then
  oc apply -f 03-networking/manifests/route-portal.yaml
fi

if step "networkpolicies"; then
  oc apply -f 03-networking/manifests/networkpolicy-deny-all.yaml
  oc apply -f 03-networking/manifests/networkpolicy-allow-postgres.yaml
  oc apply -f 03-networking/manifests/networkpolicy-allow-account-service.yaml
  oc apply -f 03-networking/manifests/networkpolicy-allow-transaction-service.yaml
  oc apply -f 03-networking/manifests/networkpolicy-allow-portal.yaml
  oc apply -f 03-networking/manifests/networkpolicy-allow-monitoring.yaml
fi

if step "verify route"; then
  PORTAL_HOST=$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')
  curl -sk -o /dev/null -w "    portal: HTTP %{http_code}\n" "https://$PORTAL_HOST/health" || true
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 4 — Security
# ──────────────────────────────────────────────────────────────────────────

if step "scc rbac"; then
  oc apply -f 04-security/manifests/scc-financeflow.yaml
  oc apply -f 04-security/manifests/clusterrole-use-financeflow-scc.yaml
  oc apply -f 04-security/manifests/role-viewer.yaml
  oc apply -f 04-security/manifests/role-deployer.yaml
  oc apply -f 04-security/manifests/rolebinding-viewer.yaml
  oc apply -f 04-security/manifests/rolebinding-deployer.yaml
  oc apply -f 04-security/manifests/rolebinding-sa-use-scc.yaml
fi

if step "restart for scc"; then
  oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
  wait_rollout account-service
  wait_rollout transaction-service
  wait_rollout portal
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 5 — Service Mesh
# ──────────────────────────────────────────────────────────────────────────

if step "istio control plane"; then
  oc apply -f 05-service-mesh/manifests/smcp.yaml
fi

if step "wait istio healthy"; then
  for i in $(seq 1 20); do
    state=$(oc get istio default -n istio-system -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    [ "$state" = "Healthy" ] && { ok "Istio Healthy"; break; }
    echo "    ... state=$state"
    sleep 15
  done
fi

if step "enroll namespace mesh"; then
  oc apply -f 05-service-mesh/manifests/smmr.yaml
fi

if step "restart for sidecars"; then
  oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
  wait_rollout account-service
  wait_rollout transaction-service
  wait_rollout portal
fi

if step "mtls destinationrules"; then
  oc apply -f 05-service-mesh/manifests/peerauthentication-mtls.yaml
  oc apply -f 05-service-mesh/manifests/destinationrule-account-service.yaml
  oc apply -f 05-service-mesh/manifests/destinationrule-transaction-service.yaml
  oc apply -f 05-service-mesh/manifests/virtualservice-account-service.yaml
fi

if step "canary v11"; then
  oc tag "$NAMESPACE/financeflow-account:v1.0" "$NAMESPACE/financeflow-account:v1.1"
  oc apply -f 05-service-mesh/manifests/deployment-account-service-v11.yaml
fi

if step "kiali"; then
  oc apply -f 05-service-mesh/manifests/kiali.yaml
  oc apply -f 05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml
fi

if step "user workload monitoring"; then
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
fi

if step "podmonitor istio sidecar"; then
  oc adm policy add-role-to-user \
    view \
    system:serviceaccount:openshift-user-workload-monitoring:prometheus-user-workload \
    -n "$NAMESPACE"
  oc apply -f 05-service-mesh/manifests/podmonitor-istio-sidecar.yaml
fi

if step "wait kiali dashboard"; then
  oc rollout status deployment/kiali -n istio-system --timeout=180s
  KIALI_HOST=""
  for i in $(seq 1 18); do
    KIALI_HOST=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$KIALI_HOST" ]; then
      CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$KIALI_HOST/" || true)
      if [ "$CODE" != "000" ]; then
        ok "Kiali dashboard reachable at https://$KIALI_HOST (HTTP $CODE)"
        break
      fi
    fi
    echo "    ... waiting for Kiali route ($i/18)"
    sleep 10
  done
fi

if step "generate traffic"; then
  oc exec deployment/portal -n "$NAMESPACE" -- sh -c \
    "for i in \$(seq 1 60); do wget -qO- http://account-service:8080/api/accounts >/dev/null 2>&1; sleep 0.2; done"
fi

if step "verify istio metrics"; then
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
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 6 — CI/CD
# ──────────────────────────────────────────────────────────────────────────

if step "console plugins"; then
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
fi

if step "financeflow-cicd permissions"; then
  oc adm policy add-role-to-user \
    registry-editor \
    "system:serviceaccount:$NAMESPACE:financeflow-cicd"
  oc adm policy add-scc-to-user pipelines-scc \
    -z financeflow-cicd \
    -n "$NAMESPACE"
fi

if step "github webhook secret"; then
  if oc get secret github-webhook-secret -n "$NAMESPACE" >/dev/null 2>&1; then
    ok "secret already exists"
  else
    WEBHOOK_SECRET=$(openssl rand -hex 20)
    oc create secret generic github-webhook-secret \
      --from-literal=secret="$WEBHOOK_SECRET" \
      -n "$NAMESPACE"
    echo "    Webhook secret (register this in GitHub): $WEBHOOK_SECRET"
  fi
fi

if step "git push credentials"; then
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
fi

if step "label namespace argocd"; then
  oc label namespace "$NAMESPACE" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
fi

if step "tekton pipeline"; then
  oc apply -f 06-cicd/manifests/pvc-pipeline-source.yaml
  oc apply -f 06-cicd/manifests/task-run-tests.yaml
  oc apply -f 06-cicd/manifests/task-update-manifest.yaml
  oc apply -f 06-cicd/manifests/pipeline-financeflow.yaml
fi

if step "webhook trigger chain"; then
  oc apply -f 06-cicd/manifests/triggerbinding-github.yaml
  oc apply -f 06-cicd/manifests/triggertemplate-financeflow.yaml
  oc apply -f 06-cicd/manifests/eventlistener.yaml
  oc apply -f 06-cicd/manifests/route-eventlistener.yaml
  oc apply -f 06-cicd/manifests/networkpolicy-allow-router-to-webhook.yaml
  oc apply -f 06-cicd/manifests/peerauthentication-webhook-ingress-permissive.yaml
fi

if step "argocd appproject application"; then
  oc apply -f 06-cicd/manifests/argocd-project.yaml -n openshift-gitops
  oc apply -f 06-cicd/manifests/argocd-app-financeflow.yaml -n openshift-gitops
  echo "    ArgoCD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
  echo "    ArgoCD admin password: $(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null)"
fi

if step "manual pipelinerun account"; then
  oc create -f 06-cicd/manifests/pipelinerun-account-service.yaml
fi

if step "manual pipelinerun transaction"; then
  oc create -f 06-cicd/manifests/pipelinerun-transaction-service.yaml
fi

# ──────────────────────────────────────────────────────────────────────────
# Chapter 7 — Observability
# ──────────────────────────────────────────────────────────────────────────

if step "grafana operator"; then
  oc apply -f 07-observability/manifests/grafana/namespace.yaml
  oc apply -f 07-observability/manifests/grafana/operatorgroup.yaml
  oc apply -f 07-observability/manifests/grafana/subscription.yaml
  oc apply -f 07-observability/manifests/grafana/serviceaccount.yaml
  # oc wait errors immediately with "no matching resources found" if zero
  # pods match the selector right now — poll for the pod to exist first.
  # Label is app.kubernetes.io/name=grafana-operator on grafana-operator v5.
  echo "    waiting for the grafana-operator pod to be created..."
  for i in $(seq 1 24); do
    pod_count=$(oc get pods -n grafana -l app.kubernetes.io/name=grafana-operator --no-headers 2>/dev/null | wc -l)
    [ "$pod_count" -gt 0 ] && break
    sleep 10
  done
  oc wait --for=condition=Ready pods -l app.kubernetes.io/name=grafana-operator -n grafana --timeout=180s
fi

if step "thanos bearer token"; then
  TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
  oc create secret generic grafana-thanos-bearer-token \
    --from-literal=BEARER_TOKEN="Bearer $TOKEN" \
    -n grafana --dry-run=client -o yaml | oc apply -f -
fi

if step "grafana instance"; then
  oc apply -f 07-observability/manifests/grafana/grafana.yaml
  oc wait --for=condition=GrafanaReady grafana/financeflow-grafana -n grafana --timeout=180s
fi

if step "grafana datasource"; then
  oc apply -f 07-observability/manifests/grafana/datasource.yaml
fi

if step "verify datasource"; then
  GRAFANA_POD=$(oc get pod -n grafana -l app=financeflow-grafana -o jsonpath='{.items[0].metadata.name}')
  DS_UID=$(oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
    "http://localhost:3000/api/datasources" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['uid'])")
  oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
    "http://localhost:3000/api/datasources/uid/$DS_UID/health"
  echo
fi

if step "grafana route dashboard"; then
  oc apply -f 07-observability/manifests/grafana/route.yaml
  oc apply -f 07-observability/manifests/grafana/dashboard-service-mesh.yaml
fi

if step "servicemonitors prometheusrule"; then
  oc apply -f 07-observability/manifests/servicemonitor-account-service.yaml
  oc apply -f 07-observability/manifests/servicemonitor-transaction-service.yaml
  oc apply -f 07-observability/manifests/prometheusrule-financeflow.yaml
fi

if step "tempo"; then
  oc apply -f 07-observability/manifests/tempo.yaml
  oc apply -f 07-observability/manifests/peerauthentication-tempo-ingress-permissive.yaml
  oc apply -f 07-observability/manifests/networkpolicy-allow-collector-to-tempo.yaml
  for i in $(seq 1 20); do
    oc get pod tempo-financeflow-0 -n "$NAMESPACE" 2>/dev/null | grep -q "Running" && { ok "Tempo Running"; break; }
    sleep 10
  done
fi

if step "otel collector"; then
  oc apply -f 07-observability/manifests/otel-collector.yaml
fi

if step "financeflow overview dashboard"; then
  oc apply -f 07-observability/manifests/dashboard-financeflow-overview.yaml
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────

if step "summary"; then
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
fi
