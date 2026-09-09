# Deploy Guide — Cluster Admin

**FinanceFlow Workshop — OpenShift Container Capabilities**

Full end-to-end deploy for someone with **cluster-admin** access: one-time
cluster prep, then all 51 steps of the workshop, then (optionally) how to
hand self-service access to a normal user so they can run the workshop
themselves.

All commands below assume your shell's current directory is `chapters/`
inside this repo.

---

## Before You Start

- `oc` CLI installed, logged in with cluster-admin access
- Repo cloned, `cd chapters` before running anything here

Set the namespace once, in every terminal you use for this guide:

```bash
export NAMESPACE=financeflow-workshop
```

---

## Part A — One-time cluster prep

Installs operators and cluster-wide settings every later chapter depends
on. Run once per cluster.

### A1 — Verify you have cluster-admin

```bash
oc whoami
oc auth can-i '*' '*' --all-namespaces
```

If the second command doesn't print `yes`, stop here.

### A2 — Install the missing operators

Installs OpenShift Pipelines, GitOps, Service Mesh 3 (Sail Operator), Tempo,
Kiali, OpenTelemetry, and OpenShift Virtualization in one shot:

```bash
oc apply -k 00-prerequisites/manifests/missing-operators/
```

### A3 — Wait for the six `openshift-operators` CSVs to succeed

```bash
watch -n15 "oc get csv -n openshift-operators | grep -iE 'pipelines|gitops|servicemesh|tempo|kiali|opentelemetry'"
```

Wait until every row shows `Succeeded`, then `Ctrl+C`.

### A4 — Wait for OpenShift Virtualization's CSV

```bash
watch -n15 "oc get csv -n openshift-cnv"
```

Wait for `kubevirt-hyperconverged` to show `Succeeded`.

### A5 — Activate OpenShift Virtualization

```bash
oc apply -f 00-prerequisites/manifests/hyperconverged.yaml
watch -n15 "oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'"
```

Wait for `True`.

### A6 — Enable user-workload monitoring

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

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "pipelines-console-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
```

### A9 — Enable the GitOps console plugin

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "gitops-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
```

---

## Part B — Full workshop deploy (51 steps)

Cluster-admin can run every step directly. This mirrors
`./deploy-demo-resume.sh --list` 1:1 — 51 steps, Chapters 0–7.

### Chapter 0 — Namespace

**Step 1 — Create the namespace**

```bash
oc new-project "$NAMESPACE" --display-name="FinanceFlow Workshop"
oc project "$NAMESPACE"
```

**Step 2 — Create the ServiceAccounts**

```bash
oc apply -f 04-security/manifests/serviceaccount-financeflow.yaml
oc apply -f 04-security/manifests/serviceaccount-cicd.yaml
```

### Chapter 1 — Builds

**Step 3 — Create ImageStreams**

```bash
oc apply -f 01-builds/manifests/imagestream-account.yaml
oc apply -f 01-builds/manifests/imagestream-transaction.yaml
oc apply -f 01-builds/manifests/imagestream-portal.yaml
```

**Step 4 — Create BuildConfigs**

```bash
oc apply -f 01-builds/manifests/buildconfig-account.yaml
oc apply -f 01-builds/manifests/buildconfig-transaction.yaml
oc apply -f 01-builds/manifests/buildconfig-portal-docker.yaml
```

**Step 5 — Build and push `financeflow-account:v1.0`**

```bash
oc start-build financeflow-account --from-dir=../app/account-service --follow
```

**Step 6 — Build and push `financeflow-transaction:v1.0`**

```bash
oc start-build financeflow-transaction --from-dir=../app/transaction-service --follow
```

**Step 7 — Build and push `financeflow-portal:v1.0`**

```bash
oc start-build financeflow-portal --from-dir=../app/portal --follow
```

**Step 8 — Pin Chapter 2 manifests to the `:v1.0` tag you just built**

```bash
sed -i "s|image: financeflow-account:.*|image: financeflow-account:v1.0|" \
  02-deployments/manifests/deployment-account-service.yaml
sed -i "s|image: financeflow-transaction:.*|image: financeflow-transaction:v1.0|" \
  02-deployments/manifests/deployment-transaction-service.yaml
```

If you intend to run Chapter 6's CI/CD steps, commit this now so git matches
the cluster:

```bash
git add 02-deployments/manifests/deployment-account-service.yaml \
        02-deployments/manifests/deployment-transaction-service.yaml
git commit -m "ci: pin account/transaction-service to v1.0 for fresh-cluster deploy [skip ci]"
git push origin HEAD:refs/heads/main
```

### Chapter 2 — Deployments

