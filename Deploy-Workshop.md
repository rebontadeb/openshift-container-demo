# Deploy Workshop — Step-by-Step Guide

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Before You Start

- `oc` CLI installed and logged in: `oc whoami`
- Cluster-admin access (needed for Part A — operator installs, console
  plugins, monitoring config)
- Workshop repo cloned locally, and you're running commands from the repo
  root (the paths below assume that)
- A GitHub fork of this repo, plus a Personal Access Token with `repo`
  scope, if you intend to reach Chapter 6's CI/CD steps

Set the namespace once, in every terminal you use for this guide:

```bash
export NAMESPACE=financeflow-workshop
```

All commands below assume `$NAMESPACE` is set. If you skip this, substitute
`financeflow-workshop` manually.

---

## Part A — Cluster Preparation (cluster-admin, run once per cluster)

These steps install the operators and cluster-wide settings every later
chapter depends on. One person (the instructor, or whoever has
cluster-admin) runs Part A once; students then each get their own namespace
in Part B.

### A1 — Verify you have cluster-admin

```bash
oc whoami
oc auth can-i '*' '*' --all-namespaces
```

If the second command doesn't print `yes`, stop — the rest of Part A will fail.

### A2 — Install the missing operators

Installs OpenShift Pipelines, GitOps, Service Mesh 3 (Sail Operator), Tempo,
Kiali, OpenTelemetry, and OpenShift Virtualization in one shot via a
Kustomize overlay of Subscriptions:

```bash
oc apply -k chapters/00-prerequisites/manifests/missing-operators/
```

### A3 — Wait for the six `openshift-operators` CSVs to succeed

```bash
watch -n15 "oc get csv -n openshift-operators | grep -iE 'pipelines|gitops|servicemesh|tempo|kiali|opentelemetry'"
```

Wait until every row shows `Succeeded`, then `Ctrl+C`.

### A4 — Wait for OpenShift Virtualization's CSV

`kubevirt-hyperconverged` installs into its own `openshift-cnv` namespace
with its own OperatorGroup — check it separately:

```bash
watch -n15 "oc get csv -n openshift-cnv"
```

Wait for `kubevirt-hyperconverged` to show `Succeeded`.

### A5 — Activate OpenShift Virtualization

The operator is installed, but virtualization itself isn't active until you
create its `HyperConverged` custom resource:

```bash
oc apply -f chapters/00-prerequisites/manifests/hyperconverged.yaml
```

```bash
watch -n15 "oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'"
```

Wait for `True`.

### A6 — Enable user-workload monitoring

Kiali's traffic graphs (Chapter 5) and the app's own ServiceMonitors
(Chapter 7) both need OpenShift's user-workload Prometheus, which is off by
default:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1 && \
  oc patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type=merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}' || \
  oc create configmap cluster-monitoring-config -n openshift-monitoring \
    --from-literal=config.yaml="enableUserWorkload: true"
```

### A7 — Wait for user-workload monitoring pods

```bash
watch -n10 "oc get pods -n openshift-user-workload-monitoring"
```

Wait for `prometheus-user-workload-*` and `thanos-ruler-user-workload-*` to
show `Running`.

### A8 — Enable the Pipelines console plugin

The Pipelines operator installs its console plugin pod but doesn't switch it
on — without this, Developer → Pipelines stays empty in the web console even
though the Pipeline objects exist:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "pipelines-console-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
```

### A9 — Enable the GitOps console plugin

