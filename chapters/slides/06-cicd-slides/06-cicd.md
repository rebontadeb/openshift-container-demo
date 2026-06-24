# Chapter 6
## CI/CD — Pipelines & GitOps

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. CI vs CD — what each solves
2. OpenShift Pipelines (Tekton) — architecture
3. Pipeline anatomy: Tasks, Pipelines, Workspaces
4. Webhook triggers — git push → pipeline
5. OpenShift GitOps (ArgoCD) — architecture
6. GitOps model: git as the source of truth
7. The full CI/CD loop for FinanceFlow
8. Lab 6 walkthrough

---

## CI vs CD — the Division

```
Developer pushes code
        │
        ▼
  ┌─────────────┐
  │     CI      │  OpenShift Pipelines (Tekton)
  │             │  • Clone source
  │             │  • Run tests
  │             │  • Build image
  │             │  • Push to ImageStream
  │             │  • Update image tag in git
  └──────┬──────┘
         │ git commit with new image tag
         ▼
  ┌─────────────┐
  │     CD      │  OpenShift GitOps (ArgoCD)
  │             │  • Detects git change
  │             │  • Compares cluster vs git
  │             │  • Syncs cluster to match git
  └─────────────┘
```

**CI produces a verified artifact. CD delivers it.**

---

## OpenShift Pipelines — Tekton

Built on the Kubernetes-native **Tekton** project. Installed via OperatorHub.

| Resource | Role |
|----------|------|
| `Task` | Unit of work — one or more sequential steps (containers) |
| Cluster resolver | Shared tasks (git-clone, buildah, oc-client) live in `openshift-pipelines` ns, referenced via `resolver: cluster` — ClusterTasks were removed in Pipelines 1.17 |
| `Pipeline` | Ordered graph of tasks with shared workspaces |
| `PipelineRun` | One execution of a Pipeline with specific params |
| `Workspace` | Shared storage between tasks (PVC or emptyDir) |
| `EventListener` | HTTP server that receives webhooks |
| `TriggerBinding` | Extracts fields from webhook payload |
| `TriggerTemplate` | Creates a PipelineRun from trigger data |

---

## FinanceFlow Pipeline

```
git push
    │
EventListener ← GitHub webhook (HMAC-validated)
    │
TriggerBinding — extracts: repo-url, revision (SHA), ref
    │
TriggerTemplate — creates PipelineRun
    │
    ▼
Pipeline: financeflow-pipeline
    │
    ├── Task: git-clone        (cluster resolver, openshift-pipelines ns)
    ├── Task: run-tests        (custom — pytest)
    ├── Task: buildah          (cluster resolver — builds Containerfile)
    ├── Task: openshift-client (cluster resolver — tags image :stable in ImageStream)
    └── Task: update-manifest  (custom — commits new tag to git)
```

Each task runs in its own pod. Workspace PVC is shared across all tasks.

---

## Task Anatomy

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: run-tests
spec:
  params:
    - name: service
      type: string
  workspaces:
    - name: source
  steps:
    - name: install-deps
      image: python:3.11-slim
      workingDir: $(workspaces.source.path)/app/$(params.service)
      script: |
        pip install -r requirements.txt

    - name: run-pytest
      image: python:3.11-slim
      workingDir: $(workspaces.source.path)/app/$(params.service)
      script: |
        python -m pytest tests/ -v
```

Each `step` is a container. Steps in a Task run **sequentially**.  
Tasks in a Pipeline run **in parallel by default**, unless `runAfter` is set.

---

## Workspaces — Sharing Data Between Tasks

```yaml
# Pipeline declares workspaces
workspaces:
  - name: source        # each task gets the same PVC mounted

# Task 1 (git-clone) writes to it
workspaces:
  - name: output
    workspace: source

# Task 2 (run-tests) reads from it
workspaces:
  - name: source
    workspace: source

# Task 3 (buildah) reads Containerfile from it
workspaces:
  - name: source
    workspace: source
