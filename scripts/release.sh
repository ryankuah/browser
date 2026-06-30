#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Browser.xcodeproj"
SCHEME="${SCHEME:-Browser}"
CONFIGURATION="${CONFIGURATION:-Release}"
REMOTE="${RELEASE_REMOTE:-origin}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_PUSH="${SKIP_PUSH:-0}"
SKIP_GITHUB_RELEASE="${SKIP_GITHUB_RELEASE:-0}"

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh [patch|minor|major|VERSION]

Creates a signed release by:
  1. Bumping MARKETING_VERSION and CURRENT_PROJECT_VERSION.
  2. Running scripts/package_release.sh to sign, notarize, staple, verify, and package.
  3. Committing the version bump.
  4. Creating an annotated git tag.
  5. Pushing the commit and tag.
  6. Creating a GitHub release with the DMG and appcast.xml.

Examples:
  scripts/release.sh patch
  scripts/release.sh minor
  scripts/release.sh 1.3.0

Useful environment variables:
  DEVELOPER_ID_APPLICATION  Explicit Developer ID Application identity.
  NOTARYTOOL_PROFILE        notarytool keychain profile. Defaults to browser-notary.
  RELEASE_CONVEX_URL        Convex URL embedded in release builds.
                            Defaults to the production Browser deployment.
  BROWSER_CONVEX_URL        Overrides RELEASE_CONVEX_URL for packaging.
  NOTARIZE=0                Build a local test package without notarization.
  DRY_RUN=1                 Show the computed release values without changing files.
  SKIP_PUSH=1               Do not push the commit or tag.
  SKIP_GITHUB_RELEASE=1     Do not create the GitHub release.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

current_build_setting() {
  local setting="$1"

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings |
    awk -F'= ' -v key="$setting" '$1 ~ " " key " $" {print $2; exit}'
}

validate_version() {
  local version="$1"

  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
    die "version must look like 1.2 or 1.2.3: $version"
}

next_version() {
  local current="$1"
  local bump="$2"
  local major minor patch

  IFS='.' read -r major minor patch <<<"$current"
  patch="${patch:-}"

  case "$bump" in
    patch)
      if [[ -z "$patch" ]]; then
        echo "$major.$minor.1"
      else
        echo "$major.$minor.$((patch + 1))"
      fi
      ;;
    minor)
      echo "$major.$((minor + 1))"
      ;;
    major)
      echo "$((major + 1)).0"
      ;;
    *)
      validate_version "$bump"
      echo "$bump"
      ;;
  esac
}

ensure_clean_worktree() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    die "working tree is not clean; commit or stash existing changes before releasing"
  fi
}

update_project_versions() {
  local version="$1"
  local build_number="$2"
  local project_file="$PROJECT/project.pbxproj"

  run /usr/bin/perl -0pi -e \
    "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${version};/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${build_number};/g" \
    "$project_file"
}

main() {
  local bump="${1:-patch}"

  if [[ "$bump" == "-h" || "$bump" == "--help" ]]; then
    usage
    exit 0
  fi

  require_command git
  require_command xcodebuild
  require_command xcrun
  require_command gh

  if [[ "$SKIP_PUSH" == "1" && "$SKIP_GITHUB_RELEASE" != "1" ]]; then
    die "SKIP_PUSH=1 requires SKIP_GITHUB_RELEASE=1"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    ensure_clean_worktree
  fi

  local current_version current_build version build_number tag
  current_version="$(current_build_setting MARKETING_VERSION)"
  current_build="$(current_build_setting CURRENT_PROJECT_VERSION)"
  [[ -n "$current_version" ]] || die "could not read MARKETING_VERSION"
  [[ -n "$current_build" ]] || die "could not read CURRENT_PROJECT_VERSION"
  [[ "$current_build" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION must be an integer: $current_build"

  version="$(next_version "$current_version" "$bump")"
  build_number="$((current_build + 1))"
  tag="v$version"

  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag already exists locally: $tag"
  fi
  if git -C "$ROOT_DIR" ls-remote --exit-code --tags "$REMOTE" "$tag" >/dev/null 2>&1; then
    die "tag already exists on $REMOTE: $tag"
  fi
  if [[ "$SKIP_GITHUB_RELEASE" != "1" ]]; then
    gh release view "$tag" >/dev/null 2>&1 && die "GitHub release already exists: $tag"
    gh auth status >/dev/null
  fi

  echo "Releasing Browser $version (build $build_number)"

  update_project_versions "$version" "$build_number"

  if [[ "$DRY_RUN" == "1" ]]; then
    exit 0
  fi

  plutil -lint "$PROJECT/project.pbxproj" >/dev/null

  "$ROOT_DIR/scripts/package_release.sh"

  local dmg_path appcast_path
  dmg_path="$ROOT_DIR/build/release/Browser-$version.dmg"
  appcast_path="$ROOT_DIR/build/release/appcast.xml"
  [[ -f "$dmg_path" ]] || die "expected DMG was not created: $dmg_path"
  [[ -f "$appcast_path" ]] || die "expected appcast was not created: $appcast_path"

  git -C "$ROOT_DIR" add "$PROJECT/project.pbxproj"
  git -C "$ROOT_DIR" commit -m "Release $tag"
  git -C "$ROOT_DIR" tag -a "$tag" -m "Release $tag"

  if [[ "$SKIP_PUSH" != "1" ]]; then
    git -C "$ROOT_DIR" push "$REMOTE" HEAD
    git -C "$ROOT_DIR" push "$REMOTE" "$tag"
  fi

  if [[ "$SKIP_GITHUB_RELEASE" != "1" ]]; then
    gh release create "$tag" \
      "$dmg_path" \
      "$appcast_path" \
      --title "Browser $version" \
      --notes "Release $version"
  fi

  echo "Created release $tag"
}

main "$@"