Same gap, same fix — ArgoCD Applications otherwise show nothing in-console:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "gitops-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
```

Part A is complete. Every step below runs as a regular user in their own
namespace.

---

## Part B — Workshop Deployment (per student, 51 steps)

Run these from the repo root. Each step corresponds 1:1 to a step in
`chapters/deploy-demo-resume.sh` — if you need to jump to a specific step by
name instead of typing everything by hand, `./chapters/deploy-demo-resume.sh --list`
prints the same 51 titles with their numbers.

### Chapter 0 — Namespace

**Step 1 — Create the namespace**

Every resource in this workshop lives in one namespace, isolated per student.

```bash
oc new-project "$NAMESPACE" --display-name="FinanceFlow Workshop"
oc project "$NAMESPACE"
```

**Step 2 — Create the ServiceAccounts**

Chapter 2's Deployment manifests already set `serviceAccountName:
financeflow-app` directly — if that ServiceAccount doesn't exist yet, pod
admission fails outright with `serviceaccount financeflow-app not found`.
Create both ServiceAccounts now, ahead of Chapter 4 where they're formally
introduced:

```bash
oc apply -f chapters/04-security/manifests/serviceaccount-financeflow.yaml
oc apply -f chapters/04-security/manifests/serviceaccount-cicd.yaml
```

---

### Chapter 1 — Builds

**Step 3 — Create ImageStreams**

```bash
oc apply -f chapters/01-builds/manifests/imagestream-account.yaml
oc apply -f chapters/01-builds/manifests/imagestream-transaction.yaml
oc apply -f chapters/01-builds/manifests/imagestream-portal.yaml
```

**Step 4 — Create BuildConfigs**

```bash
oc apply -f chapters/01-builds/manifests/buildconfig-account.yaml
oc apply -f chapters/01-builds/manifests/buildconfig-transaction.yaml
oc apply -f chapters/01-builds/manifests/buildconfig-portal-docker.yaml
```

**Step 5 — Build and push `financeflow-account:v1.0`**

```bash
oc start-build financeflow-account --from-dir=app/account-service --follow
```

**Step 6 — Build and push `financeflow-transaction:v1.0`**

```bash
oc start-build financeflow-transaction --from-dir=app/transaction-service --follow
```

**Step 7 — Build and push `financeflow-portal:v1.0`**

```bash
oc start-build financeflow-portal --from-dir=app/portal --follow
```

**Step 8 — Pin Chapter 2 manifests to the `:v1.0` tag you just built**

Chapter 6's CI pipeline rewrites these two Deployment files to a full git-SHA
image tag on every webhook-triggered build. That SHA only exists in the
registry of whichever cluster built it — on a fresh cluster the tag is gone.
Force both files back to `:v1.0` (what you just built above) so git matches
the live cluster before Chapter 6 creates the ArgoCD Application:

```bash
sed -i "s|image: financeflow-account:.*|image: financeflow-account:v1.0|" \
  chapters/02-deployments/manifests/deployment-account-service.yaml
sed -i "s|image: financeflow-transaction:.*|image: financeflow-transaction:v1.0|" \
  chapters/02-deployments/manifests/deployment-transaction-service.yaml
```

If you're going to commit/push this repo yourself (needed only if you'll
run the Chapter 6 CI/CD steps later), commit the change now so git matches
what you just built:

```bash
git add chapters/02-deployments/manifests/deployment-account-service.yaml \
        chapters/02-deployments/manifests/deployment-transaction-service.yaml
git commit -m "ci: pin account/transaction-service to v1.0 for fresh-cluster deploy [skip ci]"
git push origin HEAD:refs/heads/main
```

---

### Chapter 2 — Deployments

**Step 9 — Create the `postgres-credentials` Secret**

Created imperatively — never commit a real password to git:

```bash
POSTGRES_PASSWORD=$(openssl rand -base64 24)
oc create secret generic postgres-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=POSTGRES_USER=financeflow \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB=financeflow \
  --from-literal=DB_USER=financeflow \
  --from-literal=DB_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=DB_NAME=financeflow
