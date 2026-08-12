# FinanceFlow Workshop — Student Quickstart

Copy-paste these commands in order. Replace `<your-name>` everywhere with your own short name (lowercase, no spaces — e.g. `alice`).

## 1. Log in to the cluster

```bash
oc login https://api.<cluster-domain>:6443 --token=<your-token>
oc whoami
```

## 2. Clone the workshop repo

```bash
git clone <repo-url>
cd ocp-demo-namespace-agnostic
```

## 3. Set your namespace across the repo

```bash
chapters/set-namespace.sh financeflow-<your-name>
```

Review the changes (optional):

```bash
git diff --stat
```

## 4. Prepare the cluster (one-time, run once per cluster)

```bash
chapters/prepare-cluster.sh
```

## 5. Deploy FinanceFlow into your namespace

```bash
NAMESPACE=financeflow-<your-name> chapters/deploy-demo-resume.sh
```

Follow the on-screen pauses — press Enter to advance one step at a time. To run straight through without pauses:

```bash
NAMESPACE=financeflow-<your-name> chapters/deploy-demo-resume.sh -y
```

## 6. Verify it's running

```bash
oc get pods -n financeflow-<your-name>
oc get route portal -n financeflow-<your-name>
```

Open the printed route URL in your browser.

## 7. Resume after a crash (if needed)

```bash
NAMESPACE=financeflow-<your-name> chapters/deploy-demo-resume.sh --list
NAMESPACE=financeflow-<your-name> chapters/deploy-demo-resume.sh --from <step-number>
```

## 8. Clean up at the end of the workshop

```bash
NAMESPACE=financeflow-<your-name> chapters/cleanup-demo.sh
```
