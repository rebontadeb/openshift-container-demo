#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 6 — CI/CD: Pipelines & GitOps  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH6="$REPO_ROOT/chapters/06-cicd/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── PRE-CHECK ─────────────────────────────────────────────────────────────────
say "Verify operators are installed"
oc get csv -n openshift-operators | grep -E "pipelines|gitops" || \
  echo "WARNING: operators not yet installed — install from OperatorHub first"

say "Verify Tekton resolver tasks are available (ClusterTasks removed in Pipelines 1.14+)"
oc get tasks -n openshift-pipelines 2>/dev/null | grep -E "git-clone|buildah|openshift-client" || \
  echo "Tasks resolved at runtime via hub/cluster resolver — OK"
pause

# ── DEMO 1: Show the pipeline ─────────────────────────────────────────────────
# TALKING POINTS:
#   "Let me show the pipeline definition before we run it.
#    Five tasks, each runs in its own pod, all share a PVC workspace."

say "Apply pipeline resources"
oc apply -f "$CH6/pvc-pipeline-source.yaml"
oc apply -f "$CH6/task-run-tests.yaml"
oc apply -f "$CH6/task-update-manifest.yaml"
oc apply -f "$CH6/pipeline-financeflow.yaml"

say "Show the pipeline task graph"
oc get pipeline financeflow-pipeline -o jsonpath='{.spec.tasks[*].name}' | tr ' ' '\n'

say "Show it in the Pipelines UI  [switch to browser]"
echo "Console: $(oc whoami --show-console)"
echo "Navigate: Developer → Pipelines → financeflow-pipeline → Graph tab"
pause

# ── DEMO 2: Manual PipelineRun ────────────────────────────────────────────────
# TALKING POINTS:
#   "Let me trigger a run manually first — same as what the webhook does automatically.
#    Watch each task appear as a pod in the namespace."

say "Grant the CI/CD SA registry permissions"
oc adm policy add-role-to-user registry-editor \
  "system:serviceaccount:${NAMESPACE}:financeflow-cicd" 2>/dev/null || true
oc adm policy add-scc-to-user privileged \
  -z financeflow-cicd -n "$NAMESPACE" 2>/dev/null || true

say "Trigger a PipelineRun for account-service"
oc create -f "$CH6/pipelinerun-account-service.yaml"

say "Watch pods appear — one per task"
oc get pods -w &
W=$!
sleep 5
kill $W 2>/dev/null || true
oc get pods | grep -E "clone|test|build|tag|update"

say "Stream pipeline logs (tkn CLI not required — use the console or oc logs)"
PRUN=$(oc get pipelinerun --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
echo "PipelineRun: $PRUN"
echo "Console: Developer → Pipelines → PipelineRuns → $PRUN → Logs  [switch to browser]"
oc get pipelinerun "$PRUN" -o jsonpath='{.status.conditions[0].message}' && echo ""
pause

# ── DEMO 3: ArgoCD Application ────────────────────────────────────────────────
# TALKING POINTS:
#   "Now the CD side. ArgoCD watches the manifests directory in git.
#    I'll show you what happens when the cluster drifts from git."

say "Show ArgoCD Application status"
oc get application financeflow -n openshift-gitops 2>/dev/null || \
  echo "Apply argocd-project.yaml and argocd-app-financeflow.yaml first"

ARGOCD_URL="https://$(oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo 'not-installed')"
echo -e "${G}ArgoCD UI: $ARGOCD_URL${R}"
pause

say "DEMO: manually scale down account-service — ArgoCD will revert it"
oc scale deployment account-service --replicas=1
oc get pods -l tier=account-service
echo "account-service now has 1 pod"

say "Wait for ArgoCD selfHeal to restore replicas (up to 3 min)..."
echo "In ArgoCD UI — watch application go OutOfSync then back to Synced"
for i in {1..12}; do
  REPLICAS=$(oc get deployment account-service -o jsonpath='{.spec.replicas}')
  echo "  [${i}0s] replicas: $REPLICAS"
  [ "$REPLICAS" -eq 2 ] && break
  sleep 10
done
oc get pods -l tier=account-service
pause

# ── DEMO 4: GitOps — make a config change ─────────────────────────────────────
# TALKING POINTS:
#   "Now let's see the real GitOps loop. I'll change a ConfigMap in git,
#    push, and ArgoCD applies it to the cluster — no oc apply from anyone."

say "Show current account-service ConfigMap"
oc get configmap account-service-config -o yaml | grep -A 5 "data:"

say "Make a config change — push to git  [instructor action]"
echo "Edit chapters/02-deployments/manifests/configmap-account-service.yaml"
echo "Add: LOG_LEVEL: INFO"
echo "Then: git add . && git commit -m 'config: add LOG_LEVEL' && git push"
pause

say "ArgoCD detects the commit → applies the change"
oc get application financeflow -n openshift-gitops -w &
W=$!; sleep 45; kill $W 2>/dev/null || true
oc get configmap account-service-config -o yaml | grep -i log || true
pause

# ── DEMO 5: Webhook trigger ───────────────────────────────────────────────────
# TALKING POINTS:
#   "The last piece — a code push auto-triggers the pipeline.
#    No manual PipelineRun. Just git push → build → deploy."

say "Apply Trigger resources and webhook route"
oc apply -f "$CH6/triggerbinding-github.yaml"
oc apply -f "$CH6/triggertemplate-financeflow.yaml"
oc apply -f "$CH6/eventlistener.yaml"
oc apply -f "$CH6/route-eventlistener.yaml"

WEBHOOK_URL="https://$(oc get route financeflow-webhook -o jsonpath='{.spec.host}')"
echo -e "${G}GitHub webhook URL: $WEBHOOK_URL${R}"
echo "Register this in: GitHub → Repo → Settings → Webhooks"
pause

say "Simulate a git push — watch a PipelineRun appear automatically"
echo "Push any change to app/account-service/ on main branch"
echo "PipelineRun will appear within 5 seconds of the push"
oc get pipelinerun -w &
W=$!; sleep 30; kill $W 2>/dev/null || true
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 6 complete — the full CI/CD loop"
echo ""
echo "CI (Tekton):  git push → test → build → tag → commit manifest"
echo "CD (ArgoCD):  git commit → detect → diff → sync → cluster updated"
echo ""
oc get pipeline
oc get application -n openshift-gitops
echo -e "${G}Every code push now automatically builds, tests, and deploys FinanceFlow. Ready for Chapter 7 — Observability.${R}"
