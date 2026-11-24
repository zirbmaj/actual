#!/usr/bin/env bash
# Fork maintenance for the `jmbr` branch. See JMBR.md.
#
#   upstream-release.sh detect         Which release is the branch based on, and is there a newer one?
#   upstream-release.sh rebase <tag>   Rebase the branch onto <tag> as the local branch sync/<tag>.
#   upstream-release.sh notify         CI only: open the upgrade pull request, or an issue if that fails.
#
# Environment:
#   JMBR_BRANCH    fork branch to maintain (default: $GITHUB_REF_NAME, else jmbr)
#   JMBR_UPSTREAM  upstream repository URL
#   JMBR_TAG       sync to this upstream tag instead of the newest release
#   JMBR_REDO      "true" to repeat a release that already has a pull request or issue
#   JMBR_BUILD     notify only: result of the image build (success, failure, skipped)

set -euo pipefail

BRANCH=${JMBR_BRANCH:-${GITHUB_REF_NAME:-jmbr}}
UPSTREAM=${JMBR_UPSTREAM:-https://github.com/actualbudget/actual.git}
UPSTREAM_WEB=${UPSTREAM%.git}
LABEL=upstream-release
RELEASE_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
DETAILS=$(mktemp)

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  export GIT_COMMITTER_NAME='github-actions[bot]'
  export GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
fi

die() {
  echo "error: $*" >&2
  exit 1
}

# Print key=value and, in CI, also set it as a step output.
emit() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

# Full history of the fork branch plus upstream's release tags. Works from the
# one-commit checkout that actions/checkout makes.
fetch_refs() {
  local depth=()
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    depth=(--unshallow)
  fi
  git fetch --quiet --no-tags "${depth[@]}" origin \
    "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git fetch --quiet --no-tags "$UPSTREAM" '+refs/tags/v*:refs/tags/v*'
}

# The upstream release the fork branch currently sits on.
base_tag() {
  git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' \
    "origin/$BRANCH"
}

newest_release() {
  git tag --list 'v[0-9]*' | grep -E "$RELEASE_RE" | sort -V | tail -n 1
}

# True when $1 is a strictly newer version than $2.
is_newer() {
  [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# True when this release already has a pull request or an issue (any state),
# so the daily run does not repeat itself.
already_notified() {
  local tag=$1 count
  command -v gh >/dev/null && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  count=$(gh pr list --repo "$GITHUB_REPOSITORY" --state all \
    --head "sync/$tag" --base "$BRANCH" --json number --jq length) || count=0
  if [ "$count" -gt 0 ]; then
    return 0
  fi
  count=$(gh issue list --repo "$GITHUB_REPOSITORY" --state all \
    --label "$LABEL" --limit 500 --json title \
    --jq "[.[] | select(.title | startswith(\"Upstream release $tag \"))] | length") ||
    count=0
  [ "$count" -gt 0 ]
}

# Rebase the fork branch from release $1 onto release $2, leaving the result
# checked out as sync/$2. On a conflict: write the details to $DETAILS, abort
# the rebase and return 1.
rebase_onto() {
  local base=$1 target=$2
  [ -z "$(git status --porcelain --untracked-files=no)" ] ||
    die "the working tree has uncommitted changes"
  git switch --quiet -C "sync/$target" "origin/$BRANCH"
  if git rebase --quiet --onto "$target" "$base" >/dev/null 2>&1; then
    return 0
  fi
  {
    echo "Stopped at: $(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo unknown)"
    echo "Conflicting files:"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
  } >"$DETAILS"
  git rebase --abort
  return 1
}

cmd_detect() {
  local base target
  fetch_refs
  base=$(base_tag)
  target=${JMBR_TAG:-$(newest_release)}
  git rev-parse --quiet --verify "refs/tags/$target^{commit}" >/dev/null ||
    die "upstream has no tag '$target'"
  emit base "$base"
  if [ "$target" = "$base" ]; then
    echo "$BRANCH is already based on $base."
    emit tag ''
  elif [ -z "${JMBR_TAG:-}" ] && ! is_newer "$target" "$base"; then
    echo "$BRANCH is based on $base, newer than the newest release $target."
    emit tag ''
  elif [ "${JMBR_REDO:-}" != true ] && already_notified "$target"; then
    echo "$target already has a pull request or issue. Nothing to do."
    emit tag ''
  else
    echo "$BRANCH is based on $base; upstream has $target."
    emit tag "$target"
  fi
}

cmd_rebase() {
  local target=${1:?usage: upstream-release.sh rebase <tag>} base
  fetch_refs
  base=$(base_tag)
  if rebase_onto "$base" "$target"; then
    echo "Rebased $BRANCH from $base onto $target as sync/$target."
    emit rebase clean
  else
    cat "$DETAILS"
    emit rebase conflict
  fi
}

build_line() {
  local run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  case ${JMBR_BUILD:-skipped} in
    success) echo "- Server image: builds and boots ([run]($run))" ;;
    skipped) echo "- Server image: not built ([run]($run))" ;;
    *) echo "- Server image: **build or boot test failed** ([run]($run))" ;;
  esac
}

