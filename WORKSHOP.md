# OpenShift Container Capabilities Workshop

**Audience:** Developers & Platform Engineers (Mixed)
**Level:** Intermediate (comfortable with containers, new to OpenShift)
**Format:** Full Workshop Kit — slides, hands-on labs, demo scripts, sample app

---

## Sample Application: FinanceFlow

A multi-tier personal finance and banking application used throughout every chapter as the workshop vehicle.

| Tier | Technology | Purpose |
|------|-----------|---------|
| Web Portal | Nginx + Vanilla JS | Account dashboard, transaction history UI |
| Account Service | Python Flask | Account management, balance queries |
| Transaction Service | Python Flask | Fund transfers, payment processing |
| Database | PostgreSQL | Accounts and transactions store |

**Why a Finance App?**
Financial applications have real-world requirements that map perfectly to every workshop topic: strict security, encrypted traffic, audit trails, high availability, and zero-downtime deployments. Every lab decision feels motivated rather than academic.

Each chapter builds on the previous one — by the end, FinanceFlow is containerized, deployed, scaled, secured, meshed, CI/CD-automated, and fully observable.

---

## Chapter Overview

| # | Chapter | Key OpenShift Concepts | Complexity |
|---|---------|------------------------|------------|
| 0 | Prerequisites & Setup | `oc` CLI, cluster access, namespaces | ⬜ Intro |
| 1 | Container Builds & Images | Dockerfile, S2I, ImageStreams, BuildConfigs | 🟢 Beginner |
| 2 | Deployments & Scaling | Deployments, Health Probes, HPA, Rolling Updates | 🟡 Easy |
| 3 | Networking & Routing | Services, Routes, NetworkPolicies | 🟡 Easy–Medium |
| 4 | Security & RBAC | SCCs, ServiceAccounts, RBAC, Secrets | 🟠 Medium |
| 5 | Service Mesh | Istio/OSSM, mTLS, Traffic Management, Canary | 🔴 Medium–Hard |
| 6 | CI/CD — Pipelines & GitOps | Tekton Pipelines, Triggers, ArgoCD, App-of-Apps | 🔴 Hard |
| 7 | OpenTelemetry & Observability | OTel SDK, Collector, Traces, Metrics, Logs | 🔴 Hard |

---

---

## Chapter 0 — Prerequisites & Setup

**Duration:** 30 min
**Goal:** Every attendee has a working OpenShift session and the tools needed for the rest of the workshop.

### Concepts
- What is OpenShift vs Kubernetes?
- OpenShift-specific additions: Projects, Routes, SCCs, OperatorHub
- The `oc` CLI vs `kubectl`
- OpenShift Web Console overview: Developer vs Administrator perspectives

### Architecture: FinanceFlow Overview
```
         [ Web Portal ]
               |
    ┌──────────┴──────────┐
    |                     |
[ Account Service ]  [ Transaction Service ]
    |                     |
    └──────────┬──────────┘
               |
          [ PostgreSQL ]
```

### Lab 0 — Environment Setup
1. Install / verify `oc` CLI
2. Log in to the cluster: `oc login <cluster-url> --token=<token>`
3. Create your workshop namespace: `oc new-project financeflow-<your-name>`
4. Verify access: `oc whoami`, `oc status`
5. Clone the workshop repo: `git clone <repo-url>`
6. Explore the Web Console — Developer vs Administrator view

### Key Commands
```bash
oc login https://api.<cluster>:6443 --token=<token>
oc new-project financeflow-workshop
oc whoami
oc status
oc get nodes
oc projects
```

### Instructor Notes
- Pre-provision one namespace per attendee OR one shared namespace per team of 2
- Confirm each attendee can reach the Web Console before moving on
- Walk through the 4-tier FinanceFlow architecture — set context for why each chapter matters

---

---

## Chapter 1 — Container Builds & Images

**Duration:** 60 min
**Goal:** Build the FinanceFlow application images using OpenShift-native build strategies.

### Concepts
- Container image anatomy: layers, base images, labels
- OpenShift BuildConfig strategies:
  - **Docker strategy** — traditional Dockerfile build
  - **Source-to-Image (S2I)** — buildpack-style, no Dockerfile required
- **ImageStreams** — OpenShift's image registry abstraction and tagging
- **ImageStreamTags** — trigger deployments on image change
- Build triggers: webhook, image change, manual

### Architecture: Build Flow
```
[app/account-service/Dockerfile]   [app/transaction-service/Dockerfile]
            |                                    |
       BuildConfig                          BuildConfig
       (docker strategy)                   (docker strategy)
            |                                    |
        Build Pod                            Build Pod
            |                                    |
  ImageStream: financeflow-account    ImageStream: financeflow-transaction
            |
  (triggers Deployment in Ch. 2)

[app/portal/]   ← nginx S2I builder (no Dockerfile needed)
      |
  BuildConfig (S2I strategy)
      |
  ImageStream: financeflow-portal
```

### Lab 1a — Docker Strategy Build (Account Service)
1. Review `app/account-service/Containerfile`
2. Create an ImageStream for the account service
3. Create a BuildConfig using Docker strategy
4. Start a build and stream logs: `oc start-build ... --follow`
5. Inspect the resulting ImageStreamTag

### Lab 1b — Docker Strategy Build (Transaction Service)
1. Repeat for `app/transaction-service/`
2. Note how the Containerfile differs: the transaction service needs additional dependencies for payment processing
3. Tag both images: `financeflow-account:v1.0`, `financeflow-transaction:v1.0`

### Lab 1c — S2I Build (Web Portal)
1. Use OpenShift's built-in `nginx` S2I builder
2. Create a BuildConfig pointing to `app/portal/` source
3. Compare Docker vs S2I: no Dockerfile required, builder handles assembly
4. Inspect the S2I build log — observe how it differs from Docker strategy

