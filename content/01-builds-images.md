# Chapter 1 — Container Builds & Images

**FinanceFlow Workshop — OpenShift Container Capabilities**

**Chapter:** 1 | **Duration:** 60 min | **Complexity:** 🟢 Beginner

---

## Objectives

By the end of this chapter you will:
- Understand how OpenShift builds container images without a local container runtime
- Build the FinanceFlow backend services using the **Docker (Containerfile) strategy**
- Build the portal using the **S2I (Source-to-Image) strategy** — no Containerfile required
- Understand ImageStreams and how they decouple your manifests from the registry URL
- Tag images and observe how an image change triggers an automatic rebuild

---

## Prerequisites

- Chapter 0 complete — you are logged in and your namespace exists
- Workshop repo cloned locally
- `oc whoami` returns your username

```bash
oc project financeflow-<your-name>
oc whoami
```

---

## Concepts

### The Problem with `podman build`

On a developer laptop:
```bash
podman build -t myapp .
```

- Requires a container runtime locally
- Image lives on one machine
- No audit trail
- No auto-rebuild on base image update
- Hard to standardise across a team

### OpenShift Builds: The Cluster Does It

On your laptop you use `podman build` — it runs locally and needs the container runtime.
On OpenShift, a **Build Pod** runs inside the cluster and produces the image, which lands in the **internal registry**. You never need Docker or Podman on the machine that triggers the build.

```
Developer laptop                    OpenShift Cluster
──────────────────                  ─────────────────────────────────
  source code                         Build Pod (runs Containerfile)
      │                                       │
  oc start-build ──── uploads source ──────► │
  --from-dir=./app/                          │ builds image
                                             ▼
                                      Internal Registry
                                             │
                                      ImageStream Tag
                                             │
                                      (triggers Deployment)
```

No local runtime. No image on your laptop. Audited. Triggerable.

### Two Build Strategies

| | Docker Strategy | S2I Strategy |
|---|---|---|
| **Input** | Your Containerfile | Just source files |
| **Control** | Full | Builder decides structure |
| **Who writes the build logic** | You | Red Hat / community |
| **Best for** | Full flexibility | Standardised team builds |

| Strategy | How it works | When to use |
|----------|-------------|-------------|
| **Docker** | Runs your `Containerfile` in the build pod | Full control, existing Containerfiles |
| **S2I** | Builder image assembles your app — no Containerfile needed | Standardised builds, language runtimes |

### What is an ImageStream?

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

An **ImageStream** is an OpenShift abstraction over a container image. Instead of hardcoding `image-registry.openshift-image-registry.svc:5000/financeflow-workshop/financeflow-account:abc123` in every Deployment, you just write `financeflow-account:latest` and OpenShift resolves it.

### Docker Strategy: Containerfile in the Cluster

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

The source is archived and uploaded to the build pod. The Containerfile runs. The image is pushed to the internal registry.

### S2I Strategy: No Containerfile

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

### OpenShift S2I Builders (out of the box)

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

### Build Triggers

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

### Image Tagging

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

### Build History & Audit

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

### Web Console: Builds View

**Developer perspective → Builds**

- Live log streaming
- Build pipeline visualization
- ImageStream tag history
- Trigger history

---

## Hands-On Lab

### Lab 1a — Create ImageStreams

#### Step 1 — Apply all three ImageStreams

```bash
oc apply -f chapters/01-builds/manifests/imagestream-account.yaml
oc apply -f chapters/01-builds/manifests/imagestream-transaction.yaml
oc apply -f chapters/01-builds/manifests/imagestream-portal.yaml
```

#### Step 2 — Verify

```bash
oc get imagestreams
```

Expected output:
```
NAME                     IMAGE REPOSITORY                                                        TAGS   UPDATED
financeflow-account      image-registry.openshift-image-registry.svc:5000/.../financeflow-account
financeflow-portal       image-registry.openshift-image-registry.svc:5000/.../financeflow-portal
financeflow-transaction  image-registry.openshift-image-registry.svc:5000/.../financeflow-transaction
```

> **Note:** No tags yet — we haven't built anything. The ImageStream is just a named slot.

#### Step 3 — Inspect an ImageStream

```bash
oc describe imagestream financeflow-account
```

