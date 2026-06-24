# Chapter 5
## Service Mesh

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. What is a service mesh and why it matters
2. Envoy sidecar — the mesh data plane
3. OpenShift Service Mesh components
4. Joining the mesh — Istio/IstioCNI (Sail Operator) and namespace labels
5. mTLS — automatic encryption between services
6. Traffic management — VirtualService and DestinationRule
7. Canary deployments without changing code
8. Circuit breaking
9. Kiali — the mesh control tower
10. Lab 5 walkthrough

---

## The Problem Service Mesh Solves

Without a mesh, every service must handle these itself:

| Concern | Without mesh | With mesh |
|---------|-------------|-----------|
| Encryption in transit | Code + cert management | Automatic mTLS |
| Retries & timeouts | Each service implements | VirtualService policy |
| Circuit breaking | Code (e.g., Hystrix) | DestinationRule outlier |
| Traffic splitting (canary) | Custom load balancer config | Weight field in VirtualService |
| Distributed tracing | Instrumentation in every service | Sidecar adds trace headers |
| Traffic metrics | Custom Prometheus in every service | Sidecar exports automatically |

**Zero code changes** — the mesh handles all of this at the infrastructure layer.

---

## The Sidecar Pattern

```
┌─────────────────────────────────────┐
│              Pod                     │
│                                      │
│  ┌───────────┐    ┌───────────────┐  │
│  │ Your App  │◄──►│ Envoy Proxy   │  │
│  │ :8080     │    │ :15001 (out)  │  │
│  └───────────┘    │ :15006 (in)   │  │
│                   └───────────────┘  │
└─────────────────────────────────────┘
          ▲                ▲
          │                │ mTLS
          │                ▼
┌─────────────────────────────────────┐
│              Pod                     │
│  ┌───────────┐    ┌───────────────┐  │
│  │ Other App │◄──►│ Envoy Proxy   │  │
│  └───────────┘    └───────────────┘  │
└─────────────────────────────────────┘
```

iptables rules redirect ALL traffic through Envoy — the app never knows the proxy is there.

---

## OpenShift Service Mesh Components

| Component | Role |
|-----------|------|
| **Istio** (Sail Operator) | Control plane — policies, certificates, config |
| **Envoy** | Data plane sidecar — all traffic goes through it |
| **Kiali** | Topology graph, traffic flow, health |
| **Tempo** | Distributed tracing — end-to-end request spans (Jaeger-compatible UI) |
| **Prometheus** | Mesh metrics (auto-collected by sidecars) |
| **Grafana** | Mesh dashboards |

All installed via **OperatorHub**: `servicemeshoperator3`, Tempo Operator, `kiali-ossm`.

> OpenShift Service Mesh 2 (Maistra, `ServiceMeshControlPlane`/`ServiceMeshMemberRoll`) is end-of-life on this cluster version. OSSM 3 runs on the **Sail Operator** instead.

---

## Joining the Mesh

Two CRDs from the Sail Operator (`sailoperator.io/v1`) replace the old SMCP:

```yaml
# 1. Istio — the control plane itself (cluster-admin)
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.28-latest
  namespace: istio-system
  updateStrategy:
    type: InPlace
---
# 2. IstioCNI — node-level CNI plugin
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v1.28-latest
  namespace: istio-cni
```

```yaml
# 3. Namespaces join the mesh via a label — no ServiceMeshMemberRoll
apiVersion: v1
kind: Namespace
metadata:
  name: financeflow-workshop
  labels:
    istio-injection: enabled
```

Once the namespace has that label, **every new pod** gets an Envoy sidecar injected automatically.

---

## mTLS — Automatic Encryption

```
Before mesh:                    After mesh:
  Portal ──HTTP──► Account       Portal ──mTLS──► Account
  (plain text)                   (encrypted + authenticated)
```

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: financeflow-mtls
  namespace: financeflow-workshop
spec:
  mtls:
    mode: STRICT    # reject any plain-text connection
```

**PERMISSIVE** (default): accepts both mTLS and plain-text  
**STRICT**: plain-text is rejected — only fully meshed pods can communicate

Start with PERMISSIVE during migration, switch to STRICT when all pods have sidecars.

---

## DestinationRule — Define Traffic Policy

```yaml
spec:
  host: account-service

  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL      # mTLS using mesh-managed certs
    outlierDetection:
      consecutive5xxErrors: 3 # eject after 3 failures
      interval: 30s
      baseEjectionTime: 30s

  subsets:                     # named groups of pods (by label)
    - name: v1-0
      labels:
        version: v1.0
    - name: v1-1
      labels:
        version: v1.1
