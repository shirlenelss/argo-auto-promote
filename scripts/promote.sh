#!/usr/bin/env bash
# Simulate a GitOps promotion of ONE service's image tag through
# dev -> stage -> prod. Each "promotion" pins the new tag in that env's
# values file (chart/services/<service>/<env>.yaml) -- what Argo CD would
# then sync via that service's own Application (see
# repo/appset/applicationset-services.yaml). Independent promotion: this
# only ever touches the one service you name.
#
# Usage: scripts/promote.sh <service> [image-tag]   (default tag: 0.0.2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART="$PROJECT_ROOT/chart"

SERVICE="${1:?Usage: scripts/promote.sh <service> [image-tag]}"
NEW_TAG="${2:-0.0.2}"
ENVS=(dev stage prod)

if [[ ! -d "$CHART/services/$SERVICE" ]]; then
  echo "::error:: no such service: $CHART/services/$SERVICE not found" >&2
  exit 1
fi

# Simulated registry: a flat text file standing in for a real image registry.
# Each promotion "pushes" the image under a per-env tag, e.g. dev-v1.0.0,
# dev-v1.0.1, ... The counter is derived from how many entries that env
# already has, so it survives across script runs. It's gitignored, not
# committed (it's simulation output, like the values-file edits below);
# reset it with `rm scripts/registry.txt`.
REGISTRY="$SCRIPT_DIR/registry.txt"
touch "$REGISTRY"

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

show_env() {
  local env="$1"
  helm template "$SERVICE-$env" "$CHART" -f "$CHART/services/$SERVICE/$env.yaml" -n "sample-$env" \
    | grep -E "^  namespace:|^  replicas:|image:" \
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

echo "Promoting $SERVICE:$NEW_TAG through: ${ENVS[*]}"
hr
echo "STARTING STATE (current pinned tag):"
for e in "${ENVS[@]}"; do
  tag=$(grep 'tag:' "$CHART/services/$SERVICE/$e.yaml" | head -1 | awk '{print $2}' | tr -d '"')
  printf "  %-6s -> %s:%s\n" "$e" "$SERVICE" "$tag"
done
hr

for env in "${ENVS[@]}"; do
  echo ">>> PROMOTE $SERVICE:$NEW_TAG to [$env]"
  sed -i.bak "s/tag: \".*\"/tag: \"$NEW_TAG\"/" "$CHART/services/$SERVICE/$env.yaml"
  rm -f "$CHART/services/$SERVICE/$env.yaml.bak"
  registry_push "$env" "$SERVICE:$NEW_TAG"
  echo "    rendered manifest for $env:"
  show_env "$env"
  echo "    (in real ArgoCD: commit + push -> app '$SERVICE-$env' auto-syncs)"
  hr
done

echo "DONE. $SERVICE now pinned to $NEW_TAG in: ${ENVS[*]}."
echo "Git diff of the promotion:"
( cd "$PROJECT_ROOT" && git --no-pager diff --stat "chart/services/$SERVICE" )
hr
echo "Simulated registry (scripts/registry.txt):"
cat "$REGISTRY" | sed 's/^/    /'
