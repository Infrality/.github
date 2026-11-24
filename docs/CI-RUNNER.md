# Where CI runs, and how to switch

The private repositories' Linux jobs run where their repository variable `CI_RUNNER` says:

| `CI_RUNNER` | Runs on | Costs |
| --- | --- | --- |
| unset or `ubuntu-latest` | GitHub-hosted | the Free plan's $12/month of minutes, then blocked |
| `infrality-ci` | the private runner VM (Infrality/ci-runner) | nothing on GitHub today |

Windows and macOS jobs (agent) are always GitHub-hosted. This repository is public: its own
workflows always run hosted (free for public repositories) and never on the private runner.

## Switching

- **From a phone:** Actions → **Switch CI runner** → Run workflow → `hosted` or `self-hosted`
  (`status` only prints). Needs the `RUNNER_SWITCH_TOKEN` secret (see the workflow's header).
- **From a laptop:** `scripts/ci-runner.sh hosted|self-hosted|status [repo...]`.
- **One repository by hand:** its Settings → Secrets and variables → Actions → Variables → `CI_RUNNER`.

It is a repository variable in each repository because, on GitHub Free, organisation variables
are not visible to private repositories. The next job that starts reads the new value. A job
already queued for the runner keeps waiting for it: when the VM is down, switch to `hosted`,
then cancel and re-run the waiting runs.

## Why a public repository can never pick the runner

Two independent locks:

1. the organisation's Default runner group refuses public repositories
   (`allows_public_repositories: false`; Free has no other group);
2. every reusable workflow resolves its runner as
   `${{ (github.event.repository.visibility != 'public' && inputs.runs-on) || 'ubuntu-latest' }}`.

## Ship skips a CI run it already did

`ci-node.yml` / `ci-go.yml` record, on each pull request run, the git tree they checked (a `ci/tree`
commit status on the pull request's head). On the merge to main, `tested-tree.yml` compares
main's tree with it: same tree and a green CI run → Ship goes straight to the image (build, Trivy,
cosign) and the deploy (verify, smoke test, rollback). Anything else, including main having moved on
since the pull request's CI, or a `workflow_dispatch` of Ship, runs the full CI first.
