#!/usr/bin/env bash
# Reads the app's platform.yaml and checks it against the request: the person
# asking must be the owner the repo names, which only someone who can push to
# the repo could have written there, and a public app must be on the reviewed
# list in public-apps.txt.
#   scripts/read-platform.sh <app dir>
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
  awk -v name="$name" -v repo="$REPO" '$1 == name && $2 == repo { found = 1 } END { exit !found }' public-apps.txt ||
    fail "platform.yaml says public: true, but \"$name\" isn't an approved public app. Public apps need the platform team's approval: ask them to add it to public-apps.txt in projects-autodeploy."
else
  public=false
fi

{
  echo "name=$name"
  echo "storage=$storage"
  echo "public=$public"
} >> "$GITHUB_OUTPUT"
echo "platform.yaml checks passed: $name, owned by $owner$([[ "$public" == true ]] && echo ", public")."
