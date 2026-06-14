#!/usr/bin/env bash
# Unified Kubernetes workflow for GLOW (local k3d, production on Orbit).
#
# Interim secret storage: compose/.env (local) or helm/environments/production/secrets.env
# Future: GitLab CI variables / external vault (CI/CD extension point).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${DEVOPS_ROOT}/helm/glow"
GLOW_KUBECONFIG_DEFAULT="${HOME}/.kube/glow-config.yaml"
GLOW_K3D_KUBECONFIG="${HOME}/.kube/glow-k3d.yaml"

# shellcheck source=lib/kubeconfig.sh
source "${SCRIPT_DIR}/lib/kubeconfig.sh"
# shellcheck source=lib/env-files.sh
source "${SCRIPT_DIR}/lib/env-files.sh"
# shellcheck source=lib/k8s-apply-secrets.sh
source "${SCRIPT_DIR}/lib/k8s-apply-secrets.sh"
# shellcheck source=lib/helm-deploy.sh
source "${SCRIPT_DIR}/lib/helm-deploy.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/k8s.sh <command> ...

Single entry point for Kubernetes: secrets, deploy, local k3d, and service dev.

Environment:
  KUBECONFIG     Orbit vCluster only (default ~/.kube/glow-config.yaml for deploy production).
                 Never point this at k3d — k3d uses ~/.kube/glow-k3d.yaml via "local" commands.
  GLOW_HOME      Required for: k8s.sh dev <service>

Secrets (stored in secrets.env / compose/.env for now):
  secrets init <local|production>
                 Create env file, generate passwords + OIDC, push to cluster
  secrets apply <env>              Push current env file to cluster
  secrets rotate <env>             Regenerate OIDC secrets, push to cluster
  secrets restart <env>            Rollout restart Deployments (pick up new secrets)

Deploy (Orbit university cluster — NOT local k3d):
  deploy [production] [options]
    --bootstrap    Apply namespaces + secrets, then helm install/upgrade
    --tag <tag>    Set global.imageTag
    --dry-run      helm template only
    --no-wait      Apply manifests and return (skip rollout wait; use: k8s.sh wait production)

  Requires Orbit kubeconfig at ~/.kube/glow-config.yaml.

Lifecycle:
  teardown <local|production>   helm uninstall glow (keeps namespace, PVCs)
  destroy <env> --confirm       Delete entire namespace

Cluster status:
  status <local|production>   Pods, services, Ingress (local) or HTTPRoute (production)
  wait <local|production>     Block until all workloads are Ready (live pod snapshots)
  logs <env> <pod-or-deployment>  Follow logs for a pod or deployment

Local k3d (uses ~/.kube/glow-k3d.yaml — never touches glow-config.yaml):
  local setup | deploy | wait | status | logs | undeploy | destroy [options]
  (local status/wait/logs are aliases — same as: k8s.sh status local, etc.)

Local service dev:
  dev <glow-user|glow-restaurant|...> [--no-build]

Examples:
  export KUBECONFIG=~/.kube/glow-config.yaml
  ./scripts/k8s.sh secrets init production
  ./scripts/k8s.sh deploy production --bootstrap
  ./scripts/k8s.sh status production
  ./scripts/k8s.sh wait production
  ./scripts/k8s.sh deploy production --tag latest
  ./scripts/k8s.sh secrets rotate production
  ./scripts/k8s.sh teardown production

  ./scripts/k8s.sh local setup && ./scripts/k8s.sh local deploy
  export GLOW_HOME=/path/to/code && ./scripts/k8s.sh dev glow-user
EOF
}

cmd_secrets_init() {
  local env="$1"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  ensure_secrets_file true
  ensure_bootstrap_passwords
  "${SCRIPT_DIR}/ensure-oidc-secrets.sh" --env "${env}"
  k8s_apply_cluster_secrets "${env}"
  echo ""
  echo "Initialized secrets for ${env}:"
  echo "  File:    ${GLOW_SECRETS_FILE}"
  echo "  Cluster: namespace ${GLOW_K8S_NAMESPACE}"
  echo ""
  if [[ "${env}" == "local" ]]; then
    echo "Next: ./scripts/k8s.sh local deploy"
  else
    echo "Next: ./scripts/k8s.sh deploy production"
  fi
}

cmd_secrets_apply() {
  local env="$1"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  ensure_secrets_file false
  k8s_apply_cluster_secrets "${env}"
  echo "Applied cluster secrets from ${GLOW_SECRETS_FILE}"
  echo "Run: ./scripts/k8s.sh secrets restart ${env}"
}

