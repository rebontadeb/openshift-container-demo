# Chapter 3 — Networking & Routing

**FinanceFlow Workshop — OpenShift Container Capabilities**

**Chapter:** 3 | **Duration:** 45 min | **Complexity:** 🟡 Easy–Medium

---

## Objectives

By the end of this chapter you will:
- Understand how ClusterIP Services (created in Chapter 2) give pods stable DNS auto-registration
- Expose FinanceFlow externally via an OpenShift Route with TLS edge termination
- Verify in-cluster DNS resolution using `oc exec`
- Apply a default-deny NetworkPolicy and observe the traffic impact
- Restore connectivity by applying targeted allow policies

---

## Prerequisites

- Chapter 2 complete — all pods Running and Ready, with all four Services created:
  ```bash
  oc get pods
  oc get svc
  ```

---

## Concepts

### FinanceFlow Network Topology

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

```
Internet → HAProxy Router (openshift-ingress) → Route → Service → Pod(s)

Inside cluster:
  Pod A  →  Service DNS (CoreDNS)  →  ClusterIP  →  kube-proxy  →  Pod B
```

Key rule: **always talk to Services, never to pod IPs**. Pod IPs change on restart; Service ClusterIPs are stable.

### The Flat Pod Network

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

### Services — What They Do

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

### Service Types

| Type | Reachable from | Use case |
|------|---------------|----------|
| `ClusterIP` | Inside cluster only | All internal services |
| `NodePort` | Node IP + static port (30000–32767) | Quick external access, not production |
| `LoadBalancer` | Cloud load balancer IP | Cloud environments only |
| `ExternalName` | Maps to external DNS | Migrate external DBs into the mesh |

**We use `ClusterIP` for everything** — access from outside goes through a Route, not a NodePort.

### In-cluster DNS

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

### OpenShift Routes

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

**Route vs Kubernetes Ingress:** Routes are OpenShift-native and more feature-rich. Ingress works too, but Routes are the standard on OCP.

### TLS Termination Modes

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

**FinanceFlow uses `edge`** — nginx doesn't need to handle TLS certificates. HAProxy decrypts the HTTPS traffic and forwards plain HTTP to the portal pod on port 8080. The pod never sees TLS.

### NetworkPolicies — Why They Matter

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

### NetworkPolicy Structure

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

### FinanceFlow Allow Matrix

```
                postgres  account-svc  transaction-svc  portal
postgres           —          ✗             ✗             ✗
account-svc       ✓           —             ✗             ✗
transaction-svc   ✓           ✓             —             ✗
portal            ✗           ✓             ✓             —
router            ✗           ✗             ✗             ✓
prometheus        ✓           ✓             ✓             ✓  (port 8080 only)
```

Row = source, Column = destination. Everything else is **denied** by the `deny-all-ingress` policy.

### Web Console: Network Topology

**Developer → Topology** shows:
- Arrows between services (derived from Service selectors)
- Click a Route → opens the app URL
- Network Policy view: **Administrator → Networking → NetworkPolicies**

The policy view shows which policies protect each pod and which sources are allowed.

---

## Hands-On Lab

### Lab 3a — Inspect the Services

All four Services (`postgres`, `account-service`, `transaction-service`, `portal`) were already created in Chapter 2, right alongside their Deployments — that's what let those pods reach `Ready` in the first place. This lab starts by inspecting what's already there, then builds the Route and NetworkPolicies on top.

#### Step 1 — Inspect the ClusterIPs

```bash
oc get svc
```

Expected output:
```
NAME                  TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
account-service       ClusterIP   172.30.45.12     <none>        8080/TCP   12m
portal                ClusterIP   172.30.112.88    <none>        8080/TCP   12m
postgres              ClusterIP   172.30.201.34    <none>        5432/TCP   15m
transaction-service   ClusterIP   172.30.78.56     <none>        8080/TCP   12m
```

ClusterIPs are virtual — they only exist in iptables/OVN rules. They don't respond to ping.

#### Step 2 — Verify DNS from inside a pod

```bash
# Exec into the portal pod
oc exec -it deployment/portal -- sh

# Inside the pod — short DNS name works:
wget -qO- http://account-service:8080/health/ready
# {"status": "ready"}

# Fully qualified name also works:
wget -qO- http://account-service.financeflow-workshop.svc.cluster.local:8080/health/ready
# {"status": "ready"}

# DNS lookup
nslookup account-service
# Server: 172.30.0.10  (CoreDNS)
# Address: 172.30.45.12

exit
```

> **What's happening:** CoreDNS (at 172.30.0.10) resolves `account-service` to the ClusterIP `172.30.45.12`. kube-proxy then distributes the connection across all `Ready` pods matching `tier: account-service`.

### Lab 3b — Create the Route

#### Step 1 — Apply the Route

```bash
oc apply -f chapters/03-networking/manifests/route-portal.yaml
```

#### Step 2 — Get the assigned URL

```bash
oc get route portal
```

```
NAME     HOST/PORT                                          PATH   SERVICES   PORT   TERMINATION     WILDCARD
portal   portal-financeflow-workshop.apps.<cluster-domain>        portal     http   edge/Redirect   None
```

#### Step 3 — Open in a browser

```bash
# Print the full URL
echo "https://$(oc get route portal -o jsonpath='{.spec.host}')"
```

Navigate to the URL — you should see the FinanceFlow portal over HTTPS. The browser will show a valid certificate from the cluster's wildcard cert.