production_note() {
  local tag=$1
  cat <<EOF
### Production

Nothing here deploys. Upgrade the running server separately, from your own
deploy runbook, and only after a data backup. While \`$BRANCH\` carries no code
patches, production should run the official image pinned to this version
(\`actualbudget/actual-server:${tag#v}\`), not an image built from this fork.
EOF
}

manual_steps() {
  local base=$1 target=$2
  cat <<EOF
\`\`\`sh
# remotes: origin = this fork, upstream = $UPSTREAM_WEB
git fetch origin && git fetch upstream --tags
git switch $BRANCH && git pull --ff-only
git rebase --onto $target $base
# on a conflict: fix the files, \`git add\` them, \`git rebase --continue\`
git push --force-with-lease origin $BRANCH
\`\`\`

The push changes workflow files, so it needs a credential that may do that
(for a personal access token: the \`workflow\` scope).
EOF
}

open_issue() {
  local title=$1 body=$2
  gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
    --body-file "$body" --label "$LABEL" --assignee "$GITHUB_REPOSITORY_OWNER"
}

# Push sync/$2 and open (or refresh) the pull request. On failure the reason
# is left in $DETAILS and the function returns 1.
open_pull_request() {
  local base=$1 target=$2 body existing
  local force=()
  if [ "${JMBR_REDO:-}" = true ]; then
    force=(--force)
  fi
  if ! git push "${force[@]}" origin "HEAD:refs/heads/sync/$target" >"$DETAILS" 2>&1; then
    return 1
  fi
  existing=$(gh pr list --repo "$GITHUB_REPOSITORY" --state open \
    --head "sync/$target" --base "$BRANCH" --json number --jq '.[0].number // empty')
  if [ -n "$existing" ]; then
    gh pr comment "$existing" --repo "$GITHUB_REPOSITORY" \
      --body "Rebuilt \`sync/$target\` from the current \`$BRANCH\`.

$(build_line)" >"$DETAILS" 2>&1
    return
  fi
  body=$(mktemp)
  cat >"$body" <<EOF
Upstream released **[$target]($UPSTREAM_WEB/releases/tag/$target)**. \`$BRANCH\` is
still based on $base. This branch is \`$BRANCH\` rebased onto $target.

- Rebase: clean
$(build_line)

### Fork commits on top of $target

$(git log --reverse --format='- `%h` %s' "$target..HEAD")

### To land it

Move \`$BRANCH\` to this branch. That keeps \`$BRANCH\` as "release tag + fork
commits", and GitHub then marks this pull request as merged:

\`\`\`sh
git fetch origin
git push --force-with-lease=$BRANCH:origin/$BRANCH origin origin/sync/$target:$BRANCH
\`\`\`

The merge button (merge commit) gives the same files if you have no terminal
at hand; the next sync flattens the history again. The diff shown here is
large because it includes everything upstream changed since $base.

$(production_note "$target")
EOF
  gh pr create --repo "$GITHUB_REPOSITORY" --base "$BRANCH" \
    --head "sync/$target" --title "Upstream release $target" \
    --body-file "$body" --label "$LABEL" \
    --assignee "$GITHUB_REPOSITORY_OWNER" >"$DETAILS" 2>&1
}

cmd_notify() {
  : "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REPOSITORY_OWNER:?}"
  local target=${JMBR_TAG:?} base body
  [[ $target =~ ^v[0-9A-Za-z._-]+$ ]] || die "unexpected tag '$target'"
  fetch_refs
  base=$(base_tag)
  body=$(mktemp)
  gh label create "$LABEL" --repo "$GITHUB_REPOSITORY" --color 1D76DB \
    --description 'A new upstream release is available' --force >/dev/null ||
    true

  if ! rebase_onto "$base" "$target"; then
    cat >"$body" <<EOF
Upstream released **[$target]($UPSTREAM_WEB/releases/tag/$target)**. \`$BRANCH\` is
still based on $base, and its commits no longer apply cleanly on top of
$target, so the rebase has to be done by hand.

\`\`\`
$(cat "$DETAILS")
\`\`\`

### To do it by hand

$(manual_steps "$base" "$target")

$(production_note "$target")
EOF
    open_issue "Upstream release $target needs a manual rebase" "$body"
    return
  fi

  if open_pull_request "$base" "$target"; then
    cat "$DETAILS"
    return
  fi

  cat >"$body" <<EOF
Upstream released **[$target]($UPSTREAM_WEB/releases/tag/$target)**. \`$BRANCH\` is
still based on $base.

- Rebase onto $target: clean
$(build_line)

The pull request could not be opened automatically:

\`\`\`
$(tail -n 15 "$DETAILS")
\`\`\`

### To land it by hand

$(manual_steps "$base" "$target")

$(production_note "$target")
EOF
  open_issue "Upstream release $target is ready to land by hand" "$body"
}

main() {
  case ${1:-} in
    detect) cmd_detect ;;
    rebase) cmd_rebase "${2:-}" ;;
    notify) cmd_notify ;;
    *) die "usage: upstream-release.sh detect | rebase <tag> | notify" ;;
  esac
}

# Keep this on one line: the rebase rewrites this file while it is running, so
# bash must have read the whole script before `main` starts.
main "$@"; exit
