# lambda-micro-vms

A minimal, heavily commented Lambda MicroVMs hello world: a CloudFormation-built MicroVM image, one MicroVM called over HTTPS, then suspended, resumed and terminated. Source of truth: `docs/SPEC.md`. Verified service facts: `docs/reference/microvms-notes.md` (read it instead of searching the web).

## Principles

- Minimal on purpose: only SPEC section 2's goals. No `validate`/`suspend`/`resume`/`terminate` hooks, no SAM, no Lambda functions, no VPC connectors, no run hook payload, no tooling beyond `tsc` and `node --test`.
- No account IDs and no region literals outside `config.env`; templates use `AWS::AccountId`, `AWS::Region`, `AWS::Partition`.
- Every tunable is configuration: `config.env` for scripts, CFN `Parameters` for templates.
- Every script that calls `aws` calls `assert_sandbox` first.
- Snapshot-safe image: `al2023-minimal` base, Node from `dnf install -y nodejs24`.
- No runtime dependencies in `app/`; Node 24 runs `.ts` directly.
- Bind `0.0.0.0`; generate per-instance values in the `run` hook, never before the snapshot.
- Least-privilege IAM; always tear down.
- Heavy comments: this repo teaches. Say which MicroVM concept each piece demonstrates.

## Commands

- Setup: `npm --prefix app ci`
- Typecheck: `npm --prefix app run typecheck` (`tsc --noEmit`)
- Test: `npm --prefix app test` (`node --test 'test/**/*.test.ts'`)
- Single test: `cd app && node --test --test-name-pattern=<name> 'test/**/*.test.ts'`
- Infra lint: `cfn-lint infra/*.yaml` (from P2-01)
- Scripts syntax: `bash -n scripts/*.sh`
- Docker build (needs the daemon): `docker build --platform linux/arm64 -t mvm-hello:verify app`
- All offline checks: `make check`
- Live (AWS, sandbox only, Phase 3): `make deploy`, `make smoke`, `make destroy`
- CLI shapes, offline: `aws lambda-microvms <command> help`

## Module map

- `app/src/state.ts`: `State` type, `createState()`, shared `state` (`instanceId`, `microvmId`, `requestCount`, `appListening`).
- `app/src/app.ts`: `handleApp(s, method, path)` → `Reply` `{ status, body }` for the app server (`GET /`, else 404).
- `app/src/hooks.ts`: `handleHook(s, method, path, rawBody, now)` → `HookReply` (`Reply` plus `log`) for `POST /aws/lambda-microvms/runtime/v1/{ready,run}`.
- `app/src/main.ts`: two `node:http` servers on `0.0.0.0` (`APP_PORT`, `HOOKS_PORT` from env), adapting requests to the handlers.
- `app/test/*.test.ts`: `node:test` tests calling the handlers directly, no network.
- `app/Dockerfile`: base image, `nodejs24`, `ENV APP_PORT`/`ENV HOOKS_PORT`, `COPY src/`, `CMD ["node", "src/main.ts"]`.
- `infra/bootstrap.yaml`: bucket, build role, execution role, log group; exports `${AWS::StackName}-{ArtifactBucketName,BuildRoleArn,ExecutionRoleArn,LogGroupName}`.
- `infra/image.yaml`: the `AWS::Lambda::MicrovmImage`; outputs `ImageArn`, `LatestActiveImageVersion`.
- `scripts/lib.sh`: config loading, `log`, `die`, `require_cmd`, `assert_sandbox`, `stack_output`, `managed_connector_arn`, `base_image_arn`; `REPO_ROOT`, `BUILD_DIR`, `MICROVM_FILE`, `BOOTSTRAP_STACK`, `IMAGE_STACK`.
- `scripts/deploy.sh` (`--package-only`), `run.sh`, `call.sh [path]`, `microvm.sh <status|suspend|resume|terminate>`, `smoke.sh`, `destroy.sh`.
- `config.env`: every tunable (SPEC section 5 plus `POLL_INTERVAL_SECONDS`, `IMAGE_WAIT_SECONDS`, `TERMINATE_WAIT_SECONDS`, `INGRESS_CONNECTOR`). `.env` (gitignored): `EXPECTED_ACCOUNT_ID`, optional `AWS_PROFILE`.
- `.build/` (gitignored): `app-<sha256>.zip`, `microvm.json`, `<target>.log`, `cloudwatch.log`.

## Constraints

Rules marked (data) are also in `docs/kukulu.json` `constraints` or `verify` and run on every `kukulu_verify`.

