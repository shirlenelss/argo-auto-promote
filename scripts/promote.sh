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

# Simulated registry: a flat text file standing in for a real image registry.
# Each promotion "pushes" the image under a per-env tag, e.g. dev-v1.0.0,
# dev-v1.0.1, ... The counter is derived from how many entries that env
# already has, so it survives across script runs. It's gitignored, not
# committed (it's simulation output, like the overlay edits below); reset it
# with `rm scripts/registry.txt`.
REGISTRY="$SCRIPT_DIR/registry.txt"
touch "$REGISTRY"

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

show_env() {
  local env="$1"
  kustomize build "$REPO/overlay/$env" \
    | grep -E "^  namespace:|^  replicas:|- image:" \
    | sed 's/^/    /'
}

registry_push() {
  local env="$1" image="$2"
  local count sim_tag ts
  count=$(awk -v e="${env}-v1\\." '$2 ~ "^"e { c++ } END { print c+0 }' "$REGISTRY")
  sim_tag="${env}-v1.0.${count}"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s %s\n' "$image" "$sim_tag" "$ts" >> "$REGISTRY"
  echo "    [registry] env=$env  image=$image  tag=$sim_tag"
}

echo "Promoting nginx:$NEW_TAG through: ${ENVS[*]}"
hr
echo "STARTING STATE (current pinned tags):"
for e in "${ENVS[@]}"; do
  tag=$(grep 'newTag:' "$REPO/overlay/$e/kustomization.yaml" | head -1 | awk '{print $2}' | tr -d '"')
  printf "  %-6s -> nginx:%s\n" "$e" "$tag"
done
hr

for env in "${ENVS[@]}"; do
  echo ">>> PROMOTE nginx:$NEW_TAG to [$env]"
  ( cd "$REPO/overlay/$env" && kustomize edit set image "nginx=nginx:$NEW_TAG" )
  registry_push "$env" "nginx:$NEW_TAG"
  echo "    rendered manifest for $env:"
  show_env "$env"
  echo "    (in real ArgoCD: commit + push -> app 'service-a-$env' auto-syncs)"
  hr
done

echo "DONE. All envs now pinned to nginx:$NEW_TAG."
echo "Git diff of the promotion:"
( cd "$PROJECT_ROOT" && git --no-pager diff --stat repo/overlay )
hr
echo "Simulated registry (scripts/registry.txt):"
cat "$REGISTRY" | sed 's/^/    /'
