# Lab 5 — Service Mesh

**Chapter:** 5 | **Duration:** 60 min | **Complexity:** 🔴 Medium–Advanced

---

## Objectives

By the end of this lab you will:
- Install OpenShift Service Mesh and join the FinanceFlow namespace
- Verify automatic sidecar injection
- Enforce mTLS in STRICT mode across the namespace
- Deploy a canary version and split traffic with VirtualService weights
- Observe the live traffic graph in Kiali
- Test circuit breaking with outlier detection

---

## Prerequisites

- Chapters 1–4 complete — all pods Running with the `financeflow-app` service account
- Cluster-admin access (required for OperatorHub and the Istio control plane)
- OpenShift Service Mesh 3 (Sail Operator) installed (Lab 5a)

---

## Lab 5a — Install OpenShift Service Mesh

### Step 1 — Install required operators via OperatorHub

OpenShift Service Mesh 3 depends on three operators. Install them in this order from **Administrator → OperatorHub**:

1. **Red Hat OpenShift Service Mesh 3** (installs the Sail Operator, package `servicemeshoperator3`)
2. **Tempo Operator** (distributed tracing storage/collection — replaces the deprecated Jaeger operator)
3. **Kiali Operator** (provided by Red Hat, package `kiali-ossm`)

For each: search, select, click Install, keep all defaults, wait for `Succeeded`.

```bash
# Verify all operators are ready
oc get csv -n openshift-operators | grep -E "servicemeshoperator3|tempo|kiali"
```

All should show `Succeeded`.

### Step 2 — Create the Istio control plane

OpenShift Service Mesh 3 uses the Sail Operator's `Istio` and `IstioCNI` custom resources (`sailoperator.io/v1`) instead of the old `ServiceMeshControlPlane`:

```bash
oc apply -f chapters/05-service-mesh/manifests/smcp.yaml
```

This creates the `istio-system` and `istio-cni` namespaces plus the `Istio` and `IstioCNI` resources. Wait for the control plane to initialise (3–5 minutes):

```bash
oc get istio -n istio-system -w
```

```
NAME      REVISIONS   READY   IN USE   ACTIVE REVISION   VERSION   AGE
default   1           1       True     default            v1.28.0   4m
```

`READY` must show `1` before continuing.

### Step 3 — Add FinanceFlow namespace to the mesh

OSSM 3 enrolls namespaces with a label rather than a `ServiceMeshMemberRoll`:

```bash
oc apply -f chapters/05-service-mesh/manifests/smmr.yaml

# Verify the namespace was labeled
oc get namespace financeflow-workshop --show-labels | grep istio-injection
# istio-injection=enabled
```

### Step 4 — Enable monitoring so Kiali graphs actually show traffic

Kiali's traffic graphs (used throughout the rest of this lab) read the
`istio_requests_total` metric from Thanos. That metric only exists if
something is scraping the Envoy sidecars into Prometheus — without this step,
every graph stays empty no matter how much traffic you generate later.

```bash
# Enable user-workload monitoring (cluster-admin, one-time)
oc patch configmap cluster-monitoring-config -n openshift-monitoring \
  --type=merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}'

# Wait for it to come up
oc get pods -n openshift-user-workload-monitoring -w
# prometheus-user-workload-0/1, thanos-ruler-user-workload-0 → Running

# Grant the monitoring SA permission to scrape FinanceFlow
oc adm policy add-role-to-user \
  view \
  system:serviceaccount:openshift-user-workload-monitoring:prometheus-user-workload \
  -n financeflow-workshop

# Apply the PodMonitor that scrapes each Envoy sidecar's /stats/prometheus
oc apply -f chapters/05-service-mesh/manifests/podmonitor-istio-sidecar.yaml
```

---

## Lab 5b — Sidecar Injection

### Step 1 — Restart pods to get sidecars injected

Once a namespace has the `istio-injection: enabled` label, existing pods don't automatically get sidecars — only new pods do. Trigger a rollout for each deployment:

```bash
oc rollout restart deployment/account-service
oc rollout restart deployment/transaction-service
oc rollout restart deployment/portal
oc rollout restart deployment/postgres

oc rollout status deployment/account-service
oc rollout status deployment/transaction-service
```