### Lab 1d — Build Triggers & Webhooks
1. Add an image change trigger to the account service BuildConfig
2. Simulate a base image update by tagging a new parent image
3. Watch the automatic rebuild — this is how you get security patches without manual intervention

### Key Manifests
- `chapters/01-builds/manifests/imagestream-account.yaml`
- `chapters/01-builds/manifests/imagestream-transaction.yaml`
- `chapters/01-builds/manifests/imagestream-portal.yaml`
- `chapters/01-builds/manifests/buildconfig-account.yaml`
- `chapters/01-builds/manifests/buildconfig-transaction.yaml`
- `chapters/01-builds/manifests/buildconfig-portal-s2i.yaml`

### Key Commands
```bash
oc new-build --name=financeflow-account --binary --strategy=docker
oc start-build financeflow-account --from-dir=./app/account-service --follow
oc start-build financeflow-transaction --from-dir=./app/transaction-service --follow
oc get builds
oc get imagestreams
oc describe imagestream financeflow-account
oc tag financeflow-account:latest financeflow-account:v1.0
oc tag financeflow-transaction:latest financeflow-transaction:v1.0
```

### Instructor Notes
- Show the build log streaming in both CLI and Web Console (Builds view)
- Highlight how ImageStreams decouple the internal registry URL from your manifests
- The financial context: explain why image tagging and immutability matter for audit compliance
- Common gotcha: S2I requires source to match the builder's expected directory structure

---

---

## Chapter 2 — Deployments & Scaling

**Duration:** 60 min
**Goal:** Deploy the full FinanceFlow stack and explore OpenShift deployment and scaling primitives.

### Concepts
- **Deployment** vs **DeploymentConfig** — when to use each
- **ReplicaSets** — how OpenShift maintains desired state
- **Health probes**: `livenessProbe`, `readinessProbe`, `startupProbe`
- **Rolling updates** and **Recreate** strategies
- **Horizontal Pod Autoscaler (HPA)** — CPU/memory-based autoscaling
- **Resource requests and limits** — QoS classes, scheduler behaviour

### Architecture: What We're Deploying
```
[PostgreSQL Deployment]
  └── PVC (account + transaction data)
  └── Secret (DB credentials)

[Account Service Deployment]
  └── ConfigMap  (DB_HOST, DB_PORT)
  └── Secret     (DB_PASSWORD)
  └── Probe: GET /health/ready

[Transaction Service Deployment]
  └── ConfigMap  (DB_HOST, ACCOUNT_SERVICE_URL)
  └── Secret     (DB_PASSWORD)
  └── Probe: GET /health/ready

[Web Portal Deployment]
  └── ConfigMap  (nginx.conf — proxies /api/accounts, /api/transactions)
  └── Probe: GET /health
```

Each Deployment's Service is created right alongside it in this chapter (not Chapter 3) — the readiness probes above need `postgres`, `account-service`, etc. to resolve via DNS *before* Chapter 3 even starts.

### Lab 2a — Deploy the Database
1. Create a Secret for PostgreSQL credentials
2. Create a PVC for data persistence
3. Deploy PostgreSQL with a liveness + readiness probe
4. Verify the pod is `Running` and `Ready`
5. Exec into the pod and verify the `financeflow` database was initialized

### Lab 2b — Deploy Account & Transaction Services
1. Deploy the account service with env vars from ConfigMap and Secret
2. Deploy the transaction service — note it depends on the account service URL
3. Observe the rolling deployment in the Web Console topology view
4. Understand `READY` state — a financial service that can't reach the DB must never serve traffic

### Lab 2c — Health Probes Deep Dive
1. Intentionally break the `readinessProbe` endpoint on the account service
2. Watch traffic stop routing to the broken pod (stays `0/1 Ready`)
3. Fix the probe and watch recovery
4. Break the `livenessProbe` — watch the pod restart (not just removed from rotation)
5. Discuss: for a payment service, would you rather a pod restart or stay in a broken state?

### Lab 2d — Rolling Update: Zero-Downtime Deployment
1. Change an environment variable on the transaction service (simulate a config change)
2. Watch the rolling update: new pods come up, old pods terminate only after new ones are `Ready`
3. Try `oc rollout undo` to roll back
4. Discuss: what `maxUnavailable` and `maxSurge` settings make sense for a payment processor?

### Lab 2e — Horizontal Pod Autoscaler
1. Deploy the web portal
2. Create an HPA targeting 60% CPU on the account service (min: 2, max: 8)
3. Generate load: `while true; do curl http://account-service/api/accounts; done`
4. Watch pods scale up; remove load and watch scale-down
5. Discuss: why `minReplicas: 2` is a baseline requirement for any financial service

### Key Manifests
- `chapters/02-deployments/manifests/secret-postgres.yaml` (placeholder only — create the real Secret imperatively, see Lab 2a Step 1)
- `chapters/02-deployments/manifests/pvc-postgres.yaml`
- `chapters/02-deployments/manifests/configmap-account-service.yaml`
- `chapters/02-deployments/manifests/configmap-transaction-service.yaml`
- `chapters/02-deployments/manifests/configmap-portal-nginx.yaml`
- `chapters/02-deployments/manifests/deployment-postgres.yaml`
- `chapters/02-deployments/manifests/service-postgres.yaml`
- `chapters/02-deployments/manifests/deployment-account-service.yaml`
- `chapters/02-deployments/manifests/service-account-service.yaml`
- `chapters/02-deployments/manifests/deployment-transaction-service.yaml`
- `chapters/02-deployments/manifests/service-transaction-service.yaml`
- `chapters/02-deployments/manifests/deployment-portal.yaml`
- `chapters/02-deployments/manifests/service-portal.yaml`
- `chapters/02-deployments/manifests/hpa-account-service.yaml`

