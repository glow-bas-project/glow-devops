#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_SCRIPT="${DEVOPS_ROOT}/scripts/k8s.sh"
CHART_DIR="${DEVOPS_ROOT}/helm/glow"
GLOW_K3D_KUBECONFIG="${HOME}/.kube/glow-k3d.yaml"

# shellcheck source=helm-deploy.sh
source "${SCRIPT_DIR}/helm-deploy.sh"
# shellcheck source=env-files.sh
source "${SCRIPT_DIR}/env-files.sh"
# shellcheck source=k8s-apply-secrets.sh
source "${SCRIPT_DIR}/k8s-apply-secrets.sh"

k3d_use_kubeconfig() {
  export KUBECONFIG="${GLOW_K3D_KUBECONFIG}"
}
k3d_use_kubeconfig

CLUSTER_NAME="${K3D_CLUSTER_NAME:-glow-dev}"
NAMESPACE="${K3D_NAMESPACE:-glow-local}"
LOCAL_PORT="${K3D_HTTP_PORT:-8880}"
HOSTS_NAME="${K3D_HOST:-localhost}"

usage() {
  cat <<EOF
Usage: ./scripts/k8s.sh local [command] [options]

Commands:
  setup       Create k3d cluster, namespace, and secrets
  deploy      helm upgrade --install, then wait for pods (default)
  wait        Block until Deployments are Ready (also runs after deploy by default)
  status      Show pods, services, Ingress
  logs        kubectl logs for a pod (pass pod name or label)
  undeploy    helm uninstall glow from ${NAMESPACE}
  destroy     Delete k3d cluster ${CLUSTER_NAME}
  help        Show this help

Options (deploy):
  --tag <tag>     Set global.imageTag
  --no-wait       Apply manifests and return immediately (skip rollout wait)
  --dry-run       helm template only

Examples:
  ./scripts/k8s.sh local setup
  ./scripts/k8s.sh local deploy
  ./scripts/k8s.sh local deploy --no-wait
  ./scripts/k8s.sh local status
EOF
}

