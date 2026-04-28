#!/usr/bin/env bash
set -euo pipefail

readonly VERSION_FILE=".gitlab/ci/VERSION"
readonly VERSION_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

read_version() {
  if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "Missing ${VERSION_FILE}"
    exit 1
  fi

  local version
  version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
  if [[ ! "${version}" =~ ${VERSION_PATTERN} ]]; then
    echo "Invalid CI version '${version}'. Expected format vX.Y.Z."
    exit 1
  fi

  printf "%s\n" "${version}"
}

ensure_changed_for_mr() {
  local version="$1"
  local target_branch="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}"
  if [[ -z "${target_branch}" ]]; then
    return
  fi

  git fetch origin "${target_branch}" --quiet
  local target_ref="origin/${target_branch}"
  local previous_version
  previous_version="$(git show "${target_ref}:${VERSION_FILE}" 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ "${previous_version}" == "${version}" ]]; then
    echo "CI template files changed, but ${VERSION_FILE} was not updated."
    echo "Current and target branch both use version '${version}'."
    exit 1
  fi
}

ensure_tag_missing() {
  local version="$1"
  local tag_name="ci/${version}"

  git fetch --tags --quiet
  if git rev-parse -q --verify "refs/tags/${tag_name}" >/dev/null; then
    echo "Tag '${tag_name}' already exists. Choose a new value in ${VERSION_FILE}."
    exit 1
  fi
}

main() {
  local change_output
  change_output="$(./scripts/ci/detect-ci-template-changes.sh)"
  eval "${change_output}"

  if [[ "${CI_TEMPLATES_CHANGED}" != "true" ]]; then
    echo "No CI template changes detected; skipping version validation."
    exit 0
  fi

  local version
  version="$(read_version)"
  ensure_changed_for_mr "${version}"
  ensure_tag_missing "${version}"
  echo "CI version validation passed for ${version}."
}

main "$@"
