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

configure_authenticated_remote() {
  local token="${CI_TAG_PUSH_TOKEN:-}"
  local server_host="${CI_SERVER_HOST:-}"
  local project_path="${CI_PROJECT_PATH:-}"

  if [[ -z "${token}" || -z "${server_host}" || -z "${project_path}" ]]; then
    echo "Missing tag push credentials. Required: CI_TAG_PUSH_TOKEN, CI_SERVER_HOST, CI_PROJECT_PATH."
    exit 1
  fi

  local remote_url="https://oauth2:${token}@${server_host}/${project_path}.git"
  git remote set-url origin "${remote_url}"
}

main() {
  local change_output
  change_output="$(./scripts/ci/detect-ci-template-changes.sh)"
  eval "${change_output}"

  if [[ "${CI_TEMPLATES_CHANGED}" != "true" ]]; then
    echo "No CI template changes detected; skipping tag creation."
    exit 0
  fi

  local version tag_name
  version="$(read_version)"
  tag_name="ci/${version}"

  git fetch --tags --quiet
  if git rev-parse -q --verify "refs/tags/${tag_name}" >/dev/null; then
    echo "Tag '${tag_name}' already exists."
    exit 1
  fi

  configure_authenticated_remote

  git tag -a "${tag_name}" -m "Release CI template ${tag_name}"
  git push origin "${tag_name}"
  echo "Created and pushed tag ${tag_name}."
}

main "$@"
