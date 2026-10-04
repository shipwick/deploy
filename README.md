# Shipwick deploy

A GitHub Action that deploys with [Shipwick](https://shipwick.com) from a
workflow. It downloads the `shipwick` CLI, verifies it against the release's
checksums and runs `shipwick deploy` against your server.

```yaml
- uses: shipwick/deploy@v1
  with:
    url: https://agent.example.com
    token: ${{ secrets.SHIPWICK_TOKEN }}
    image: ghcr.io/company/my-api:${{ github.sha }}
```

Keep `deploy.yaml` in the repository and pass the image the workflow just
built. The step fails when the deployment fails, and the version that worked
keeps serving; nothing else in the workflow is needed for that.

A complete workflow, building the image on GitHub and deploying it:

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
      - uses: shipwick/deploy@v1
        with:
          url: https://agent.example.com
          token: ${{ secrets.SHIPWICK_TOKEN }}
          image: ghcr.io/${{ github.repository }}:${{ github.sha }}
```

## Inputs

| Input | | Default |
|---|---|---|
| `url` | The URL of your Shipwick agent | required |
| `token` | An API token with the `deploy` role, from a secret | required |
| `image` | Deploy this image instead of the one in `deploy.yaml` (`--image`) | |
| `file` | The `deploy.yaml` to deploy. A `shipwick.yaml` deploys its applications at the same time, in dependency order. One path per line deploys several `deploy.yaml` in order, stopping at the first failure (`-f`, repeated); `--image` then does not apply | `deploy.yaml` |
| `env-file` | A `NAME=value` file that fills in `${NAME}` placeholders before the file is sent (`--env-file`). One path per line | |
| `version` | The release of the CLI to use, such as `v0.3.1` | the latest release |
| `applications` | The applications of a `shipwick.yaml` to deploy, one name per line or separated by spaces (`shipwick deploy <name>...`). With exactly one, `image` applies to it. Needs shipwick 0.8.0 or later | every application in the file |
| `no-wait` | Start the deployment and return at once (`--no-wait`) | `false` |
| `check-only` | For testing this action: download and verify the CLI, print its version, stop | `false` |

Several applications, with a secret filled in from the workflow:

```yaml
- run: echo "POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD }}" > .env.production
- uses: shipwick/deploy@v1
  with:
    url: https://agent.example.com
    token: ${{ secrets.SHIPWICK_TOKEN }}
    file: |
      postgres/deploy.yaml
      api/deploy.yaml
    env-file: .env.production
```

One application out of a `shipwick.yaml`, with the image the workflow built
for it; the others in the file are left as they run:

```yaml
- uses: shipwick/deploy@v1
  with:
    url: https://agent.example.com
    token: ${{ secrets.SHIPWICK_TOKEN }}
    file: shipwick.yaml
    applications: api
    image: ghcr.io/company/api:${{ github.sha }}
```

## Outputs

| Output | |
|---|---|
| `version` | The version that was deployed, as the CLI reports it (`my-api 1.4.2  deployed in 6.1s`) |
| `url` | The `https://` URL the application is served at |

Both are empty when the application has no domain (`url`), with `no-wait`, or
when the deployment failed. With several applications they describe the last
one.

```yaml
- uses: shipwick/deploy@v1
  id: deploy
  with: { url: https://agent.example.com, token: "${{ secrets.SHIPWICK_TOKEN }}" }
- run: echo "Deployed ${{ steps.deploy.outputs.version }} at ${{ steps.deploy.outputs.url }}"
```

The CLI stays on the job's `PATH` after the step, so `shipwick status`,
`shipwick logs` and the rest work in the steps that follow, given the same two
variables:

```yaml
- run: shipwick status my-api
  env:
    SHIPWICK_AGENT_URL: https://agent.example.com
    SHIPWICK_AGENT_TOKEN: ${{ secrets.SHIPWICK_TOKEN }}
```

## The token

Give CI a token with the `deploy` role and nothing more: it can deploy, roll
back, stop and start applications, and cannot delete applications or manage
tokens. Create it on your laptop and store it as a repository or environment
secret:

```bash
shipwick token create ci --role deploy      # printed once
shipwick token revoke ci                    # when it leaks or the pipeline goes
```

The token reaches the CLI as the `SHIPWICK_AGENT_TOKEN` environment variable,
never as an argument, and is masked in the job log. Keep the agent's URL on
HTTPS: the CLI warns when a token is about to travel over plain HTTP.

## Versions

`version:` pins the CLI to a release tag; without it, each run downloads the
latest release. Pin it when a reproducible pipeline matters more than fixes
arriving on their own. The agent on your server is upgraded separately, by
running the installer there again; a CLI newer than the agent tells you so
when it needs something the agent does not have.

Pin the action itself as you pin any other: `shipwick/deploy@v1` follows the
latest `v1.x`, a full tag or a commit SHA stays put.

## Verification

Everything the action downloads comes from the assets of a
[shipwick/shipwick release](https://github.com/shipwick/shipwick/releases):
the binary for the runner's operating system and architecture, and the
release's `checksums.txt`. The binary is installed only if its SHA-256 matches
the checksums file, the same check the installer and `shipwick upgrade` make.
Both are fetched over HTTPS from `github.com`; the GitHub API is not used, so
the action is not subject to its rate limits.

Runners: `ubuntu-*` (x64 and arm64) and `macos-*`. Windows runners are not
supported; the step fails and says so.

## Testing

The *CI* workflow of this repository checks the script with shellcheck and
runs the action with `check-only: true` on each supported runner, pinned to a
release and following the latest one, which downloads, verifies and runs the
CLI without a server to deploy to. The same input works in your own
repository to check the download path before wiring up a token.

The *End to end* workflow deploys to a live agent: an application from
[test/e2e](test/e2e), then an image that does not exist, which has to fail
the step and leave the first version running. It is started by hand before a
release and needs a test server's URL and a `deploy` token in the
repository's secrets; its file says which.

Problems with the CLI or the agent belong in
[shipwick/shipwick](https://github.com/shipwick/shipwick/issues); problems
with this action, in this repository's issues.

## License

[Apache License 2.0](LICENSE).
