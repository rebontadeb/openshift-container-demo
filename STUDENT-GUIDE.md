# FinanceFlow Workshop — Student Guide

## About this workshop

FinanceFlow is a 4-tier sample banking app (Nginx portal, two Python Flask
services, PostgreSQL) used across 8 chapters to teach OpenShift Container
Platform hands-on. Full curriculum and lab-by-lab detail: `WORKSHOP.md`.

Deployment is driven by one script, `chapters/deploy-demo-resume.sh` — 52
numbered steps, grouped below by chapter. It pauses before every step and
prints the step's title, so running it is itself a walkthrough of what each
chapter does. You deploy into your **own namespace** — none of these
commands touch anyone else's.

Replace `<your-name>` below with your own short name (lowercase, no spaces
— e.g. `alice`). Set `REPO_ROOT` once and every command below works
regardless of your current directory:

```bash
export REPO_ROOT=~/ocp-demo-namespace-agnostic
```

## How to run one chapter at a time

The script pauses **before** each step and shows its title before running
it. That pause is your natural stop point:

1. Run with `--from <first step of the chapter>` (no `-y`).
2. Press Enter to advance through that chapter's steps one at a time.
3. When the title of the **next chapter's first step** appears, press
   `Ctrl+C` instead of Enter — nothing for the next chapter has run yet.
4. Resume later with `--from <next chapter's first step>`.

See every step number/title without running anything:

```bash
"$REPO_ROOT"/chapters/deploy-demo-resume.sh --list
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
git -C "$REPO_ROOT" diff --stat   # optional: review the changes
```

## 4. Prepare the cluster (one-time, run once per cluster)

```bash
"$REPO_ROOT"/chapters/prepare-cluster.sh
```

## 5. Deploy, chapter by chapter

Each block below runs just that chapter's steps (stop with `Ctrl+C` at the
next chapter's title, per **How to run one chapter at a time** above). Or
skip straight to **Deploy everything at once**.

### Chapter 0 — Prerequisites (steps 1–2)
Namespace + ServiceAccounts.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 1
```

| Step | Title |
|---|---|
| 1 | Create the namespace ($NAMESPACE) |
| 2 | Create ServiceAccounts financeflow-app / financeflow-cicd |

### Chapter 1 — Builds & Images (steps 3–8)
ImageStreams, BuildConfigs, Docker-strategy builds for all three services.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 3
```

| Step | Title |
|---|---|
| 3 | Create ImageStreams (account, transaction, portal) |
| 4 | Create BuildConfigs (account, transaction, portal) |
| 5 | Build and push financeflow-account:v1.0 |
| 6 | Build and push financeflow-transaction:v1.0 |
| 7 | Build and push financeflow-portal:v1.0 |
| 8 | Pin Chapter 2 manifests to the freshly-built :v1.0 tag |

### Chapter 2 — Deployments & Scaling (steps 9–14)
Postgres, all three service Deployments/Services, HPA.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 9
```

| Step | Title |
|---|---|
| 9 | Create the postgres-credentials Secret |
| 10 | Apply PVC, ConfigMaps, Postgres Deployment + Service |
| 11 | Apply account-service Deployment + Service |
| 12 | Apply transaction-service Deployment + Service |
| 13 | Apply portal Deployment + Service |
| 14 | Apply the account-service HPA |

### Chapter 3 — Networking & Routing (steps 15–17)
Route, NetworkPolicies, reachability check.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 15
```

| Step | Title |
|---|---|
| 15 | Apply the portal Route |
| 16 | Apply NetworkPolicies (deny-all + allow-lists) |
| 17 | Verify the app is reachable through the Route |

### Chapter 4 — Security & RBAC (steps 18–19)
Custom SCC, RBAC, restart workloads onto the hardened ServiceAccount.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 18
```

| Step | Title |
|---|---|
| 18 | Apply the SCC, ClusterRole, Roles, and RoleBindings |
| 19 | Restart account-service/transaction-service/portal to pick up financeflow-scc |

### Chapter 5 — Service Mesh (steps 20–31)
Istio control plane, sidecar injection, mTLS, canary traffic split, Kiali.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 20
```

| Step | Title |
|---|---|
| 20 | Create the Istio control plane (Sail Operator) — this can take a few minutes |
| 21 | Wait for Istio to report Healthy |
| 22 | Enroll the namespace in the mesh (istio-injection label) |
| 23 | Restart workloads to inject Envoy sidecars |
| 24 | Apply mTLS policy, DestinationRules, and the canary VirtualService |
| 25 | Deploy the account-service canary (v1.1) |
| 26 | Deploy Kiali and grant it cluster-monitoring-view |
| 27 | Ensure user-workload monitoring is enabled |
| 28 | Grant the monitoring SA permission to scrape this namespace, apply the istio-sidecar-metrics PodMonitor |
| 29 | Wait for the Kiali dashboard to come up |
| 30 | Generate traffic so the mesh has something to report |
| 31 | Verify istio_requests_total metrics reached Thanos |

### Chapter 6 — CI/CD: Pipelines & GitOps (steps 32–41)
Tekton Pipeline/Tasks, webhook triggers, ArgoCD Application.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 32
```

| Step | Title |
|---|---|
| 32 | Ensure the Pipelines and GitOps console plugins are enabled |
| 33 | Grant financeflow-cicd permission to push images and run buildah |
| 34 | Create the GitHub webhook Secret |
| 35 | Create git push credentials for the pipeline and link them to financeflow-cicd |
| 36 | Label the namespace for ArgoCD |
| 37 | Apply the Tekton Pipeline, Tasks, and the pipeline-source PVC |
| 38 | Apply the webhook Trigger chain (TriggerBinding, TriggerTemplate, EventListener, Route) |
| 39 | Apply the ArgoCD AppProject and Application (into openshift-gitops) |
| 40 | Trigger a manual PipelineRun for account-service |
| 41 | Trigger a manual PipelineRun for transaction-service |

### Chapter 7 — OpenTelemetry & Observability (steps 42–51)
Grafana, Tempo tracing, OTel Collector, ServiceMonitors, alerting rules.

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from 42
```

| Step | Title |
|---|---|
| 42 | Install the Grafana Operator |
| 43 | Generate the Thanos bearer token Secret for Grafana |
| 44 | Deploy the Grafana instance |
| 45 | Apply the Grafana datasource CR |
| 46 | Verify the datasource authenticates |
| 47 | Apply the Grafana Route and the Service Mesh dashboard |
| 48 | Apply ServiceMonitors and the PrometheusRule for app metrics/alerting |
| 49 | Deploy Tempo (TempoMonolithic) and its mTLS/NetworkPolicy exceptions |
| 50 | Deploy the OTel Collector |
| 51 | Apply the FinanceFlow overview dashboard |

Step 52 just prints the final summary (Route URLs, webhook secret, etc.).

### Deploy everything at once

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh
```

Or without pauses, straight through:

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh -y
```

---

## 6. Verify it's running

```bash
oc get pods -n financeflow-<your-name>
oc get route portal -n financeflow-<your-name>
```

Open the printed route URL in your browser.

## 7. Resume after a crash

Find where you left off, then jump back in:

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --list
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/deploy-demo-resume.sh --from <step-number>
```

## 8. Clean up at the end of the workshop

```bash
NAMESPACE=financeflow-<your-name> "$REPO_ROOT"/chapters/cleanup-demo.sh
```
