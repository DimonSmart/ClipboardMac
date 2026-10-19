#!/bin/bash
set -euo pipefail

remote="${1:-origin}"
branch="${2:-main}"
first_version="${3:-1.0.0}"
bump="${4:-Patch}"
tag_prefix="v"

if [[ ! "$first_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "First version must be MAJOR.MINOR.PATCH." >&2
  exit 1
fi
case "$bump" in
  Patch|Minor|Major) ;;
  *) echo "Bump must be Patch, Minor, or Major." >&2; exit 1 ;;
esac
root="$(git rev-parse --show-toplevel)"
cd "$root"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before publishing." >&2
  exit 1
fi

git fetch --prune --tags "$remote"
git switch "$branch"
git pull --ff-only "$remote" "$branch"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree became dirty after updating '$branch'." >&2
  exit 1
fi

latest="$(git tag --merged "$branch" --list "${tag_prefix}*" | \
  awk -v prefix="$tag_prefix" 'match($0, "^" prefix "[0-9]+\\.[0-9]+\\.[0-9]+$") { print substr($0, 2) }' | \
  sort -V | tail -n 1)"
if [[ -n "$latest" ]]; then
  IFS=. read -r major minor patch <<< "$latest"
  case "$bump" in
    Major) next="$((major + 1)).0.0" ;;
    Minor) next="${major}.$((minor + 1)).0" ;;
    Patch) next="${major}.${minor}.$((patch + 1))" ;;
  esac
else
  next="$first_version"
fi
tag="${tag_prefix}${next}"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || [[ -n "$(git ls-remote --tags "$remote" "refs/tags/$tag")" ]]; then
  echo "Tag '$tag' already exists." >&2
  exit 1
fi

echo "Publishing $tag from $branch to $remote"
git tag -a "$tag" -m "Release $tag"
if ! git push --atomic "$remote" "$branch" "$tag"; then
  git tag -d "$tag" >/dev/null || true
  exit 1
fi
echo "Published release tag: $tag"