cmd_secrets_rotate() {
  local env="$1"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  ensure_secrets_file false
  "${SCRIPT_DIR}/ensure-oidc-secrets.sh" --env "${env}" --rotate
  k8s_apply_cluster_secrets "${env}"
  cat <<EOF

Rotated OIDC secrets for ${env} and applied to cluster.

Next:
  1. ./scripts/k8s.sh secrets restart ${env}
  2. Re-import Keycloak realm (K8s automation = future CI task)
EOF
}

cmd_secrets_restart() {
  local env="$1"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  kubectl rollout restart deployment -n "${GLOW_K8S_NAMESPACE}"
  kubectl rollout status deployment -n "${GLOW_K8S_NAMESPACE}" --timeout=10m
  echo "Restarted deployments in ${GLOW_K8S_NAMESPACE}"
}

activate_cluster_env() {
  local env="$1"
  resolve_glow_env "${env}"

  if [[ "${env}" == "local" ]]; then
    export KUBECONFIG="${GLOW_K3D_KUBECONFIG}"
    if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
      echo "Cannot reach k3d (kubeconfig: ${GLOW_K3D_KUBECONFIG})." >&2
      echo "  ./scripts/k8s.sh local setup" >&2
      return 1
    fi
    return 0
  fi

  require_cluster "${env}"
}

print_env_urls() {
  local env="$1"
  local values_file="${DEVOPS_ROOT}/helm/environments/${env}/values.yaml"

  if [[ "${env}" == "local" ]]; then
    local port="${K3D_HTTP_PORT:-8880}"
    echo "  UI:       http://localhost:${port}/"
    echo "  Keycloak: http://localhost:${port}/auth/realms/glow-realm"
    return 0
  fi

  if [[ ! -f "${values_file}" ]]; then
    return 0
  fi

  local origin auth
  origin="$(grep -E '^  publicOrigin:' "${values_file}" | head -1 | sed 's/^  publicOrigin: *//')"
  auth="$(grep -E '^  authBaseUrl:' "${values_file}" | head -1 | sed 's/^  authBaseUrl: *//')"
  if [[ -n "${origin}" ]]; then
    echo "  UI:       ${origin}/"
  fi
  if [[ -n "${auth}" ]]; then
    echo "  Keycloak: ${auth}/realms/glow-realm"
  fi
}

cmd_status() {
  local env="${1:-}"
  if [[ -z "${env}" ]]; then
    echo "Usage: ./scripts/k8s.sh status <local|production>" >&2
    exit 1
  fi

  activate_cluster_env "${env}" || exit 1
  echo "Namespace: ${GLOW_K8S_NAMESPACE}"
  echo ""
  if [[ "${env}" == "local" ]]; then
    kubectl get pods,svc,ingress -n "${GLOW_K8S_NAMESPACE}"
  else
    kubectl get pods,svc,httproute -n "${GLOW_K8S_NAMESPACE}"
  fi
  echo ""
  echo "URLs:"
  print_env_urls "${env}"
}

cmd_wait() {
  local env="${1:-}"
  if [[ -z "${env}" ]]; then
    echo "Usage: ./scripts/k8s.sh wait <local|production>" >&2
    exit 1
  fi

  activate_cluster_env "${env}" || exit 1
  echo ""
  helm_wait_rollouts "${GLOW_K8S_NAMESPACE}" "${GLOW_WAIT_TIMEOUT:-20m}" \
    "./scripts/k8s.sh logs ${env} <name>"
}

cmd_logs() {
  local env="${1:-}" target="${2:-}"
  if [[ -z "${env}" || -z "${target}" ]]; then
    echo "Usage: ./scripts/k8s.sh logs <local|production> <pod-or-deployment>" >&2
    exit 1
  fi

  activate_cluster_env "${env}" || exit 1

  if kubectl get pod -n "${GLOW_K8S_NAMESPACE}" "${target}" >/dev/null 2>&1; then
    kubectl logs -n "${GLOW_K8S_NAMESPACE}" "${target}" -f
  elif kubectl get deploy -n "${GLOW_K8S_NAMESPACE}" "${target}" >/dev/null 2>&1; then
    kubectl logs -n "${GLOW_K8S_NAMESPACE}" "deploy/${target}" -f --tail=100
  else
    kubectl logs -n "${GLOW_K8S_NAMESPACE}" -l "app.kubernetes.io/name=glow-${target}" -f --tail=100
  fi
}