require_tools() {
  local missing=()
  for cmd in kubectl helm k3d; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if ((${#missing[@]} > 0)); then
    echo "Missing required tools: ${missing[*]}" >&2
    exit 1
  fi
}

merge_k3d_kubeconfig() {
  k3d_use_kubeconfig
  k3d kubeconfig merge "${CLUSTER_NAME}" \
    -o "${GLOW_K3D_KUBECONFIG}" \
    --kubeconfig-switch-context >/dev/null
}

ensure_k3d_cluster() {
  require_tools
  k3d_use_kubeconfig
  if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "Creating k3d cluster ${CLUSTER_NAME} (Traefik ingress on port ${LOCAL_PORT})..."
    k3d cluster create "${CLUSTER_NAME}" \
      --port "${LOCAL_PORT}:80@loadbalancer"
    merge_k3d_kubeconfig
  else
    merge_k3d_kubeconfig
    if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
      echo "Starting k3d cluster ${CLUSTER_NAME}..."
      k3d cluster start "${CLUSTER_NAME}"
      merge_k3d_kubeconfig
    fi
  fi

  if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    echo "Cannot reach k3d API for cluster ${CLUSTER_NAME}." >&2
    echo "Kubeconfig: ${GLOW_K3D_KUBECONFIG}" >&2
    echo "Try: ./scripts/k8s.sh local destroy && ./scripts/k8s.sh local setup" >&2
    exit 1
  fi
}

setup_cluster() {
  ensure_k3d_cluster
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  if [[ "${HOSTS_NAME}" != "localhost" ]] && ! grep -q "${HOSTS_NAME}" /etc/hosts 2>/dev/null; then
    echo "Add to /etc/hosts: 127.0.0.1 ${HOSTS_NAME}"
  fi

  if [[ ! -f "${DEVOPS_ROOT}/compose/.env" ]]; then
    cp "${DEVOPS_ROOT}/compose/.env.example" "${DEVOPS_ROOT}/compose/.env"
  fi

  "${K8S_SCRIPT}" secrets apply local
  echo "Setup complete. Run: ./scripts/k8s.sh local deploy"
}

deploy_release() {
  local env="local"
  local ns="${NAMESPACE}"
  local release="glow"
  local image_tag=""
  local dry_run=false
  local wait_after=true

  while (($#)); do
    case "$1" in
      --tag)
        image_tag="$2"
        shift 2
        ;;
      --no-wait)
        wait_after=false
        shift
        ;;
      --wait)
        wait_after=true
        shift
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  ensure_k3d_cluster

  helm_prepare_dependencies "${CHART_DIR}"

  local -a args=(
    -f "${CHART_DIR}/values.yaml"
    -f "${DEVOPS_ROOT}/helm/environments/local/values.yaml"
    -f "${DEVOPS_ROOT}/helm/environments/orbit-resources.yaml"
    -n "${ns}"
  )
  if [[ -n "${image_tag}" ]]; then
    args+=(--set "global.imageTag=${image_tag}")
  fi

  if [[ "${dry_run}" == true ]]; then
    helm template "${release}" "${CHART_DIR}" "${args[@]}"
    return 0
  fi

  if [[ "${wait_after}" == true ]]; then
    HELM_POST_WAIT=true helm_deploy "${release}" "${CHART_DIR}" "${ns}" \
      "${args[@]}" \
      --create-namespace
  else
    helm_deploy "${release}" "${CHART_DIR}" "${ns}" \
      "${args[@]}" \
      --create-namespace
  fi

  if [[ "${wait_after}" == true ]]; then
    echo ""
    helm_wait_rollouts "${ns}" "${K3D_WAIT_TIMEOUT:-30m}" \
      "./scripts/k8s.sh logs local <name>" || exit 1
    echo ""
    echo "URLs (port ${LOCAL_PORT}):"
    echo "  UI:       http://${HOSTS_NAME}:${LOCAL_PORT}/"
    echo "  Keycloak: http://${HOSTS_NAME}:${LOCAL_PORT}/auth/realms/glow-realm"
  else
    echo ""
    echo "URLs (port ${LOCAL_PORT}):"
    echo "  UI:       http://${HOSTS_NAME}:${LOCAL_PORT}/"
    echo "  Keycloak: http://${HOSTS_NAME}:${LOCAL_PORT}/auth/realms/glow-realm"
    echo ""
    echo "Deploy applied. Pods start in the background (Quarkus JVMs need several minutes on k3d)."
    echo "  ./scripts/k8s.sh local wait     # block until Ready"
    echo "  ./scripts/k8s.sh local status   # snapshot"
    echo "  kubectl get pods -n ${ns} -w    # live view"
  fi
}

cmd_wait() {
  ensure_k3d_cluster
  echo ""
  helm_wait_rollouts "${NAMESPACE}" "${K3D_WAIT_TIMEOUT:-30m}" \
    "./scripts/k8s.sh logs local <name>"
}

cmd_status() {
  ensure_k3d_cluster
  kubectl get pods,svc,ingress -n "${NAMESPACE}"
}

cmd_logs() {
  ensure_k3d_cluster
  local target="${1:-}"
  if [[ -z "${target}" ]]; then
    echo "Usage: ./scripts/k8s.sh local logs <pod-name-or-label>" >&2
    exit 1
  fi
  if kubectl get pod -n "${NAMESPACE}" "${target}" >/dev/null 2>&1; then
    kubectl logs -n "${NAMESPACE}" "${target}" -f
  elif kubectl get deploy -n "${NAMESPACE}" "${target}" >/dev/null 2>&1; then
    kubectl logs -n "${NAMESPACE}" "deploy/${target}" -f --tail=100
  else
    kubectl logs -n "${NAMESPACE}" -l "app.kubernetes.io/name=glow-${target}" -f --tail=100
  fi
}

cmd_undeploy() {
  require_tools
  helm uninstall glow -n "${NAMESPACE}" || true
}

cmd_destroy() {
  require_tools
  k3d cluster delete "${CLUSTER_NAME}" || true
}

main() {
  local cmd="${1:-deploy}"
  shift || true

  case "${cmd}" in
    setup) setup_cluster ;;
    deploy | "") deploy_release "$@" ;;
    wait) cmd_wait ;;
    status) cmd_status ;;
    logs) cmd_logs "${1:-}" ;;
    undeploy) cmd_undeploy ;;
    destroy) cmd_destroy ;;
    help | --help | -h) usage ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
