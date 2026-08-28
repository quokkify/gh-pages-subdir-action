# gh-pages-subdir-action

Safely publish one generated directory into a subdirectory of a shared GitHub Pages branch. Existing sibling paths are preserved, updates use a force-with-lease retry, and optional retention prunes only `pr-N` directories beside the destination.

## Usage

```yaml
permissions:
  contents: write

steps:
  - uses: quokkify/gh-pages-subdir-action@<full-commit-sha> # v0.1.0
    with:
      token: ${{ secrets.GITHUB_TOKEN }}
      publish-dir: allure-report
      destination-dir: allure/pr-${{ github.event.pull_request.number }}
      branch: gh-pages
      retention-count: "20"
```

Pin the action to a full commit SHA. The version comment documents the corresponding release without weakening the immutable reference.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | yes | — | Token with `contents: write` for the target repository. |
| `publish-dir` | yes | — | Directory to publish, relative to `GITHUB_WORKSPACE`. |
| `destination-dir` | yes | — | Safe relative destination on the Pages branch. |
| `branch` | no | `gh-pages` | Branch that stores Pages content. |
| `retention-count` | no | `0` | Newest sibling `pr-N` directories to keep; `0` disables pruning. |

When retention is enabled, the destination basename must be `pr-N`. Other sibling directories, such as documentation or coverage sites, are never part of the retention set.

## Safety properties

- Rejects absolute paths, traversal, workspace/checkout escapes through symlinks, and `.git` destination components.
- Disables repository hooks for internal Git operations as defense in depth.
- Keeps the token in `GIT_ASKPASS`, never in the remote URL or Git command arguments.
- Preserves sibling paths and creates an orphan Pages branch when needed.
- Avoids empty commits for unchanged content.
- Uses a lease-protected push and one rebase/retry for concurrent publishers.

## Development

Requirements: Bash, Git, Python 3, rsync, and ShellCheck.

```bash
bash -n deploy-gh-pages-subdir.sh tests/integration.sh
shellcheck deploy-gh-pages-subdir.sh tests/integration.sh
bash tests/integration.sh
```

## License

MIT. See [LICENSE](LICENSE).