### Key Commands
```bash
oc apply -k chapters/02-deployments/manifests/
oc get pods -w
oc get svc
oc describe pod <pod-name>
oc rollout status deployment/account-service
oc rollout undo deployment/transaction-service
oc scale deployment account-service --replicas=3
oc autoscale deployment account-service --min=2 --max=8 --cpu-percent=60
oc get hpa
```

### Instructor Notes
- The Web Console topology view is excellent here — show all 4 tiers connected
- Lab 2c (probe failure) is the most educational moment — be deliberate and slow
- Reinforce the financial context throughout: "would a bank accept a payment service that goes to 0 replicas during a deploy?"
- HPA requires the metrics server to be running; verify beforehand

---

---

## Chapter 3 — Networking & Routing

**Duration:** 60 min
**Goal:** Expose FinanceFlow externally and enforce strict inter-service network boundaries.

### Concepts
- **Services** — ClusterIP, NodePort, LoadBalancer — and when to use each
- **Routes** — OpenShift's URL exposure primitive (HAProxy-based)
  - HTTP vs edge-terminated TLS vs passthrough TLS
  - Custom hostnames and wildcard certs
- **Ingress** — Kubernetes-native vs OpenShift Route
- **NetworkPolicies** — namespace-scoped micro-segmentation
  - Default-deny posture
  - Allow rules: ingress, egress, namespace selectors

### Architecture: Traffic & Isolation Model
```
Internet
   |
 Route (financeflow.apps.<cluster>) — HTTPS only
   |
 Service: portal (ClusterIP :8080)
   |
 Portal Pod
   |──────────────────────────────────────┐
   |                                      |
 Service: account-service (ClusterIP)   Service: transaction-service (ClusterIP)
   |                                      |
 Account Pod                           Transaction Pod
   └──────────────┬───────────────────────┘
                  |
         Service: postgres (ClusterIP)
                  |
             PostgreSQL Pod

NetworkPolicy rules:
  internet    → portal only (port 8080)
  portal      → account-service, transaction-service
  transaction → account-service (balance checks before transfers)
  account     → postgres
  transaction → postgres
  (all other paths: DENY)
```

### Lab 3a — Inspect the Services and Expose the Portal via Route
1. All four ClusterIP Services (`postgres`, `account-service`, `transaction-service`, `portal`) already exist from Chapter 2 — inspect their ClusterIPs and confirm DNS resolution from inside a pod (`nslookup account-service`)
2. Create an edge-TLS Route for the portal (TLS termination + HTTP→HTTPS redirect baked into one manifest — see `route-portal.yaml`)
3. Access FinanceFlow in a browser — confirm the dashboard loads over HTTPS, and that plain HTTP redirects
4. Discuss: a finance portal must never serve login pages over plain HTTP

### Lab 3b — NetworkPolicies: Default Deny
1. Apply `networkpolicy-deny-all.yaml` to the namespace
2. Observe: nothing works — the portal returns 503, transactions fail
3. Add allow rules step by step, verifying the app recovers at each step:
   - `networkpolicy-allow-portal.yaml` — external ingress to portal
   - `networkpolicy-allow-account-service.yaml` / `networkpolicy-allow-transaction-service.yaml` — portal/inter-service calls
   - `networkpolicy-allow-postgres.yaml` — both services → postgres
   - `networkpolicy-allow-monitoring.yaml` — Prometheus scraping
4. Attempt to curl the transaction service directly from outside — confirm it's blocked
5. Discuss: PCI-DSS and SOC 2 compliance requirements for network segmentation

### Key Manifests
- `chapters/03-networking/manifests/route-portal.yaml` (edge TLS + redirect; the 4 Services live in `chapters/02-deployments/manifests/`)
- `chapters/03-networking/manifests/networkpolicy-deny-all.yaml`
- `chapters/03-networking/manifests/networkpolicy-allow-portal.yaml`
- `chapters/03-networking/manifests/networkpolicy-allow-account-service.yaml`
- `chapters/03-networking/manifests/networkpolicy-allow-transaction-service.yaml`
- `chapters/03-networking/manifests/networkpolicy-allow-postgres.yaml`
- `chapters/03-networking/manifests/networkpolicy-allow-monitoring.yaml`

### Key Commands
```bash
oc get svc
oc apply -f chapters/03-networking/manifests/route-portal.yaml
oc get route portal
curl -Lk https://$(oc get route portal -o jsonpath='{.spec.host}')
oc apply -f chapters/03-networking/manifests/networkpolicy-deny-all.yaml
oc get networkpolicy
oc describe networkpolicy networkpolicy-allow-account-service
# Verify block: exec into portal pod and try to reach postgres directly
oc exec -it <portal-pod> -- curl http://postgres:5432
```

### Instructor Notes
- The "default deny then allow" flow is the most impactful demo in this chapter
- The financial context makes the NetworkPolicy labs feel real: "no external actor should ever directly call the DB or transaction service"
- Show the Web Console network visualization if OpenShift Network Observability is installed
- PCI-DSS reference: cards/payments must be isolated — this is a direct compliance mapping

---

---

## Chapter 4 — Security & RBAC

**Duration:** 75 min
**Goal:** Harden FinanceFlow using OpenShift's layered security model — treating it as a production financial system.

### Concepts
- **Security Context Constraints (SCCs)** — OpenShift's pod admission control
  - Built-in SCCs: `restricted-v2`, `anyuid`, `privileged`
  - How SCCs differ from Kubernetes PodSecurityAdmission
- **ServiceAccounts** — workload identity in the cluster
- **RBAC**: Roles, ClusterRoles, RoleBindings, ClusterRoleBindings
  - Principle of least privilege
  - Aggregated ClusterRoles
- **Secrets management**:
  - Kubernetes Secrets (base64 — not encryption at rest by default)
  - OpenShift etcd encryption
  - External Secrets Operator pattern (intro — pull from Vault / AWS Secrets Manager)
- **Pod security hardening**: securityContext, read-only filesystem, dropped capabilities

