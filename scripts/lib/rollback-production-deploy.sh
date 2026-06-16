#!/usr/bin/env bash
# CI helper: revert chart commit on glow-devops main, redeploy previous tag.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
  local service="" chart_commit="" previous_tag="" token="${GLOW_DEVOPS_UPDATE_TOKEN:-}"
  local project="${GLOW_DEVOPS_PROJECT:-backend-architecture-and-scalability/glow-devops}"
  local host="${GLOW_DEVOPS_HOST:-gitlab.au.dk}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service) service="$2"; shift 2 ;;
      --chart-commit) chart_commit="$2"; shift 2 ;;
      --previous-tag) previous_tag="$2"; shift 2 ;;
      --token) token="$2"; shift 2 ;;
      *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
  done

  [[ -n "${service}" && -n "${chart_commit}" && -n "${previous_tag}" ]] || {
    echo "Usage: --service <name> --chart-commit <sha> --previous-tag <tag>" >&2
    exit 1
  }
  [[ -n "${token}" ]] || { echo "GLOW_DEVOPS_UPDATE_TOKEN required" >&2; exit 1; }

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT

  git clone --depth 50 --branch main \
    "https://gitlab-ci-token:${token}@${host}/${project}.git" "${workdir}/glow-devops"
  cd "${workdir}/glow-devops"
  git config user.email "glow-ci@gitlab.au.dk"
  git config user.name "GLOW CI"
  git revert --no-edit "${chart_commit}"
  git push origin main

  "${LIB_DIR}/deploy-production-service.sh" --service "${service}" --tag "${previous_tag}"
}

main "$@"