### Step 2 — Verify sidecar injection

Each pod should now show `2/2` containers:

```bash
oc get pods
```

```
NAME                                   READY   STATUS    RESTARTS
account-service-abc123-xxxx            2/2     Running   0
account-service-abc123-yyyy            2/2     Running   0
transaction-service-def456-xxxx        2/2     Running   0
portal-ghi789-xxxx                     2/2     Running   0
postgres-jkl012-xxxx                   2/2     Running   0
```

The second container is the Envoy proxy (`istio-proxy`).

```bash
# Confirm the sidecar container name
oc get pod -l tier=account-service -o jsonpath='{.items[0].spec.containers[*].name}'
# account-service  istio-proxy
```

### Step 3 — Deploy Kiali and open it

```bash
oc apply -f chapters/05-service-mesh/manifests/kiali.yaml

oc wait --for=condition=Successful kiali/kiali -n istio-system --timeout=120s

# Kiali queries Thanos using its own service account token
# (external_services.prometheus.auth.use_kiali_token: true in kiali.yaml) —
# without this binding every graph/health request 403s
oc apply -f chapters/05-service-mesh/manifests/clusterrolebinding-kiali-monitoring.yaml
oc rollout restart deployment/kiali -n istio-system

echo "Kiali: https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
```

Open the URL in your browser. Navigate to **Graph → Namespace: financeflow-workshop**. You should see the four service tiers connected with traffic arrows.

Generate some traffic to populate the graph:

```bash
oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 50); do wget -qO- http://account-service:8080/api/accounts > /dev/null; done"
```

In Kiali, observe:
- Green arrows = successful traffic
- Lock icons = mTLS in PERMISSIVE mode (mixed)
- Request rate, error rate, P99 latency per edge

---

## Lab 5c — Enforce mTLS

### Step 1 — Apply STRICT mTLS

```bash
oc apply -f chapters/05-service-mesh/manifests/peerauthentication-mtls.yaml
```

### Step 2 — Verify STRICT mode is active

```bash
oc describe peerauthentication financeflow-mtls
```

### Step 3 — Confirm plain-text is now rejected

Try connecting to account-service **without** the sidecar (simulating a non-meshed client):

```bash
# Run a plain curl from a pod WITHOUT a sidecar (note: oc run creates a fresh pod)
oc run mtls-test --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --annotations='sidecar.istio.io/inject=false' \
  --command -- sh -c \
  "curl -s http://account-service:8080/health/ready; sleep 3600" &

sleep 10

oc logs mtls-test
# Connection reset by peer  OR  upstream connect error
# The Envoy sidecar on account-service rejected the plain-text connection

oc delete pod mtls-test
```

Meshed pods (with Envoy sidecars) communicate fine — Envoy handles the TLS handshake transparently.

### Step 4 — Check Kiali

Back in Kiali → Graph. All edges between FinanceFlow services should now show a **closed padlock** icon indicating STRICT mTLS.

---

## Lab 5d — Canary Deployment

### Step 1 — Label existing pods as v1.0

The DestinationRule uses `version` labels to route to subsets. Patch the stable deployment:

```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"add","path":"/spec/template/metadata/labels/version","value":"v1.0"}]'

oc rollout status deployment/account-service
```

Verify the pods have the version label:
```bash
oc get pods -l tier=account-service --show-labels
```

### Step 2 — Deploy the canary (v1.1)

```bash
oc apply -f chapters/05-service-mesh/manifests/deployment-account-service-v11.yaml
oc rollout status deployment/account-service-v11
```

You now have:
- `account-service` deployment: 2 pods with `version=v1.0`
- `account-service-v11` deployment: 1 pod with `version=v1.1`

Both deployments are behind the **same** `account-service` Service (matched by `tier=account-service`).

### Step 3 — Apply DestinationRule and VirtualService

```bash
oc apply -f chapters/05-service-mesh/manifests/destinationrule-account-service.yaml
oc apply -f chapters/05-service-mesh/manifests/virtualservice-account-service.yaml
```

### Step 4 — Generate traffic and watch the split in Kiali