Notice `lookupPolicy: local: true` — this means any Deployment in this namespace can reference the image as just `financeflow-account:latest` and OpenShift will resolve the full internal registry URL.

### Lab 1b — Docker Strategy Build: Account Service

#### Step 1 — Apply the BuildConfig

```bash
oc apply -f chapters/01-builds/manifests/buildconfig-account.yaml
```

```bash
oc get buildconfigs
```

#### Step 2 — Start the build by uploading source

The `--from-dir` flag archives the local directory and sends it to the build pod — no Git push required.

```bash
oc start-build financeflow-account \
  --from-dir=./app/account-service \
  --follow
```

Watch the build log stream. You will see:
1. Source upload
2. `FROM python:3.11-slim` — base image pull
3. `RUN addgroup / adduser` — creating the non-root user
4. `RUN pip install` — installing dependencies
5. `COPY app.py` — copying source
6. `Pushing image` — image pushed to the internal registry

#### Step 3 — Verify the build completed

```bash
oc get builds
```

```
NAME                      TYPE     FROM     STATUS     STARTED         DURATION
financeflow-account-1     Docker   Binary   Complete   2 minutes ago   1m15s
```

#### Step 4 — Inspect the ImageStreamTag

```bash
oc get imagestreamtag financeflow-account:latest
```

```bash
oc describe imagestreamtag financeflow-account:latest
```

Notice the image digest (`sha256:...`) — this is the immutable identifier. The tag `latest` is just a pointer to this digest.

### Lab 1c — Docker Strategy Build: Transaction Service

Same pattern — repeat for the transaction service.

```bash
oc apply -f chapters/01-builds/manifests/buildconfig-transaction.yaml

oc start-build financeflow-transaction \
  --from-dir=./app/transaction-service \
  --follow
```

Compare the two builds:

```bash
oc get builds
```

```bash
# See both images are now in the registry
oc get imagestreams
```

### Lab 1d — S2I Build: Portal (no Containerfile)

S2I (Source-to-Image) lets OpenShift build an image from **just your source files** — no Containerfile needed. A builder image knows how to assemble your app.

For the portal, the `nginx` builder takes your static HTML/JS/CSS files and produces a ready-to-run nginx image.

#### Step 1 — Look at what we're NOT writing

Open `app/portal/` — there **is** a Containerfile here because we also support Docker strategy. With S2I, you only need:
```
app/portal/
├── index.html
├── app.js
├── style.css
└── nginx.conf      ← S2I nginx builder picks this up automatically
```

> **About the portal Containerfile:** it is written for OpenShift's non-root requirements. Three things to notice when you read it:
> 1. **No `adduser`/`addgroup`** — instead of creating a fixed user, it uses `chown 1001:0` + `chmod g+rwx` so the image works with any UID OpenShift assigns from the namespace range (containers always run with GID 0 in OpenShift, giving group-write access regardless of UID).
> 2. **`sed -i '/^user /d' /etc/nginx/nginx.conf`** — removes the `user nginx;` directive from nginx's main config, which causes a fatal error when nginx cannot switch to that user.
> 3. **`mkdir -p /var/cache/nginx/*_temp`** — pre-creates nginx's temp directories so nginx never needs to `mkdir` at runtime (which would also fail as non-root).
>
> The S2I build handles all of this automatically — it uses OpenShift's hardened nginx builder image that is already non-root compatible.

#### Step 2 — Check the available S2I builders

```bash
oc get imagestreams -n openshift | grep nginx
```

#### Step 3 — Apply the S2I BuildConfig

```bash
oc apply -f chapters/01-builds/manifests/buildconfig-portal-s2i.yaml
```

```bash
oc start-build financeflow-portal-s2i \
  --from-dir=./app/portal \
  --follow
```

Watch the build — notice the difference from the Docker strategy:
- No `FROM` / `RUN` / `COPY` steps
- Instead: `Assemble script`, `Copying sources into image`
- The builder image handles everything

#### Step 4 — Compare Docker vs S2I for the same portal

```bash
oc apply -f chapters/01-builds/manifests/buildconfig-portal-docker.yaml

oc start-build financeflow-portal \
  --from-dir=./app/portal \
  --follow
```

```bash
oc get builds
```

