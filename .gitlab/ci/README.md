# Glow Shared GitLab CI: Versioning and Release Policy

This repository provides shared GitLab CI templates for service repositories.

## Entrypoint Boundaries

Use entrypoints based on repository type:

- Public service entrypoint (for microservice repos):
  - `/.gitlab/ci/entry/service-pipeline.yml`
- Public plugin entrypoint (for Gradle plugin repos):
  - `/.gitlab/ci/entry/plugin-pipeline.yml`
- Internal-only governance entrypoint (for `glow-devops` repo itself):
  - `/.gitlab/ci/entry/template-release-pipeline.yml`

## Version Source and Tag Format

- Canonical template version is stored in `.gitlab/ci/VERSION`.
- Required format: `vX.Y.Z`.
- CI release tags are created as `ci/vX.Y.Z`.

The `ci/` namespace avoids collisions with service or repo release tags.

## Automatic Version Validation

`validate_ci_version` runs in merge requests and default-branch pushes.

When relevant files change (`.gitlab/ci/**`, `scripts/ci/**`, `scripts/compose-up.sh`, `compose/docker-compose.yml`, `examples/service-gitlab-ci.yml`), it enforces:

1. `.gitlab/ci/VERSION` exists and matches `vX.Y.Z`.
2. In merge requests, VERSION must differ from target branch.
3. Tag `ci/<VERSION>` must not already exist.

If no relevant files changed, the validation job exits successfully without blocking.

## Automatic Tag Creation on Main

`tag_ci_version` runs on default-branch push pipelines:

- checks for relevant template changes,
- validates VERSION and tag uniqueness,
- creates and pushes annotated tag `ci/<VERSION>`.

Tag creation uses `resource_group` to avoid concurrent tag race conditions on rapid pushes.

## Required GitLab Settings

- Protect tags with pattern: `ci/v*`.
- Use a protected token variable `CI_TAG_PUSH_TOKEN` with minimal scope needed for tag push.
- Do not hardcode credentials in repository files.

## Consumer Include Policy

Service repositories must include the pipeline entrypoint with an immutable `ref`.

Use one of:

- CI template release tag (recommended):
  - `ref: "ci/vX.Y.Z"`
- Full commit SHA (strictest pinning):
  - `ref: "<40-char commit sha>"`

Do not use branch references such as `main` for shared pipeline includes.

Service include example:

- `/.gitlab/ci/entry/service-pipeline.yml`

Plugin include example:

- `/.gitlab/ci/entry/plugin-pipeline.yml`

## Root Pipeline in `glow-devops`

The root `.gitlab-ci.yml` in this repository includes only:

- `/.gitlab/ci/entry/template-release-pipeline.yml`

This ensures internal template governance runs in `glow-devops` without forcing consumer repos to execute governance jobs.

## Multi-Arch Image Publishing

The shared image publish job:

- builds and pushes multi-arch manifests for `linux/amd64` and `linux/arm64`,
- publishes tags:
  - `${CI_PIPELINE_IID}`
  - `${CI_COMMIT_SHA}`
  - `${CI_COMMIT_SHORT_SHA}`
  - `latest`
- verifies manifest existence and platform coverage for each tag,
- exports `IMAGE_REF_BY_DIGEST` and `IMAGE_DIGEST` via dotenv artifact (`image.env`).

Deployments should prefer digest references (`image@sha256:...`) over mutable tags.

## Local Compose Contract

To avoid per-service Gradle customization:

- compose services use `SERVICE_IMAGE_REF` as a generic single-service image override,
- `scripts/compose-up.sh` runs all services when no service is provided,
- `scripts/compose-up.sh --image <repo:tag> <service>` overrides image for exactly one service run,
- Gradle plugin composes one service by injecting `SERVICE_IMAGE_REF` and `COMPOSE_SERVICE_NAME`.

## Validation Checklist

1. MR changes CI/template files but not VERSION -> pipeline fails.
2. MR changes CI/template files and bumps VERSION -> pipeline passes.
3. VERSION set to existing `ci/v*` tag -> validation fails.
4. Two close default-branch pushes with template changes -> tag creation serialized; no tag race.
5. Plugin repo using plugin entrypoint -> validate/test/version_guard/publish flow runs with optional overrides.
6. Inspect `${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHA}` -> manifest includes `linux/amd64` and `linux/arm64`.
7. Pull `:latest` on both amd64 and arm64 hosts -> succeeds.
8. Run `scripts/compose-up.sh` without service args -> full environment starts.
9. Run `scripts/compose-up.sh --image <repo:tag> <service>` -> only selected service uses override image.

