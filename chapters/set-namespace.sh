#!/usr/bin/env bash
# Rewrite every hardcoded reference to the default workshop namespace
# (financeflow-workshop) across manifests, scripts, and docs, so each
# student can deploy FinanceFlow into their own namespace.
#
# Usage:
#   chapters/set-namespace.sh <new-namespace> [old-namespace]
#
# Example:
#   chapters/set-namespace.sh financeflow-alice
#
# Only rewrites files under version control (git ls-files), so build
# artifacts, __pycache__, etc. are never touched. Run with --dry-run to
# preview the file list without writing anything.

set -euo pipefail

DRY_RUN=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--dry-run" ]; then
    DRY_RUN=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

NEW_NS="${1:-}"
OLD_NS="${2:-financeflow-workshop}"

if [ -z "$NEW_NS" ]; then
  echo "Usage: $0 <new-namespace> [old-namespace] [--dry-run]" >&2
  exit 1
fi

# DNS-1123 label: lowercase alphanumeric or '-', start/end alphanumeric, <=63 chars
DNS1123='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
if ! [[ "$NEW_NS" =~ $DNS1123 ]]; then
  echo "Error: '$NEW_NS' is not a valid Kubernetes namespace name" >&2
  echo "(lowercase alphanumeric and '-', must start/end alphanumeric, max 63 chars)" >&2
  exit 1
fi

if ! [[ "$OLD_NS" =~ $DNS1123 ]]; then
  echo "Error: '$OLD_NS' is not a valid Kubernetes namespace name" >&2
  exit 1
fi

if [ "$NEW_NS" = "$OLD_NS" ]; then
  echo "New namespace is same as old namespace ($OLD_NS) — nothing to do." >&2
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: must run inside the git repo" >&2
  exit 1
fi

SELF="$(git ls-files --full-name -- "${BASH_SOURCE[0]}")"

mapfile -t FILES < <(git grep -lI --fixed-strings "$OLD_NS" -- \
  '*.yaml' '*.yml' '*.sh' '*.md' ":!$SELF" 2>/dev/null || true)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No files contain '$OLD_NS' — nothing to do."
  exit 0
fi

echo "Replacing '$OLD_NS' -> '$NEW_NS' in ${#FILES[@]} file(s):"
printf '  %s\n' "${FILES[@]}"

if $DRY_RUN; then
  echo "(--dry-run: no files modified)"
  exit 0
fi

for f in "${FILES[@]}"; do
  sed -i "s/${OLD_NS}/${NEW_NS}/g" "$f"
done

echo
echo "Done. Review with: git diff"
echo "Then deploy with:  NAMESPACE=$NEW_NS chapters/deploy-demo-resume.sh"
