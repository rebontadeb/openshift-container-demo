> **TRAINER ONLY — Presentation delivered by the trainer at the start of the workshop.**

# Chapter 0
## Prerequisites & Workshop Setup

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Welcome

**What we're building over this workshop:**

```
Internet
    │
[HAProxy Router]
    │
[Portal — nginx]          ← Chapter 3: Route + NetworkPolicy
    │
[Account Service]         ← Chapter 2: Deployment + HPA
[Transaction Service]     ← Chapter 4: RBAC + SCC
    │
[PostgreSQL + PVC]        ← Chapter 2: PVC + Recreate strategy

All wrapped with:
  Service Mesh (Ch 5) → mTLS + canary deployments (OSSM 3 / Sail)
  CI/CD (Ch 6)        → Tekton + ArgoCD
  Observability (Ch 7)→ OTel + Prometheus + Tempo
```

By the end: a production-grade financial application running on OpenShift, built entirely from code.

---

## Workshop Chapters

| Ch | Topic | Duration |
|----|-------|----------|
| 0  | Prerequisites (this session) — includes the project template's LimitRange/ResourceQuota | 30 min |
| 1  | Builds & ImageStreams | 45 min |
| 2  | Deployments & Scaling | 60 min |
| 3  | Networking & Routing | 45 min |
| 4  | Security & RBAC | 45 min |
| 5  | Service Mesh | 60 min |
| 6  | CI/CD: Pipelines + GitOps | 60 min |
| 7  | OpenTelemetry & Observability | 60 min |

**Total:** ~7 hours (typically split over 2 days)

---

## What You Need — Laptop

| Tool | Version | Install |
|------|---------|---------|
| `oc` CLI | 4.18+ | mirror.openshift.com |
| `git` | any | system package manager |
| `podman` | 4.x+ | Optional — local testing only |
| `python3` | 3.9+ | Optional — verification scripts |
| Browser | Chrome / Firefox | For Web Console + Kiali |

**The `oc` CLI version must be within one minor version of the cluster.**

---

## What You Need — Access

- **OpenShift cluster** 4.18 or newer
- **Your credentials** — username/password or token from the platform team
- **Cluster API URL** — `https://api.<cluster-domain>:6443`
- **Web Console URL** — `https://console-openshift-console.apps.<cluster-domain>`

Verify before the workshop:
```bash
oc login https://api.<cluster-domain>:6443 \
  --username=<your-user> \
  --insecure-skip-tls-verify=false
oc whoami   # should print your username
```

---

## Cluster Requirements (for Instructors)

| Requirement | Minimum |
|-------------|---------|
| OCP version | 4.18+ |
| Worker nodes | 3 × 8 CPU / 32 GB RAM |
| Storage | Default StorageClass with dynamic provisioning |
| Image registry | Internal registry exposed (default route) |
| Network | Egress to `registry.access.redhat.com` and `quay.io` |
| Operators | Pipelines, GitOps, Service Mesh 3 (Tempo, Kiali), OpenTelemetry |

---

## Cluster Access — Two Ways

**Web Console (browser):**
```
https://console-openshift-console.apps.<cluster-domain>
→ Developer perspective  (day-to-day: topology, logs, builds)
→ Administrator perspective  (cluster-wide: nodes, operators, quotas)
```

**CLI (`oc`):**
```bash
# Login with username/password
oc login https://api.<cluster-domain>:6443 -u <user> -p <password>

# Login with token (from Web Console → ? → Copy login command)
oc login --token=sha256~... --server=https://api.<cluster-domain>:6443
```

The `oc` CLI is `kubectl` plus OpenShift extensions.  
Every `kubectl` command works. `oc` adds Routes, Projects, Builds, SCCs.

---

## OpenShift vs Kubernetes — Quick Reference

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| Namespace | Namespace | Project (wraps Namespace) |
| External exposure | Ingress | **Route** (HAProxy-backed) |
| Pod security | Pod Security Standards | **SCC** (Security Context Constraints) |
| Image builds | External CI only | **BuildConfig + ImageStream** |
| Developer UI | Dashboard (optional) | **Web Console** (built-in) |
| Service mesh | Install manually | **OSSM 3** (Istio/Sail, Kiali, Tempo) |
| CI/CD | Install manually | **Pipelines** (Tekton) + **GitOps** (ArgoCD) |

Everything in this workshop uses the OpenShift-native APIs.

---

## The Workshop Repository

```bash
git clone https://github.com/<YOUR_ORG>/openshift-containerization-demo.git
cd openshift-containerization-demo
```

Repository structure:
```
app/                      ← FinanceFlow source code (4 services)
chapters/
  00-prerequisites/       ← this chapter (project template includes LimitRange/ResourceQuota)
  01-builds/
  02-deployments/
  ...
  07-observability/
  slides/                 ← slide deck per chapter
WORKSHOP.md               ← chapter index and full outline
```

---

## Pre-flight Check

Run the automated check script before starting any labs:

```bash
chmod +x chapters/00-prerequisites/demo/cluster-preflight-check.sh
./chapters/00-prerequisites/demo/cluster-preflight-check.sh
```

Expected output:
```
── Local tools ──
  ✔ oc CLI found: 4.18.x
  ✔ git found: git version 2.43.x
  ⚠ podman not found — needed for local testing only

── Cluster access ──
  ✔ Logged in as: rdeb
  ✔ OCP version: 4.18.x (≥ 4.18 required)

── Permissions ──
  ✔ cluster-admin or sufficient permissions
...
PASS: 10  WARN: 2  FAIL: 0
  Cluster is workshop-ready.
```

---

## Student Setup — Three Things Only

The trainer has already prepared the cluster. Students need to:

1. **Install `oc` CLI** on their laptop
   - Download: `https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/`
2. **Log in** with the credentials on your handout:
   ```bash
   oc login https://api.<cluster-domain>:6443 -u <username> -p <password>
   oc project financeflow-workshop
   ```
3. **Clone the repo**:
   ```bash
   git clone https://github.com/<YOUR_ORG>/openshift-containerization-demo.git
   cd openshift-containerization-demo
   ```

That's it — namespace, quota, registry, and operators are already in place.

---

## Housekeeping

- Labs build on each other — don't skip chapters
- Every `oc` command in a lab references the `financeflow-workshop` namespace
- If you fall behind: each chapter's `manifests/` can be applied as a batch with `oc apply -k`
- The `demo/` scripts are for the instructor — follow along, don't run them yourself
- Red blocks = breaking; Yellow blocks = optional but recommended; Green blocks = verify/checkpoint

**Questions at any time — raise your hand or post in the workshop Slack channel.**