| Build | Strategy | Duration | Flexibility |
|-------|----------|----------|-------------|
| `financeflow-portal-s2i-1` | S2I | Faster (no pip/apt) | Less — builder decides the structure |
| `financeflow-portal-1` | Docker | Slightly slower | Full — your Containerfile runs |

> **When to use S2I:** Standardised team builds, compliance environments where you don't want developers writing arbitrary Containerfiles. OpenShift ships S2I builders for Python, Node.js, Java, PHP, Ruby, Go, nginx, and more.

### Lab 1e — Image Tagging

A tag is just a pointer. You can create multiple tags pointing at the same digest.

```bash
# Tag the account service build as v1.0
oc tag financeflow-account:latest financeflow-account:v1.0

# Tag the transaction service
oc tag financeflow-transaction:latest financeflow-transaction:v1.0

# Tag the portal
oc tag financeflow-portal:latest financeflow-portal:v1.0
```

```bash
oc get imagestream financeflow-account -o jsonpath='{.status.tags[*].tag}' && echo
```

You should see: `latest v1.0`

```bash
# Confirm both tags point to the same digest
oc get imagestreamtag financeflow-account:latest -o jsonpath='{.image.metadata.name}'
oc get imagestreamtag financeflow-account:v1.0  -o jsonpath='{.image.metadata.name}'
```

Both should print the same `sha256:...` digest.

### Lab 1f — Build Triggers (Observe)

The BuildConfigs have two triggers defined:
- `ConfigChange` — rebuilds when the BuildConfig YAML itself changes
- `ImageChange` — rebuilds when the base image (`python:3.11-slim`) receives an update

#### Observe ConfigChange trigger

Patch the BuildConfig to add a label — this counts as a config change:

```bash
oc patch buildconfig financeflow-account \
  --type=merge \
  -p '{"metadata":{"labels":{"touched":"true"}}}'
```

```bash
oc get builds --watch
```

A new build (`financeflow-account-2`) starts automatically within seconds.

#### Observe build history

```bash
oc get builds -l buildconfig=financeflow-account
```

```
NAME                    TYPE     FROM     STATUS     STARTED
financeflow-account-1   Docker   Binary   Complete   5 minutes ago
financeflow-account-2   Docker   Binary   Complete   1 minute ago
```

> **Why this matters:** When Red Hat releases a patched `python:3.11-slim` base image, the ImageChange trigger automatically rebuilds your application image — security patches propagate to your app without any manual intervention.

### Checkpoint — Verify Everything

```bash
# All three ImageStreams should have tags
oc get imagestreams

# All builds should be Complete
oc get builds

# The internal registry holds the images
oc get imagestreamtag financeflow-account:latest
oc get imagestreamtag financeflow-transaction:latest
oc get imagestreamtag financeflow-portal:latest
```

### Web Console Walkthrough

1. Open the OpenShift Web Console
2. Switch to **Developer** perspective → select your project
3. Navigate to **Builds** → **Builds** — see all build runs with logs
4. Navigate to **Builds** → **BuildConfigs** — see triggers, strategy, output
5. Navigate to **Builds** → **ImageStreams** — see tags and digest history

The Web Console build log view is identical to `oc start-build --follow` but visual.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `error: build error: no such file or directory: Containerfile` | Wrong `--from-dir` path | Make sure you're uploading the service subdirectory, not the repo root |
| Build stuck in `Pending` | No available build nodes / quota | Check `oc describe build <name>` for events |
| `ImageStreamTag not found` | ImageStream not created yet | Apply ImageStream YAML before BuildConfig |
| S2I build fails with `permission denied` | Source files not readable by builder UID | Check file permissions on host |
| `error: tag latest not found` | Build failed before push | Check build logs: `oc logs build/<name>` |

---

## Key Takeaways

- **ImageStreams** decouple your manifests from the internal registry URL — change the registry, not your YAMLs
- **Docker strategy** runs your Containerfile inside the cluster — no local runtime needed
- **S2I strategy** removes the Containerfile entirely — the builder knows how to assemble your language/framework
- **Build triggers** automate rebuilds on config change or base image update — security patches are free
- Every build is recorded — you have full history with `oc get builds`

---

*Next: [Chapter 2 — Deployments & Scaling](02-deployments-scaling.md)*