cmd_deploy() {
  local env="production"
  local image_tag=""
  local bootstrap=false
  local dry_run=false
  local wait_after=true

  while (($#)); do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || { echo "Missing value for --tag" >&2; exit 1; }
        image_tag="$2"
        shift 2
        ;;
      --bootstrap) bootstrap=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --no-wait) wait_after=false; shift ;;
      production) env="$1"; shift ;;
      *)
        echo "Unknown deploy argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  resolve_glow_env "${env}"
  require_cluster "${env}"

  if [[ "${bootstrap}" == true ]]; then
    kubectl apply -f "${DEVOPS_ROOT}/k8s/namespaces.yaml"
    if [[ ! -f "${GLOW_SECRETS_FILE}" ]]; then
      echo "No ${GLOW_SECRETS_FILE}; running secrets init..." >&2
      cmd_secrets_init "${env}"
    else
      k8s_apply_cluster_secrets "${env}"
    fi
  fi

  helm_prepare_dependencies "${CHART_DIR}"

  local -a args=(
    -f "${CHART_DIR}/values.yaml"
    -f "${DEVOPS_ROOT}/helm/environments/${env}/values.yaml"
    -f "${DEVOPS_ROOT}/helm/environments/orbit-resources.yaml"
    -n "${GLOW_K8S_NAMESPACE}"
  )
  if [[ -n "${image_tag}" ]]; then
    args+=(--set "global.imageTag=${image_tag}")
  fi

  if [[ "${dry_run}" == true ]]; then
    helm template glow "${CHART_DIR}" "${args[@]}"
    return 0
  fi

  if [[ "${wait_after}" == true ]]; then
    HELM_POST_WAIT=true helm_deploy glow "${CHART_DIR}" "${GLOW_K8S_NAMESPACE}" \
      "${args[@]}" \
      --create-namespace
    echo ""
    helm_wait_rollouts "${GLOW_K8S_NAMESPACE}" "${GLOW_WAIT_TIMEOUT:-20m}" \
      "./scripts/k8s.sh logs ${env} <name>" || exit 1
    echo ""
    echo "URLs:"
    print_env_urls "${env}"
  else
    helm_deploy glow "${CHART_DIR}" "${GLOW_K8S_NAMESPACE}" \
      "${args[@]}" \
      --create-namespace
    echo ""
    echo "Deploy applied. Watch progress:"
    echo "  ./scripts/k8s.sh status production"
    echo "  ./scripts/k8s.sh wait production"
  fi
}

cmd_teardown() {
  local env="$1"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  helm uninstall glow -n "${GLOW_K8S_NAMESPACE}" || true
  echo "Removed Helm release 'glow' from ${GLOW_K8S_NAMESPACE} (namespace, secrets, PVCs remain)"
}

cmd_destroy() {
  local env="$1"
  local confirm="${2:-}"
  resolve_glow_env "${env}"
  require_cluster "${env}"
  if [[ "${confirm}" != "--confirm" ]]; then
    echo "Refusing to delete namespace ${GLOW_K8S_NAMESPACE} without --confirm" >&2
    echo "  ./scripts/k8s.sh destroy ${env} --confirm" >&2
    exit 1
  fi
  kubectl delete namespace "${GLOW_K8S_NAMESPACE}" --wait=true
  echo "Deleted namespace ${GLOW_K8S_NAMESPACE}"
}

main() {
  local top="${1:-}"
  shift || true

  case "${top}" in
    "" | help | --help | -h)
      usage
      ;;
    secrets)
      local sub="${1:-}" env="${2:-}"
      case "${sub}" in
        init) cmd_secrets_init "${env}" ;;
        apply) cmd_secrets_apply "${env}" ;;
        rotate) cmd_secrets_rotate "${env}" ;;
        restart) cmd_secrets_restart "${env}" ;;
        *)
          echo "Usage: ./scripts/k8s.sh secrets init|apply|rotate|restart <local|production>" >&2
          exit 1
          ;;
      esac
      ;;
    deploy)
      cmd_deploy "$@"
      ;;
    status)
      cmd_status "${1:-}"
      ;;
    wait)
      cmd_wait "${1:-}"
      ;;
    logs)
      cmd_logs "${1:-}" "${2:-}"
      ;;
    teardown)
      cmd_teardown "${1:-}"
      ;;
    destroy)
      cmd_destroy "${1:-}" "${2:-}"
      ;;
    local)
      exec "${SCRIPT_DIR}/lib/k3d-local.sh" "$@"
      ;;
    dev)
      exec "${SCRIPT_DIR}/lib/k8s-dev-local.sh" "$@"
      ;;
    *)
      echo "Unknown command: ${top}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
