# Lab 6 — CI/CD: Pipelines & GitOps

**Chapter:** 6 | **Duration:** 60 min | **Complexity:** 🔴 Advanced

---

## Objectives

By the end of this lab you will:
- Install OpenShift Pipelines (Tekton) and OpenShift GitOps (ArgoCD)
- Apply custom Tasks and a multi-stage Pipeline for FinanceFlow
- Trigger a manual PipelineRun and watch it progress in the UI
- Create an ArgoCD Application that watches the manifests directory
- Make a git change and observe ArgoCD auto-sync the cluster
- Wire a GitHub webhook to trigger the full CI pipeline on push

---

## Prerequisites

- Chapters 1–4 complete — all pods Running, `financeflow-cicd` SA exists
- Cluster-admin access (operator installs)
- A GitHub fork or clone of the workshop repository (webhook needs a public URL) —
  `pipelinerun-*.yaml` and `argocd-*.yaml` already point at this run's repo
  (replace the URL in all YAML files with your own org/repo if you're forking this lab)
- A GitHub Personal Access Token (repo scope) for the pipeline's own git push step
  (Lab 6b, Step 1b) — separate from any token you use to push from your own machine

---

## Lab 6a — Install Operators

### Step 1 — Install OpenShift Pipelines

**Administrator → OperatorHub → search "OpenShift Pipelines"**

Select **Red Hat OpenShift Pipelines** → Install → keep defaults → Install.

```bash
# Wait for the operator to be ready
oc get csv -n openshift-operators | grep pipelines
# Red Hat OpenShift Pipelines  ...  Succeeded
```

ClusterTasks were removed in OpenShift Pipelines 1.17 — shared Tasks now live in the `openshift-pipelines` namespace and are referenced via the `cluster` resolver (see `pipeline-financeflow.yaml`). Verify they're available:
```bash
oc get tasks -n openshift-pipelines | grep -E "git-clone|buildah|openshift-client"
```

### Step 1b — Enable the Pipelines console plugin

The operator installs the `pipelines-console-plugin` pod, but doesn't always
enable it in the cluster's Console config — without this, the Developer
perspective's **Pipelines** view stays empty even though `oc get pipeline`
shows your Pipeline exists:

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "pipelines-console-plugin" is missing from this list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'

# wait for the console pod to roll out, then hard-refresh your browser
oc get pods -n openshift-console
```

### Step 2 — Install OpenShift GitOps

**Administrator → OperatorHub → search "OpenShift GitOps"**

Select **Red Hat OpenShift GitOps** → Install → keep defaults → Install.

```bash
oc get csv -n openshift-operators | grep gitops
# Red Hat OpenShift GitOps  ...  Succeeded

# ArgoCD is deployed into openshift-gitops namespace
oc get pods -n openshift-gitops
```

### Step 2b — Enable the GitOps console plugin

Same gap as the Pipelines operator (Step 1b): the operator installs the
`gitops-plugin` pod but doesn't enable it in the Console config — without
this, ArgoCD applications show nothing in the OpenShift console even though
`oc get application -n openshift-gitops` reports `Synced`/`Healthy` fine.

```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
# if "gitops-plugin" is missing from that list:
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'

# wait for the console pod to roll out, then hard-refresh your browser
oc get pods -n openshift-console
```

### Step 3 — Get the ArgoCD admin password

```bash
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d && echo

# Get the ArgoCD URL
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='{.spec.host}'
```

Log in to the ArgoCD UI with `admin` and the password above.

---

## Lab 6b — Deploy the Tekton Pipeline

### Step 1 — Grant the CI/CD service account build permissions

The `financeflow-cicd` SA (Chapter 4) needs permission to push images and trigger rollouts:

```bash
# Allow the SA to push to the internal registry (ImageStream write)
oc adm policy add-role-to-user \
  registry-editor \
  system:serviceaccount:financeflow-workshop:financeflow-cicd

# Allow buildah to run — pipelines-scc (not privileged!) is purpose-built by
# the Tekton operator for this: RunAsAny on UID (catalog Tasks like git-clone
# hardcode their own non-root UID) but fsGroup: MustRunAs, so it auto-derives
# a writable group for the shared pipeline-source PVC from THIS namespace's
# allocated range — unlike privileged (fsGroup: RunAsAny), which assigns
# nothing and forces you into hardcoding a GID that breaks the moment this
# namespace is ever deleted/recreated with a different allocated range.
oc adm policy add-scc-to-user pipelines-scc \
  -z financeflow-cicd \
  -n financeflow-workshop
```

### Step 1b — Give the pipeline its own git push credentials

`task-update-manifest.yaml`'s `git-commit-push` step runs `git push origin HEAD`
with no auth of its own — easy to miss, since nothing fails until that exact
step runs. Tekton auto-injects `~/.git-credentials`/`~/.gitconfig` into every
step of a run based on annotated Secrets attached to the *ServiceAccount* the
run executes as (`financeflow-cicd`), so no Task or workspace changes are
needed — just attach the Secret:

```bash
oc create secret generic git-credentials-cicd \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=<your-github-username> \
  --from-literal=password=<your-github-PAT-with-repo-scope>

oc annotate secret git-credentials-cicd tekton.dev/git-0=https://github.com

oc secrets link financeflow-cicd git-credentials-cicd
```

### Step 2 — Apply pipeline resources

```bash
# Create the workspace PVC and custom Tasks
oc apply -f chapters/06-cicd/manifests/pvc-pipeline-source.yaml
oc apply -f chapters/06-cicd/manifests/task-run-tests.yaml
oc apply -f chapters/06-cicd/manifests/task-update-manifest.yaml

# Create the Pipeline
oc apply -f chapters/06-cicd/manifests/pipeline-financeflow.yaml

# Verify
oc get tasks
oc get pipeline
```

### Step 3 — Inspect the pipeline in the UI

**Developer → Pipelines → financeflow-pipeline → Graph tab**

You should see the task graph:
```
clone → test → build → tag-image → update-manifest
```

---

## Lab 6c — Manual PipelineRun

### Step 1 — Edit the PipelineRun YAML

`chapters/06-cicd/manifests/pipelinerun-account-service.yaml` already points
at this run's repo. If you're forking the lab, open it and update `repo-url`
to your own GitHub org/repo first.

### Step 2 — Trigger the run

```bash
oc create -f chapters/06-cicd/manifests/pipelinerun-account-service.yaml
```

> Note: use `oc create` not `oc apply` — `generateName` means a new object is created each time.

### Step 3 — Watch the run

```bash
# Stream logs from the active PipelineRun
oc get pipelinerun --sort-by=.metadata.creationTimestamp | tail -1
PRUN=$(oc get pipelinerun --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

oc logs -f pipelineruns/$PRUN --all-containers 2>/dev/null || \
  tkn pipelinerun logs $PRUN -f
```

Or watch in the UI: **Developer → Pipelines → financeflow-pipeline → PipelineRuns tab**

Click the run to see task-by-task progress, step logs, and timing.

### Step 4 — Verify the image was built and tagged

```bash
oc get imagestreamtag financeflow-account:v1.0
oc get imagestreamtag financeflow-account:stable
```

---

## Lab 6d — Set Up ArgoCD

### Step 1 — Fork the repository

ArgoCD needs to pull from a git repository. Fork the workshop repo to your GitHub account and note the HTTPS clone URL.

### Step 2 — Update the ArgoCD YAML files

Both ArgoCD files already point at this run's repo
(`https://github.com/rebontadeb/openshift-container-demo.git`). If you're
forking the lab, update `repoURL`/`sourceRepos` in both files to your own:
```bash
sed -i 's|https://github.com/[^/]*/[^"]*\.git|https://github.com/<your-org>/<your-repo>.git|g' \
  chapters/06-cicd/manifests/argocd-project.yaml \
  chapters/06-cicd/manifests/argocd-app-financeflow.yaml
```

### Step 3 — Let ArgoCD manage the namespace

The GitOps operator only creates the RoleBinding that lets ArgoCD's
application-controller manage resources in `financeflow-workshop` if the
namespace carries this label:

```bash
oc label namespace financeflow-workshop argocd.argoproj.io/managed-by=openshift-gitops
```

> **Do not** `oc apply -f chapters/06-cicd/manifests/namespace-argocd-managed.yaml`
> for this — see the comments in that file. It's a full `Namespace` object, and
> applying it would overwrite kubectl's `last-applied-configuration` tracking
> for the *whole* namespace, silently deleting Chapter 5's `istio-injection:
> enabled` label (kubectl's 3-way merge treats a label missing from the new
> apply, that was present in the old one, as "remove it"). `oc label` only
> ever touches the key you name.

Without this step, ArgoCD will sync `ConfigMap`/`PersistentVolumeClaim` fine
(reachable via its own default ClusterRole) but every `Deployment`/`Service`/
`HorizontalPodAutoscaler` sync fails with `is forbidden: ... cannot patch
resource ... in the namespace financeflow-workshop`.

### Step 4 — Create the ArgoCD AppProject and Application

These go into the `openshift-gitops` namespace (ArgoCD's namespace):

```bash
oc apply -f chapters/06-cicd/manifests/argocd-project.yaml \
  -n openshift-gitops

oc apply -f chapters/06-cicd/manifests/argocd-app-financeflow.yaml \
  -n openshift-gitops
```

### Step 5 — Watch the initial sync

In the ArgoCD UI, the `financeflow` application will appear and begin syncing:

```bash
# CLI equivalent
oc get application financeflow -n openshift-gitops
```

```
NAME          SYNC STATUS   HEALTH STATUS
financeflow   Synced        Healthy
```

If it shows `OutOfSync`, click **Sync** in the UI or:
```bash
oc patch application financeflow -n openshift-gitops \
  --type=merge -p '{"operation":{"sync":{}}}'
```

### Step 6 — Test self-healing

Manually scale down the account-service:
```bash
oc scale deployment account-service --replicas=1
oc get pods -l tier=account-service
# Shows 1 pod
```

Wait up to 3 minutes (ArgoCD's default poll interval). ArgoCD detects the drift and restores replicas to 2:
```bash
oc get pods -l tier=account-service
# Back to 2 pods — restored by ArgoCD selfHeal
```

---

## Lab 6e — GitOps in Action

### Step 1 — Make a configuration change in git

Edit a ConfigMap in the manifests directory — for example, add an environment variable annotation:

```bash
# Change a non-breaking config value
# Edit chapters/02-deployments/manifests/configmap-account-service.yaml
# Add a new key: LOG_LEVEL: "INFO"
```

Commit and push:
```bash
git add chapters/02-deployments/manifests/configmap-account-service.yaml
git commit -m "config: set LOG_LEVEL to INFO for account-service"
git push origin main
```

### Step 2 — Watch ArgoCD detect and apply the change

Within 3 minutes (or click **Refresh** in the ArgoCD UI):

```bash
oc get application financeflow -n openshift-gitops -w
# SYNC STATUS changes to OutOfSync then back to Synced

oc get configmap account-service-config -o yaml | grep LOG_LEVEL
# LOG_LEVEL: INFO
```

ArgoCD applied the change without any `oc apply` command from you.

---

## Lab 6f — GitHub Webhook (Full Loop)

### Step 1 — Create the webhook secret

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
echo "Save this: $WEBHOOK_SECRET"

oc create secret generic github-webhook-secret \
  --from-literal=secret=$WEBHOOK_SECRET \
  -n financeflow-workshop
```

### Step 2 — Apply the trigger resources

```bash
oc apply -f chapters/06-cicd/manifests/triggerbinding-github.yaml
oc apply -f chapters/06-cicd/manifests/triggertemplate-financeflow.yaml
oc apply -f chapters/06-cicd/manifests/eventlistener.yaml
oc apply -f chapters/06-cicd/manifests/route-eventlistener.yaml

# Get the webhook URL
WEBHOOK_URL="https://$(oc get route financeflow-webhook \
  -o jsonpath='{.spec.host}')"
echo "Webhook URL: $WEBHOOK_URL"
```

### Step 3 — Register the webhook in GitHub

1. Go to your forked repo → **Settings → Webhooks → Add webhook**
2. **Payload URL**: paste the `$WEBHOOK_URL`
3. **Content type**: `application/json`
4. **Secret**: paste `$WEBHOOK_SECRET`
5. **Events**: Just the `push` event
6. Click **Add webhook**

GitHub sends a ping event — the EventListener responds with `200 OK`.

### Step 4 — Push a code change to trigger the pipeline

Make any change to a file in `app/account-service/` and push to main:

```bash
# Example: add a comment to app.py
echo "# v1.1 release" >> app/account-service/app.py
git add app/account-service/app.py
git commit -m "feat: account-service v1.1 patch"
git push origin main
```

### Step 5 — Watch the full loop

```bash
# Watch PipelineRuns appear within seconds of the push
oc get pipelinerun -w

# Once the pipeline completes, watch ArgoCD sync the updated manifest
oc get application financeflow -n openshift-gitops -w

# Watch the Deployment roll over to the new image
oc rollout status deployment/account-service
```

**Developer → Pipelines → PipelineRuns** shows the full pipeline.  
**ArgoCD UI → financeflow** shows the sync status.  
**Developer → Topology** shows the rolling update in progress.

---

## Checkpoint

```bash
# Operators installed
oc get csv -n openshift-operators | grep -E "pipelines|gitops"

# Pipeline and tasks
oc get pipeline financeflow-pipeline
oc get tasks

# ArgoCD application healthy
oc get application financeflow -n openshift-gitops

# EventListener running
oc get eventlistener financeflow-webhook
oc get route financeflow-webhook
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| PipelineRun stuck in `Pending` | `financeflow-cicd` SA lacks permissions | Add `registry-editor` and `pipelines-scc` |
| `buildah` step fails with permission error | SA needs pipelines-scc | `oc adm policy add-scc-to-user pipelines-scc -z financeflow-cicd` |
| `git-clone` fails: auth error | Private repo without credentials | Add a `basic-auth` or `ssh-auth` workspace secret |
| `git-clone`/`update-manifest` fails: `Permission denied` writing to the shared workspace | SA's SCC has `fsGroup: RunAsAny` (e.g. `privileged`) — nothing assigns a writable group to the PVC, so whichever Task's hardcoded UID touches it first "owns" it | Use `pipelines-scc` (`fsGroup: MustRunAs`) instead of `privileged`; don't hardcode an `fsGroup` value in `podTemplate.securityContext` — it won't survive the namespace being recreated |
| ArgoCD shows `Unknown` sync | Repo URL mismatch or network issue | Check `argocd-project.yaml` sourceRepos field |
| Webhook returns `400` | HMAC mismatch | Secret in GitHub and `github-webhook-secret` must match |
| EventListener pod crashes | SA missing Tekton trigger permissions | `oc get events -n financeflow-workshop` |

---

## Key Takeaways

- Tekton Tasks are reusable units — `git-clone` and `buildah` are already provided in the `openshift-pipelines` namespace, referenced via the `cluster` resolver (ClusterTasks were removed in Pipelines 1.17)
- Pipeline workspace is a PVC shared between all tasks — clone once, use everywhere
- TriggerBinding extracts webhook payload fields; TriggerTemplate uses them to create a PipelineRun
- ArgoCD `selfHeal: true` means the cluster always matches git — manual changes get reverted
- `ignoreDifferences` for `spec.replicas` prevents ArgoCD fighting the HPA
- Secrets stay out of both Tekton (SA cannot read them) and ArgoCD (not in AppProject whitelist)

---

*Next: [Lab 7 — OpenTelemetry & Observability](../../07-observability/lab/07-observability.md)*
