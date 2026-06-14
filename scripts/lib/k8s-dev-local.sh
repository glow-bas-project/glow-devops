#!/usr/bin/env bash
# Build a service with glowBuild, import image into k3d, and redeploy via Helm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART_DIR="${DEVOPS_ROOT}/helm/glow"

CLUSTER_NAME="${K3D_CLUSTER_NAME:-glow-dev}"
NAMESPACE="${K3D_NAMESPACE:-glow-local}"
HOSTS_NAME="${K3D_HOST:-localhost}"
LOCAL_PORT="${K3D_HTTP_PORT:-8880}"

declare -A SERVICE_REPOS=(
  [glow-restaurant]=glow-restaurant
  [glow-user]=glow-user-service
  [glow-order]=glow-order-service
  [glow-cart]=glow-cart-service
  [glow-courier]=glow-courier-service
  [glow-menu]=glow-menu-service
  [glow-payment]=glow-payment-service
)

declare -A SERVICE_IMAGES=(
  [glow-restaurant]=glow-restaurant-service
  [glow-user]=glow-user-service
  [glow-order]=glow-order-service
  [glow-cart]=glow-cart-service
  [glow-courier]=glow-courier-service
  [glow-menu]=glow-menu-service
  [glow-payment]=glow-payment-service
)

declare -A API_PATHS=(
  [glow-restaurant]=restaurant
  [glow-user]=user
  [glow-order]=order
  [glow-cart]=cart
  [glow-courier]=courier
  [glow-menu]=menu
  [glow-payment]=payment
)

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s.sh dev <compose-service> [options]

Builds a local image with ./gradlew glowBuild, imports it into k3d, and
updates the Helm release to use image tag "local" for that service.

Requires:
  GLOW_HOME          Parent directory of glow-devops and service repos
  k3d cluster        ./scripts/k8s.sh local setup
  compose/.env       Same as glowBuild / compose workflow

Options:
  --no-build         Skip gradlew glowBuild (image must exist locally)
  --help             Show this help

Examples:
  export GLOW_HOME=/path/to/code
  ./scripts/k8s.sh dev glow-user
  ./scripts/k8s.sh dev glow-restaurant --no-build
EOF
}

resolve_compose_service() {
  local input="$1"
  if [[ -n "${SERVICE_REPOS[${input}]:-}" ]]; then
    echo "${input}"
    return 0
  fi
  case "${input}" in
    restaurant | user | order | cart | courier | menu | payment)
      echo "glow-${input}"
      return 0
      ;;
  esac
  return 1
}

main() {
  local service_input="${1:-}"
  local no_build=false

  while (($#)); do
    case "$1" in
      --no-build)
        no_build=true
        shift
        ;;
      --help | -h | help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "${service_input}" ]]; then
          service_input="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${service_input}" ]]; then
    usage >&2
    exit 1
  fi

  local compose_service
  compose_service="$(resolve_compose_service "${service_input}")" || {
    echo "Unknown service: ${service_input}" >&2
    usage >&2
    exit 1
  }

  if [[ -z "${GLOW_HOME:-}" ]]; then
    echo "GLOW_HOME is not set (parent of glow-devops and service repos)" >&2
    exit 1
  fi

  local repo_name="${SERVICE_REPOS[${compose_service}]}"
  local image_name="${SERVICE_IMAGES[${compose_service}]}"
  local api_path="${API_PATHS[${compose_service}]}"
  local repo_dir="${GLOW_HOME}/${repo_name}"
  local local_image="${image_name}:local"

  if [[ ! -d "${repo_dir}" ]]; then
    echo "Service repo not found: ${repo_dir}" >&2
    exit 1
  fi

  if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "k3d cluster ${CLUSTER_NAME} not running. Run: ./scripts/k8s.sh local setup" >&2
    exit 1
  fi

  if [[ "${no_build}" != true ]]; then
    echo "Building ${local_image} in ${repo_dir}..."
    (cd "${repo_dir}" && ./gradlew glowBuild)
  fi

  if ! docker image inspect "${local_image}" >/dev/null 2>&1; then
    echo "Local image not found: ${local_image} (run without --no-build)" >&2
    exit 1
  fi

  echo "Importing ${local_image} into k3d cluster ${CLUSTER_NAME}..."
  k3d image import "${local_image}" -c "${CLUSTER_NAME}"

  (cd "${CHART_DIR}" && helm dependency update)

  local -a set_args=()
  local i=0
  while IFS= read -r name; do
    if [[ "${name}" == "${api_path}" ]]; then
      set_args+=("--set" "microservices[${i}].imageRef=${local_image}")
      break
    fi
    i=$((i + 1))
  done < <(python3 - "${DEVOPS_ROOT}/helm/glow/values.yaml" <<'PY'
import sys, yaml
from pathlib import Path
data = yaml.safe_load(Path(sys.argv[1]).read_text())
for ms in data.get("microservices", []):
    print(ms["name"])
PY
)

  if ((${#set_args[@]} == 0)); then
    echo "Could not find microservice ${api_path} in helm/glow/values.yaml" >&2
    exit 1
  fi

  helm upgrade --install glow "${CHART_DIR}" \
    -f "${CHART_DIR}/values.yaml" \
    -f "${DEVOPS_ROOT}/helm/environments/local/values.yaml" \
    "${set_args[@]}" \
    -n "${NAMESPACE}" \
    --create-namespace \
    --wait --timeout 10m

  kubectl rollout status deployment/glow-"${api_path}" -n "${NAMESPACE}" --timeout=120s

  echo ""
  echo "Service redeployed: http://${HOSTS_NAME}:${LOCAL_PORT}/api/${api_path}/"
}

main "$@"
