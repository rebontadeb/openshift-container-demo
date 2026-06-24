# Chapter 4
## Security & RBAC

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. Identity in OpenShift — humans vs workloads
2. Service Accounts
3. Security Context Constraints (SCCs)
4. RBAC — Roles, ClusterRoles, Bindings
5. Pod Security Context
6. Least-privilege design for FinanceFlow
7. Auditing access
8. Lab 4 walkthrough

---

## Two Types of Identity

```
┌─────────────────────────────────────────────────────┐
│                 OpenShift Cluster                    │
│                                                      │
│  Humans                   Workloads                  │
│  ────────                 ────────                   │
│  Users                    ServiceAccounts            │
│  Groups                   (one per pod/app)          │
│                                                      │
│  Authenticate via:        Authenticate via:          │
│  LDAP / OAuth / HTPasswd  Mounted JWT token          │
└─────────────────────────────────────────────────────┘
```

Every Pod runs as a ServiceAccount — even if you don't specify one, it defaults to `default`.

**Best practice:** Never use the `default` SA. Create a dedicated SA per application.

---

## Service Accounts

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: financeflow-app
  namespace: financeflow-workshop
```

```yaml
# Reference in Deployment
spec:
  template:
    spec:
      serviceAccountName: financeflow-app
      containers: [...]
```

The SA's JWT token is auto-mounted at:
```
/var/run/secrets/kubernetes.io/serviceaccount/token
```

This token is how the pod authenticates to the Kubernetes API.

---

## Security Context Constraints (SCCs)

SCCs are OpenShift's answer to **"what is this pod allowed to do?"**

They control:
- Which UID the container runs as
- Whether it can run privileged
- Which Linux capabilities it can use
- Which volume types it can mount
- Whether it can access host namespaces

```bash
oc get scc          # list all SCCs
oc describe scc restricted
```

SCCs are evaluated **when a pod is admitted** — not at runtime.

---

## The SCC Ladder

```
  restricted          ← default; non-root, no caps, no host access
       │
  restricted-v2       ← default SCC in OCP 4.18; seccomp profile enforced
       │
  nonroot             ← any non-root UID
       │
  nonroot-v2          ← nonroot + seccomp
       │
  anyuid              ← any UID including root (use sparingly)
       │
  hostmount-anyuid    ← can mount hostPath
       │
  privileged          ← full host access — never for apps
```

**FinanceFlow uses `financeflow-scc`** (MustRunAsNonRoot) — the Python services declare `USER 1001` in their Containerfiles, which falls outside `restricted`'s MustRunAsRange.  
The nginx portal uses `chown 1001:0` + `chmod g+rwx` so it works correctly regardless of which UID OpenShift assigns.

---

## What `restricted` Blocks

```bash
# Try to run as root — blocked by SCC
oc run root-attempt --image=alpine --command -- sh -c "id"
# Error: pods "root-attempt" is forbidden:
#   unable to validate against any security context constraint:
#   [spec.containers[0].securityContext.runAsUser: Invalid value: 0: must be in the ranges: [1000620000, 1000629999]]
```

The admission controller rejects the pod before it ever schedules.

---

## Granting SCC to a Service Account

```bash
# Imperative (quick demo)
oc adm policy add-scc-to-user financeflow-scc \
  -z financeflow-app \
  -n financeflow-workshop

# Declarative (production) — ClusterRole + RoleBinding
```

```yaml
# ClusterRole grants "use" permission on the SCC
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: use-financeflow-scc
rules:
  - apiGroups: ["security.openshift.io"]
    resources: ["securitycontextconstraints"]
    resourceNames: ["financeflow-scc"]
    verbs: ["use"]
```

---

## RBAC Building Blocks

```
Role / ClusterRole          → defines WHAT is allowed
     ↓
