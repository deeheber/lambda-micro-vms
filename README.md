# lambda-micro-vms

A minimal "hello world" for [AWS Lambda MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html).
It builds a MicroVM image with CloudFormation, runs a MicroVM, calls it over HTTPS, then suspends, resumes and terminates it.
It's meant for learning the service and as a template to fork. The code and scripts are heavily commented with the MicroVM concept each piece shows.

> Status: the code has been checked offline only (`make check`). The live sandbox run (`make deploy`, `make smoke`) has not been recorded yet, so no measurements are quoted here.

## Prerequisites

- An AWS account with admin access. Use a sandbox account: everything here is created and destroyed by the scripts.
- `EXPECTED_ACCOUNT_ID` set to that account's ID, exported in your shell or in a gitignored `.env` file in the repo root. Every script that calls AWS refuses to run against any other account. Optionally set `AWS_PROFILE` in the same place.
- AWS CLI v2 (with the `lambda-microvms` commands), `jq`, `zip`, Node 24 and Docker.
- The region is set in `config.env` (`REGION`). An `AWS_REGION` already in your environment wins.

## Quick start

```sh
make check     # offline: typecheck, unit tests, script syntax, template lint
make deploy    # build and upload the app, create both stacks, wait for the image
make smoke     # run a MicroVM end to end and verify it
make destroy   # tear everything down
```

## Make targets

| Target | What it does | Concept it demonstrates |
|---|---|---|
| `make deploy` | Packages `app/`, creates the stacks, waits for an active image version | Image build: the platform runs your Dockerfile, waits for the `ready` hook to return 200, then snapshots the running app |
| `make run` | Launches one MicroVM from the latest image version | The `run` hook fires once per MicroVM, after the snapshot is restored, which is where per-instance values (`instanceId`) are created; the idle policy is set here |
| `make call` | Mints a token and calls the app over HTTPS (`CALL_PATH=/other make call` for another path) | Auth: a short-lived token sent as `X-aws-proxy-auth` through the MicroVM proxy |
| `make status` | Prints the MicroVM's state | The lifecycle states (`RUNNING`, `SUSPENDED`, ...) |
| `make suspend` | Suspends the MicroVM | Suspend keeps memory and disk and stops compute billing |
| `make resume` | Resumes it | Resume continues from the saved memory; the idle policy can also auto-resume on traffic |
| `make terminate` | Terminates it | Terminate ends all charges for that MicroVM |
| `make smoke` | Run, call, suspend, resume, call, terminate, asserting memory survived | Same `instanceId` and a larger `requestCount` after resume prove the memory was preserved |
| `make destroy` | Terminates MicroVMs, deletes both stacks, empties the bucket | Always tear down |
| `make check` | Offline checks, no AWS calls | n/a |

The app itself is two tiny servers (`app/src/`): one on `APP_PORT` returning JSON with the `instanceId`, `microvmId` and a `requestCount`, and one on `HOOKS_PORT` for the platform's `ready` and `run` hook calls. Each hook call prints one JSON line, which you can read in CloudWatch Logs.

## Two stacks

- `infra/bootstrap.yaml` (`<STACK_PREFIX>-bootstrap`): the artifact bucket, the build role, the execution role and the log group. It changes rarely and has to exist first, because the app zip must be uploaded to the bucket before an image can point at it.
- `infra/image.yaml` (`<STACK_PREFIX>-image`): the `AWS::Lambda::MicrovmImage`. It changes whenever the app does, and a failed image build never takes the bucket or roles with it.

## Content-hashed artifacts

`deploy.sh` zips `app/` deterministically (sorted entries, fixed modes and timestamps) and names the zip after its SHA-256: `s3://<bucket>/artifacts/app-<sha256>.zip`. Unchanged code gives the same key, so CloudFormation sees no change and no new image version is built. Changed code gives a new key, which is a changed template property, which builds a new image version. The `artifacts/` prefix is the only path the build role can read.

## Cost model

- While a MicroVM is running you pay the baseline compute rate (default 2 GB / 1 vCPU); bursts up to 4x are billed only while in use.
- While it is suspended you pay for storage only.
- Each image version costs storage.
- Data transfer is billed at standard rates.

The defaults are cost-conscious: idle MicroVMs suspend after `IDLE_MAX_SECONDS`, and `MAX_DURATION_SECONDS` caps every MicroVM's lifetime. Always run `make destroy` when you are done.

## Configuration

Every tunable lives in `config.env`, each with a comment saying where its default comes from. The CloudFormation templates take the same values as parameters, which `deploy.sh` passes.

To change a port, edit both `config.env` (`APP_PORT` or `HOOKS_PORT`) and the matching `ENV` line in `app/Dockerfile`. `deploy.sh` refuses to continue if they disagree.

## Fork it

1. Set `STACK_PREFIX` and `IMAGE_NAME` in `config.env` to your own names.
2. Replace `app/src/` with your app. Keep the `ready` hook answering 503 until your app is up, and create anything unique to one MicroVM in the `run` hook, never before the snapshot.
3. Keep the Dockerfile on the managed `al2023-minimal` base with Node from `dnf`, so the image stays snapshot-safe.

## Next experiments

See the issues labelled [`next-experiment`](https://github.com/deeheber/lambda-micro-vms/issues?q=is%3Aissue+label%3Anext-experiment) and [`ROADMAP.md`](ROADMAP.md).
