#!/usr/bin/env bash
# First checks on a "Host an app" request, before anything is read or created.
# REPO and REQUESTED_BY come from a form: they are validated here and never
# echoed back until they have passed.
set -euo pipefail

ORG=Virtual-Protocol

fail() {
  echo "::error::$1"
  printf '### Not hosted\n\n%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

[[ "$REPO" =~ ^[A-Za-z0-9._-]{1,100}$ ]] ||
  fail "That isn't a repository name. Give just the name, like internal-bizops-tool."
[[ "$REQUESTED_BY" =~ ^[A-Za-z0-9._%+-]+@virtuals\.io$ ]] ||
  fail "Requests must come from a @virtuals.io address."

info=$(gh api "repos/$ORG/$REPO" 2>/dev/null) ||
  fail "There's no repository called $REPO in $ORG. If it's under someone's own GitHub account, move it into $ORG first."
[[ "$(jq -r .owner.login <<<"$info")" == "$ORG" ]] ||
  fail "$REPO isn't in the $ORG organization. Move it there first."
[[ "$(jq -r .private <<<"$info")" == true ]] ||
  fail "$REPO is public. Internal apps must be in a private repository."
[[ "$(jq -r .archived <<<"$info")" == false ]] ||
  fail "$REPO is archived."

echo "Request checks passed for $ORG/$REPO."