echo "Generated postgres password (save this): $POSTGRES_PASSWORD"
```

**Step 10 — Apply PVC, ConfigMaps, Postgres Deployment + Service**

```bash
oc apply -f chapters/02-deployments/manifests/pvc-postgres.yaml
oc apply -f chapters/02-deployments/manifests/configmap-account-service.yaml
oc apply -f chapters/02-deployments/manifests/configmap-transaction-service.yaml
oc apply -f chapters/02-deployments/manifests/configmap-portal-nginx.yaml
oc apply -f chapters/02-deployments/manifests/configmap-postgres-init.yaml
oc apply -f chapters/02-deployments/manifests/deployment-postgres.yaml
oc apply -f chapters/02-deployments/manifests/service-postgres.yaml
oc rollout status deployment/postgres --timeout=180s
```

**Step 11 — Apply account-service Deployment + Service**

```bash
oc apply -f chapters/02-deployments/manifests/deployment-account-service.yaml
oc apply -f chapters/02-deployments/manifests/service-account-service.yaml
oc rollout status deployment/account-service --timeout=180s
```

**Step 12 — Apply transaction-service Deployment + Service**

```bash
oc apply -f chapters/02-deployments/manifests/deployment-transaction-service.yaml
oc apply -f chapters/02-deployments/manifests/service-transaction-service.yaml
oc rollout status deployment/transaction-service --timeout=180s
```

**Step 13 — Apply portal Deployment + Service**

```bash
oc apply -f chapters/02-deployments/manifests/deployment-portal.yaml
oc apply -f chapters/02-deployments/manifests/service-portal.yaml
oc rollout status deployment/portal --timeout=180s
```

**Step 14 — Apply the account-service HPA**

```bash
oc apply -f chapters/02-deployments/manifests/hpa-account-service.yaml
```

---

### Chapter 3 — Networking

**Step 15 — Apply the portal Route**

```bash
oc apply -f chapters/03-networking/manifests/route-portal.yaml
echo "Portal: https://$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
```

**Step 16 — Apply NetworkPolicies (deny-all + allow-lists)**

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-deny-all.yaml
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-postgres.yaml
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-account-service.yaml
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-transaction-service.yaml
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-portal.yaml
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-monitoring.yaml
```

**Step 17 — Verify the app is reachable through the Route**

```bash
PORTAL_HOST=$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "portal: HTTP %{http_code}\n" "https://$PORTAL_HOST/health"
```

Expect `HTTP 200`.

---

### Chapter 4 — Security

**Step 18 — Apply the SCC, ClusterRole, Roles, and RoleBindings**

```bash
oc apply -f chapters/04-security/manifests/scc-financeflow.yaml
oc apply -f chapters/04-security/manifests/clusterrole-use-financeflow-scc.yaml
oc apply -f chapters/04-security/manifests/role-viewer.yaml
oc apply -f chapters/04-security/manifests/role-deployer.yaml
oc apply -f chapters/04-security/manifests/rolebinding-viewer.yaml
oc apply -f chapters/04-security/manifests/rolebinding-deployer.yaml
oc apply -f chapters/04-security/manifests/rolebinding-sa-use-scc.yaml
```

**Step 19 — Restart the three app Deployments to pick up `financeflow-scc`**

```bash
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
oc rollout status deployment/account-service --timeout=180s
oc rollout status deployment/transaction-service --timeout=180s
oc rollout status deployment/portal --timeout=180s
```

---

### Chapter 5 — Service Mesh

**Step 20 — Create the Istio control plane (Sail Operator)**

This can take a few minutes — the operator was already installed in Part A,
this step just creates the `Istio`/`IstioCNI` custom resources.

```bash
oc apply -f chapters/05-service-mesh/manifests/smcp.yaml
```

**Step 21 — Wait for Istio to report Healthy**

```bash
watch -n15 "oc get istio default -n istio-system -o jsonpath='{.status.state}'"
```

Wait for `Healthy`.

**Step 22 — Enroll the namespace in the mesh**

Labels the namespace `istio-injection: enabled` — every new pod from now on
gets an Envoy sidecar automatically.

```bash
oc apply -f chapters/05-service-mesh/manifests/smmr.yaml
```

**Step 23 — Restart workloads to inject Envoy sidecars**

Existing pods don't retroactively get a sidecar — only new ones. Restart to
pick it up:

```bash
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
oc rollout status deployment/account-service --timeout=180s
oc rollout status deployment/transaction-service --timeout=180s
oc rollout status deployment/portal --timeout=180s
```

Confirm every pod now shows `2/2` containers: `oc get pods`.

