#!/usr/bin/env bash
set -euo pipefail

readonly TARGET_SHA="${CI_COMMIT_SHA:-HEAD}"
readonly BEFORE_SHA="${CI_COMMIT_BEFORE_SHA:-}"
readonly MR_BASE_SHA="${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}"
readonly MR_TARGET_BRANCH="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"

resolve_base_ref() {
  if [[ -n "${MR_BASE_SHA}" ]]; then
    printf "%s\n" "${MR_BASE_SHA}"
    return
  fi

  if [[ -n "${MR_TARGET_BRANCH}" ]]; then
    printf "origin/%s\n" "${MR_TARGET_BRANCH}"
    return
  fi

  if [[ -n "${BEFORE_SHA}" && "${BEFORE_SHA}" != "0000000000000000000000000000000000000000" ]]; then
    printf "%s\n" "${BEFORE_SHA}"
    return
  fi

  printf "%s\n" "${TARGET_SHA}^"
}

is_ci_path() {
  local path="$1"
  [[ "${path}" == .gitlab/ci/* ]] || [[ "${path}" == .gitlab/ci ]] || \
    [[ "${path}" == scripts/ci/* ]] || [[ "${path}" == scripts/compose-up.sh ]] || \
    [[ "${path}" == compose/docker-compose.yml ]] || [[ "${path}" == examples/service-gitlab-ci.yml ]]
}

main() {
  local base_ref
  base_ref="$(resolve_base_ref)"

  if [[ "${base_ref}" == origin/* ]]; then
    git fetch origin "${MR_TARGET_BRANCH}" --quiet
  fi

  local changed=0
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if is_ci_path "${file}"; then
      changed=1
      break
    fi
  done < <(git diff --name-only "${base_ref}" "${TARGET_SHA}")

  if [[ "${changed}" -eq 1 ]]; then
    echo "CI_TEMPLATES_CHANGED=true"
  else
    echo "CI_TEMPLATES_CHANGED=false"
  fi
}

main "$@"
