# Lab 4 — Security & RBAC

**Chapter:** 4 | **Duration:** 45 min | **Complexity:** 🟡 Medium

---

## Objectives

By the end of this lab you will:
- Create dedicated Service Accounts for application and CI/CD workloads
- Understand SCCs and the privileges they grant or deny
- Create a custom SCC and bind it to a ServiceAccount
- Design and test least-privilege RBAC roles
- Verify that no workload identity can read Secrets

---

## Prerequisites

- Chapter 3 complete — all pods Running, Services and Routes in place
- Cluster-admin access for the SCC sections (4a–4b)
- Namespace-admin access is sufficient for the RBAC sections (4c–4d)

---

## Lab 4a — Service Accounts

### Step 1 — Examine the current situation

By default every pod in OpenShift runs under the `default` service account:

```bash
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'
```

All pods show `default`. This means all pods share the same identity — a compromised pod has the same API access as all other pods.

### Step 2 — Create dedicated Service Accounts

```bash
oc apply -f chapters/04-security/manifests/serviceaccount-financeflow.yaml
oc apply -f chapters/04-security/manifests/serviceaccount-cicd.yaml
oc get serviceaccounts
```

### Step 3 — Patch deployments to use the app Service Account

```bash
for deploy in account-service transaction-service portal; do
  oc patch deployment $deploy --type=json -p \
    '[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"financeflow-app"}]'
done
```

Wait for rollouts to complete:
```bash
oc rollout status deployment/account-service
oc rollout status deployment/transaction-service
oc rollout status deployment/portal
```

Verify the change:
```bash
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'
```

All non-postgres pods should now show `financeflow-app`.

### Step 4 — What does the default SA token allow?

```bash
# Check what the financeflow-app SA can currently do (before adding any roles)
oc auth can-i list pods \
  --as system:serviceaccount:financeflow-workshop:financeflow-app
# no

oc auth can-i get secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-app
# no
```

By default a new ServiceAccount has no permissions. Pods can still run — they just can't call the Kubernetes API.

---

## Lab 4b — Security Context Constraints

### Step 1 — List built-in SCCs

```bash
oc get scc
```

```
NAME                              PRIV    CAPS         SELINUX     RUNASUSER   FSGROUP    SUPGROUP   PRIORITY   READONLYROOTFS   VOLUMES
anyuid                            false   <no value>   MustRunAs   RunAsAny    RunAsAny   RunAsAny   10         false            ...
hostaccess                        false   <no value>   MustRunAs   MustRunAsRange RunAsAny RunAsAny  <no value> false            ...
nonroot                           false   <no value>   MustRunAs   MustRunAsNonRoot RunAsAny RunAsAny <no value> false          ...
privileged                        true    [*]          RunAsAny    RunAsAny    RunAsAny   RunAsAny   <no value> false            ...
restricted                        false   <no value>   MustRunAs   MustRunAsRange RunAsAny RunAsAny  <no value> false           ...
```

### Step 2 — Inspect the restricted SCC

```bash
oc describe scc restricted
```

Notice the `RunAsUser` strategy is `MustRunAsRange` — OpenShift assigns a UID from the namespace's allocated range (e.g., 1000620000–1000629999). Our Containerfile uses UID 1001 which falls outside this range — but `MustRunAsNonRoot` allows any non-root UID.

### Step 3 — Try running a container as root

```bash
oc run root-test \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --command -- sleep 3600 \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}'
```

```
Error from server (Forbidden): pods "root-test" is forbidden:
  unable to validate against any security context constraint:
  [spec.containers[0].securityContext.runAsUser: Invalid value: 0: must be in the ranges: [1000620000, ...]]
```

The SCC admission webhook blocks the pod before it ever schedules.

### Step 4 — Create the custom FinanceFlow SCC

```bash
oc apply -f chapters/04-security/manifests/scc-financeflow.yaml
oc describe scc financeflow-scc
```

Compare to `restricted` — our custom SCC explicitly sets `MustRunAsNonRoot` (any non-root UID, not a cluster-assigned range), drops ALL capabilities, and disallows host namespace access.

### Step 5 — Grant the SCC to the app ServiceAccount

```bash
# Declarative approach (preferred):
oc apply -f chapters/04-security/manifests/clusterrole-use-financeflow-scc.yaml
oc apply -f chapters/04-security/manifests/rolebinding-sa-use-scc.yaml

# Equivalent imperative command (for reference):
# oc adm policy add-scc-to-user financeflow-scc \
#   -z financeflow-app -n financeflow-workshop
```

### Step 6 — Verify pods use the correct SCC

```bash
# Check which SCC OpenShift assigned to running pods
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}'
```

Pods running as UID 1001 will match `financeflow-scc` (or `restricted` — OpenShift picks the most restrictive that passes). The annotation shows the actual SCC used.

---

## Lab 4c — RBAC

### Step 1 — Create the viewer and deployer roles

```bash
oc apply -f chapters/04-security/manifests/role-viewer.yaml
oc apply -f chapters/04-security/manifests/role-deployer.yaml
oc get roles
```

Inspect what each role allows:
```bash
oc describe role financeflow-viewer
oc describe role financeflow-deployer
```

Notice that `secrets` is absent from both roles — this is intentional.

### Step 2 — Create role bindings

```bash
oc apply -f chapters/04-security/manifests/rolebinding-viewer.yaml
oc apply -f chapters/04-security/manifests/rolebinding-deployer.yaml
oc get rolebindings
```

