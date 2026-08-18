# Prepare Cluster — Admin Guide

**FinanceFlow Workshop — OpenShift Container Capabilities**

This is the cluster-admin, run-once-per-cluster setup behind
`chapters/prepare-cluster.sh`, broken into individual steps. Run this
before any student starts [Deploy-Workshop.md](Deploy-Workshop.md).

> Prefer running the script instead of typing commands by hand?
> `./chapters/prepare-cluster.sh` does exactly what's below, with pauses
> between steps.

---

## Before You Start

- `oc` CLI installed and logged in with cluster-admin access
- Workshop repo cloned locally, running commands from the repo root

---

## Cluster Preparation (run once per cluster)

These steps install the operators and cluster-wide settings every later
chapter depends on. One person (the instructor, or whoever has
cluster-admin) runs this once; students then each get their own namespace
for the rest of the workshop.

### A1 — Verify you have cluster-admin

```bash
oc whoami
oc auth can-i '*' '*' --all-namespaces
```

If the second command doesn't print `yes`, stop — the rest of this guide will fail.

### A2 — Install the missing operators

Installs OpenShift Pipelines, GitOps, Service Mesh 3 (Sail Operator), Tempo,
Kiali, OpenTelemetry, and OpenShift Virtualization in one shot via a
Kustomize overlay of Subscriptions:

```bash
oc apply -k chapters/00-prerequisites/manifests/missing-operators/
```

### A3 — Wait for the six `openshift-operators` CSVs to succeed

```bash
watch -n15 "oc get csv -n openshift-operators | grep -iE 'pipelines|gitops|servicemesh|tempo|kiali|opentelemetry'"
```

Wait until every row shows `Succeeded`, then `Ctrl+C`.

### A4 — Wait for OpenShift Virtualization's CSV

`kubevirt-hyperconverged` installs into its own `openshift-cnv` namespace
with its own OperatorGroup — check it separately:

```bash
watch -n15 "oc get csv -n openshift-cnv"
```

Wait for `kubevirt-hyperconverged` to show `Succeeded`.

### A5 — Activate OpenShift Virtualization

The operator is installed, but virtualization itself isn't active until you
create its `HyperConverged` custom resource:

```bash
oc apply -f chapters/00-prerequisites/manifests/hyperconverged.yaml
```

```bash
watch -n15 "oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'"
```

Wait for `True`.

### A6 — Enable user-workload monitoring

Kiali's traffic graphs (Chapter 5) and the app's own ServiceMonitors
(Chapter 7) both need OpenShift's user-workload Prometheus, which is off by
default:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1 && \
  oc patch configmap cluster-monitoring-config -n openshift-monitoring \
    --type=merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}' || \
  oc create configmap cluster-monitoring-config -n openshift-monitoring \
    --from-literal=config.yaml="enableUserWorkload: true"
```

### A7 — Wait for user-workload monitoring pods

```bash
watch -n10 "oc get pods -n openshift-user-workload-monitoring"
```

Wait for `prometheus-user-workload-*` and `thanos-ruler-user-workload-*` to
show `Running`.

### A8 — Enable the Pipelines console plugin

The Pipelines operator installs its console plugin pod but doesn't switch it
on — without this, Developer → Pipelines stays empty in the web console even
though the Pipeline objects exist:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "pipelines-console-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
```

### A9 — Enable the GitOps console plugin

Same gap, same fix — ArgoCD Applications otherwise show nothing in-console:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "gitops-plugin" is missing from the list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
```

---

Cluster preparation is complete. Hand off to students — they continue at
[Deploy-Workshop.md](Deploy-Workshop.md), Part B, each in their own
namespace.
