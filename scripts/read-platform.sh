#!/usr/bin/env bash
# Reads the app's platform.yaml and checks it against the request: the person
# asking must be the owner the repo names, which only someone who can push to
# the repo could have written there, and a public app must be approved.
#   scripts/read-platform.sh <app dir>
# Needs: REPO REQUESTED_BY GITHUB_OUTPUT GITHUB_STEP_SUMMARY
# Optional: PUBLIC_APPS, the approved public apps (this repo's PUBLIC_APPS
#   Actions variable, which the bizops portal's Public apps page edits):
#   [{"name": "<app name>", "repo": "<repo in Virtual-Protocol>", ...}]
set -euo pipefail

dir="$1"
file="$dir/platform.yaml"

fail() {
  echo "::error::$1"
  printf '### Not hosted\n\n%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

# One line, no control characters: these values end up in messages.
field() { yq -r "$1 // \"\"" "$file" | tr -d '\000-\037' ; }

[[ -f "$file" ]] ||
  fail "The repo has no platform.yaml. Ask Claude to get the app ready for hosting first."

name=$(field .name)
owner=$(field .owner | tr '[:upper:]' '[:lower:]')
requested=$(tr '[:upper:]' '[:lower:]' <<<"$REQUESTED_BY")

[[ "$name" =~ ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ && "$name" != *--* ]] ||
  fail "name in platform.yaml must be 3-24 lowercase letters, digits and single dashes."
[[ "$owner" == "$requested" ]] ||
  fail "platform.yaml lists \"$owner\" as the owner, but this request came from $requested. Only the owner named in the repo can host it."

for need in postgres redis; do
  [[ "$(field ".needs.$need")" != true ]] ||
    fail "needs.$need isn't available yet. Ask the platform team."
done

storage=$(field .needs.storage)
[[ "$storage" == true ]] || storage=false

public=$(field .public)
if [[ "$public" == true ]]; then
  # Both the name and the repo must match, so approving one app doesn't let
  # another repo take its name and be public too. A missing or broken list
  # approves nothing.
  jq -e --arg name "$name" --arg repo "$REPO" '
    type == "array" and
    any(.[]; type == "object" and .name == $name and ((.repo // "") | ascii_downcase) == ($repo | ascii_downcase))
  ' <<<"${PUBLIC_APPS:-[]}" >/dev/null 2>&1 ||
    fail "platform.yaml says public: true, but \"$name\" from $REPO isn't an approved public app. Public apps need the platform team's approval: ask them to approve it under Tech help → Public apps in the bizops portal, then host it again."
else
  public=false
fi

# What the owner sets on GitHub before the first deploy, named as deploy-app.yml
# reads them from .env.example: public values are variables, the rest secrets.
keys=$(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$dir/.env.example" 2>/dev/null |
  grep -vxE 'PORT|NODE_ENV|APP_URL|STORAGE_BUCKET|GOOGLE_CLOUD_PROJECT' | sort -u || true)
secrets=$(grep -vE '^(NEXT_PUBLIC_|VITE_)' <<<"$keys" | paste -sd, - || true)
variables=$(grep -E '^(NEXT_PUBLIC_|VITE_)' <<<"$keys" | paste -sd, - || true)

{
  echo "name=$name"
  echo "storage=$storage"
  echo "public=$public"
  echo "secrets=$secrets"
  echo "variables=$variables"
} >> "$GITHUB_OUTPUT"
echo "platform.yaml checks passed: $name, owned by $owner$([[ "$public" == true ]] && echo ", public")."