### Step 3 — Test viewer permissions with `oc auth can-i`

Simulate what a member of the `financeflow-developers` group can do:

```bash
# Allowed — read pods
oc auth can-i get pods \
  --as-group financeflow-developers \
  --as fake-dev-user \
  -n financeflow-workshop
# yes

# Allowed — read logs
oc auth can-i get pods/log \
  --as-group financeflow-developers \
  --as fake-dev-user \
  -n financeflow-workshop
# yes

# Blocked — cannot delete deployments
oc auth can-i delete deployments \
  --as-group financeflow-developers \
  --as fake-dev-user \
  -n financeflow-workshop
# no

# Blocked — cannot read secrets
oc auth can-i get secrets \
  --as-group financeflow-developers \
  --as fake-dev-user \
  -n financeflow-workshop
# no
```

### Step 4 — Test deployer permissions

Simulate what the CI/CD service account can do:

```bash
# Allowed — update deployments
oc auth can-i update deployments \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
# yes

# Allowed — create services
oc auth can-i create services \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
# yes

# Blocked — cannot read or create secrets
oc auth can-i get secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
# no

oc auth can-i create secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
# no
```

> **Why can't CI/CD touch secrets?** The pipeline deploys code changes — it has no business reading production database passwords. If the CI/CD service account token were compromised, the attacker still couldn't exfiltrate credentials. Platform admins own secret lifecycle.

### Step 5 — List all permissions for the CI/CD SA

```bash
oc auth can-i --list \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd \
  -n financeflow-workshop
```

This shows every (resource, verb) pair the SA can perform. A useful audit checklist.

### Step 6 — Who can delete pods? (policy audit)

```bash
oc policy who-can delete pods -n financeflow-workshop
```

This should show cluster-admins and namespace admins — not the `financeflow-developers` group.

---

## Lab 4d — Pod Security Context Audit

### Step 1 — Verify all pods are running as non-root

The FinanceFlow deployment manifests declare `runAsNonRoot: true` but do not pin `runAsUser` — the actual UID comes from each image's `USER` directive, subject to the SCC. Check the real running UID with:

```bash
for pod in $(oc get pods -l app=financeflow -o jsonpath='{.items[*].metadata.name}'); do
  echo -n "$pod: "
  oc exec "$pod" -- id 2>/dev/null || echo "(not exec-able)"
done
```

Expected output after Chapter 4 SA and SCC are in place:
```
account-service-*:     uid=1001(appuser) gid=1001(appgroup)
transaction-service-*: uid=1001(appuser) gid=1001(appgroup)
portal-*:              uid=1001 gid=0(root) groups=0(root)
```

> **Why the portal shows `gid=0`:** the portal Containerfile uses `chown 1001:0` + `chmod g+rwx` (group-0 ownership) rather than creating a dedicated group, so the supplemental group is 0 — the always-present group on OpenShift containers. This lets the portal work with any UID OpenShift assigns while still having write access to the nginx temp directories.

### Step 2 — Check QoS class and security annotations

```bash
oc get pods -o json | \
  jq -r '.items[] | [.metadata.name, .status.qosClass, (.metadata.annotations["openshift.io/scc"] // "none")] | @tsv'
```

### Step 3 — Try to exec into a pod and escalate

```bash
POD=$(oc get pod -l tier=account-service -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- id
# uid=1001 gid=1001 groups=1001

oc exec $POD -- whoami
# appuser  (or the username mapped to UID 1001 in the Containerfile)

# Can the app process write to the root filesystem?
oc exec $POD -- touch /test-file || echo "Read-only or permission denied"

# Can it install packages?
oc exec $POD -- pip install requests 2>&1 | head -3
# Writing to /root or attempting pip install will fail — non-root user
```

### Step 4 — Verify secrets are not world-readable inside the pod

```bash
# The mounted secret volume is only readable by the pod's UID
oc exec $POD -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/
```

---

## Checkpoint

```bash
# Service accounts exist
oc get serviceaccounts

# Custom SCC exists
oc get scc financeflow-scc

# Roles and bindings are in place
oc get roles
oc get rolebindings

# Deployments use financeflow-app SA
oc get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'

# No workload can read secrets
oc auth can-i get secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-app
# no
oc auth can-i get secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
# no
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod stuck in `Pending` after SA patch | SCC doesn't allow UID 1001 | `oc describe pod <name>` → check SCC admission error |
| `forbidden: unable to validate against any SCC` | SA not bound to SCC | `oc apply -f rolebinding-sa-use-scc.yaml` |
| `oc auth can-i` returns wrong answer | Cached policy — wait a few seconds | Re-run after 10s; RBAC propagation is async |
| `oc policy who-can` shows unexpected users | Inherited ClusterRoleBinding | `oc get clusterrolebindings | grep <namespace>` |
| Pod cannot call Kubernetes API | SA has no Role bound | Bind the appropriate Role or ClusterRole |

---

## Key Takeaways

- Every pod needs a dedicated ServiceAccount — `default` shares identity across all pods in the namespace
- SCCs are OpenShift's admission gate for pod privileges — `restricted` is the right starting point for all apps
- RBAC is additive: a subject gets the union of all bound roles — keep roles narrow
- Secrets must be excluded from developer and CI/CD roles — only platform admins create and rotate credentials
- `oc auth can-i` and `oc policy who-can` are your audit tools — run them after every RBAC change

---

*Next: [Lab 5 — Service Mesh](../../05-service-mesh/lab/05-service-mesh.md)*