### Security Layers
```
┌──────────────────────────────────────────┐
│          Cluster-level RBAC              │  ← Who can do what in the cluster
├──────────────────────────────────────────┤
│       Namespace-level RBAC               │  ← Who can do what in financeflow-workshop
├──────────────────────────────────────────┤
│   Security Context Constraints (SCCs)    │  ← What a pod is allowed to do at runtime
├──────────────────────────────────────────┤
│       Pod Security Context               │  ← What this specific pod does
├──────────────────────────────────────────┤
│     Container Security Context           │  ← What this container does
└──────────────────────────────────────────┘
```

### Lab 4a — Service Accounts and SCCs
1. Check what SA/SCC the current pods run under (`default` SA, `restricted-v2`): `oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'`
2. Create dedicated ServiceAccounts: `financeflow-app` (all application pods) and `financeflow-cicd` (Chapter 6's pipeline)
3. Patch the account/transaction/portal Deployments to use `financeflow-app` instead of `default`
4. Create a minimal custom SCC (`financeflow-scc`): non-root, no privilege escalation, all capabilities dropped, no host access
5. Grant it to `financeflow-app` via a ClusterRole (`use-financeflow-scc`) + RoleBinding — not the imperative `oc adm policy add-scc-to-user` shortcut, which is shown only for reference

### Lab 4b — RBAC: Role Separation for a Finance Team
1. Create `financeflow-viewer` Role: read-only on pods, logs, deployments, services, routes (for developers)
2. Create `financeflow-deployer` Role: create/update on deployments, services, configmaps, routes, HPAs, NetworkPolicies (for the CI/CD ServiceAccount) — **secrets are excluded from both roles**
3. Bind `financeflow-viewer` to the `financeflow-developers` Group, and `financeflow-deployer` to the `financeflow-cicd` ServiceAccount
4. Verify boundaries with `oc auth can-i`: can the developer group read secrets? Can the CI/CD SA create secrets?
5. Discuss: nobody who deploys code should also be able to read production DB credentials

### Lab 4c — Secrets Best Practices
1. Inspect `postgres-credentials` — understand base64 is encoding, not encryption
2. Mount a Secret as environment variable vs as a volume file — which is more secure?
3. Rotate the database password Secret without downtime:
   - Create new Secret version
   - Trigger rolling restart: `oc rollout restart deployment/account-service`
4. Intro: External Secrets Operator pattern — pulling `DB_PASSWORD` from HashiCorp Vault or AWS Secrets Manager (conceptual if ESO not installed)

### Lab 4d — Pod Security Context Audit
1. The account/transaction/portal Deployments (Chapter 2) already declare `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]` — no separate "hardened" variant needed
2. `oc exec` into a pod and run `id` — confirm it's running as the Containerfile's non-root UID (1001), not root
3. Confirm the actual SCC in use via the pod annotation: `oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'`
4. Try `oc exec ... -- touch /test-file` — confirm the non-root user can't write to the root filesystem

### Key Manifests
- `chapters/04-security/manifests/serviceaccount-financeflow.yaml`
- `chapters/04-security/manifests/serviceaccount-cicd.yaml`
- `chapters/04-security/manifests/scc-financeflow.yaml`
- `chapters/04-security/manifests/clusterrole-use-financeflow-scc.yaml`
- `chapters/04-security/manifests/rolebinding-sa-use-scc.yaml`
- `chapters/04-security/manifests/role-viewer.yaml`
- `chapters/04-security/manifests/role-deployer.yaml`
- `chapters/04-security/manifests/rolebinding-viewer.yaml`
- `chapters/04-security/manifests/rolebinding-deployer.yaml`

### Key Commands
```bash
oc get pod <name> -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
oc policy who-can delete pods -n financeflow-workshop
oc adm policy add-scc-to-user financeflow-scc -z financeflow-app -n financeflow-workshop   # imperative reference only
oc auth can-i get secrets --as-group financeflow-developers --as fake-dev -n financeflow-workshop
oc auth can-i get secrets --as system:serviceaccount:financeflow-workshop:financeflow-cicd
oc auth can-i --list --as system:serviceaccount:financeflow-workshop:financeflow-cicd -n financeflow-workshop
oc rollout restart deployment/account-service
```

### Instructor Notes
- Use the financial context aggressively: "the CI/CD pipeline that deploys code should never be able to read DB passwords in prod"
- SCCs are the most common source of confusion for Kubernetes→OpenShift migrants — spend time here
- `restricted-v2` is the default SCC on OpenShift 4.11+ (validated here on 4.21) — stricter than the old `restricted`; seccomp is enforced
- `oc policy who-can` is a gift for debugging permission issues in real teams — show it prominently

---

---

## Chapter 5 — Service Mesh (OpenShift Service Mesh / Istio)

**Duration:** 90 min
**Goal:** Add OpenShift Service Mesh to the FinanceFlow namespace for automatic mTLS, traffic management, and canary deployments.

### Concepts
- Why a service mesh: mTLS, observability, and traffic control without code changes
- **Sidecar injection** — Envoy proxy running alongside every pod
- **Control plane vs data plane**: Istiod, Envoy
- **mTLS** — automatic mutual TLS between all services; critical for financial data in transit
- **Traffic management**:
  - `VirtualService` — routing rules per request
  - `DestinationRule` — load balancing, connection pools, circuit breaking
  - `Gateway` — ingress into the mesh
- **Canary deployments** — traffic-weighted routing between versions
- **Observability built-in**: Kiali (service graph), Tempo (traces, via a Jaeger-compatible UI), Grafana (metrics)

> **Version note:** OpenShift Service Mesh 2 (`ServiceMeshControlPlane`/`ServiceMeshMemberRoll`, Maistra-based) is end-of-life on OCP 4.21. This workshop uses **OSSM 3**, built on the **Sail Operator**, whose CRDs are `Istio` and `IstioCNI` (`sailoperator.io/v1`). Namespaces join the mesh via a plain `istio-injection: enabled` label, not a ServiceMeshMemberRoll. Jaeger (the Operator) is likewise replaced by the **Tempo Operator**.

### Architecture: Mesh Overlay
```
[Portal Pod + Envoy sidecar]
       | mTLS
[Account Service v1.0 Pod + Envoy]      [Transaction Service Pod + Envoy]
[Account Service v1.1 Pod + Envoy] ← canary, weighted via VirtualService
       | mTLS
[PostgreSQL Pod + Envoy]
```

### Lab 5a — Enable Service Mesh
1. Install three operators: **Red Hat OpenShift Service Mesh 3** (`servicemeshoperator3`), **Tempo Operator**, **Kiali Operator** (`kiali-ossm`)
2. Apply `smcp.yaml` — creates the `istio-system`/`istio-cni` namespaces and the `Istio`/`IstioCNI` CRs. Verify: `oc get istio -n istio-system`
3. Apply `smmr.yaml` — labels the `financeflow-workshop` namespace `istio-injection: enabled`
4. Restart the account/transaction/portal Deployments to trigger sidecar injection
5. Verify: `oc get pods` — each pod should show `2/2 READY` (app + Envoy)

### Lab 5b — Verify mTLS
1. Open Kiali — observe the live service graph for FinanceFlow
2. Confirm all edges show the padlock icon (mTLS active)
3. Apply `peerauthentication-mtls.yaml` (`mode: STRICT`) — no plain-text traffic allowed
4. Exec into a pod without a sidecar and try plain HTTP to account-service — observe the connection reset
5. Discuss: mTLS in a financial system means stolen network packets cannot be decrypted

### Lab 5c — Canary Deployment: Account Service v1.1
1. Label the existing account-service pods `version: v1.0`; deploy `deployment-account-service-v11.yaml` (1 replica, `version: v1.1`) alongside them
2. Apply `destinationrule-account-service.yaml` — defines subsets `v1-0` and `v1-1` by pod label
3. Apply `virtualservice-account-service.yaml` — routes 90% to v1.0, 10% to v1.1
4. Generate traffic and watch the split live in Kiali's traffic graph
5. Gradually shift weights: 50/50 → 100% v1.1; roll back instantly with `virtualservice-account-service-stable.yaml`
6. Discuss: canary releases are the standard for zero-risk deployments in financial systems

### Lab 5d — Circuit Breaking: Transaction Service
1. Apply `destinationrule-transaction-service.yaml` — outlier detection settings (consecutive errors, ejection window)
2. Patch the transaction-service readiness probe to point at a non-existent path, simulating a failing pod
3. Generate load — watch Envoy eject the failing pod from the load-balancing pool
4. Observe the ejected pod in Kiali; restore the probe and observe recovery after the ejection window

### Key Manifests
- `chapters/05-service-mesh/manifests/smcp.yaml` (Istio + IstioCNI, `sailoperator.io/v1`)
- `chapters/05-service-mesh/manifests/smmr.yaml` (namespace label, not a ServiceMeshMemberRoll)
- `chapters/05-service-mesh/manifests/peerauthentication-mtls.yaml`
- `chapters/05-service-mesh/manifests/destinationrule-account-service.yaml`
- `chapters/05-service-mesh/manifests/virtualservice-account-service.yaml`
- `chapters/05-service-mesh/manifests/virtualservice-account-service-stable.yaml`
- `chapters/05-service-mesh/manifests/deployment-account-service-v11.yaml`
- `chapters/05-service-mesh/manifests/destinationrule-transaction-service.yaml`
- `chapters/05-service-mesh/manifests/kiali.yaml`

### Key Commands
```bash
oc get istio -n istio-system
oc get istiocni -n istio-cni
oc get namespace financeflow-workshop --show-labels | grep istio-injection
oc get pods -n financeflow-workshop    # look for 2/2 READY
oc get peerauthentication
oc get virtualservice
oc get destinationrule
```

### Instructor Notes
- OSSM 3 installation takes 5–10 min; pre-install and verify before the workshop
- Kiali is the star of this chapter — keep it open throughout all labs
- The canary lab with live traffic split in Kiali is the most visually impressive moment in the whole workshop
- Circuit breaking: a steady load loop is enough to trigger ejection once the readiness probe is broken
- Connect to the financial theme: a payment processor must never cascade a failure through the whole system

---

---

## Chapter 6 — CI/CD: OpenShift Pipelines & GitOps

**Duration:** 90 min
**Goal:** Build a complete CI/CD pipeline that automatically tests and builds FinanceFlow on every git push, then deploys it via GitOps with zero manual `oc apply` commands.

### Concepts

**CI — OpenShift Pipelines (Tekton)**
- `Task` — a unit of work (clone, test, build, push)
- `Pipeline` — an ordered graph of Tasks with shared Workspaces
- `PipelineRun` / `TaskRun` — execution instances
- `Workspace` — shared storage between Tasks (PVC or emptyDir)
- **ClusterTasks** — reusable Tasks shipped with OpenShift Pipelines (`git-clone`, `buildah`, `s2i-python`, etc.)
- **Tekton Triggers**: `EventListener` → `TriggerBinding` → `TriggerTemplate` → `PipelineRun`
- **Cluster resolver**: shared Tasks (`git-clone`, `buildah`, `openshift-client`) live in the `openshift-pipelines` namespace and are referenced via `resolver: cluster` — ClusterTasks were removed in OpenShift Pipelines 1.17

**CD — OpenShift GitOps (ArgoCD)**
- Git as the single source of truth for cluster state
- `Application` CRD — maps a Git repo path to a cluster namespace
- **Sync policies**: manual vs automated, self-healing, pruning
- **App-of-Apps pattern** — one parent Application managing multiple child Applications
- **Kustomize overlays** — environment promotion (dev → staging → prod)

### Full CI/CD Flow
```
Developer → git push
               |
         GitHub Webhook
               |
         EventListener (financeflow-webhook)
               |
    TriggerBinding extracts repo-url/revision
               |
    TriggerTemplate creates a PipelineRun (account-service, on push to main)
               |
  clone → test → build (buildah) → tag :stable (ImageStream) → update-manifest
                                                                       |
                                                    commits new image tag to
                                                    chapters/02-deployments/manifests/
                                                    deployment-<service>.yaml in git
               |
         ArgoCD detects diff
               |
    Auto-sync (selfHeal + prune) → cluster updated, replicas left to the HPA
               |
         FinanceFlow updated in prod
         with zero manual intervention
```

### Lab 6a — Install Operators
1. Install **Red Hat OpenShift Pipelines** and **Red Hat OpenShift GitOps** from OperatorHub
2. Shared Tekton Tasks (`git-clone`, `buildah`, `openshift-client`) live in the `openshift-pipelines` namespace — verify: `oc get tasks -n openshift-pipelines`
3. Get the ArgoCD admin password and Route from the `openshift-gitops` namespace

### Lab 6b — Build the CI Pipeline
1. `financeflow-pipeline` is a single parametrized `Pipeline` reused for every service (`service`, `image-name`, `image-tag` params) with 5 Tasks:
   - `clone` — `git-clone` via the cluster resolver
   - `test` — custom Task `run-tests` (pytest)
   - `build` — `buildah` via the cluster resolver
   - `tag-image` — `openshift-client` via the cluster resolver, tags the ImageStream `:stable`
   - `update-manifest` — custom Task that edits the Deployment YAML and pushes to git
2. Grant the `financeflow-cicd` ServiceAccount (Chapter 4) `registry-editor` and the `privileged` SCC (needed for rootless buildah)
3. Create a `PipelineRun` manually for account-service and watch it in the Web Console Pipelines DAG view

### Lab 6c — Fail Fast: Test Gate
1. Introduce a deliberate test failure in the account service
2. Trigger the pipeline — watch it stop at the `test` Task, never reaching `build`
3. Fix the test — watch the full pipeline succeed
4. Discuss: in financial software, a test gate prevents broken payment logic from ever reaching an image

### Lab 6d — Git Webhook Triggers
1. `triggerbinding-github.yaml` extracts `repo-url`, `revision`, `ref` from the GitHub push payload
2. `triggertemplate-financeflow.yaml` maps those into a `PipelineRun` for account-service (the simplest end-to-end loop for the workshop)
3. `eventlistener.yaml` validates the webhook HMAC secret and filters for `refs/heads/main`; `route-eventlistener.yaml` exposes it externally
4. Register the Route URL as a webhook in the GitHub repository
5. Push a commit to `app/account-service/` — watch the pipeline start automatically within seconds

### Lab 6e — GitOps: Create the ArgoCD Application
1. No separate `gitops/` repo or dev/prod overlays — the `Application` (`argocd-app-financeflow.yaml`) points straight at `chapters/02-deployments/manifests` in this repo and syncs into `financeflow-workshop`
2. The `AppProject` (`argocd-project.yaml`) whitelists only the resource kinds FinanceFlow needs (Deployment, Service, ConfigMap, Route, HPA, NetworkPolicy) — **Secrets are not whitelisted**
3. Log in to the ArgoCD UI; apply both manifests into `openshift-gitops`
4. Trigger a manual sync — watch ArgoCD apply the manifests

### Lab 6f — Self-Healing & Automated Sync
1. `syncPolicy.automated` has `selfHeal: true` and `prune: true`; `ignoreDifferences` excludes `spec.replicas` so ArgoCD never fights the HPA
2. Make a manual `oc scale deployment account-service --replicas=1`
3. Watch ArgoCD detect the drift and restore `replicas: 2` within ~3 minutes (default poll interval)
4. Make a code change → git push → CI pipeline builds → updates image tag in Git → ArgoCD deploys automatically
5. End-to-end: from `git push` to running pod with new code — measure the time

### Key Manifests
- `chapters/06-cicd/manifests/pvc-pipeline-source.yaml`
- `chapters/06-cicd/manifests/task-run-tests.yaml`
- `chapters/06-cicd/manifests/task-update-manifest.yaml`
- `chapters/06-cicd/manifests/pipeline-financeflow.yaml`
- `chapters/06-cicd/manifests/pipelinerun-account-service.yaml`
- `chapters/06-cicd/manifests/pipelinerun-transaction-service.yaml`
- `chapters/06-cicd/manifests/triggerbinding-github.yaml`
- `chapters/06-cicd/manifests/triggertemplate-financeflow.yaml`
- `chapters/06-cicd/manifests/eventlistener.yaml`
- `chapters/06-cicd/manifests/route-eventlistener.yaml`
- `chapters/06-cicd/manifests/secret-github-webhook.yaml` (placeholder — create the real secret imperatively)
- `chapters/06-cicd/manifests/argocd-project.yaml` (apply into `openshift-gitops`)
- `chapters/06-cicd/manifests/argocd-app-financeflow.yaml` (apply into `openshift-gitops`)

### Key Commands
```bash
# Tekton
oc get tasks -n openshift-pipelines
oc get pipeline && oc get pipelinerun
oc create -f chapters/06-cicd/manifests/pipelinerun-account-service.yaml   # generateName — use create, not apply
oc logs -f pipelineruns/<name> --all-containers

# ArgoCD
oc get application financeflow -n openshift-gitops
oc patch application financeflow -n openshift-gitops --type=merge -p '{"operation":{"sync":{}}}'
```

### Instructor Notes
- The Web Console Pipelines DAG view is a highlight — keep it visible during Lab 6b/6c
- Lab 6c (test gate failure) is the most impactful CI demo — make the failure obvious
- Lab 6f self-healing is the most impactful CD demo — the audience finds it almost magical
- Fork the workshop repo to a GitHub account the cluster can reach — the webhook needs a public URL
- The end-to-end timing in Lab 6f is satisfying: typically 3–5 min from `git push` to running pod
- Common gotcha: `pipeline-source` PVC is `ReadWriteOnce` — fine here since Tasks run sequentially, not in parallel

---

---

## Chapter 7 — OpenTelemetry & Observability

**Duration:** 90 min
**Goal:** Instrument FinanceFlow with OpenTelemetry to trace financial transactions end-to-end, monitor service health, and correlate signals across traces, metrics, and logs.

### Concepts
- **The three pillars**: Traces, Metrics, Logs — and why OTel unifies them
- **OpenTelemetry SDK** — language-level instrumentation (auto-instrumentation vs manual spans)
- **OTel Collector** — vendor-neutral telemetry pipeline
  - Receivers, Processors, Exporters
- **Distributed tracing** — following a transaction across portal → account service → transaction service → DB
- **OpenShift monitoring** (Prometheus + Alertmanager)
  - `ServiceMonitor` — scrape your app's `/metrics` endpoint
  - `PrometheusRule` — custom alerting rules
- **Correlation** — linking trace ID across logs and metrics

### Observability Architecture
```
[Portal]
    |  HTTP headers (W3C Trace Context propagation)
[Account Service (OTel SDK)]
    |  HTTP headers
[Transaction Service (OTel SDK)]
    |  OTLP/gRPC :4317
[OTel Collector]
    |            |
 [Tempo]   [Prometheus]
 (traces,  (re-exported
  via       /metrics +
  jaegerui  ServiceMonitor
  Route)    scrape)
    |            |
    └────── [Grafana] ──────┘
                 |
          OpenShift Observe
          (Web Console)
```

> **Version note:** Tempo ships no UI of its own. `tempo.yaml` is a `TempoMonolithic` CR (in-memory storage, no object storage/S3 needed) with `jaegerui.enabled: true`, so the workflow below looks like a native Jaeger UI but the Route is `tempo-financeflow-jaegerui`.

### Lab 7a — Enable User-Workload Monitoring
1. Patch `cluster-monitoring-config` in `openshift-monitoring` to set `enableUserWorkload: true`
2. Wait for `prometheus-user-workload-*` and `thanos-ruler-user-workload-*` pods to start
3. (If needed) grant the `prometheus-user-workload` SA `view` on `financeflow-workshop` with `oc adm policy add-role-to-user`

### Lab 7b — Deploy Tempo and the OTel Collector
1. Install the **OpenTelemetry Operator** (Tempo Operator was already installed in Chapter 5)
2. Apply `tempo.yaml` (`TempoMonolithic`, 2Gi in-memory storage, Jaeger-compatible UI + Route) — wait for the `tempo-financeflow` pod, then confirm `oc get route tempo-financeflow-jaegerui`
3. Apply `otel-collector.yaml` (`OpenTelemetryCollector` CR) — its traces pipeline exports to **both** `debug` (collector logs) and `otlp/tempo` (`tempo-financeflow:4317`); its metrics pipeline re-exports on `:8889` for Prometheus to scrape
4. Verify the Collector pod is running and its auto-created Service is reachable from account-service on port 4317

### Lab 7c — Instrument the Services with the OTel SDK
1. Add `opentelemetry-sdk`, `-exporter-otlp-proto-grpc`, `-instrumentation-flask`, `-instrumentation-sqlalchemy`, `-instrumentation-requests` to each service's `requirements.txt`
2. In `app.py`: build a `TracerProvider` with a `BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_EXPORTER_OTLP_ENDPOINT))`, then call `FlaskInstrumentor().instrument_app(app)` and `SQLAlchemyInstrumentor().instrument()` — **zero changes to business logic**, just setup code (see `otel-instrumentation-snippet.py`)
3. Add `OTEL_EXPORTER_OTLP_ENDPOINT: "http://financeflow-collector:4317"` to both ConfigMaps
4. Rebuild both images and `oc rollout restart` both Deployments

### Lab 7d — Prometheus Metrics
1. Apply the three `ServiceMonitor`s (`account-service`, `transaction-service`, `otel-collector`) — picked up automatically once UWM is enabled, no special namespace label needed
2. Generate load, then query in **Administrator → Observe → Metrics**:
   - `rate(http_requests_total{namespace="financeflow-workshop"}[2m])`
   - `account_balance_dollars`
   - `rate(transfer_requests_total{status="success"}[5m]) / rate(transfer_requests_total[5m])`
   - `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{namespace="financeflow-workshop"}[5m]))`

### Lab 7e — Alerting with PrometheusRule
1. Apply `prometheusrule-financeflow.yaml` — seven rules across availability, error-rate, latency, and resource groups (e.g. `AccountServiceDown`, `HighTransferErrorRate`, `SlowTransferProcessing`, `PodMemoryNearLimit`)
2. View them in **Administrator → Observe → Alerting**, filtered to `financeflow-workshop` — all `Inactive`
3. Scale `account-service` to 0 replicas; after ~90s `AccountServiceDown` fires `Firing`/`critical`; restore replicas

### Lab 7f — Distributed Tracing with Tempo
1. Open the `tempo-financeflow-jaegerui` Route
2. Make a transfer through the portal
3. **Service**: `transaction-service`, **Operation**: `POST /api/transactions/transfer`, **Find Traces** — see the full waterfall: transaction-service → its own DB query → account-service PATCH → account-service's DB update → transaction-service's INSERT, each with exact timing
4. Sort by **Longest First** to identify the bottleneck span; inspect its `db.statement`/`http.url` tags

### Lab 7g — Grafana Dashboard
1. Apply `grafana-dashboard-configmap.yaml` (sidecar-discovered via the `grafana_dashboard: "true"` label) into the `grafana` namespace's Grafana instance (deployed via the Grafana Operator, Prometheus datasource proxied through Thanos querier)
2. With load running, the dashboard shows Request Rate, Error Rate, P99 Latency, Transfer Volume, Active Account Balances, and Transfer Success Rate

### Key Manifests
- `chapters/07-observability/manifests/tempo.yaml`
- `chapters/07-observability/manifests/otel-collector.yaml`
- `chapters/07-observability/manifests/otel-instrumentation-snippet.py`
- `chapters/07-observability/manifests/servicemonitor-account-service.yaml`
- `chapters/07-observability/manifests/servicemonitor-transaction-service.yaml`
- `chapters/07-observability/manifests/servicemonitor-otel-collector.yaml`
- `chapters/07-observability/manifests/podmonitor-istio-sidecar.yaml`
- `chapters/07-observability/manifests/prometheusrule-financeflow.yaml`
- `chapters/07-observability/manifests/grafana-dashboard-configmap.yaml`
- `chapters/07-observability/manifests/grafana/` (Operator, instance, datasource, Route — separate namespace `grafana`)

### Key Commands
```bash
oc get pods -n openshift-user-workload-monitoring
oc get pods -l app.kubernetes.io/managed-by=tempo-operator
oc get route tempo-financeflow-jaegerui
oc get opentelemetrycollector financeflow
oc get servicemonitor
oc get prometheusrule
oc get route grafana -n grafana
```

### Instructor Notes
- OTel SDK instrumentation (Lab 7c) is the wow-moment of this chapter: a handful of setup lines, zero business-logic changes, full traces
- Pre-generate some transfers before the trace walkthrough so Tempo has interesting data
- The financial context makes every metric meaningful: "a 5% error rate on transfers means real money lost"
- Tempo's `jaegerui` feature means the UI walkthrough is identical to native Jaeger — don't over-explain the swap, just note it happened

---

---

## Appendix A — Workshop Infrastructure Checklist

Before the workshop begins, verify the following are installed and healthy on the cluster:

| Component | Namespace | Verify With |
|-----------|-----------|-------------|
| OpenShift 4.18+ (validated on 4.21; enforced by the preflight script) | — | `oc version` |
| Metrics Server | `openshift-monitoring` | `oc get hpa` succeeds |
| OpenShift Pipelines (Tekton) | `openshift-operators` | `oc get tasks -n openshift-pipelines` (ClusterTasks removed in 1.17) |
| OpenShift Pipelines Triggers | `openshift-pipelines` | `oc get crd eventlisteners` |
| OpenShift Service Mesh 3 (`servicemeshoperator3`, Sail) | `istio-system` | `oc get istio -n istio-system` |
| OpenShift GitOps (ArgoCD) | `openshift-gitops` | ArgoCD Route accessible |
| OpenTelemetry Operator | `openshift-operators` | `oc get crd opentelemetrycollectors` |
| Tempo Operator | `openshift-operators` | `oc get crd tempomonolithics` |
| Prometheus (built-in) | `openshift-monitoring` | Web Console → Observe → Metrics |
| Kiali Operator (`kiali-ossm`) | `openshift-operators` | `oc get kiali` |

See `chapters/00-prerequisites/manifests/missing-operators/` for ready-to-apply Subscriptions for every operator above.

---

## Appendix B — Directory Structure (Full Workshop Kit)

```
openshift-containerization-demo/
├── WORKSHOP.md                        ← This file
├── app/
│   ├── portal/                        ← Nginx + Vanilla JS finance dashboard
│   ├── account-service/               ← Python Flask: account management
│   ├── transaction-service/           ← Python Flask: transfers & payments
│   └── database/                      ← PostgreSQL init scripts
└── chapters/
    ├── 00-prerequisites/
    │   ├── manifests/missing-operators/   ← Subscriptions for every required operator
    │   ├── trainer/                       ← Pre-workshop cluster prep notes
    │   └── demo/
    ├── 01-builds/
    │   ├── manifests/                 ← ImageStreams, BuildConfigs
    │   ├── lab/                       ← Step-by-step lab guide
    │   └── demo/                      ← Instructor demo script
    ├── 02-deployments/
    │   ├── manifests/
    │   ├── lab/
    │   └── demo/
    ├── 03-networking/
    ├── 04-security/
    ├── 05-service-mesh/
    ├── 06-cicd/
    ├── 07-observability/
    └── slides/                        ← Slide deck per chapter (e.g. 06-cicd-slides/)
```

---

## Appendix C — Suggested Schedule

| Time Block | Duration | Activity |
|------------|----------|----------|
| 09:00–09:30 | 30 min | Chapter 0 — Setup & Prerequisites |
| 09:30–10:30 | 60 min | Chapter 1 — Builds & Images |
| 10:30–10:45 | 15 min | Break |
| 10:45–11:45 | 60 min | Chapter 2 — Deployments & Scaling |
| 11:45–12:45 | 60 min | Chapter 3 — Networking & Routing |
| 12:45–13:30 | 45 min | Lunch |
| 13:30–14:45 | 75 min | Chapter 4 — Security & RBAC |
| 14:45–16:15 | 90 min | Chapter 5 — Service Mesh |
| 16:15–16:30 | 15 min | Break |
| 16:30–18:00 | 90 min | Chapter 6 — CI/CD: Pipelines & GitOps |
| 18:00–19:30 | 90 min | Chapter 7 — OpenTelemetry & Observability |
| 19:30–19:45 | 15 min | Wrap-up & Q&A |

**Total: ~10.5 hours (full-day workshop)**

**Half-day format (5 hrs):** Chapters 0–4 only; Chapter 5 as instructor demo.
**Two-day format:** Day 1 = Chapters 0–4, Day 2 = Chapters 5–7.

---

*Workshop validated on OpenShift 4.21 (OpenShift Service Mesh 3 / Sail Operator, Tempo Operator); minimum 4.18, enforced by `chapters/00-prerequisites/demo/cluster-preflight-check.sh`.*
