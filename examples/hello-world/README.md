# Hello world

A minimal "hello world" for [AWS Lambda MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html).
It builds a MicroVM image with CloudFormation, runs a MicroVM, calls it over HTTPS, then suspends, resumes and terminates it.
It's meant for learning the service and as a template to fork. The code and scripts are heavily commented with the MicroVM concept each piece shows.

> Status: tested end to end in a sandbox account on 2026-11-01.

## Prerequisites

- An AWS sandbox account. The scripts create and delete CloudFormation stacks, IAM roles, an S3 bucket, a log group and MicroVM resources; an admin role covers all of these.
- `EXPECTED_ACCOUNT_ID` set to that account's ID, exported in your shell or in a gitignored `.env` file in the repo root or this example folder. Every script that calls AWS refuses to run against any other account. Optionally set `AWS_PROFILE` in the same place. Example-local `.env` values override root `.env` values.
- AWS CLI v2 (with the `lambda-microvms` commands), `jq`, `zip`, `curl`, `cfn-lint`, Node 24 and Docker.
- The region is set in `config.env` (`REGION`). An `AWS_REGION` already in your environment wins.

## Quick start

From the repo root, enter the example and install dependencies:

```sh
cd examples/hello-world
npm ci
```

For an automated check, run the commands below. To explore each lifecycle step
yourself, use the [first hands-on lab](#first-hands-on-lab-pause-and-restart-a-workspace) instead.
Always run `npm run destroy` after an AWS session, including after a failure.

```sh
npm run check     # offline: typecheck, unit tests, script syntax, template lint
npm run deploy    # build and upload the app, create both stacks, wait for the image
npm run smoke     # run a MicroVM end to end and verify it
npm run destroy   # tear everything down
```

## First hands-on lab: pause and restart a workspace

Imagine this VM is Alice's notebook workspace. Learn what survives when she
steps away, then compare that with starting a fresh workspace from the same image.

### 1. Prepare and read the app

Complete the prerequisites above, including setting `EXPECTED_ACCOUNT_ID` for
your sandbox account. From the repo root, run:

```sh
cd examples/hello-world
npm ci
npm run check
```

Read [`hooks.ts`](app/src/hooks.ts), [`state.ts`](app/src/state.ts) and
[`app.ts`](app/src/app.ts). Find where the app becomes ready for the snapshot,
where it creates `instanceId`, and where it increments `requestCount`.

### 2. Launch and make two requests

The remaining steps call AWS and create billable resources. Run them only in
your sandbox. If a step still fails after the retries below, stop and run step 5.
The defaults terminate a VM after 10 minutes suspended or 30 minutes total;
complete the comparisons within those limits.

```sh
npm run deploy
npm run microvm:run
npm run call
npm run call
```

If the first call fails while the VM starts, retry for up to 60 seconds. Record `instanceId`,
`microvmId` and `requestCount` from each response. Both calls should have the
same IDs and an increasing count.

### 3. Suspend and resume the same workspace

```sh
npm run microvm:suspend
npm run microvm:status
```

Check status every few seconds for up to 60 seconds. Once it reports
`SUSPENDED`, send traffic:

```sh
npm run call
```

With the default `AUTO_RESUME=true`, the request should wake the VM. Expect the
same IDs and a count larger than before suspension: its memory survived. If the
call fails, retry it; if auto-resume still does not work, run
`npm run microvm:resume` and call again. Record which path worked.

### 4. Start a fresh workspace

```sh
npm run microvm:terminate
npm run microvm:run
npm run call
```

Retry the call if the new VM is still starting. Expect new `instanceId` and
`microvmId` values and a count of 1 on its first request. A request whose response
was lost can still increment the count. A fresh VM starts from the image's snapshot;
resuming the previous VM continued its saved session.

### 5. Tear down

```sh
npm run destroy
```

For later experiments, `npm run smoke` automates the suspend/resume memory check.
If you have torn down the deployment, run `npm run deploy` before the smoke test.
Follow the smoke test with `npm run destroy` to remove the image and supporting resources.
Next, follow the issue order in [`ROADMAP.md`](../../ROADMAP.md).

## npm scripts

| Script | What it does | Concept it demonstrates |
|---|---|---|
| `npm run deploy` | Packages `app/`, creates the stacks, waits for an active image version | Image build: the platform runs your Dockerfile, waits for the `ready` hook to return 200, then snapshots the running app |
| `npm run microvm:run` | Launches one MicroVM from the latest image version | The `run` hook fires once per MicroVM, after the snapshot is restored, which is where per-instance values (`instanceId`) are created; the idle policy is set here |
| `npm run call` | Mints a token and calls the app over HTTPS (`npm run call -- /other` for another path) | Auth: a short-lived token sent as `X-aws-proxy-auth` through the MicroVM proxy |
| `npm run microvm:status` | Prints the MicroVM's state | The lifecycle states (`RUNNING`, `SUSPENDED`, ...) |
| `npm run microvm:suspend` | Suspends the MicroVM | Suspend keeps memory and disk and stops compute billing |
| `npm run microvm:resume` | Resumes it | Resume continues from the saved memory; the idle policy can also auto-resume on traffic |
| `npm run microvm:terminate` | Terminates it | Terminate ends all charges for that MicroVM |
| `npm run smoke` | Run, call, suspend, resume, call, terminate, asserting memory survived | Same `instanceId` and a larger `requestCount` after resume prove the memory was preserved |
| `npm run destroy` | Terminates MicroVMs, deletes both stacks, empties the bucket | Always tear down |
| `npm run check` | Offline checks, no AWS calls. [GitHub Actions](../../.github/workflows/checks.yaml) runs it on every PR to `main` | n/a |

The app itself is two tiny servers (`app/src/`): one on `APP_PORT` returning JSON with the `instanceId`, `microvmId` and a `requestCount`, and one on `HOOKS_PORT` for the platform's `ready` and `run` hook calls. Each hook call prints one JSON line, which you can read in CloudWatch Logs.

## Two stacks

- `infra/bootstrap.yaml` (`<STACK_PREFIX>-bootstrap`): the artifact bucket, the build role, the execution role and the log group. It changes rarely and has to exist first, because the app zip must be uploaded to the bucket before an image can point at it.
- `infra/image.yaml` (`<STACK_PREFIX>-image`): the `AWS::Lambda::MicrovmImage`. It changes whenever the app does, and a failed image build never takes the bucket or roles with it.

## Content-hashed artifacts

`deploy.sh` zips `app/` deterministically (sorted entries, fixed modes and timestamps) and names the zip after its SHA-256: `s3://<bucket>/artifacts/app-<sha256>.zip`. Unchanged code gives the same key, so CloudFormation sees no change and no new image version is built. Changed code gives a new key, which is a changed template property, which builds a new image version. Any other changed image parameter builds one too, including a newer base image version, which `deploy.sh` picks up when `BASE_IMAGE_VERSION` is empty. The `artifacts/` prefix is the only path the build role can read.

## Cost model

- While a MicroVM is running you pay the baseline compute rate (default 2 GB / 1 vCPU); bursts up to 4x are billed only while in use.
- While it is suspended you pay for storage only.
- Each image version costs storage.
- Data transfer is billed at standard rates.

The defaults are cost-conscious: idle MicroVMs suspend after `IDLE_MAX_SECONDS`, and `MAX_DURATION_SECONDS` caps every MicroVM's lifetime. Always run `npm run destroy` when you are done.

## Configuration

Every tunable lives in `config.env`, each with a comment saying where its default comes from. `deploy.sh` passes the image and stack settings to CloudFormation as parameters; the scripts read the rest directly.

To change a port, edit both `config.env` (`APP_PORT` or `HOOKS_PORT`) and the matching `ENV` line in `app/Dockerfile`. `deploy.sh` refuses to continue if they disagree.

## Fork it

These steps create an independent app. For the next lesson in this repo, keep
the stack and image names unchanged as described in [ROADMAP.md](../../ROADMAP.md).

1. Set `STACK_PREFIX` and `IMAGE_NAME` in `config.env` to your own names.
2. Replace `app/src/` with your app. Keep the `ready` hook answering 503 until your app is up, and create anything unique to one MicroVM in the `run` hook, never before the snapshot.
3. Keep the Dockerfile on the managed `al2023-minimal` base with Node from `dnf`, so the image stays snapshot-safe.

## Next experiments

See the issues labelled [`next-experiment`](https://github.com/deeheber/lambda-micro-vms/issues?q=is%3Aissue+label%3Anext-experiment) and [`ROADMAP.md`](../../ROADMAP.md).