```

DestinationRule = **how** to talk to a service (policy, subsets).  
VirtualService = **where** to send traffic.

---

## VirtualService — Traffic Routing

```yaml
spec:
  hosts:
    - account-service
  http:
    - route:
        - destination:
            host: account-service
            subset: v1-0
          weight: 90        # 90% to stable
        - destination:
            host: account-service
            subset: v1-1
          weight: 10        # 10% to canary
      timeout: 10s
      retries:
        attempts: 3
        retryOn: "5xx,reset"
```

Change weights and `oc apply` — traffic shifts in seconds, no deployment needed.

---

## Canary Deployment Pattern

```
Phase 1 — Baseline
  [v1.0] [v1.0]          weight: 100 / 0

Phase 2 — Canary (10%)
  [v1.0] [v1.0] [v1.1]  weight: 90 / 10
       ↓ watch Kiali + Tempo for errors

Phase 3 — Shift (50%)
  [v1.0] [v1.1]          weight: 50 / 50
       ↓ metrics look good

Phase 4 — Full cutover
  [v1.1] [v1.1]          weight: 0 / 100
       ↓ decommission v1.0 deployment

Rollback at any phase: weight 100 / 0
```

**No new `oc set image` required** — the VirtualService weight is the only change.

---

## Circuit Breaking

```yaml
outlierDetection:
  consecutive5xxErrors: 3    # 3 failures in a row...
  interval: 30s              # ...within 30s
  baseEjectionTime: 30s      # ...ejects the pod for 30s
  maxEjectionPercent: 50     # but never more than 50% of the pool
```

```
Normal:   [pod A] [pod B] [pod C]  — all receive traffic

pod B fails 3 times:

Ejected:  [pod A] [pod C]          — B is removed from rotation
           ↑                       — traffic redistributed automatically
After 30s: [pod A] [pod B] [pod C] — B is re-admitted; if it fails again, ejected longer
```

Prevents one bad pod from degrading the entire service — critical for payment flows.

---

## Kiali — The Mesh Control Tower

**Navigate to:** Kiali URL in the mesh namespace  
`oc get route kiali -n istio-system`

**Graph view shows:**
- Real-time traffic flow between services
- Request rate, error rate, latency (RED metrics)
- mTLS lock icons on each connection
- Canary weight split visualised as traffic thickness

**Tracing (Tempo, via its Jaeger-compatible UI — Route `tempo-financeflow-jaegerui`):**
- End-to-end trace: Portal → Account → PostgreSQL
- See exactly which hop added latency

_[demo — live Kiali graph]_

---

## Lab 5 — Your Turn

1. Install OSSM 3, Tempo, and Kiali operators via OperatorHub
2. Apply `smcp.yaml` (Istio/IstioCNI) and `smmr.yaml` (namespace label) — wait for the control plane
3. Restart pods — verify sidecar injection (2/2 containers)
4. Apply STRICT mTLS — test that plain-text is rejected
5. Label pods with `version: v1.0` and deploy the canary `v1.1`
6. Apply DestinationRule and VirtualService (90/10 split)
7. Generate traffic — watch Kiali graph show the split
8. Shift to 50/50 then 100% v1.1
9. Test circuit breaking: break a pod, watch Kiali eject it

**Estimated time:** 60 min  
**Lab guide:** `chapters/05-service-mesh/lab/05-service-mesh.md`

---

## Chapter 5 — Summary

| Concept | Key Point |
|---------|-----------|
| Sidecar proxy | All traffic via Envoy — zero app code changes |
| Istio + IstioCNI (Sail) | Control plane + namespace label for injection |
| PeerAuthentication STRICT | Enforces mTLS — plain-text connections rejected |
| DestinationRule | Defines subsets (canary pods) + outlier detection |
| VirtualService | Traffic weights — shift canary by editing YAML, not deployments |
| Kiali | Real-time mesh topology with RED metrics |

**Next:** Chapter 6 — CI/CD  
*(Tekton Pipelines + ArgoCD GitOps — automate everything built so far)*
