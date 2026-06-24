# Chapter 2
## Deployments & Scaling

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. Deployment vs DeploymentConfig
2. Deploying the FinanceFlow stack
3. Health probes — live, ready, startup
4. Zero-downtime rolling updates
5. Horizontal Pod Autoscaler
6. Resource requests & limits
7. Lab 2 walkthrough

---

## What We're Deploying

```
[PostgreSQL]        ← PVC + Secret
      ↕
[Account Service]   ← ConfigMap (DB_HOST) + Secret (DB_PASSWORD)
      ↕
[Transaction Svc]   ← ConfigMap (ACCOUNT_SERVICE_URL) + Secret
      ↕
[Portal]            ← nginx reverse proxy
```

Images from Chapter 1 ImageStreamTags.
Secrets and ConfigMaps inject configuration.

---

## Deployment vs DeploymentConfig

| | `Deployment` | `DeploymentConfig` |
|--|--|--|
| Origin | Kubernetes native | OpenShift-specific |
| Recommended today | **Yes** | Legacy only |
| HPA support | ✅ | ✅ |
| Built-in image triggers | ❌ | ✅ (but use CI/CD instead) |

**We use `Deployment` — it's the Kubernetes standard and fully supported.**

---

## Secrets vs ConfigMaps

```yaml
# ConfigMap — non-sensitive config
data:
  DB_HOST: postgres
  DB_PORT: "5432"

# Secret — sensitive values
stringData:
  DB_PASSWORD: REPLACE_ME   # base64 encoded at rest
```

**Rule:** If you'd be embarrassed to see it in a log, it's a Secret.

Never `--from-file` a `.env` into a ConfigMap.
Always create Secrets imperatively — never in committed YAML.

---

## Health Probes

Three probes, three jobs:

```
Pod starts
    │
[startupProbe]  ← "Is the app done initialising?"
    │ passes
    ├─────────────────────────────────────────
    │                                        │
[livenessProbe]                    [readinessProbe]
"Is the app alive?"                "Can it serve traffic?"
    │ fails                              │ fails
restarts container              removed from Service
                                (no restart — waits)
```

---

## Probe Configuration

```yaml
startupProbe:
  httpGet:
    path: /health/live
    port: 8080
  failureThreshold: 12   # 12 × 5s = 60s to start
  periodSeconds:    5

livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  periodSeconds:    15
  failureThreshold: 3    # 3 × 15s = 45s before restart

readinessProbe:
  httpGet:
    path: /health/ready
    port: 8080
  periodSeconds:    10
  failureThreshold: 3    # 3 × 10s = 30s before removed from rotation
```

---

## Why Two Endpoints?

```python
@app.route("/health/live")
def liveness():
    return {"status": "ok"}, 200     # always 200 if process is alive

@app.route("/health/ready")
def readiness():
    db.session.execute("SELECT 1")   # checks DB connection
    return {"status": "ready"}, 200  # 503 if DB unreachable
```

A payment pod that lost its DB connection:
- `/health/live` → 200 (process is fine — don't restart)
- `/health/ready` → 503 (can't serve — remove from rotation)

The pod waits quietly until the DB recovers. No restart, no data loss.

---

## Rolling Update Strategy

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0   # ← zero downtime guarantee
    maxSurge:        1  # ← one extra pod during rollout
```

Timeline:
```
Replicas: 2

Step 1:  [v1] [v1]          — start new pod
Step 2:  [v1] [v1] [v2]     — v2 passes readiness
Step 3:  [v1] [v2]          — old v1 terminated
Step 4:  [v2] [v2] [v1-new] — second rollout
Step 5:  [v2] [v2]          — complete ✓
```

Old pod is **never terminated** until new pod is `Ready`.

---

## Rollout Commands

```bash
# Trigger a rollout (new image tag)
oc set image deployment/account-service \
  account-service=financeflow-account:v1.1

# Watch progress
oc rollout status deployment/account-service

# See history
oc rollout history deployment/account-service

# Instant rollback
oc rollout undo deployment/account-service
```

---

## Horizontal Pod Autoscaler

```yaml
spec:
  minReplicas: 2      # never below 2 for financial services
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type:               Utilization
          averageUtilization: 60
```

Scale-up triggers at 60% average CPU.
Scale-down waits 120s stabilisation — prevents flapping.

---

## HPA Behaviour Tuning

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 30    # react fast to spikes
    policies:
      - type: Pods
        value: 2                      # add 2 pods at a time
        periodSeconds: 30
  scaleDown:
    stabilizationWindowSeconds: 120   # wait 2 min before removing pods
    policies:
      - type: Pods
        value: 1                      # remove 1 pod at a time
        periodSeconds: 60
```

Aggressive scale-up. Conservative scale-down.
Right for a payment processor — never drop capacity mid-transaction.

---

## Resource Requests and Limits

```yaml
resources:
  requests:           # scheduler uses this to find a node
    cpu:    100m      # 0.1 CPU core
    memory: 128Mi
  limits:             # hard cap — OOM kill if exceeded
    cpu:    500m
    memory: 256Mi
```

| QoS Class | When | Eviction priority |
|-----------|------|------------------|
| `Guaranteed` | requests == limits | Last |
| `Burstable` | requests < limits | Middle |
| `BestEffort` | none set | First |

---

## Web Console: Topology View

**Developer → Topology**

- See all 4 tiers with health rings
- Click a pod → logs, env vars, events
- Deployment donut shows rolling update progress live

_[demo]_

---

## Lab 2 — Your Turn

**What you will do:**

1. Deploy PostgreSQL with PVC and init script
2. Deploy account-service, transaction-service, portal
3. Break the readiness probe — watch traffic reroute without restart
4. Break the liveness probe — watch container restart
5. Trigger a rolling update and observe zero downtime
6. Apply the HPA, generate load, watch pods scale
7. Inspect QoS classes with and without resource limits

**Estimated time:** 60 min
**Lab guide:** `chapters/02-deployments/lab/02-deployments-scaling.md`

---

## Chapter 2 — Summary

| Concept | Key Point |
|---------|-----------|
| Rolling update | `maxUnavailable: 0` = zero downtime |
| Readiness probe | Controls traffic, not restarts |
| Liveness probe | Controls restarts, not traffic |
| HPA | minReplicas ≥ 2 for financial services |
| Resource limits | Always set — protect scheduling and avoid eviction |

**Next:** Chapter 3 — Networking & Routing
*(exposing FinanceFlow to the world)*
