#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 2 — Deployments & Scaling  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CH2="$REPO_ROOT/chapters/02-deployments/manifests"

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()   { echo -e "${B}► $*${R}"; }
done_(){ echo -e "${G}✔ $*${R}"; }
pause() { echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

oc project "$NAMESPACE"

# ── DEMO 1: Secrets vs ConfigMaps ─────────────────────────────────────────────
# TALKING POINTS:
#   "First, why separate Secrets from ConfigMaps?
#    ConfigMaps are non-sensitive — you can read them in oc describe.
#    Secrets are base64-encoded in etcd (encrypted at rest with OCP etcd encryption).
#    Best practice: never put passwords in YAML files or git."

say "Create the PostgreSQL Secret IMPERATIVELY — no password in any file"
oc create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=financeflow \
  --from-literal=POSTGRES_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=POSTGRES_DB=financeflow \
  --from-literal=DB_USER=financeflow \
  --from-literal=DB_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=DB_NAME=financeflow \
  --dry-run=client -o yaml    # show the YAML first without applying

pause

say "Now apply it for real"
oc create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=financeflow \
  --from-literal=POSTGRES_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=POSTGRES_DB=financeflow \
  --from-literal=DB_USER=financeflow \
  --from-literal=DB_PASSWORD=FinanceFlow_S3cure! \
  --from-literal=DB_NAME=financeflow 2>/dev/null || echo "Secret already exists"

say "Show how a Secret looks — base64, not plaintext, not encrypted"
oc get secret postgres-credentials -o jsonpath='{.data.DB_PASSWORD}' | base64 -d && echo

pause

# ── DEMO 2: Deploy PostgreSQL with PVC ────────────────────────────────────────
# TALKING POINTS:
#   "PostgreSQL uses a PVC — persistent storage that survives pod restarts.
#    Also note: strategy: Recreate — not RollingUpdate.
#    Two Postgres pods writing simultaneously = data corruption."

say "Create PVC and init-script ConfigMap"
oc apply -f "$CH2/pvc-postgres.yaml"
oc create configmap postgres-init \
  --from-file=init.sql="$REPO_ROOT/app/database/init.sql" 2>/dev/null || true

say "Deploy PostgreSQL — watch the PVC go from Pending to Bound"
oc apply -f "$CH2/deployment-postgres.yaml"
oc get pvc -w &
PVC_PID=$!
oc get pods -w -l tier=database &
POD_PID=$!
sleep 20
kill $PVC_PID $POD_PID 2>/dev/null || true

say "Create the postgres Service — account/transaction-service need this DNS name to reach Ready"
oc apply -f "$CH2/service-postgres.yaml"

say "Verify init script ran — tables exist"
POD=$(oc get pod -l tier=database -o jsonpath='{.items[0].metadata.name}')
oc exec "$POD" -- env PGPASSWORD=FinanceFlow_S3cure! psql -U financeflow -d financeflow -c "\dt"
pause

# ── DEMO 3: Deploy services and show topology ──────────────────────────────────
# TALKING POINTS:
#   "Apply everything else with Kustomize — single command."
#   "Each Deployment gets its Service applied right alongside it — that's
#    what gives every tier a stable DNS name from the moment it starts."

say "Apply ConfigMaps, Deployments, and their Services"
oc apply -f "$CH2/configmap-account-service.yaml"
oc apply -f "$CH2/configmap-transaction-service.yaml"
oc apply -f "$CH2/deployment-account-service.yaml"
oc apply -f "$CH2/service-account-service.yaml"
oc apply -f "$CH2/deployment-transaction-service.yaml"
oc apply -f "$CH2/service-transaction-service.yaml"
oc apply -f "$CH2/deployment-portal.yaml"
oc apply -f "$CH2/service-portal.yaml"

say "Watch all pods come up"
oc get pods -w &
WATCH_PID=$!
sleep 30
kill $WATCH_PID 2>/dev/null || true
oc get pods
pause

say "Open Web Console → Developer → Topology  [switch to browser]"
echo "Console: $(oc whoami --show-console)"
pause

# ── DEMO 4: Health Probes ─────────────────────────────────────────────────────
# TALKING POINTS:
#   "Three probes, three jobs. Let me show you the difference live."

say "Show probe configuration"
oc describe deployment account-service | grep -A 8 "Liveness\|Readiness\|Startup"
pause

say "BREAK READINESS — traffic stops, no restart"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/broken"}]'

say "Watch: pod goes 0/1 READY but does NOT restart"
oc get pods -w -l tier=account-service &
W=$!; sleep 35; kill $W 2>/dev/null || true

say "RESTORE readiness — pod recovers without restart"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health/ready"}]'
oc get pods -w -l tier=account-service &
W=$!; sleep 20; kill $W 2>/dev/null || true
pause

say "BREAK LIVENESS — pod RESTARTS (RESTARTS counter increments)"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health/broken"}]'

oc get pods -w -l tier=account-service &
W=$!; sleep 60; kill $W 2>/dev/null || true

say "RESTORE liveness"
oc patch deployment account-service --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health/live"}]'
pause

# ── DEMO 5: Rolling Update ────────────────────────────────────────────────────
# TALKING POINTS:
#   "maxUnavailable: 0 means the old pod stays until the new one is Ready.
#    Live demo — watch the replica count during the rollout."

say "Simulate a new release — tag v1.1"
oc tag financeflow-account:v1.0 financeflow-account:v1.1

say "Trigger rolling update"
oc set image deployment/account-service \
  account-service=financeflow-account:v1.1

say "Watch zero-downtime rollout"
oc rollout status deployment/account-service

say "Rollout history"
oc rollout history deployment/account-service

say "Instant rollback"
oc rollout undo deployment/account-service
oc rollout status deployment/account-service
pause

# ── DEMO 6: HPA ───────────────────────────────────────────────────────────────
# TALKING POINTS:
#   "The HPA watches CPU. When it goes above 60%, new pods are added.
#    minReplicas: 2 — we never drop below 2 for this payment service."

say "Apply HPA"
oc apply -f "$CH2/hpa-account-service.yaml"
oc get hpa

say "Generate load — exec into portal pod and hit account-service in a loop"
oc exec -it deployment/portal -- sh -c \
  "while true; do wget -qO- http://account-service:8080/api/accounts > /dev/null; done" &
LOAD_PID=$!

say "Watch HPA scale up — takes ~60s"
for i in {1..8}; do
  echo "--- $i ---"
  oc get hpa account-service-hpa
  oc get pods -l tier=account-service --no-headers | wc -l | xargs echo "Pods:"
  sleep 15
done

kill $LOAD_PID 2>/dev/null || true

say "Scale-down stabilisation window is 120s — watch pods decrease slowly"
oc get hpa -w &
W=$!; sleep 150; kill $W 2>/dev/null || true
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 2 complete"
oc get pods
oc get svc
oc get hpa
echo -e "${G}Stack is deployed and scaling, all Services in place. Ready for Chapter 3 — Networking.${R}"
