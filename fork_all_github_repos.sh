#!/usr/bin/env bash
set -euo pipefail

# Fork all repositories from a given user using GitHub CLI (gh).
# Requires: gh (authenticated), jq
#
# Usage:
#   ./fork_all_github_repos.sh <source_user> [--org <org>] [--include-forks] [--include-archived] [--wait]
#
# Examples:
#   ./fork_all_github_repos.sh alice
#   ./fork_all_github_repos.sh alice --org my-org --include-forks --include-archived --wait

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is required." >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required." >&2
  exit 2
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source_user> [--org <org>] [--include-forks] [--include-archived] [--wait]" >&2
  exit 2
fi

SOURCE_USER=$1; shift
ORG=""
INCLUDE_FORKS=false
INCLUDE_ARCHIVED=false
WAIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)
      ORG=$2; shift 2;;
    --include-forks)
      INCLUDE_FORKS=true; shift;;
    --include-archived)
      INCLUDE_ARCHIVED=true; shift;;
    --wait)
      WAIT=true; shift;;
    *)
      echo "Unknown option: $1" >&2; exit 2;;
  esac
done

echo "Fetching repositories for $SOURCE_USER ..."

# Helper: gh api with Connection: close to avoid flaky keep-alive/HTTP2 EOFs
gh_api() {
  gh api -H "Connection: close" "$@"
}

# Helper: retry a command with backoff
retry() {
  local n=0 max=5 delay=1
  while ! "$@"; do
    n=$((n+1))
    if [[ $n -ge $max ]]; then
      return 1
    fi
    sleep "$delay"
    delay=$(( delay < 8 ? delay*2 : 8 ))
  done
}

# Helper: capture stdout of a command with retries
retry_capture() {
  local __var=$1; shift
  local out
  local n=0 max=5 delay=1
  while true; do
    if out=$("$@" 2>/dev/null); then
      printf -v "$__var" '%s' "$out"
      return 0
    fi
    n=$((n+1))
    if [[ $n -ge $max ]]; then
      return 1
    fi
    sleep "$delay"
    delay=$(( delay < 8 ? delay*2 : 8 ))
  done
}

# Resolve target owner once (reduces API calls)
if [[ -n "$ORG" ]]; then
  target_owner="$ORG"
else
  if ! retry_capture target_owner gh_api user -q .login; then
    echo "Error: failed to query authenticated user (gh api user)." >&2
    echo "Tip: ensure 'gh auth login' is done and network/proxy is OK." >&2
    exit 1
  fi
fi

# gh repo list USER --limit supports up to 1000
REPOS_JSON=$(gh repo list "$SOURCE_USER" --limit 1000 --json name,owner,isFork,isArchived | jq -c '.[]')

created=0
skipped=0
failed=0

while IFS= read -r item; do
  name=$(jq -r '.name' <<<"$item")
  owner=$(jq -r '.owner.login' <<<"$item")
  is_fork=$(jq -r '.isFork' <<<"$item")
  is_archived=$(jq -r '.isArchived' <<<"$item")

  if [[ $INCLUDE_FORKS != true && $is_fork == "true" ]]; then
    continue
  fi
  if [[ $INCLUDE_ARCHIVED != true && $is_archived == "true" ]]; then
    continue
  fi

  target_repo="$name"

  # Check if fork already exists
  if retry gh_api -X GET "/repos/$target_owner/$target_repo" >/dev/null 2>&1; then
    echo "[skip] $target_owner/$target_repo already exists"
    ((skipped++))
    continue
  fi

  src_full="$owner/$name"
  echo "[fork] $src_full -> ${target_owner}/$target_repo"

  if [[ -n "$ORG" ]]; then
    if retry gh repo fork "$src_full" --org "$ORG" --clone=false --remote=false >/dev/null 2>&1; then
      ((created++))
    else
      echo "[fail] $src_full"; ((failed++)); continue
    fi
  else
    if retry gh repo fork "$src_full" --clone=false --remote=false >/dev/null 2>&1; then
      ((created++))
    else
      echo "[fail] $src_full"; ((failed++)); continue
    fi
  fi

  if [[ $WAIT == true ]]; then
    # wait up to ~60s
    retries=12
    until gh_api -X GET "/repos/$target_owner/$target_repo" >/dev/null 2>&1 || [[ $retries -eq 0 ]]; do
      sleep 5; retries=$((retries-1))
    done
  fi

  sleep 0.3
done <<< "$REPOS_JSON"

echo
echo "Summary:"
echo "  Created/Requested: $created"
echo "  Skipped existing:  $skipped"
echo "  Failed:            $failed"
