# Lab 2 — Deployments & Scaling

**Chapter:** 2 | **Duration:** 60 min | **Complexity:** 🟡 Easy–Medium

---

## Objectives

By the end of this lab you will:
- Deploy the full 4-tier FinanceFlow stack using the images built in Chapter 1
- Understand the difference between `livenessProbe`, `readinessProbe`, and `startupProbe`
- Observe zero-downtime rolling updates in action
- Configure a Horizontal Pod Autoscaler and watch it respond to load
- Understand resource requests/limits and why they matter for scheduling

---

## Prerequisites

- Chapter 1 complete — all three ImageStreamTags exist:
  ```bash
  oc get imagestreamtag financeflow-account:v1.0
  oc get imagestreamtag financeflow-transaction:v1.0
  oc get imagestreamtag financeflow-portal:v1.0
  ```

---

## Background: Deployment vs DeploymentConfig

OpenShift supports two types:

| | `Deployment` | `DeploymentConfig` |
|--|--|--|
| Origin | Kubernetes native | OpenShift-specific (legacy) |
| Triggers | External (CI/CD, HPA) | Built-in (image change, config change) |
| Use today? | **Yes — preferred** | Legacy systems only |

We use `Deployment` throughout this workshop. ImageStream change triggers are handled by the CI/CD pipeline in Chapter 6.

---

## Lab 2a — Deploy the Database

### Step 1 — Create the Secret

Never put real passwords in YAML files committed to git. Create the secret imperatively:

```bash
oc create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=financeflow \
  --from-literal=POSTGRES_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=POSTGRES_DB=financeflow \
  --from-literal=DB_USER=financeflow \
  --from-literal=DB_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=DB_NAME=financeflow
```

Verify — notice values are base64-encoded, not encrypted:
```bash
oc get secret postgres-credentials -o yaml
oc get secret postgres-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d && echo
```

> **Workshop discussion:** `base64` is encoding, not encryption. Anyone with `oc get secret` access can decode it. OpenShift etcd encryption (Chapter 4) encrypts the underlying storage. For production, use the External Secrets Operator to pull from Vault or AWS Secrets Manager.

### Step 2 — Create the PersistentVolumeClaim

```bash
oc apply -f chapters/02-deployments/manifests/pvc-postgres.yaml
oc get pvc
```

```
NAME            STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
postgres-data   Pending                                       gp3
```

Status is `Pending` until a pod mounts it — that's normal.

### Step 3 — Create the init-script ConfigMap

The database init SQL needs to reach the pod. Create a ConfigMap from the file:

```bash
oc create configmap postgres-init \
  --from-file=init.sql=app/database/init.sql
```

### Step 4 — Deploy PostgreSQL

```bash
oc apply -f chapters/02-deployments/manifests/deployment-postgres.yaml
oc get pods -w
```

Wait for `Running 1/1`. Notice the PVC status changes to `Bound`:
```bash
oc get pvc
```

### Step 5 — Create the postgres Service

The account and transaction services connect to the database by the hostname `postgres` (see `DB_HOST` in their ConfigMaps below). That hostname only resolves once a matching Service exists — create it now, before deploying the dependent services:

```bash
oc apply -f chapters/02-deployments/manifests/service-postgres.yaml
oc get svc postgres
```

### Step 6 — Verify database connectivity

```bash
POD=$(oc get pod -l tier=database -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- psql -U financeflow -d financeflow -c "\dt"
```

You should see the `accounts` and `transactions` tables from the init script.

---

## Lab 2b — Deploy ConfigMaps and Services

### Step 1 — Apply ConfigMaps

```bash
oc apply -f chapters/02-deployments/manifests/configmap-account-service.yaml
oc apply -f chapters/02-deployments/manifests/configmap-transaction-service.yaml
oc get configmaps
```

### Step 2 — Deploy Account Service

```bash
oc apply -f chapters/02-deployments/manifests/deployment-account-service.yaml
oc apply -f chapters/02-deployments/manifests/service-account-service.yaml
oc get pods -w -l tier=account-service
```

Wait for `Running 1/1` on both replicas. The readiness probe queries the database (`SELECT 1`) — without the `account-service` Service in place yet that's fine (nothing depends on its DNS name yet), but the pods *do* need the `postgres` Service from Lab 2a Step 5 to reach `Ready`. If they stay at `0/1`, confirm `oc get svc postgres` exists.

