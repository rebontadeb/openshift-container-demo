# Chapter 3
## Networking & Routing

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. The flat pod network
2. Services — ClusterIP and DNS
3. Service types comparison
4. OpenShift Routes vs Kubernetes Ingress
5. TLS termination modes
6. NetworkPolicies — zero-trust inside the cluster
7. FinanceFlow network topology
8. Lab 3 walkthrough

---

## FinanceFlow Network Topology

```
Internet
    │  HTTPS
    ▼
[HAProxy Router]  ← OpenShift IngressController
    │  Route: portal.apps.<cluster-domain>
    ▼
[portal:8080]     ← ClusterIP Service
    │
    ├──────────────────────────┐
    ▼                          ▼
[account-service:8080]   [transaction-service:8080]
    │                          │
    └──────────┬───────────────┘
               ▼
          [postgres:5432]
```

Everything inside the cluster talks over ClusterIP Services — never pod IPs directly.

---

## The Flat Pod Network

Every pod gets its **own routable IP** within the cluster:

```bash
oc get pods -o wide
NAME                          IP
account-service-6b8d4f-xxxx   10.128.1.47
account-service-6b8d4f-yyyy   10.128.2.31
postgres-7d9f5c-xxxx          10.128.1.52
```

**By default, all pods can reach all other pods** — no firewall.

Problems with using pod IPs directly:
- Pod restarts → new IP
- Scaling adds/removes pods
- You can't load balance across replicas

**Services solve all three.**

---

## Services — What They Do

A Service gives you:

1. **A stable ClusterIP** — never changes, even as pods restart
2. **DNS registration** — `account-service.financeflow-workshop.svc.cluster.local`
3. **Load balancing** — kube-proxy distributes across all matching pods
4. **Health-aware routing** — only sends traffic to `Ready` pods

```yaml
spec:
  selector:
    tier: account-service    # ← matches pod labels
  ports:
    - port: 8080
      targetPort: 8080
```

The selector glues Service → Pods. Add a pod with the right label → instantly in rotation.

---

## Service Types

| Type | Reachable from | Use case |
|------|---------------|----------|
| `ClusterIP` | Inside cluster only | All internal services |
| `NodePort` | Node IP + static port (30000–32767) | Quick external access, not production |
| `LoadBalancer` | Cloud load balancer IP | Cloud environments only |
| `ExternalName` | Maps to external DNS | Migrate external DBs into the mesh |

**We use `ClusterIP` for everything** — access from outside goes through a Route, not a NodePort.

---

## In-cluster DNS

OpenShift's CoreDNS auto-registers every Service:

```
<service-name>.<namespace>.svc.cluster.local
```

From any pod in the same namespace, the short form works:

```bash
# These all resolve to the same ClusterIP:
curl http://account-service:8080/health/ready
curl http://account-service.financeflow-workshop:8080/health/ready
curl http://account-service.financeflow-workshop.svc.cluster.local:8080/health/ready
```

This is how `transaction-service` finds `account-service` — no hardcoded IPs, no service discovery config.

---

## OpenShift Routes

A `Route` exposes a Service outside the cluster through the HAProxy router:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
spec:
  to:
    kind: Service
    name: portal
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

OpenShift auto-assigns a hostname:
```
portal-financeflow-workshop.apps.<cluster-domain>
```

**Route vs Kubernetes Ingress:**  
Routes are OpenShift-native and more feature-rich. Ingress works too, but Routes are the standard on OCP.

---

## TLS Termination Modes

```
                  ┌──────────────────────────────────────────┐
                  │          HAProxy Router                   │
                  │                                           │
  Client ──HTTPS──► edge        TLS ends here, HTTP inside    │
                  │                                           │
  Client ──HTTPS──► passthrough TLS goes straight to pod     │
                  │                                           │
  Client ──HTTPS──► reencrypt   TLS ends + re-encrypts       │
                  └──────────────────────────────────────────┘
```

| Mode | When to use |
|------|-------------|
| `edge` | App doesn't handle TLS — most services |
| `passthrough` | App owns its own cert (mutual TLS, mTLS) |
| `reencrypt` | Compliance requires end-to-end encryption |

**FinanceFlow uses `edge`** — nginx doesn't need to handle TLS certificates.

---

## NetworkPolicies — Why They Matter

Without NetworkPolicies, **any pod can reach any other pod** in any namespace.

In a financial application this means:
- A compromised portal pod can directly query postgres
- A compromised transaction-service can reach the monitoring namespace
- A rogue workload in another namespace can scrape account data

**Default deny + explicit allow** is the zero-trust posture:

```
Apply deny-all → apply only the paths you actually need
```

NetworkPolicies are **additive** — multiple policies on the same pod are OR'd together.

---

## NetworkPolicy Structure

```yaml
spec:
  podSelector:          # which pods this policy protects
    matchLabels:
      tier: account-service

  policyTypes:
    - Ingress           # control inbound traffic

  ingress:
    - from:
        - podSelector:  # who can connect
            matchLabels:
              tier: portal
        - podSelector:
            matchLabels:
              tier: transaction-service
      ports:
        - port: 8080    # on which port
```

Empty `podSelector: {}` = applies to **all** pods (used for deny-all).

---

## FinanceFlow Allow Matrix

```
                postgres  account-svc  transaction-svc  portal
postgres           —          ✗             ✗             ✗
account-svc       ✓           —             ✗             ✗
transaction-svc   ✓           ✓             —             ✗
portal            ✗           ✓             ✓             —
router            ✗           ✗             ✗             ✓
prometheus        ✓           ✓             ✓             ✓  (port 8080 only)
```

Row = source, Column = destination.  
Everything else is **denied** by the `deny-all-ingress` policy.

---

## Web Console: Network Topology

**Developer → Topology** shows:
- Arrows between services (derived from Service selectors)
- Click a Route → opens the app URL
- Network Policy view: **Administrator → Networking → NetworkPolicies**

The policy view shows which policies protect each pod and which sources are allowed.

---

## Lab 3 — Your Turn

1. Apply all four Services — inspect ClusterIP and DNS
2. Create the Route — access FinanceFlow in a browser over HTTPS
3. Test in-cluster DNS with `oc exec`
4. Apply `deny-all` NetworkPolicy — watch connectivity break
5. Apply allow policies one by one — restore each path
6. Verify the final topology with `oc describe networkpolicy`

**Estimated time:** 45 min  
**Lab guide:** `chapters/03-networking/lab/03-networking-routing.md`

---

## Chapter 3 — Summary

| Concept | Key Point |
|---------|-----------|
| ClusterIP | Stable virtual IP + DNS for every Service |
| Route | OpenShift-native external exposure via HAProxy |
| TLS edge termination | Router handles certs — app stays plain HTTP inside |
| NetworkPolicy | Default deny + explicit allow = zero-trust pod networking |
| DNS short name | `<svc-name>` works within the same namespace |

**Next:** Chapter 4 — Security & RBAC  
*(SCCs, service accounts, and role-based access control)*