**Step 9 — Create the `postgres-credentials` Secret**

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
oc apply -f 02-deployments/manifests/pvc-postgres.yaml
oc apply -f 02-deployments/manifests/configmap-account-service.yaml
oc apply -f 02-deployments/manifests/configmap-transaction-service.yaml
oc apply -f 02-deployments/manifests/configmap-portal-nginx.yaml
oc apply -f 02-deployments/manifests/configmap-postgres-init.yaml
oc apply -f 02-deployments/manifests/deployment-postgres.yaml
oc apply -f 02-deployments/manifests/service-postgres.yaml
oc rollout status deployment/postgres --timeout=180s
```

**Step 11 — Apply account-service Deployment + Service**

```bash
oc apply -f 02-deployments/manifests/deployment-account-service.yaml
oc apply -f 02-deployments/manifests/service-account-service.yaml
oc rollout status deployment/account-service --timeout=180s
```

**Step 12 — Apply transaction-service Deployment + Service**

```bash
oc apply -f 02-deployments/manifests/deployment-transaction-service.yaml
oc apply -f 02-deployments/manifests/service-transaction-service.yaml
oc rollout status deployment/transaction-service --timeout=180s
```

**Step 13 — Apply portal Deployment + Service**

```bash
oc apply -f 02-deployments/manifests/deployment-portal.yaml
oc apply -f 02-deployments/manifests/service-portal.yaml
oc rollout status deployment/portal --timeout=180s
```

**Step 14 — Apply the account-service HPA**

```bash
oc apply -f 02-deployments/manifests/hpa-account-service.yaml
```

### Chapter 3 — Networking

**Step 15 — Apply the portal Route**

```bash
oc apply -f 03-networking/manifests/route-portal.yaml
echo "Portal: https://$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
```

**Step 16 — Apply NetworkPolicies (deny-all + allow-lists)**

```bash
oc apply -f 03-networking/manifests/networkpolicy-deny-all.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-postgres.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-account-service.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-transaction-service.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-portal.yaml
oc apply -f 03-networking/manifests/networkpolicy-allow-monitoring.yaml
```

**Step 17 — Verify the app is reachable through the Route**

```bash
PORTAL_HOST=$(oc get route portal -n "$NAMESPACE" -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "portal: HTTP %{http_code}\n" "https://$PORTAL_HOST/health"
```

Expect `HTTP 200`.

### Chapter 4 — Security

**Step 18 — Apply the SCC, ClusterRole, Roles, and RoleBindings**

```bash
oc apply -f 04-security/manifests/scc-financeflow.yaml
oc apply -f 04-security/manifests/clusterrole-use-financeflow-scc.yaml
oc apply -f 04-security/manifests/role-viewer.yaml
oc apply -f 04-security/manifests/role-deployer.yaml
oc apply -f 04-security/manifests/rolebinding-viewer.yaml
oc apply -f 04-security/manifests/rolebinding-deployer.yaml
oc apply -f 04-security/manifests/rolebinding-sa-use-scc.yaml
```

**Step 19 — Restart the three app Deployments to pick up `financeflow-scc`**

```bash
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
oc rollout status deployment/account-service --timeout=180s
oc rollout status deployment/transaction-service --timeout=180s
oc rollout status deployment/portal --timeout=180s
```

### Chapter 5 — Service Mesh

**Step 20 — Create the Istio control plane (Sail Operator)**

```bash
oc apply -f 05-service-mesh/manifests/smcp.yaml
```

**Step 21 — Wait for Istio to report Healthy**

```bash
watch -n15 "oc get istio default -n istio-system -o jsonpath='{.status.state}'"
```

**Step 22 — Enroll the namespace in the mesh**

```bash
oc apply -f 05-service-mesh/manifests/smmr.yaml
```

**Step 23 — Restart workloads to inject Envoy sidecars**

```bash
oc rollout restart deployment/account-service deployment/transaction-service deployment/portal -n "$NAMESPACE"
oc rollout status deployment/account-service --timeout=180s
oc rollout status deployment/transaction-service --timeout=180s
oc rollout status deployment/portal --timeout=180s
```

Confirm every pod now shows `2/2` containers: `oc get pods`.

**Step 24 — Apply mTLS policy, DestinationRules, and the canary VirtualService**

```bash
oc apply -f 05-service-mesh/manifests/peerauthentication-mtls.yaml
oc apply -f 05-service-mesh/manifests/destinationrule-account-service.yaml
oc apply -f 05-service-mesh/manifests/destinationrule-transaction-service.yaml
oc apply -f 05-service-mesh/manifests/virtualservice-account-service.yaml
```

**Step 25 — Deploy the account-service canary (v1.1)**

```bash
oc tag "$NAMESPACE/financeflow-account:v1.0" "$NAMESPACE/financeflow-account:v1.1"
oc apply -f 05-service-mesh/manifests/deployment-account-service-v11.yaml
```

**Step 26 — Deploy Kiali and grant it cluster-monitoring-view**

```bash
oc apply -f 05-service-mesh/manifests/kiali.yaml
oc apply -f 05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml
```

**Step 27 — Confirm user-workload monitoring is enabled**

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
oc apply -f 05-service-mesh/manifests/podmonitor-istio-sidecar.yaml
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

Look for `"result":[{` in the output. If empty, wait ~30–60s and re-check.

### Chapter 6 — CI/CD

> Needs a GitHub fork of this repo and a Personal Access Token (repo scope).

**Step 32 — Confirm the Pipelines and GitOps console plugins are enabled**

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

**Step 33 — Grant `financeflow-cicd` permission to push images and run buildah**

```bash
oc adm policy add-role-to-user \
  registry-editor \
  "system:serviceaccount:$NAMESPACE:financeflow-cicd"
oc adm policy add-scc-to-user pipelines-scc \
  -z financeflow-cicd \
  -n "$NAMESPACE"
```

**Step 34 — Create the GitHub webhook Secret**

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
oc create secret generic github-webhook-secret \
  --from-literal=secret="$WEBHOOK_SECRET" \
  -n "$NAMESPACE"
echo "Webhook secret (register this in GitHub): $WEBHOOK_SECRET"
```

**Step 35 — Create git push credentials for the pipeline**

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

```bash
oc label namespace "$NAMESPACE" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
```

**Step 37 — Apply the Tekton Pipeline, Tasks, and pipeline-source PVC**

```bash
oc apply -f 06-cicd/manifests/pvc-pipeline-source.yaml
oc apply -f 06-cicd/manifests/task-run-tests.yaml
oc apply -f 06-cicd/manifests/task-update-manifest.yaml
oc apply -f 06-cicd/manifests/pipeline-financeflow.yaml
```

**Step 38 — Apply the webhook Trigger chain**

```bash
oc apply -f 06-cicd/manifests/triggerbinding-github.yaml
oc apply -f 06-cicd/manifests/triggertemplate-financeflow.yaml
oc apply -f 06-cicd/manifests/eventlistener.yaml
oc apply -f 06-cicd/manifests/route-eventlistener.yaml
oc apply -f 06-cicd/manifests/networkpolicy-allow-router-to-webhook.yaml
oc apply -f 06-cicd/manifests/peerauthentication-webhook-ingress-permissive.yaml
```

**Step 39 — Apply the ArgoCD AppProject and Application**

```bash
oc apply -f 06-cicd/manifests/argocd-project.yaml -n openshift-gitops
oc apply -f 06-cicd/manifests/argocd-app-financeflow.yaml -n openshift-gitops
echo "ArgoCD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
echo "ArgoCD admin password: $(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password)"
```

**Step 40 — Trigger a manual PipelineRun for account-service**

```bash
oc create -f 06-cicd/manifests/pipelinerun-account-service.yaml
```

**Step 41 — Trigger a manual PipelineRun for transaction-service**

```bash
oc create -f 06-cicd/manifests/pipelinerun-transaction-service.yaml
```

```bash
PRUN=$(oc get pipelinerun --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
oc logs -f "pipelineruns/$PRUN" --all-containers
```

### Chapter 7 — Observability

**Step 42 — Install the Grafana Operator**

```bash
oc apply -f 07-observability/manifests/grafana/namespace.yaml
oc apply -f 07-observability/manifests/grafana/operatorgroup.yaml
oc apply -f 07-observability/manifests/grafana/subscription.yaml
oc apply -f 07-observability/manifests/grafana/serviceaccount.yaml
watch -n10 "oc get pods -n grafana -l app.kubernetes.io/name=grafana-operator"
```

**Step 43 — Generate the Thanos bearer token Secret for Grafana**

```bash
TOKEN=$(oc create token grafana-sa -n grafana --duration=8760h)
oc create secret generic grafana-thanos-bearer-token \
  --from-literal=BEARER_TOKEN="Bearer $TOKEN" \
  -n grafana --dry-run=client -o yaml | oc apply -f -
```

**Step 44 — Deploy the Grafana instance**

```bash
oc apply -f 07-observability/manifests/grafana/grafana.yaml
oc wait --for=condition=GrafanaReady grafana/financeflow-grafana -n grafana --timeout=180s
```

**Step 45 — Apply the Grafana datasource CR**

```bash
oc apply -f 07-observability/manifests/grafana/datasource.yaml
```

**Step 46 — Verify the datasource authenticates**

```bash
GRAFANA_POD=$(oc get pod -n grafana -l app=financeflow-grafana -o jsonpath='{.items[0].metadata.name}')
DS_UID=$(oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['uid'])")
oc exec -n grafana "$GRAFANA_POD" -c grafana -- curl -s -u admin:financeflow \
  "http://localhost:3000/api/datasources/uid/$DS_UID/health"
```

**Step 47 — Apply the Grafana Route and the Service Mesh dashboard**

```bash
oc apply -f 07-observability/manifests/grafana/route.yaml
oc apply -f 07-observability/manifests/grafana/dashboard-service-mesh.yaml
```

**Step 48 — Apply ServiceMonitors and the PrometheusRule**

```bash
oc apply -f 07-observability/manifests/servicemonitor-account-service.yaml
oc apply -f 07-observability/manifests/servicemonitor-transaction-service.yaml
oc apply -f 07-observability/manifests/prometheusrule-financeflow.yaml
```

**Step 49 — Deploy Tempo and its mTLS/NetworkPolicy exceptions**

```bash
oc apply -f 07-observability/manifests/tempo.yaml
oc apply -f 07-observability/manifests/peerauthentication-tempo-ingress-permissive.yaml
oc apply -f 07-observability/manifests/networkpolicy-allow-collector-to-tempo.yaml
watch -n10 "oc get pod tempo-financeflow-0 -n $NAMESPACE"
```

**Step 50 — Deploy the OTel Collector**

```bash
oc apply -f 07-observability/manifests/otel-collector.yaml
```

**Step 51 — Apply the FinanceFlow overview dashboard**

```bash
oc apply -f 07-observability/manifests/dashboard-financeflow-overview.yaml
```

---

## Part C — Granting a normal user self-service access

Everything in Part B ran as cluster-admin without friction. A normal
project-admin user hits three walls the moment they try to run the same
steps themselves — all because a handful of objects in Chapters 4 and 5 are
**cluster-scoped**, and RBAC-granting itself needs elevated authority. Grant
the following before handing a student `chapters/Deploy-Guide-NormalUser.md`.

### C1 — Let the user create their own namespace

Either grant self-provisioning cluster-wide (usually already on by
default):

```bash
oc adm policy add-cluster-role-to-user self-provisioner <username>
```

or, if self-provisioning is locked down on this cluster, pre-create the
namespace yourself and make them `admin` of it:

```bash
oc new-project financeflow-<username> --display-name="FinanceFlow Workshop"
oc adm policy add-role-to-user admin <username> -n financeflow-<username>
```

Use `admin`, not `edit` — Step 28/33-equivalent commands the user runs later
(`oc adm policy add-role-to-user`, `oc adm policy add-scc-to-user`) require
`admin`'s bind authority on the namespace; `edit` cannot grant roles to
other subjects even within its own namespace.

### C2 — Pre-apply the cluster-scoped Chapter 4/5 objects

Step 18 (`scc-financeflow.yaml`, `clusterrole-use-financeflow-scc.yaml`) and
Step 26 (`clusterrolebinding-kiali-monitoring.yaml`) create a
`SecurityContextConstraints`, a `ClusterRole`, and a `ClusterRoleBinding` —
all cluster-scoped kinds. A normal user, even with `admin` on their own
namespace, cannot create these. Two options:

**Option 1 (simplest) — apply them once, cluster-admin does it for every
student, before they start:**

```bash
oc apply -f 04-security/manifests/scc-financeflow.yaml
oc apply -f 04-security/manifests/clusterrole-use-financeflow-scc.yaml
oc apply -f 05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml
```

These three objects are not namespace-specific — applying them once covers
every student's namespace. In `Deploy-Guide-NormalUser.md`, the user then
skips re-applying these three files at Steps 18/26 (their own RoleBindings
in Step 18 still apply fine, since those are namespaced).

**Option 2 — grant the user rights to create these objects themselves:**

```bash
oc create clusterrole financeflow-cluster-object-admin \
  --verb=get,list,create,apply \
  --resource=securitycontextconstraints.security.openshift.io,clusterroles.rbac.authorization.k8s.io,clusterrolebindings.rbac.authorization.k8s.io \
  --dry-run=client -o yaml | oc apply -f -
oc adm policy add-cluster-role-to-user financeflow-cluster-object-admin <username>
```

This is broader than Option 1 (it's a standing cluster-wide grant, not a
one-time apply) — prefer Option 1 for a workshop unless students genuinely
need to author their own SCC/ClusterRole objects.

### C3 — Verify

```bash
oc auth can-i create securitycontextconstraints --as=<username>
oc auth can-i create clusterrolebindings --as=<username>
oc auth can-i new-project --as=<username>
```

With Option 1 the first two will still say `no` for the user — that's
expected, since cluster-admin applied those objects on their behalf and the
user's own script run will skip re-creating them.

---

*See [Deploy-Guide-NormalUser.md](Deploy-Guide-NormalUser.md) for the
student-facing copy-paste guide, and
[content/](content/) for the full concept-and-lab material behind each step.*