### Step 3 — Deploy Transaction Service and Portal

```bash
oc apply -f chapters/02-deployments/manifests/deployment-transaction-service.yaml
oc apply -f chapters/02-deployments/manifests/service-transaction-service.yaml
oc apply -f chapters/02-deployments/manifests/deployment-portal.yaml
oc apply -f chapters/02-deployments/manifests/service-portal.yaml
oc get pods
```

Expected output — all pods Running and Ready:
```
NAME                                   READY   STATUS    RESTARTS
postgres-7d9f5c-xxxx                   1/1     Running   0
account-service-6b8d4f-xxxx            1/1     Running   0
account-service-6b8d4f-yyyy            1/1     Running   0
transaction-service-5c7f9b-xxxx        1/1     Running   0
transaction-service-5c7f9b-yyyy        1/1     Running   0
portal-4a2c1e-xxxx                     1/1     Running   0
portal-4a2c1e-yyyy                     1/1     Running   0
```

All four Services (`postgres`, `account-service`, `transaction-service`, `portal`) now exist with stable ClusterIPs and DNS names — Chapter 3 builds on top of them with a Route and NetworkPolicies.

### Step 4 — Or apply everything at once with Kustomize

```bash
# Equivalent to all the above — useful for repeatable deploys
oc apply -k chapters/02-deployments/manifests/
```

### Step 5 — Web Console Topology View

Open **Developer → Topology** in the Web Console.  
You should see all 4 tiers connected. This view is the fastest way to spot unhealthy pods during a workshop.

---

## Lab 2c — Health Probes Deep Dive

Your Deployment has three types of probes defined. Let's see each one in action.

### Understand the three probes

| Probe | Fires | On failure |
|-------|-------|-----------|
| `startupProbe` | During startup only | Kills and restarts the container |
| `livenessProbe` | Continuously after startup | Kills and restarts the container |
| `readinessProbe` | Continuously | Removes pod from Service — traffic stops, pod stays alive |

```bash
oc describe deployment account-service | grep -A 20 "Liveness\|Readiness\|Startup"
```

### Break the readiness probe

Exec into one account-service pod and block the `/health/ready` endpoint by setting an env var that makes it return 503:

```bash
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')

# Watch pod READY status in another terminal
oc get pods -w -l tier=account-service
```

In a second terminal, force a readiness failure by temporarily patching the deployment to hit a non-existent path:

```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/broken"}]'
```

Watch the output: one pod drops to `0/1 READY`. Traffic is rerouted to the remaining healthy replica — the service stays available.

Restore it:
```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/ready"}]'
```

The pod returns to `1/1 READY` without a restart.

### Break the liveness probe

```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health/broken"}]'
```

Watch: after `failureThreshold` (3) consecutive failures, the pod is **restarted** — `RESTARTS` counter increments.

Restore:
```bash
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health/live"}]'
```

> **Financial context:** The readiness probe is critical for payment services. A pod that lost its DB connection must not accept new transactions — the readiness probe removes it from rotation silently while it waits to reconnect.

---

## Lab 2d — Zero-Downtime Rolling Update

Simulate a new release by updating the image tag.

### Step 1 — Simulate a new build

Tag the existing image as `v1.1` (in practice your CI pipeline does this):
```bash
oc tag financeflow-account:v1.0 financeflow-account:v1.1
```

### Step 2 — Update the Deployment image

```bash
oc set image deployment/account-service \
  account-service=financeflow-account:v1.1
```

### Step 3 — Watch the rolling update

```bash
oc rollout status deployment/account-service
```

```
Waiting for deployment "account-service" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "account-service" rollout to finish: 1 old replicas are pending termination...
deployment "account-service" successfully rolled out
```

Because `maxUnavailable: 0`, the old pod is only terminated **after** the new pod passes its readiness probe. Zero downtime.

### Step 4 — Inspect rollout history

