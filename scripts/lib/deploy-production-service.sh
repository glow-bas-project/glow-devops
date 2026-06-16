#!/usr/bin/env bash
# CI/local helper: set image on one Deployment (expects Helm strategy: Recreate).
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${LIB_DIR}/../.." && pwd)"

source "${LIB_DIR}/env-files.sh"
source "${LIB_DIR}/kubeconfig.sh"

main() {
  local service="" tag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service) service="$2"; shift 2 ;;
      --tag) tag="$2"; shift 2 ;;
      *) echo "Usage: --service <name> --tag <tag>" >&2; exit 1 ;;
    esac
  done

  [[ -n "${service}" && -n "${tag}" ]] || { echo "Usage: --service <name> --tag <tag>" >&2; exit 1; }

  local deploy container image_repo registry
  case "${service}" in
    ui) deploy="glow-ui"; container="ui"; image_repo="glow-ui" ;;
    restaurant|user|order|cart|courier|menu|payment)
      deploy="glow-${service}"; container="${service}"; image_repo="glow-${service}-service" ;;
    *) echo "Unknown service: ${service}" >&2; exit 1 ;;
  esac

  registry="$(grep -E '^  registry:' "${DEVOPS_ROOT}/helm/glow/values.yaml" | head -1 | sed 's/^  registry: *//')"
  registry="${registry:-registry.gitlab.au.dk/backend-architecture-and-scalability}"
  local image="${registry}/${image_repo}:${tag}"

  resolve_glow_env production
  require_cluster production || exit 1

  local ns="${GLOW_K8S_NAMESPACE}"
  kubectl get deploy "${deploy}" -n "${ns}" >/dev/null || {
    echo "Missing ${deploy} — run: ./scripts/k8s.sh deploy production --bootstrap" >&2
    exit 1
  }

  echo "Deploy ${deploy} -> ${image}"
  kubectl set image "deploy/${deploy}" "${container}=${image}" -n "${ns}"
  kubectl rollout status "deploy/${deploy}" -n "${ns}" --timeout="${GLOW_DEPLOY_TIMEOUT:-10m}"
  kubectl get deploy "${deploy}" -n "${ns}" \
    -o jsonpath='Running image: {.spec.template.spec.containers[0].image}{"\n"}'
}

main "$@"