RoleBinding / ClusterRoleBinding  → grants it TO someone
```

| Resource | Scope | Use for |
|----------|-------|---------|
| `Role` | Namespace | App-specific permissions |
| `ClusterRole` | Cluster-wide | Shared permissions, SCC grants |
| `RoleBinding` | Namespace | Bind a Role or ClusterRole in one namespace |
| `ClusterRoleBinding` | Cluster-wide | Cluster admins, platform operators |

**Most day-to-day RBAC is Roles + RoleBindings — never ClusterRoleBindings for app teams.**

---

## FinanceFlow RBAC Design

```
financeflow-developers (Group)
         │
    RoleBinding → financeflow-viewer (Role)
         │
         ├── get/list/watch: pods, logs, services, configmaps
         ├── get/list/watch: deployments, routes, HPA
         └── ✗ secrets  ← developers never read credentials


financeflow-cicd (ServiceAccount)
         │
    RoleBinding → financeflow-deployer (Role)
         │
         ├── full CRUD: deployments, services, routes
         └── ✗ secrets  ← CI/CD never touches credentials
```

Platform admin creates and rotates secrets separately.

---

## Pod Security Context

Defined in the Deployment — enforced by the SCC:

```yaml
securityContext:           # pod-level
  runAsNonRoot: true       # SCC enforces: no container may run as UID 0

containers:
  - securityContext:       # container-level
      runAsUser: 1001      # Python services: explicit UID matching Containerfile USER
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

> **Portal exception:** the nginx portal omits `runAsUser` and instead uses `chown :0 + chmod g+rwx` in its Containerfile. OpenShift may assign any UID from the namespace range — group-0 write access ensures nginx can create its temp files regardless.

The SCC checks these values at admission — if the SCC doesn't allow the requested `runAsUser`, the pod is rejected.

---

## Auditing Access

```bash
# Can the financeflow-app SA get secrets?
oc auth can-i get secrets \
  --as system:serviceaccount:financeflow-workshop:financeflow-app
# no

# Can a developer list pods?
oc auth can-i list pods \
  --as-group financeflow-developers \
  --as system:authenticated
# yes

# Who can delete deployments in this namespace?
oc policy who-can delete deployments -n financeflow-workshop

# What can the CI/CD service account do?
oc auth can-i --list \
  --as system:serviceaccount:financeflow-workshop:financeflow-cicd
```

---

## Secrets Best Practices

| Practice | Why |
|----------|-----|
| Create imperatively, never in committed YAML | Prevents credentials in git history |
| RBAC: exclude secrets from deployer role | CI/CD pipeline can't exfiltrate creds |
| etcd encryption enabled (OCP default) | Secrets at rest are AES-256 encrypted |
| For production: External Secrets Operator | Pull from Vault / AWS Secrets Manager dynamically |
| Rotate regularly | Limit blast radius of a leaked credential |

```bash
# Verify etcd encryption is on
oc get apiserver cluster -o jsonpath='{.spec.encryption.type}'
# aescbc  (or aesgcm on newer clusters)
```

---

## Lab 4 — Your Turn

1. Create `financeflow-app` and `financeflow-cicd` service accounts
2. Create and inspect the custom `financeflow-scc`
3. Try running a container as root — observe SCC rejection
4. Assign the SCC to `financeflow-app` and patch deployments to use it
5. Create viewer and deployer roles — test with `oc auth can-i`
6. Verify no service account can read secrets

**Estimated time:** 45 min  
**Lab guide:** `chapters/04-security/lab/04-security-rbac.md`

---

## Chapter 4 — Summary

| Concept | Key Point |
|---------|-----------|
| ServiceAccount | Every pod needs a dedicated SA — never use `default` |
| SCC | OpenShift admission gate for pod privileges — least permissive that works |
| Role | Namespace-scoped permission set — prefer over ClusterRole |
| Secrets RBAC | Exclude secrets from CI/CD and developer roles |
| `oc auth can-i` | Verify access before and after RBAC changes |

**Next:** Chapter 5 — Service Mesh  
*(mTLS, traffic management, and observability with Istio)*
