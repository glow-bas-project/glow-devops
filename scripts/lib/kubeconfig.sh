# Kubeconfig helpers — keep Orbit (~/.kube/glow-config.yaml) separate from k3d.
# Source after DEVOPS_ROOT is set.

: "${GLOW_KUBECONFIG_DEFAULT:=${HOME}/.kube/glow-config.yaml}"
: "${GLOW_K3D_KUBECONFIG:=${HOME}/.kube/glow-k3d.yaml}"

# k3d must NEVER merge into glow-config.yaml (Orbit). Use a dedicated file.
k3d_use_kubeconfig() {
  export KUBECONFIG="${GLOW_K3D_KUBECONFIG}"
}

kubeconfig_server_for_context() {
  local ctx="$1"
  kubectl config view --context="${ctx}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

is_k3d_server() {
  local server="$1"
  [[ "${server}" =~ ^https?://(127\.0\.0\.1|0\.0\.0\.0|localhost):[0-9]+$ ]] ||
    [[ "${server}" == *k3d* ]]
}

is_orbit_server() {
  local server="$1"
  [[ "${server}" == *orbit.au.dk* ]]
}

# Pick Orbit vCluster context in glow-config (ignore k3d entries in the same file).
orbit_select_context() {
  local config_file="$1"
  local ctx server

  if [[ ! -f "${config_file}" ]]; then
    return 1
  fi

  while IFS= read -r ctx; do
    [[ -n "${ctx}" ]] || continue
    server="$(kubeconfig_server_for_context "${ctx}")"
    if is_orbit_server "${server}"; then
      kubectl config use-context "${ctx}" >/dev/null
      echo "${ctx}"
      return 0
    fi
  done < <(kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}')

  return 1
}

# Configure kubectl for university cluster (production on Orbit).
orbit_use_kubeconfig() {
  local env="${1:-}"

  if [[ "${env}" != "production" ]]; then
    return 0
  fi

  if [[ "${GLOW_KUBECONFIG_MODE:-}" == "current" ]]; then
    return 0
  fi

  if [[ -n "${KUBECONFIG:-}" ]]; then
    export KUBECONFIG
  elif [[ -f "${GLOW_KUBECONFIG_DEFAULT}" ]]; then
    export KUBECONFIG="${GLOW_KUBECONFIG_DEFAULT}"
  else
    cat >&2 <<EOF
Orbit kubeconfig not found: ${GLOW_KUBECONFIG_DEFAULT}

Download the vCluster kubeconfig from Orbit and save it there (server *.orbit.au.dk).
Do not store k3d credentials in this file — k3d uses ${GLOW_K3D_KUBECONFIG} instead.

  export KUBECONFIG=${GLOW_KUBECONFIG_DEFAULT}
  ./scripts/k8s.sh deploy production --bootstrap

Local k3d test (no Orbit file needed):

  ./scripts/k8s.sh local setup && ./scripts/k8s.sh local deploy
EOF
    return 1
  fi

  local current_server current_ctx orbit_ctx
  current_ctx="$(kubectl config current-context 2>/dev/null || true)"
  current_server="$(kubeconfig_server_for_context "${current_ctx}")"

  if is_k3d_server "${current_server}"; then
    orbit_ctx="$(orbit_select_context "${KUBECONFIG}")" || true
    if [[ -n "${orbit_ctx}" ]]; then
      echo "Switched kube context from k3d (${current_ctx}) to Orbit (${orbit_ctx})." >&2
      echo "Tip: keep k3d out of ${GLOW_KUBECONFIG_DEFAULT} — use ${GLOW_K3D_KUBECONFIG} for local." >&2
      return 0
    fi
  fi

  if [[ -n "${current_server}" ]] && ! is_orbit_server "${current_server}" && ! is_k3d_server "${current_server}"; then
    orbit_ctx="$(orbit_select_context "${KUBECONFIG}")" || true
    if [[ -n "${orbit_ctx}" ]]; then
      echo "Switched kube context to Orbit (${orbit_ctx})." >&2
    fi
  fi

  return 0
}

require_cluster() {
  local env="${1:-}"

  orbit_use_kubeconfig "${env}" || return 1

  if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    return 0
  fi

  local server ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  server="$(kubeconfig_server_for_context "${ctx}")"

  echo "Cannot reach Kubernetes cluster (kubectl cluster-info failed)." >&2
  [[ -n "${ctx}" ]] && echo "  Context:    ${ctx}" >&2
  [[ -n "${server}" ]] && echo "  API server: ${server}" >&2
  [[ -n "${KUBECONFIG:-}" ]] && echo "  KUBECONFIG=${KUBECONFIG}" >&2
  echo "" >&2

  if [[ "${GLOW_KUBECONFIG_MODE:-}" == "current" ]]; then
    cat >&2 <<EOF
k3d cluster is not reachable. Refresh and retry:

  ./scripts/k8s.sh local setup
  ./scripts/k8s.sh local deploy
EOF
    return 1
  fi

  if is_k3d_server "${server}"; then
    cat >&2 <<EOF
${GLOW_KUBECONFIG_DEFAULT} is set to a k3d context (${server}), not Orbit.

Nothing in glow-devops writes to ${GLOW_KUBECONFIG_DEFAULT}. This usually happens if
k3d was run while KUBECONFIG pointed at that file (k3d merges into whatever KUBECONFIG is set).

  Remove k3d from ${GLOW_KUBECONFIG_DEFAULT}, or re-download the Orbit kubeconfig.
  k3d uses ${GLOW_K3D_KUBECONFIG} automatically via ./scripts/k8s.sh local ...

  Deploy to Orbit (after fixing ${GLOW_KUBECONFIG_DEFAULT}):
    export KUBECONFIG=${GLOW_KUBECONFIG_DEFAULT}
    ./scripts/k8s.sh deploy production --bootstrap
EOF
    return 1
  fi

  cat >&2 <<EOF
For Orbit production:
  export KUBECONFIG=${GLOW_KUBECONFIG_DEFAULT}
  ./scripts/k8s.sh deploy production --bootstrap

For local k3d:
  ./scripts/k8s.sh local setup && ./scripts/k8s.sh local deploy
EOF
  return 1
}