**Step 24 — Apply mTLS policy, DestinationRules, and the canary VirtualService**

```bash
oc apply -f chapters/05-service-mesh/manifests/peerauthentication-mtls.yaml
oc apply -f chapters/05-service-mesh/manifests/destinationrule-account-service.yaml
oc apply -f chapters/05-service-mesh/manifests/destinationrule-transaction-service.yaml
oc apply -f chapters/05-service-mesh/manifests/virtualservice-account-service.yaml
```

**Step 25 — Deploy the account-service canary (v1.1)**

Reuses the already-built v1.0 image under a new tag — purely to demonstrate
traffic splitting, no new code:

```bash
oc tag "$NAMESPACE/financeflow-account:v1.0" "$NAMESPACE/financeflow-account:v1.1"
oc apply -f chapters/05-service-mesh/manifests/deployment-account-service-v11.yaml
```

**Step 26 — Deploy Kiali and grant it cluster-monitoring-view**

```bash
oc apply -f chapters/05-service-mesh/manifests/kiali.yaml
oc apply -f chapters/05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml
```

**Step 27 — Confirm user-workload monitoring is enabled**

Already done in Part A (Steps A6–A7) — this is a same-idempotent re-check,
harmless to re-run:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}'
```

Should contain `enableUserWorkload: true`.

**Step 28 — Grant the monitoring SA scrape permission, apply the sidecar PodMonitor**

```bash
oc adm policy add-role-to-user \
  view \
  system:serviceaccount:openshift-user-workload-monitoring:prometheus-user-workload \
  -n "$NAMESPACE"
oc apply -f chapters/05-service-mesh/manifests/podmonitor-istio-sidecar.yaml
```

**Step 29 — Wait for the Kiali dashboard to come up**

```bash
oc rollout status deployment/kiali -n istio-system --timeout=180s
KIALI_HOST=$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "kiali: HTTP %{http_code}\n" "https://$KIALI_HOST/"
```

**Step 30 — Generate traffic so the mesh has something to report**

```bash
oc exec deployment/portal -n "$NAMESPACE" -- sh -c \
  "for i in \$(seq 1 60); do wget -qO- http://account-service:8080/api/accounts >/dev/null 2>&1; sleep 0.2; done"
```

**Step 31 — Verify `istio_requests_total` metrics reached Thanos**

```bash
KIALI_TOKEN=$(oc create token kiali-service-account -n istio-system --duration=10m)
oc exec deployment/portal -n "$NAMESPACE" -- wget -qO- \
  --no-check-certificate \
  --header="Authorization: Bearer $KIALI_TOKEN" \
  "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091/api/v1/query?query=istio_requests_total%7Bdestination_service_name%3D%22account-service%22%2Cdestination_service_namespace%3D%22$NAMESPACE%22%7D"