```bash
# Continuous load — run for 2 minutes
oc exec -it deployment/portal -- sh -c \
  "for i in \$(seq 1 200); do wget -qO- http://account-service:8080/api/accounts > /dev/null; sleep 0.3; done"
```

In Kiali → Graph, click the `account-service` node. In the right panel you should see:
- ~90% of requests going to v1.0 pods
- ~10% going to the v1.1 pod

### Step 5 — Shift traffic to 50/50

Edit the VirtualService weights live:

```bash
oc patch virtualservice account-service --type=json -p \
  '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
    {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'
```

Generate more traffic and watch Kiali rebalance.

### Step 6 — Full cutover to v1.1

```bash
oc patch virtualservice account-service --type=json -p \
  '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":0},
    {"op":"replace","path":"/spec/http/0/route/1/weight","value":100}]'
```

### Step 7 — Rollback (if needed)

```bash
oc apply -f chapters/05-service-mesh/manifests/virtualservice-account-service-stable.yaml
# All traffic instantly returns to v1.0 — no pod restart required
```

---

## Lab 5e — Circuit Breaking

### Step 1 — Apply DestinationRule for transaction-service

```bash
oc apply -f chapters/05-service-mesh/manifests/destinationrule-transaction-service.yaml
```

### Step 2 — Simulate a failing pod

Break one transaction-service pod by patching its liveness endpoint (from Chapter 2):

```bash
# Get one pod name
POD=$(oc get pod -l tier=transaction-service -o jsonpath='{.items[0].metadata.name}')

# Exec in and make the app return 500
# (In a real scenario, this simulates a DB connection loss)
oc exec $POD -- sh -c "kill -SIGTERM 1" 2>/dev/null || true
# The pod will restart — watch the RESTARTS counter
```

A more controlled approach — inject a bad readiness probe temporarily:

```bash
oc patch deployment transaction-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/broken"}]'
```

### Step 3 — Watch outlier detection in Kiali

In Kiali → Graph, click the `transaction-service` node. After 3 consecutive failures within 30s, the outlier detection ejects the unhealthy pod from the load balancer pool. Kiali shows the ejected pod in red.

### Step 4 — Restore

```bash
oc patch deployment transaction-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/ready"}]'
```

---

## Checkpoint

```bash
# Control plane ready
oc get istio -n istio-system
oc get istiocni -n istio-cni

# Namespace in mesh
oc get namespace financeflow-workshop --show-labels | grep istio-injection

# All pods have sidecars (2/2)
oc get pods

# mTLS policy active
oc get peerauthentication

# Traffic policies applied
oc get destinationrule
oc get virtualservice

# Kiali accessible
oc get route kiali -n istio-system

# Monitoring pipeline feeding Kiali's graphs
oc get pods -n openshift-user-workload-monitoring
oc get podmonitor istio-sidecar-metrics
oc get clusterrolebinding kiali-cluster-monitoring-view
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pods stuck at `1/2` containers | Namespace missing `istio-injection: enabled` label | `oc get namespace financeflow-workshop --show-labels` — reapply `smmr.yaml` |
| Kiali shows no graph | No traffic generated or wrong namespace selected | Run load loop; check namespace selector in Kiali |
| `upstream connect error` after mTLS STRICT | A pod doesn't have a sidecar | Ensure all pods show `2/2`; restart any `1/1` pods |
| VirtualService not splitting traffic | DestinationRule subsets don't match pod labels | `oc get pods --show-labels` — confirm `version=v1.0/v1.1` |
| `Istio` resource stuck, `READY` not `1` | Operator not fully installed | Check CSVs: `oc get csv -n openshift-operators` |

---

## Key Takeaways

- The sidecar intercepts all traffic — the application code is never modified
- PERMISSIVE mTLS allows gradual mesh adoption; STRICT enforces it — start permissive, finish strict
- DestinationRule defines **subsets** (pods by label); VirtualService defines **weights** (traffic split)
- Canary shifts are a one-line `weight` change — no deployment rollout, instant rollback
- Kiali is the single pane of glass: topology, RED metrics, mTLS status, and tracing in one view

---

*Next: [Lab 6 — CI/CD Pipelines & GitOps](../../06-cicd/lab/06-cicd.md)*
