# Helm install/upgrade with periodic pod status while --wait runs.

helm_prepare_dependencies() {
  local chart_dir="$1"
  local lock="${chart_dir}/Chart.lock"
  local charts_glob="${chart_dir}/charts/*.tgz"

  if [[ -f "${lock}" ]] && compgen -G "${charts_glob}" >/dev/null; then
    local expected actual
    expected="$(grep -c '^- name:' "${lock}" 2>/dev/null || echo 0)"
    actual="$(find "${chart_dir}/charts" -maxdepth 1 -name '*.tgz' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${expected}" -gt 0 && "${actual}" -ge "${expected}" ]]; then
      echo "Using cached Helm dependencies in ${chart_dir}/charts/ (${actual} packages)."
      echo "To refresh: (cd ${chart_dir} && helm dependency update)"
      return 0
    fi
  fi

  echo "Fetching Helm chart dependencies (requires network)..."
  (cd "${chart_dir}" && helm dependency update)
}

helm_deploy() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  shift 3

  local waiting=false
  local timeout_display="20m"
  local arg=""
  local prev=""

  for arg in "$@"; do
    case "${arg}" in
      --wait) waiting=true ;;
      --timeout=*) timeout_display="${arg#--timeout=}" ;;
    esac
    if [[ "${prev}" == "--timeout" ]]; then
      timeout_display="${arg}"
    fi
    prev="${arg}"
  done

  echo ""
  echo "Helm release: ${release}"
  echo "Namespace:    ${namespace}"
  if [[ "${waiting}" == true ]]; then
    cat <<EOF
Waiting for all workloads to become Ready (helm --wait, timeout ${timeout_display}).
Watch in another terminal: kubectl get pods -n ${namespace} -w
EOF
  elif [[ "${HELM_POST_WAIT:-}" == "true" ]]; then
    echo "Applying manifests, then waiting for rollouts."
  else
    echo "Applying manifests (--no-wait)."
  fi
  echo ""

  set +e
  helm upgrade --install "${release}" "${chart}" "$@"
  local helm_rc=$?
  set -e

  if [[ ${helm_rc} -ne 0 ]]; then
    echo "" >&2
    echo "Helm deploy failed (exit ${helm_rc}). Recent events:" >&2
    kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 >&2 || true
    kubectl get pods -n "${namespace}" 2>&1 >&2 || true
    return "${helm_rc}"
  fi

  if [[ "${waiting}" == true ]]; then
    echo ""
    echo "Helm release '${release}' is ready in namespace '${namespace}'."
  elif [[ "${HELM_POST_WAIT:-}" == "true" ]]; then
    echo "Helm release '${release}' applied — waiting for rollouts next."
  else
    echo "Helm release '${release}' applied to namespace '${namespace}'."
    echo "Pods start in the background — run: kubectl get pods -n ${namespace} -w"
  fi
  return 0
}

# Print pod table periodically while rollout waits run (caller kills watcher_pid on exit).
helm_watch_pods() {
  local namespace="$1"
  local interval="${2:-20}"
  while true; do
    sleep "${interval}"
    echo ""
    echo "── pods $(date '+%H:%M:%S') ──"
    kubectl get pods -n "${namespace}" 2>/dev/null || true
  done
}

# Wait for Deployments/StatefulSets with live pod snapshots.
helm_wait_rollouts() {
  local namespace="$1"
  local timeout="${2:-30m}"
  local logs_hint="${3:-kubectl logs -n ${namespace} deploy/<name>}"

  local -a deploys=()
  local deploy
  while IFS= read -r deploy; do
    [[ -n "${deploy}" ]] && deploys+=("${deploy}")
  done < <(kubectl get deploy -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  local has_postgres=false
  if kubectl get statefulset glow-postgres -n "${namespace}" >/dev/null 2>&1; then
    has_postgres=true
  fi

  local total="${#deploys[@]}"
  [[ "${has_postgres}" == true ]] && ((total++)) || true

  if ((total == 0)); then
    echo "No workloads found in ${namespace}."
    return 1
  fi

  echo "Waiting for ${total} workload(s) in ${namespace} (timeout ${timeout})."
  echo "Quarkus JVM startup can take 5–10 minutes on first boot."
  echo ""
  echo "Workloads: ${deploys[*]}${has_postgres:+ glow-postgres}"
  echo ""
  kubectl get pods -n "${namespace}"
  echo ""

  helm_watch_pods "${namespace}" 20 &
  local watcher_pid=$!
  local failed=0

  local -a pids=()
  for deploy in "${deploys[@]}"; do
    (
      if kubectl rollout status "deployment/${deploy}" -n "${namespace}" --timeout="${timeout}" >/dev/null; then
        echo "✓ ${deploy} ready"
      else
        echo "✗ ${deploy} failed — try: ${logs_hint//<name>/${deploy}}" >&2
        exit 1
      fi
    ) &
    pids+=($!)
  done

  if [[ "${has_postgres}" == true ]]; then
    (
      if kubectl rollout status statefulset/glow-postgres -n "${namespace}" --timeout="${timeout}" >/dev/null; then
        echo "✓ glow-postgres ready"
      else
        echo "✗ glow-postgres failed" >&2
        exit 1
      fi
    ) &
    pids+=($!)
  fi

  for pid in "${pids[@]}"; do
    wait "${pid}" || failed=1
  done

  kill "${watcher_pid}" 2>/dev/null || true
  wait "${watcher_pid}" 2>/dev/null || true

  echo ""
  kubectl get pods -n "${namespace}"
  if ((failed)); then
    echo "" >&2
    echo "Some workloads did not become Ready:" >&2
    echo "  kubectl describe pod -n ${namespace} <name>" >&2
    echo "  ${logs_hint}" >&2
    return 1
  fi
  echo "All workloads Ready."
  return 0
}