```

Look for `"result":[{` in the output. If empty, wait ~30–60s (scrape interval
is 15s) and re-check before assuming Step 28 failed.

---

### Chapter 6 — CI/CD

> Needs a GitHub fork of this repo and a Personal Access Token (repo scope).
> Skip this chapter if you're only doing a local demo.

**Step 32 — Confirm the Pipelines and GitOps console plugins are enabled**

Already done in Part A (Steps A8–A9) — idempotent re-check:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

Should list both `pipelines-console-plugin` and `gitops-plugin`.

**Step 33 — Grant `financeflow-cicd` permission to push images and run buildah**

```bash
oc adm policy add-role-to-user \
  registry-editor \
  "system:serviceaccount:$NAMESPACE:financeflow-cicd"
oc adm policy add-scc-to-user pipelines-scc \
  -z financeflow-cicd \
  -n "$NAMESPACE"
```

> Use `pipelines-scc`, not `privileged` — `pipelines-scc`'s `fsGroup:
> MustRunAs` auto-derives a writable group for the shared pipeline-source PVC
> from this namespace's allocated range. `privileged`'s `fsGroup: RunAsAny`
> assigns nothing, forcing a hardcoded GID that breaks if the namespace is
> ever recreated with a different range.

**Step 34 — Create the GitHub webhook Secret**

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
oc create secret generic github-webhook-secret \
  --from-literal=secret="$WEBHOOK_SECRET" \
  -n "$NAMESPACE"
echo "Webhook secret (register this in GitHub): $WEBHOOK_SECRET"
```

**Step 35 — Create git push credentials for the pipeline**

The pipeline's `update-manifest` task pushes a commit back to your repo —
give it its own credentials, then link the Secret to the `financeflow-cicd`
ServiceAccount so Tekton auto-injects it into every task pod:

```bash
read -rp "GitHub username: " GITHUB_USERNAME
read -rsp "GitHub PAT (repo scope, input hidden): " GITHUB_PAT; echo
oc create secret generic git-credentials-cicd \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITHUB_USERNAME" \
  --from-literal=password="$GITHUB_PAT" \
  -n "$NAMESPACE"
oc annotate secret git-credentials-cicd tekton.dev/git-0=https://github.com -n "$NAMESPACE"
oc secrets link financeflow-cicd git-credentials-cicd -n "$NAMESPACE"
```

**Step 36 — Label the namespace for ArgoCD**

Without this label, the GitOps operator never creates the RoleBinding that
lets ArgoCD manage resources in your namespace — `Deployment`/`Service`/`HPA`
syncs would fail with `forbidden`:

```bash
oc label namespace "$NAMESPACE" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
```

**Step 37 — Apply the Tekton Pipeline, Tasks, and pipeline-source PVC**

```bash
oc apply -f chapters/06-cicd/manifests/pvc-pipeline-source.yaml
oc apply -f chapters/06-cicd/manifests/task-run-tests.yaml
oc apply -f chapters/06-cicd/manifests/task-update-manifest.yaml
oc apply -f chapters/06-cicd/manifests/pipeline-financeflow.yaml
```

**Step 38 — Apply the webhook Trigger chain**

```bash
oc apply -f chapters/06-cicd/manifests/triggerbinding-github.yaml
oc apply -f chapters/06-cicd/manifests/triggertemplate-financeflow.yaml
oc apply -f chapters/06-cicd/manifests/eventlistener.yaml
oc apply -f chapters/06-cicd/manifests/route-eventlistener.yaml
oc apply -f chapters/06-cicd/manifests/networkpolicy-allow-router-to-webhook.yaml
oc apply -f chapters/06-cicd/manifests/peerauthentication-webhook-ingress-permissive.yaml
```

**Step 39 — Apply the ArgoCD AppProject and Application**

These go into ArgoCD's own namespace, `openshift-gitops`:

```bash
oc apply -f chapters/06-cicd/manifests/argocd-project.yaml -n openshift-gitops
oc apply -f chapters/06-cicd/manifests/argocd-app-financeflow.yaml -n openshift-gitops
echo "ArgoCD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
echo "ArgoCD admin password: $(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password)"
```

**Step 40 — Trigger a manual PipelineRun for account-service**

```bash
oc create -f chapters/06-cicd/manifests/pipelinerun-account-service.yaml
```

**Step 41 — Trigger a manual PipelineRun for transaction-service**

```bash
oc create -f chapters/06-cicd/manifests/pipelinerun-transaction-service.yaml
```

Watch either run with:
```bash
PRUN=$(oc get pipelinerun --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
oc logs -f "pipelineruns/$PRUN" --all-containers
```

To complete the loop, register the webhook in GitHub (Settings → Webhooks)
using the Route from Step 38 and the secret from Step 34 — see
`content/06-cicd.md` Lab 6f for the full walkthrough.

---

### Chapter 7 — Observability

**Step 42 — Install the Grafana Operator**

Not part of Part A's operator batch — installed here, scoped to its own
`grafana` namespace:

```bash
oc apply -f chapters/07-observability/manifests/grafana/namespace.yaml
oc apply -f chapters/07-observability/manifests/grafana/operatorgroup.yaml
oc apply -f chapters/07-observability/manifests/grafana/subscription.yaml
oc apply -f chapters/07-observability/manifests/grafana/serviceaccount.yaml
```

```bash
watch -n10 "oc get pods -n grafana -l app.kubernetes.io/name=grafana-operator"
```

Wait for the pod to exist and reach `Running`/`Ready`.

**Step 43 — Generate the Thanos bearer token Secret for Grafana**

```bash
TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
oc create secret generic grafana-thanos-bearer-token \
  --from-literal=BEARER_TOKEN="Bearer $TOKEN" \
  -n grafana --dry-run=client -o yaml | oc apply -f -
```

**Step 44 — Deploy the Grafana instance**

```bash
oc apply -f chapters/07-observability/manifests/grafana/grafana.yaml
oc wait --for=condition=GrafanaReady grafana/financeflow-grafana -n grafana --timeout=180s
```

**Step 45 — Apply the Grafana datasource CR**

```bash
oc apply -f chapters/07-observability/manifests/grafana/datasource.yaml
```

**Step 46 — Verify the datasource authenticates**

```bash
GRAFANA_POD=$(oc get pod -n grafana -l app=financeflow-grafana -o jsonpath='{.items[0].metadata.name}')
DS_UID=$(oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['uid'])")
oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources/uid/$DS_UID/health"
```

Expect `{"status":"OK", ...}`.

**Step 47 — Apply the Grafana Route and the Service Mesh dashboard**

```bash
oc apply -f chapters/07-observability/manifests/grafana/route.yaml
oc apply -f chapters/07-observability/manifests/grafana/dashboard-service-mesh.yaml
```

**Step 48 — Apply ServiceMonitors and the PrometheusRule**

```bash
oc apply -f chapters/07-observability/manifests/servicemonitor-account-service.yaml
oc apply -f chapters/07-observability/manifests/servicemonitor-transaction-service.yaml
oc apply -f chapters/07-observability/manifests/prometheusrule-financeflow.yaml
```

**Step 49 — Deploy Tempo and its mTLS/NetworkPolicy exceptions**

```bash
oc apply -f chapters/07-observability/manifests/tempo.yaml
oc apply -f chapters/07-observability/manifests/peerauthentication-tempo-ingress-permissive.yaml
oc apply -f chapters/07-observability/manifests/networkpolicy-allow-collector-to-tempo.yaml
```

```bash
watch -n10 "oc get pod tempo-financeflow-0 -n $NAMESPACE"
```

Wait for `Running`.

**Step 50 — Deploy the OTel Collector**

```bash
oc apply -f chapters/07-observability/manifests/otel-collector.yaml
```

**Step 51 — Apply the FinanceFlow overview dashboard**

```bash
oc apply -f chapters/07-observability/manifests/dashboard-financeflow-overview.yaml
```

---

## Final Verification

Run these to confirm everything landed:

```bash
echo "Portal:    https://$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
echo "Kiali:     https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
echo "Grafana:   https://$(oc get route grafana -n grafana -o jsonpath='{.spec.host}')  (admin/financeflow)"
echo "Jaeger UI: https://$(oc get route tempo-financeflow-jaegerui -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
echo "ArgoCD:    https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

If you completed Chapter 6, finish wiring the webhook loop:

1. Register the GitHub webhook (repo → Settings → Webhooks) with the URL
   from Step 38 and the secret from Step 34, event `push` only.
2. `chapters/05-service-mesh/manifests/kiali.yaml`'s Grafana URL is hardcoded
   to whatever cluster it was last edited on — update it to match your
   Grafana route from Step 47 if it doesn't match.

---

## Resuming Mid-Deployment

Every step above is idempotent (`oc apply` on an existing object is a
no-op). If something fails partway through:

1. Fix the underlying issue.
2. Re-run just that step's commands — no need to redo earlier steps.
3. Continue from the next step.

If you'd rather let the script track this for you instead of manually
picking up where you left off, `chapters/deploy-demo-resume.sh --from <step
number or step-title text>` does exactly that — it skips every step before
your chosen start point.

---

*See [content/](content/) for the full concept-and-lab material behind each
of these steps.*