```bash
oc rollout history deployment/account-service
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

### Step 5 — Roll back

```bash
oc rollout undo deployment/account-service
oc rollout status deployment/account-service
oc rollout history deployment/account-service
```

---

## Lab 2e — Horizontal Pod Autoscaler

### Step 1 — Apply the HPA

```bash
oc apply -f chapters/02-deployments/manifests/hpa-account-service.yaml
oc get hpa
```

```
NAME                   REFERENCE                       TARGETS         MINPODS   MAXPODS   REPLICAS
account-service-hpa    Deployment/account-service      5%/60%, 8%/75%  2         8         2
```

### Step 2 — Generate load

Open a new terminal and run a load loop:

```bash
# Get the account-service ClusterIP
SVC_IP=$(oc get svc account-service -o jsonpath='{.spec.clusterIP}')

# Run from inside the namespace (exec into any pod)
oc exec -it deployment/portal -- sh -c \
  "while true; do wget -qO- http://account-service:8080/api/accounts > /dev/null; done"
```

### Step 3 — Watch the HPA respond

```bash
# In a separate terminal — watch every 5 seconds
watch -n5 "oc get hpa account-service-hpa && echo && oc get pods -l tier=account-service"
```

You will see `REPLICAS` increase from 2 toward 8 as CPU climbs above 60%.

### Step 4 — Stop the load and watch scale-down

Stop the load loop (`Ctrl+C`). After the `stabilizationWindowSeconds: 120` cool-down, the HPA scales back to `minReplicas: 2`.

> **Why `minReplicas: 2`?** A financial service must never drop to 1 replica — a single pod failure would cause an outage. Two replicas at minimum ensures high availability even before the HPA has time to react.

---

## Lab 2f — Resource Requests and Limits

### Inspect what we set

```bash
oc describe deployment account-service | grep -A 5 "Limits\|Requests"
```

```
Limits:
  cpu:     500m
  memory:  256Mi
Requests:
  cpu:     100m
  memory:  128Mi
```

### Understand QoS classes

```bash
oc get pod -l tier=account-service -o jsonpath='{.items[0].status.qosClass}'
```

| QoS Class | When | Impact |
|-----------|------|--------|
| `Guaranteed` | requests == limits | Last to be evicted under memory pressure |
| `Burstable` | requests < limits (our case) | Evicted after BestEffort |
| `BestEffort` | No requests/limits | First to be evicted |

### Try deploying without resource limits (see what happens)

```bash
oc run no-limits --image=financeflow-account:v1.0 \
  --env="DB_USER=x" --env="DB_PASSWORD=x"

oc describe pod no-limits | grep QoS
# QoS Class: BestEffort

oc delete pod no-limits
```

> **Best practice:** Always set requests (for scheduling) and limits (for protection). For production financial services, set `requests == limits` to get `Guaranteed` QoS.

---

## Checkpoint

```bash
# All pods Running and Ready (1/1)
oc get pods

# All four Services exist with ClusterIPs
oc get svc

# HPA active
oc get hpa

# Rollout history
oc rollout history deployment/account-service
oc rollout history deployment/transaction-service

# Describe one deployment to see all settings
oc describe deployment account-service
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod stuck in `Pending` | No PVC bound / insufficient node resources | `oc describe pod <name>` → check Events |
| Pod `CrashLoopBackOff` | App crash at startup — bad env var or missing secret | `oc logs <pod> --previous` |
| Pod `0/1 READY` | Readiness probe failing | `oc describe pod <name>` → check probe events |
| `account-service`/`transaction-service` stuck `0/1 READY`, logs show DB connection errors | `postgres` Service not created yet | `oc get svc postgres` — apply `service-postgres.yaml` from Lab 2a Step 5 |
| HPA shows `<unknown>/60%` | Metrics server not running | `oc get pods -n openshift-monitoring` |
| `ImagePullBackOff` | ImageStreamTag not found | Verify Chapter 1 builds completed: `oc get imagestreamtag` |

---

## Key Takeaways

- `maxUnavailable: 0` is your zero-downtime guarantee — old pods wait until new ones are Ready
- `readinessProbe` controls traffic routing; `livenessProbe` controls container restarts — they serve different purposes
- `minReplicas: 2` in HPA is a financial-grade availability baseline
- Resource `requests` determine scheduling; `limits` prevent noisy-neighbour memory exhaustion
- Every rollout is recorded — `oc rollout undo` is your instant escape hatch

---

*Next: [Lab 3 — Networking & Routing](../../03-networking/lab/03-networking-routing.md)*
