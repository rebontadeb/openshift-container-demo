# Chapter 1
## Container Builds & Images

**FinanceFlow Workshop — OpenShift Container Capabilities**

---

## Agenda

1. How OpenShift builds containers
2. ImageStreams — what they are and why they matter
3. Docker (Containerfile) strategy — hands-on
4. S2I strategy — no Containerfile needed
5. Build triggers — automatic rebuilds
6. Lab 1 walkthrough

---

## The Problem with `podman build`

On a developer laptop:
```bash
podman build -t myapp .
```

- Requires a container runtime locally
- Image lives on one machine
- No audit trail
- No auto-rebuild on base image update
- Hard to standardise across a team

---

## OpenShift Builds: The Cluster Does It

```
Developer laptop            OpenShift Cluster
────────────────            ─────────────────────────────────
source code
    │                         ┌─────────────┐
    │  oc start-build         │  Build Pod  │
    │  --from-dir=./app ──────►  (runs your │
    │                         │ Containerfile)
    │                         └──────┬──────┘
                                     │ image
                                     ▼
                               Internal Registry
                                     │
                               ImageStream Tag
```

No local runtime. No image on your laptop. Audited. Triggerable.

---

## Two Build Strategies

| | Docker Strategy | S2I Strategy |
|---|---|---|
| **Input** | Your Containerfile | Just source files |
| **Control** | Full | Builder decides structure |
| **Who writes the build logic** | You | Red Hat / community |
| **Best for** | Full flexibility | Standardised team builds |

---

## What is an ImageStream?

A **pointer** into the internal registry — not the image itself.

```
financeflow-account:latest  →  sha256:a1b2c3...
financeflow-account:v1.0    →  sha256:a1b2c3...   (same image)
financeflow-account:v1.1    →  sha256:d4e5f6...   (new build)
```

**Why it matters:**

- Your Deployment YAML says `financeflow-account:latest`
- You never hardcode a registry URL
- Change the registry → update the ImageStream, not every Deployment
- An image change on `latest` can **trigger a new Deployment automatically**

---

## Docker Strategy: Containerfile in the Cluster

```yaml
strategy:
  type: Docker
  dockerStrategy:
    dockerfilePath: Containerfile
output:
  to:
    kind: ImageStreamTag
    name: financeflow-account:latest
```

Start a build:
```bash
oc start-build financeflow-account \
  --from-dir=./app/account-service \
  --follow
```

The source is archived and uploaded to the build pod.
The Containerfile runs. The image is pushed to the internal registry.

---

## S2I Strategy: No Containerfile

```yaml
strategy:
  type: Source
  sourceStrategy:
    from:
      kind: ImageStreamTag
      namespace: openshift
      name: "nginx:latest"    # builder image
```

Start the same way:
```bash
oc start-build financeflow-portal-s2i \
  --from-dir=./app/portal \
  --follow
```

The `nginx` builder:
1. Takes your HTML/JS/CSS files
2. Copies them into `/usr/share/nginx/html`
3. Picks up your `nginx.conf`
4. Produces a ready-to-run image

No Containerfile written. No decisions made.

---

## OpenShift S2I Builders (out of the box)

| Builder | Image |
|---------|-------|
| Python | `python:3.11-ubi9` |
| Node.js | `nodejs:20-ubi9` |
| Java | `java:openjdk-21-ubi9` |
| Go | `golang:1.21-ubi9` |
| nginx | `nginx:latest` |
| PHP | `php:8.2-ubi9` |
| Ruby | `ruby:3.2-ubi9` |

```bash
oc get imagestreams -n openshift
```

---

## Build Triggers

Two triggers in every BuildConfig:

```yaml
triggers:
  - type: ConfigChange    # rebuild when this YAML changes
  - type: ImageChange     # rebuild when base image updates
```

**ImageChange trigger flow:**
```
Red Hat releases patched python:3.11-slim
            │
    OpenShift detects new digest on base ImageStream
            │
    BuildConfig trigger fires
            │
    New build starts automatically
            │
    financeflow-account:latest → new patched image
            │
    Deployment rollout (Chapter 2)
```

Security patches reach your app **without any manual step**.

---

## Image Tagging

Tags are just pointers — the image (digest) is immutable:

```bash
# Create a release tag
oc tag financeflow-account:latest financeflow-account:v1.0

# Both point to the same sha256 digest
oc get imagestreamtag financeflow-account:v1.0
```

**Workflow:**
- `latest` → always the most recent build (CI/CD)
- `v1.0`, `v1.1` → pinned releases (production deployments)
- `stable` → manually promoted after QA

---

## Build History & Audit

Every build is recorded:

```bash
oc get builds

NAME                    TYPE    STATUS    STARTED         DURATION
financeflow-account-1   Docker  Complete  10 minutes ago  1m12s
financeflow-account-2   Docker  Complete  2 minutes ago   1m08s
```

```bash
# Get logs for any past build
oc logs build/financeflow-account-1
```

Full audit trail. Who triggered what, when, from what source.

---

## Web Console: Builds View

**Developer perspective → Builds**

- Live log streaming
- Build pipeline visualization
- ImageStream tag history
- Trigger history

_[demo]_

---

## Lab 1 — Your Turn

**What you will do:**

1. Create ImageStreams for all 3 FinanceFlow services
2. Build account-service and transaction-service (Docker strategy)
3. Build the portal (S2I strategy — no Containerfile)
4. Compare Docker vs S2I build logs and timings
5. Tag images as `v1.0`
6. Trigger an automatic rebuild

**Estimated time:** 45 min
**Lab guide:** `labs/01-builds-images.md`

---

## Chapter 1 — Summary

| Concept | Key Point |
|---------|-----------|
| Build Pod | Cluster builds the image — no local runtime |
| Docker strategy | Your Containerfile, full control |
| S2I strategy | No Containerfile — builder handles it |
| ImageStream | Pointer abstraction — decouples manifests from registry |
| Build triggers | Auto-rebuild on config change or base image update |

**Next:** Chapter 2 — Deployments & Scaling
*(using the images we just built)*