```

The PVC is mounted at `/workspace/source` in each task pod — cloned code is available to every subsequent task.

---

## Webhook Trigger Flow

```
GitHub push → POST /hooks/my-webhook
                      │
               ┌──────▼──────────────┐
               │   EventListener     │
               │   (validates HMAC)  │
               └──────┬──────────────┘
                      │
               ┌──────▼──────────────┐
               │   TriggerBinding    │
               │   repo-url = body.repository.clone_url
               │   revision = body.after (SHA)
               └──────┬──────────────┘
                      │
               ┌──────▼──────────────┐
               │   TriggerTemplate   │
               │   → creates         │
               │     PipelineRun     │
               └─────────────────────┘
```

The webhook URL is the Route in front of the EventListener service.

---

## OpenShift GitOps — ArgoCD

Installed via OperatorHub as **OpenShift GitOps**.

```
Git repo (manifests/)
        │
        │  ArgoCD polls every 3 minutes (or webhook)
        ▼
┌─────────────────────────────────┐
│           ArgoCD                │
│                                 │
│  Desired state  ←  git repo     │
│  Actual state   ←  cluster API  │
│                                 │
│  Diff → Sync → Apply            │
└─────────────────────────────────┘
        │
        ▼
  Cluster updated to match git
```

**Key principle:** The cluster should never diverge from git. If someone applies a change manually, ArgoCD reverts it (`selfHeal: true`).

---

## ArgoCD Application

```yaml
spec:
  source:
    repoURL: https://github.com/org/repo.git
    targetRevision: main
    path: chapters/02-deployments/manifests   # watches this directory

  destination:
    namespace: financeflow-workshop

  syncPolicy:
    automated:
      prune: true       # delete resources removed from git
      selfHeal: true    # revert manual cluster changes

  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas  # HPA manages this — ignore drift here
```

---

## The Full CI/CD Loop

```
1. Developer: git push → main

2. Tekton CI:
   clone → test → build → push image → commit image tag to git

3. ArgoCD CD:
   detects new commit → diffs manifests → syncs Deployment

4. OpenShift:
   Deployment rollout (RollingUpdate, maxUnavailable:0)
   → new pods pass readiness → old pods terminated

5. Kiali:
   traffic graph shows new pods receiving traffic

6. Tempo:
   new traces tagged with the new image version
```

Zero manual steps from code push to live cluster.

---

## Security in the Pipeline

| What | How |
|------|-----|
| Pipeline runs as `financeflow-cicd` SA (Chapter 4) | Least-privilege identity |
| SA cannot read Secrets | Credentials never visible to pipeline |
| Webhook validated with HMAC secret | Only GitHub can trigger builds |
| `buildah` needs the `privileged` SCC | Granted only to `financeflow-cicd`, not app workloads |
| ArgoCD cannot modify Secrets | AppProject whitelist excludes Secret resource |
| Image signed with Cosign (production) | Supply chain attestation |

---

## Lab 6 — Your Turn

1. Install OpenShift Pipelines and GitOps operators
2. Apply Tasks, Pipeline, PVC
3. Trigger a manual PipelineRun — watch in the Pipelines UI
4. Set up the ArgoCD Application — verify `Synced` status
5. Make a config change in git — watch ArgoCD auto-sync
6. Set up GitHub webhook — push code to trigger the full loop
7. Watch Tekton build → ArgoCD sync → pods roll

**Estimated time:** 60 min  
**Lab guide:** `chapters/06-cicd/lab/06-cicd.md`

---

## Chapter 6 — Summary

| Concept | Key Point |
|---------|-----------|
| Tekton Task | Runs in its own pod — each step is a container |
| Pipeline workspace | PVC shared across all tasks — avoids re-cloning |
| EventListener | Validates webhook + creates PipelineRun automatically |
| ArgoCD Application | Polls git; syncs cluster to match declared state |
| `selfHeal: true` | Reverts manual changes — git is always source of truth |
| `ignoreDifferences` | HPA controls replicas — don't fight it with git |

**Next:** Chapter 7 — OpenTelemetry & Observability  
*(traces, metrics, and logs across the full FinanceFlow stack)*