- No 12-digit number in `infra/`, `scripts/`, `app/`, `Makefile`, `config.env` (data: `no-account-id`).
- No region literal in `infra/`, `scripts/`, `app/`, `Makefile` (data: `no-region-literal`).
- In `infra/*.yaml` only `Default`, `MinValue`, `MaxValue` may end in an integer (data: `infra-no-hardcoded-integers`); that they sit inside `Parameters:` is checked by reading.
- No numeric literal tunable in `scripts/`: no `sleep 5`, `--max-time 60`, `"port":8080`, `${X:-30}`, or `timeout=60` (data: `scripts-no-literal-tunables`). Loop bounds use `deadline=$((SECONDS + CONFIG_VAR))`.
- Every `scripts/*.sh` has `set -euo pipefail` on line 2; every script except `lib.sh` sources `lib.sh` and is executable (data: verify command).
- `assert_sandbox` runs before a script's first `aws` call (reviewer checks by reading: ordering across lines is not a line pattern).
- `app/Dockerfile`: exactly one `FROM`, `public.ecr.aws/lambda/microvms:al2023-minimal`; `dnf install -y nodejs24`; `ENV` ports equal `config.env` (data: `dockerfile-base-image`, `dockerfile-no-foreign-node`, verify command).
- `app/package.json`: no `dependencies`; `devDependencies` exactly `typescript`, `@types/node` (data: `no-runtime-dependencies`, verify command).
- `app/src/` and `app/test/` import only `node:*` and relative `.ts` paths (data: `app-imports-node-or-relative-ts`).
- No `localhost` or `127.0.0.1` in `app/src/` (data: `app-no-localhost`); both servers listen on `0.0.0.0` (reviewer checks by reading).
- No `Math.random` in `app/src/` (data: `app-no-math-random`); `randomUUID` only in `app/src/hooks.ts` (data: `randomuuid-only-in-hooks`); `instanceId` is `null` at module load and set only in the run handler (unit test plus reading).
- IAM: no bare `Resource: '*'`, no `Action` with `*` (data: `iam-no-wildcard-resource`, `iam-no-wildcard-action`); both roles trust `lambda.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession` with `aws:SourceAccount` (reviewer checks by reading).
- Scripts parse JSON with `jq` only (data: `scripts-json-with-jq`).
- The auth token (`TOKEN`) reaches curl only on stdin via `-H @-` (data: `token-not-in-args-or-output`).
- No run hook payload in `app/src/` or `scripts/` (data: `no-run-hook-payload`); no SAM, `NetworkConnector` or `Function` resources (data: `no-sam-or-extra-resources`); extra hooks stay `DISABLED` (data: `extra-hooks-disabled`); no `ALL_INGRESS`/`SHELL_INGRESS` (data: `no-extra-ingress`).
- `smoke.sh` traps `EXIT` to terminate its MicroVM; `destroy.sh` runs principle 10's four steps in order, each tolerating "already gone" (reviewer checks by reading).
- No AWS call outside the Phase 3 sandbox task. Live commands never go in `docs/kukulu.json`.

## Task protocols

**Script protocol** (every `scripts/*.sh` task):
1. Line 1 `#!/usr/bin/env bash`, line 2 `set -euo pipefail`, then `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and `source "$SCRIPT_DIR/lib.sh"`. `chmod +x` the file.
2. Call `assert_sandbox` before the first `aws` command.
3. Machine-readable output is JSON on stdout (built with `jq`); progress and errors go to stderr through `log` and `die`.
4. Every number that tunes behavior comes from a `config.env` variable. Do not assign a literal number to a variable whose name contains `timeout`, `seconds`, `minutes`, `interval`, `ttl` or `max`; name counters `attempt` or `elapsed` instead, and do not reset `SECONDS`.
5. Confirm CLI options and output field names with `aws lambda-microvms <command> help`; make no AWS call while writing the script.
6. Quote every expansion. Comment each step with the MicroVM concept it shows.

**Phase-end protocol** (P1-06, P2-09, P3-03): run the task's checks; `git push origin HEAD`; in the progress-log entry write `Manual check: NOT VERIFIED (human)` followed by the exact steps the human must perform; mark the task done. Never block on the manual check.

**Sandbox-run protocol** (P3-01): run each `make` target as its own Bash call with `run_in_background: true`, as `bash -c 'set -o pipefail; mkdir -p .build; make <target> 2>&1 | tee .build/<target>.log'`, and wait for the completion notification instead of polling. Read the exit status from the notification. `make destroy` always runs last, even after a failure.

## Commit template

```
<ID>: <title>

Goal: <one sentence>
Tests: <test files and names added or run>
Interpretation: <any reading of SPEC or the task you had to choose>
Measurement: <tuning or sandbox numbers, if any>
Manual check: <NOT VERIFIED (human) and steps, for phase-end tasks>
```

No `Co-Authored-By`, "Generated with" or other attribution trailers.

SPEC.md wins over PLAN.md, which wins over code comments.
