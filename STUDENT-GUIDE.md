# FinanceFlow Workshop — Student Guide

## About this workshop

FinanceFlow is a 4-tier sample banking app (Nginx portal, two Python Flask
services, PostgreSQL) used across 8 chapters to teach OpenShift Container
Platform hands-on:

| # | Chapter | Topics |
|---|---------|--------|
| 0 | Prerequisites | `oc` CLI, cluster login, namespaces |
| 1 | Builds & Images | Dockerfile/S2I builds, ImageStreams, BuildConfigs |
| 2 | Deployments & Scaling | Deployments, health probes, HPA, rolling updates |
| 3 | Networking & Routing | Services, Routes, NetworkPolicies |
| 4 | Security & RBAC | SCCs, ServiceAccounts, RBAC, Secrets |
| 5 | Service Mesh | Istio/OSSM, mTLS, canary traffic, circuit breaking |
| 6 | CI/CD | Tekton Pipelines, Triggers, ArgoCD/GitOps |
| 7 | Observability | OpenTelemetry, Tempo tracing, Prometheus, Grafana |

Full curriculum and lab-by-lab detail: `WORKSHOP.md`.

Every student deploys FinanceFlow into their **own namespace** — none of
these commands touch anyone else's. Replace `<your-name>` below with your
own short name (lowercase, no spaces — e.g. `alice`).

Commands below assume the repo is cloned to `$REPO_ROOT` — set that once
and every command works regardless of your current directory:

```bash
export REPO_ROOT=~/ocp-demo-namespace-agnostic
```

---

## 1. Log in to the cluster

```bash
oc login https://api.<cluster-domain>:6443 --token=<your-token>
oc whoami
```

## 2. Clone the workshop repo

```bash
git clone <repo-url> "$REPO_ROOT"
```

## 3. Set your namespace across the repo

```bash
"$REPO_ROOT"/chapters/set-namespace.sh financeflow-<your-name>
```

Review the changes (optional):

```bash
git -C "$REPO_ROOT" diff --stat
```

## 4. Prepare the cluster (one-time, run once per cluster)

```bash
"$REPO_ROOT"/chapters/prepare-cluster.sh
```

## 5. Deploy FinanceFlow into your namespace

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh
```

Follow the on-screen pauses — press Enter to advance one step at a time. To run straight through without pauses:

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh -y
```

## 6. Verify it's running

```bash
oc get pods -n financeflow-<your-name>
oc get route portal -n financeflow-<your-name>
```

Open the printed route URL in your browser.

## 7. Resume after a crash (if needed)

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --list
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from <step-number>
```

## 8. Clean up at the end of the workshop

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/cleanup-demo.sh
```
