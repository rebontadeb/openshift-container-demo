> **TRAINER ONLY — Complete this guide 24 hours before the workshop.**
> Students do not receive or follow this document.

# Trainer Setup Guide — Chapter 0: Prerequisites

---

## Purpose

This guide walks the trainer through everything that must be in place **before students arrive**. By the end, every student should be able to log in, run `oc whoami`, and have a working namespace — without troubleshooting on day one.

---

## Timeline

| When | Action |
|------|--------|
| 48 h before | Cluster access verified, operators installed |
| 24 h before | Student namespaces created, registry exposed, pre-flight passes |
| 1 h before | Run pre-flight check one final time, share login details |
| Workshop start | Demo the cluster (use `demo/00-prerequisites-demo.sh`) |

---

## Step 1 — Verify Cluster Access (Trainer)

```bash
oc login https://api.<cluster-domain>:6443 \
  --username=<cluster-admin-user> \
  --password=<cluster-admin-password>

oc whoami         # must print your admin username
oc get nodes      # all nodes must show Ready
oc get clusterversion
```

Minimum OCP version: **4.18** (validated on 4.21; this is also the hard floor enforced by `cluster-preflight-check.sh`). If the cluster is older, stop — the workshop uses `autoscaling/v2` (HPA), `tekton.dev/v1`, `sailoperator.io/v1` (OpenShift Service Mesh 3 / Sail Operator — OSSM 2's `maistra.io/v2` is end-of-life), and restricted-v2 SCC (default since 4.11, standard in 4.18).

---

## Step 2 — Apply the Project Request Template

This installs the OpenShift Project Template that auto-labels every new project `region: apac-workshop` and injects a per-namespace LimitRange + ResourceQuota at project creation time.

```bash
# 1. Install the template in openshift-config (cluster-admin required)
oc apply -f chapters/00-prerequisites/trainer/project-template.yaml

# 2. Point the cluster at this template for all new project requests
oc patch project.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"projectRequestTemplate":{"name":"project-request"}}}'

# Verify the template is installed
oc get template project-request -n openshift-config
```

> After this step, **any** `oc new-project` or Web Console project creation will automatically:
> - label the namespace `region: apac-workshop`
> - bind the requesting/admin user with the `admin` ClusterRole on their namespace
> - inject a LimitRange (default 100m/128Mi req, 500m/256Mi limits; max 2 CPU/1Gi per container)
> - inject a per-namespace ResourceQuota (10 pods, 1/2 CPU, 1/2 Gi memory, 5 PVCs, no NodePort/LoadBalancer Services)
>
> There is no separate cluster-wide `ClusterResourceQuota` in this workshop — quota is enforced per-namespace only. If you need an aggregate ceiling across all student namespaces, add a `ClusterResourceQuota` selecting `region: apac-workshop` yourself; it isn't part of this repo.

---

## Step 3 — Create Student Projects

This workshop doesn't ship a bulk-creation script — create each student's project with `oc new-project` (the template above handles labelling/quota automatically), or write your own loop over your roster:

```bash
for student in student01 student02 student03; do
  oc new-project "${student}-$(date +%d%m%y)" \
    --display-name="FinanceFlow — ${student}" 2>/dev/null || echo "Project for ${student} already exists"
done
```

Expected output per student:
```
  Now using project "student01-070626" on server "https://api.<cluster-domain>:6443".
```

Verify all projects are labelled:
```bash
oc get namespaces -l region=apac-workshop
```

---

## Step 4 — Expose the Internal Image Registry

Builds in Chapter 1 push to the internal registry. The default route must be enabled:

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge \
  -p '{"spec":{"defaultRoute":true}}'

# Verify
oc get route default-route -n openshift-image-registry
```

---

## Step 5 — Install Required Operators

Install each operator from **Administrator → OperatorHub**, or apply the ready-made Subscriptions in `chapters/00-prerequisites/manifests/missing-operators/`. Install Service Mesh first — it pulls in Tempo and Kiali as dependencies for Chapter 5's tracing/Kiali integration.

```bash
# Apply all six Subscriptions in one shot
oc apply -k chapters/00-prerequisites/manifests/missing-operators/

# Verify what's installed
oc get csv -A | grep -E "pipelines|gitops|servicemesh3|tempo|kiali|opentelemetry"
```

| Operator | Required for | OperatorHub / package name |
|----------|-------------|-----------------|
| OpenShift Pipelines | Chapter 6 | Red Hat OpenShift Pipelines (`openshift-pipelines-operator-rh`) |
| OpenShift GitOps | Chapter 6 | Red Hat OpenShift GitOps (`openshift-gitops-operator`) |
| OpenShift Service Mesh 3 | Chapter 5 | Red Hat OpenShift Service Mesh (`servicemeshoperator3`, Sail Operator) |
| Tempo | Chapters 5, 7 | Tempo Operator (`tempo-product`) — replaces the deprecated Jaeger operator |
| Kiali | Chapter 5 | Kiali Operator (Red Hat) (`kiali-ossm`) |
| OpenTelemetry | Chapter 7 | Red Hat build of OpenTelemetry (`opentelemetry-product`) |

All installs: keep all defaults, install to all namespaces, wait for `Succeeded` CSV status.

```bash
# Poll until all CSVs are Succeeded (run after each install)
oc get csv -A --no-headers | grep -v Succeeded
# Should eventually return nothing
```

---

## Step 6 — Verify the Default StorageClass

PostgreSQL (Chapter 2) needs a PVC. A default StorageClass must exist:

```bash
oc get storageclass
# One entry must have (default) in the name column
```

If no default exists, patch one:
```bash
# Replace gp3 with the actual StorageClass name on your cluster
oc patch storageclass gp3 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## Step 7 — Run the Pre-flight Check

```bash
chmod +x chapters/00-prerequisites/demo/cluster-preflight-check.sh
NAMESPACE=financeflow-workshop \
  ./chapters/00-prerequisites/demo/cluster-preflight-check.sh
```

Expected result:
```
PASS: 10+   WARN: 0–2   FAIL: 0
```

**Zero FAIL items required before proceeding.** WARN items for operators not yet installed are acceptable — those operators are installed in the relevant chapter.

---

## Step 8 — Prepare Student Login Details

Distribute to students (via Slack, printed card, or shared doc):

```
Cluster API URL:     https://api.<cluster-domain>:6443
Web Console URL:     https://console-openshift-console.apps.<cluster-domain>
Your username:       <per student>
Your password:       <per student>
Your project:        {username}-DDMMYY  (printed on your handout)
Repository:          https://github.com/<YOUR_ORG>/openshift-containerization-demo.git
```

---

## Step 9 — Day-of Checklist

Run immediately before students join:

```bash
# All nodes Ready
oc get nodes | grep -v Ready
# should return nothing

# Registry route live
oc get route default-route -n openshift-image-registry

# Project template installed
oc get template project-request -n openshift-config

# Student projects exist with correct label
oc get namespaces -l region=apac-workshop

# Pre-flight one more time
./chapters/00-prerequisites/demo/cluster-preflight-check.sh

# Open these browser tabs before presenting:
# - Web Console (Developer perspective, Topology)
# - Web Console (Administrator perspective, Operators)
echo "Console: $(oc whoami --show-console)"
```

---

## What Students Receive

Students only need to:
1. Install `oc` CLI on their laptop (provide the download URL)
2. Run `oc login` with the credentials you hand them
3. Run `git clone` on the workshop repo
4. Set `oc project financeflow-workshop`

Everything else in this guide is invisible to them — they land in a ready-to-use namespace.
