#!/usr/bin/env bash
# Simulate a GitOps promotion of an image tag through dev -> stage -> prod.
# Each "promotion" pins the new image tag in that env's overlay (what ArgoCD
# would then sync). We render the manifests at each hop so you can see the diff.
#
# Usage: scripts/promote.sh [image-tag]   (default: 1.27.0)
set -euo pipefail

# Resolve repo layout relative to this script (scripts/ lives next to repo/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="$PROJECT_ROOT/repo"
NEW_TAG="${1:-1.27.0}"
ENVS=(dev stage prod)

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

show_env() {
  local env="$1"
  kustomize build "$REPO/overlay/$env" \
    | grep -E "^  namespace:|^  replicas:|- image:" \
    | sed 's/^/    /'
}

echo "Promoting nginx:$NEW_TAG through: ${ENVS[*]}"
hr
echo "STARTING STATE (current pinned tags):"
for e in "${ENVS[@]}"; do
  tag=$(grep -A2 'images:' "$REPO/overlay/$e/kustomization.yaml" | grep newTag | awk '{print $2}' | tr -d '"')
  printf "  %-6s -> nginx:%s\n" "$e" "$tag"
done
hr

for env in "${ENVS[@]}"; do
  echo ">>> PROMOTE nginx:$NEW_TAG to [$env]"
  ( cd "$REPO/overlay/$env" && kustomize edit set image "nginx=nginx:$NEW_TAG" )
  echo "    rendered manifest for $env:"
  show_env "$env"
  echo "    (in real ArgoCD: commit + push -> app 'sample-app-$env' auto-syncs)"
  hr
done

echo "DONE. All envs now pinned to nginx:$NEW_TAG."
echo "Git diff of the promotion:"
( cd "$PROJECT_ROOT" && git --no-pager diff --stat repo/overlay )
