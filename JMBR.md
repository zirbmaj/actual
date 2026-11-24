# JMBR fork notes

This is a personal fork of
[actualbudget/actual](https://github.com/actualbudget/actual). The goal is to
run official releases and carry as few changes as possible, ideally none.

- Features belong outside the server (scripts on `@actual-app/api`) or
  upstream. A patch only lands here when it is tiny and clearly necessary.
- The fork is public. No hostnames, addresses, credentials or deployment
  details go in it. The deploy runbook is kept privately, elsewhere.

## Branches

| Branch        | What it is                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `jmbr`        | Default branch. An official release tag plus the fork's own commits on top. Production tracks this.                                  |
| `master`      | Untouched copy of upstream `master`. Never commit to it. Refresh it with GitHub's "Sync fork" button; nothing depends on it.         |
| `sync/vX.Y.Z` | Made by the release check: `jmbr` rebased onto release `vX.Y.Z`. Safe to delete once landed.                                         |

`jmbr` follows release tags (`vX.Y.Z`), not upstream's `master`, so it always
matches a version upstream actually shipped. To see what the fork carries:

```sh
git log --oneline --no-merges "$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/jmbr)"..origin/jmbr
```

## What the fork adds

| Path                                          | Purpose                                                   |
| --------------------------------------------- | --------------------------------------------------------- |
| `JMBR.md`                                     | This file                                                 |
| `.github/workflows/jmbr-upstream-release.yml` | Daily check for a new upstream release                    |
| `.github/workflows/jmbr-image.yml`            | Manual build of the server image                          |
| `.github/actions/jmbr-server-image/`          | Build and boot test shared by both workflows              |
| `.github/jmbr/upstream-release.sh`            | The logic behind the release check (also runs in a clone) |

Everything is new files with `jmbr` in the name, so a rebase never conflicts
with upstream over them.

## Upstream release check

`jmbr / upstream release check` runs daily, on every push to `jmbr`, and on
demand (Actions tab → Run workflow, or `gh workflow run jmbr-upstream-release.yml`).

1. It finds the release tag `jmbr` is based on and upstream's newest release
   tag.
2. If upstream is newer, it rebases `jmbr` onto that tag, builds the server
   image and checks that it boots.
3. It reports once per release, assigned to the repository owner:
   - **Pull request** `Upstream release vX.Y.Z` from `sync/vX.Y.Z` into `jmbr`
     when the rebase is clean.
   - **Issue** when the rebase conflicts, or when the branch or pull request
     could not be created. The issue has the steps to do it by hand.

The same run disables every workflow that is not named `jmbr-*` (see
"GitHub settings") and keeps its own schedule from being switched off by
GitHub after 60 quiet days.

To repeat a release that already has a pull request or issue, run the workflow
by hand with `redo` ticked. To aim at a specific tag, fill in `tag`.

### Landing an upgrade

Preferred, because it keeps `jmbr` as "release tag + fork commits":

```sh
git fetch origin
git push --force-with-lease=jmbr:origin/jmbr origin origin/sync/vX.Y.Z:jmbr
```

GitHub then marks the pull request as merged. The push changes workflow files,
so the credential needs to be allowed to do that (the `workflow` scope on a
personal access token).

The merge button also works and gives the same files. It leaves a merge commit
that the next sync flattens again. Only "Create a merge commit" is enabled on
this repo: squash or rebase merging would break the link to the release tag.

Without a `sync/vX.Y.Z` branch, or when the rebase conflicts:

```sh
git fetch origin && git fetch upstream --tags
git switch jmbr && git pull --ff-only
git rebase --onto vX.Y.Z vOLD        # vOLD = the release jmbr is based on now
# on a conflict: fix the files, `git add` them, `git rebase --continue`
git push --force-with-lease origin jmbr
```

Landing an upgrade here deploys nothing. Upgrading the running server is a
separate, deliberate step.

## Adding a patch

- One small commit per change on `jmbr`, with a subject that says why the fork
  needs it. Every extra commit is something to re-apply at each release.
- Prefer new files over edits to upstream files.
- If the change would be useful to everyone, open it upstream as well and drop
  it here once it ships.

## Server image

While `jmbr` has no code patches, production should run the official image
pinned to a version (`actualbudget/actual-server:X.Y.Z`), not a build of this
fork.

Once there is a real patch, run `jmbr / server image` by hand. It builds the
same Ubuntu image as upstream's release workflow (linux/amd64 only), checks
that it boots and pushes:

- `ghcr.io/<owner>/actual-server:vX.Y.Z-jmbr` (moves with each build of that
  release)
- `ghcr.io/<owner>/actual-server:vX.Y.Z-jmbr.<commit>` (never moves; pin this)

It uses the workflow's own `GITHUB_TOKEN`, no extra secrets.

**The package stays private.** The first push creates it as private. Leave it
that way: do not change its visibility, and note that GitHub does not allow a
public package to be made private again. To check, open the owner's profile →
Packages → `actual-server`; it must show "Private".

Because it is private, the server that runs it has to log in before it can
pull:

```sh
docker login ghcr.io -u <owner> --password-stdin
```

Use a personal access token (classic) with only the `read:packages` scope.
Docker keeps it on that server; it never goes in this repository, in a compose
file or in chat.

## GitHub settings this relies on

- Default branch: `jmbr`. Scheduled workflows only run from the default branch.
- Actions: only the `jmbr-*` workflows are enabled. The ones inherited from
  upstream need upstream's secrets and runners and must stay disabled; the
  release check disables any it finds active. To check:
  `gh workflow list --all`.
- Settings → Actions → General → Workflow permissions: "Allow GitHub Actions to
  create and approve pull requests" is on, so the check can open its pull
  request.
- Issues are enabled, so the check can report a conflict.
- Pull requests: only merge commits are allowed.