#### Step 4 — Verify the redirect

Try the HTTP URL — it should redirect to HTTPS:
```bash
curl -I "http://$(oc get route portal -o jsonpath='{.spec.host}')"
# HTTP/1.0 301 Moved Permanently
# Location: https://portal-financeflow-workshop.apps...
```

### Lab 3c — NetworkPolicies

#### Understanding the current state

Right now, with no NetworkPolicies applied, **any pod can reach any other pod** including pods in other namespaces. This is the OpenShift default.

#### Step 1 — Apply the deny-all policy

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-deny-all.yaml
```

This creates a policy that matches all pods (`podSelector: {}`) and specifies `Ingress` with no rules — meaning all inbound traffic is denied.

#### Step 2 — Observe the impact

Wait about 15 seconds for the policy to propagate, then test from the portal pod:

```bash
oc exec -it deployment/portal -- sh -c \
  "wget -qO- --timeout=5 http://account-service:8080/health/ready || echo BLOCKED"
# BLOCKED
```

The portal can no longer reach account-service. The FinanceFlow UI will also show errors if you refresh it.

> **Note:** Only ingress is blocked. The pod itself can still make outbound calls — but the destination pod drops the incoming connection.

#### Step 3 — Restore portal access from the router

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-portal.yaml
```

The portal is now reachable from the HAProxy router again — the UI loads. But the data calls still fail (account-service is still blocked).

#### Step 4 — Restore account-service access

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-account-service.yaml
```

Verify:
```bash
oc exec -it deployment/portal -- sh -c \
  "wget -qO- http://account-service:8080/health/ready"
# {"status": "ready"}
```

#### Step 5 — Restore transaction-service access

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-transaction-service.yaml
```

#### Step 6 — Restore database access

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-postgres.yaml
```

Verify the full stack is working — accounts and transactions load in the portal.

#### Step 7 — Apply monitoring access

```bash
oc apply -f chapters/03-networking/manifests/networkpolicy-allow-monitoring.yaml
```

This allows Prometheus (in `openshift-monitoring`) to scrape `/metrics` from all FinanceFlow pods.

#### Step 8 — Or apply everything at once

```bash
# Equivalent to all the above steps
oc apply -k chapters/03-networking/manifests/
```

#### Step 9 — Verify the final policy set

```bash
oc get networkpolicies
```

```
NAME                          POD-SELECTOR        AGE
deny-all-ingress              <none>              5m
allow-router-to-portal        tier=portal         4m
allow-to-account-service      tier=account-service  3m
allow-to-transaction-service  tier=transaction-service  2m
allow-to-postgres             tier=database       1m
allow-monitoring-scrape       app=financeflow     30s
```

```bash
# Inspect what's allowed to reach account-service
oc describe networkpolicy allow-to-account-service
```

### Lab 3d — Verify the Allow Matrix

Confirm only the intended paths work:

```bash
# portal → account-service  (should succeed)
oc exec deployment/portal -- wget -qO- http://account-service:8080/health/ready
# {"status": "ready"}

# portal → transaction-service  (should succeed)
oc exec deployment/portal -- wget -qO- http://transaction-service:8080/health/ready
# {"status": "ready"}

# portal → postgres (should FAIL — portal has no postgres policy)
oc exec deployment/portal -- sh -c \
  "timeout 5 bash -c 'echo > /dev/tcp/postgres/5432' 2>&1 || echo BLOCKED"
# BLOCKED

# account-service → postgres  (should succeed)
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- sh -c \
  "timeout 5 bash -c 'echo > /dev/tcp/postgres/5432' && echo OK || echo BLOCKED"
# OK
```

> **Financial context:** The portal being blocked from postgres is a critical control. Even if the portal were compromised, the attacker cannot directly query the accounts table — they must go through account-service and transaction-service, which enforce business logic and logging.

### Lab 3e — Inspect from the Web Console

1. Open **Administrator → Networking → NetworkPolicies**
2. Select `deny-all-ingress` — see which pods it affects
3. Select `allow-to-account-service` — see the ingress sources
4. Open **Developer → Topology** — hover over any service to see its Route URL and incoming traffic paths

---

## Checkpoint

```bash
# All Services exist
oc get svc

# Route is active and accessible
oc get route portal

# All NetworkPolicies applied
oc get networkpolicies

# Full stack is healthy
oc get pods
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Route shows `503 Service Unavailable` | No pods are Ready | `oc get pods` — check for CrashLoopBackOff |
| Route shows connection timeout | Portal Service selector doesn't match pod labels | `oc describe svc portal` — check selector vs pod labels |
| App loads but shows no data | account-service NetworkPolicy missing | `oc get networkpolicies` — apply `allow-to-account-service` |
| Pod can't reach another pod | NetworkPolicy blocking | `oc exec` from source pod and test with `wget --timeout=5` |
| `nslookup` fails inside pod | CoreDNS issue | `oc get pods -n openshift-dns` |

---

## Key Takeaways

- A `ClusterIP` Service provides a stable IP and DNS name — pod IP changes are transparent to callers
- Routes expose Services externally through HAProxy — `edge` TLS means the app stays plain HTTP
- `deny-all-ingress` + targeted allow policies = zero-trust: only explicitly allowed paths work
- NetworkPolicies are pod-level, not namespace-level — you can have fine-grained control per tier
- The portal being unable to reach postgres directly is a security feature, not a bug

---

*Next: [Chapter 4 — Security & RBAC](04-security-rbac.md)*
