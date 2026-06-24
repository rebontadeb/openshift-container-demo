#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Chapter 1 — Container Builds & Images  |  Instructor Demo Script
# ──────────────────────────────────────────────────────────────────────────────
# Usage: work through this script section by section while talking to slides.
# Each section is marked with a ── DEMO heading and talking points.
# Commands prefixed with $ are run live; lines starting with # are narration.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="${NAMESPACE:-financeflow-workshop}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Colour helpers
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0m'
say()  { echo -e "${B}► $*${R}"; }
done_() { echo -e "${G}✔ $*${R}"; }
pause(){ echo -e "${Y}[PAUSE — press Enter to continue]${R}"; read -r; }

# ── SETUP ─────────────────────────────────────────────────────────────────────
say "Switching to namespace: $NAMESPACE"
oc project "$NAMESPACE"
pause

# ── DEMO 1: The problem with local builds ────────────────────────────────────
# TALKING POINTS:
#   "On your laptop you'd run podman build. But what if 10 developers have
#    different base images cached? What if you need an audit trail? What if
#    a CVE is patched in the base image — who rebuilds?"
#   "OpenShift solves all of this with Build Pods."

say "Show the cluster — builds happen HERE, not on your laptop"
oc get nodes
pause

# ── DEMO 2: ImageStreams ───────────────────────────────────────────────────────
# TALKING POINTS:
#   "Before we build, we create an ImageStream — think of it as a named slot
#    in the internal registry. Deployments reference the slot, not the URL."

say "Creating ImageStreams for all three FinanceFlow services"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/imagestream-account.yaml"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/imagestream-transaction.yaml"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/imagestream-portal.yaml"
echo

say "List ImageStreams — notice: no tags yet, just empty slots"
oc get imagestreams
pause

say "Inspect the account ImageStream — note lookupPolicy: local: true"
oc describe imagestream financeflow-account
pause

# ── DEMO 3: Docker strategy build ─────────────────────────────────────────────
# TALKING POINTS:
#   "Now let's build the account service. We upload source from our laptop.
#    OpenShift runs the Containerfile inside a Build Pod in the cluster."
#   "Watch the log — you'll see each Containerfile instruction run."

say "Apply the BuildConfig for account-service"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/buildconfig-account.yaml"
oc get buildconfigs
pause

say "START BUILD — uploading source from ./app/account-service"
# TALKING POINT: "Notice --from-dir — no git push required for this demo."
oc start-build financeflow-account \
  --from-dir="$REPO_ROOT/app/account-service" \
  --follow
echo

done_ "Build complete"
oc get builds
pause

say "Inspect the ImageStreamTag — look at the sha256 digest"
oc describe imagestreamtag financeflow-account:latest
pause

# ── DEMO 4: Second Docker build (transaction service) ─────────────────────────
# TALKING POINT: "Same pattern. Quick run — attendees will do this themselves."

say "Build transaction-service (quick — same pattern)"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/buildconfig-transaction.yaml"
oc start-build financeflow-transaction \
  --from-dir="$REPO_ROOT/app/transaction-service" \
  --follow
pause

# ── DEMO 5: S2I build ─────────────────────────────────────────────────────────
# TALKING POINTS:
#   "Now the portal — and here's where it gets interesting. S2I means we
#    don't write a Containerfile at all. The nginx builder assembles the image."
#   "Show the portal directory — index.html, app.js, nginx.conf — that's it."
#   "Compare the build log to the Docker strategy — no FROM/RUN/COPY,
#    instead 'Assemble script' and 'Copying sources'."

say "Show the portal source — no Containerfile needed for S2I"
ls -la "$REPO_ROOT/app/portal/"
pause

say "Apply the S2I BuildConfig — builder image is openshift/nginx"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/buildconfig-portal-s2i.yaml"
oc get buildconfig financeflow-portal-s2i -o yaml | grep -A5 "sourceStrategy"
pause

say "START S2I BUILD — watch the log: no Containerfile instructions"
oc start-build financeflow-portal-s2i \
  --from-dir="$REPO_ROOT/app/portal" \
  --follow
pause

# ── DEMO 6: Docker strategy for portal (comparison) ──────────────────────────
# TALKING POINT: "Now same portal with Docker strategy — compare the logs."

say "Build portal with Docker strategy for comparison"
oc apply -f "$REPO_ROOT/chapters/01-builds/manifests/buildconfig-portal-docker.yaml"
oc start-build financeflow-portal \
  --from-dir="$REPO_ROOT/app/portal" \
  --follow
pause

say "Side-by-side: both builds complete, different strategies"
oc get builds
pause

# ── DEMO 7: Image tagging ──────────────────────────────────────────────────────
# TALKING POINTS:
#   "Tags are just pointers. The image (digest) never changes.
#    latest = mutable pointer, v1.0 = pinned release."

say "Tag all three images as v1.0"
oc tag financeflow-account:latest     financeflow-account:v1.0
oc tag financeflow-transaction:latest financeflow-transaction:v1.0
oc tag financeflow-portal:latest      financeflow-portal:v1.0

say "Both latest and v1.0 point to the same digest"
echo "latest digest:"
oc get imagestreamtag financeflow-account:latest -o jsonpath='{.image.metadata.name}' && echo
echo "v1.0 digest:"
oc get imagestreamtag financeflow-account:v1.0   -o jsonpath='{.image.metadata.name}' && echo
pause

# ── DEMO 8: Build trigger ──────────────────────────────────────────────────────
# TALKING POINTS:
#   "Watch what happens when I touch the BuildConfig.
#    ConfigChange trigger fires — a new build starts automatically."
#   "In production, the ImageChange trigger does the same when the base
#    image gets a security update."

say "Trigger an automatic rebuild via ConfigChange"
oc patch buildconfig financeflow-account \
  --type=merge \
  -p '{"metadata":{"labels":{"demo":"triggered"}}}'

say "Watch for the new build — it starts automatically"
oc get builds --watch &
WATCH_PID=$!
sleep 15
kill $WATCH_PID 2>/dev/null || true
pause

# ── DEMO 9: Web Console walkthrough ───────────────────────────────────────────
# TALKING POINT: "Same information in a visual interface. Let me show you."
# [Switch to browser]
# - Developer perspective → Builds → Builds: show all runs with logs
# - Builds → BuildConfigs: show triggers, strategy, output
# - Builds → ImageStreams: show tags, digest history
say "Open Web Console → Developer → Builds"
echo "URL: $(oc whoami --show-console)/dev-pipelines"
pause

# ── WRAP UP ───────────────────────────────────────────────────────────────────
say "Chapter 1 complete. All images are built and tagged."
oc get imagestreams
oc get builds
echo
echo -e "${G}Images ready for Chapter 2 — Deployments & Scaling${R}"
