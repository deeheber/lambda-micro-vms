# Lambda MicroVMs Hello World — Specification

Version: 0.1 Status: ready for flight

The Kūkulu planner reads this file in full and derives the build plan from it. Facts about the service, all verified on 2026-10-31, are in [`docs/reference/microvms-notes.md`](reference/microvms-notes.md). The CloudFormation resource schema is in [`docs/reference/microvmimage-schema.json`](reference/microvmimage-schema.json). Read both before planning. Every guessed number is marked `⚠️ ASSUMPTION` and has a config key.

## 1. Overview

This is a minimal, heavily commented repository that:

- builds an AWS Lambda MicroVM image with CloudFormation,
- runs one MicroVM from it,
- calls it over HTTPS,
- suspends, resumes, and terminates it.

It is for a developer learning Lambda MicroVMs, and it is the template they will fork for later experiments. The repo is done when `make deploy && make smoke && make destroy` passes against a sandbox AWS account in `us-west-2`, and the README explains which MicroVM concept each step demonstrates.

## 2. Goals and non-goals

The scope is **minimal on purpose**: only the features nearly every MicroVM user touches. Everything else is tracked as a GitHub issue labelled `next-experiment` and is out of scope for this flight.

**Goals:**

- G1 **Image.** A Dockerfile plus a TypeScript app is zipped and uploaded to S3, and an `AWS::Lambda::MicrovmImage` CloudFormation resource builds it.
- G2 **Run.** `run-microvm` with an idle policy that turns on auto-suspend and auto-resume.
- G3 **Connect.** `create-microvm-auth-token`, then an HTTPS `GET /` with the `X-aws-proxy-auth` header.
- G4 **Suspend and resume.** Suspend explicitly, then call again. The in-memory `requestCount` survives, which shows that memory state is preserved.
- G5 **Terminate and tear down.** Nothing billable is left running.
- G6 **Two lifecycle hooks.**
  - `ready`: the snapshot is taken only after the app is listening.
  - `run`: a per-MicroVM unique ID is generated after launch, not baked into the shared snapshot.
- G7 **README walkthrough.** For each `make` target, what it does and which MicroVM concept it shows.

**Non-goals** (each is a future issue; tasks must not build any of them):

- The `validate`, `suspend`, `resume`, and `terminate` lifecycle hooks. In CFN they are `DISABLED`.
- A local Docker harness that simulates hook calls.
- AWS SAM, or a "launcher" Lambda function that runs MicroVMs on demand.
- Shell access (`SHELL_INGRESS`, `create-microvm-shell-auth-token`).
- VPC egress or `AWS::Lambda::NetworkConnector`.
- WebSockets, HTTP/2, gRPC, or multiple app ports.
- Passing `runHookPayload` content. The `/run` handler reads `microvmId` only.
- Image version management (activate, deactivate, or delete versions).
- Calling AWS APIs from inside the MicroVM with execution role credentials.
- `AdditionalOsCapabilities: ["ALL"]`.
- Sizing, scaling, or cost benchmarking.
- CI pipelines, CDK, multi-region support, or PrivateLink.
- Linters and formatters beyond `tsc`, and any TypeScript build or bundling step.

## 3. Engineering principles

Each rule can be checked with a grep or a test. A violation is the most severe review finding.

1. **No account IDs and no hard-coded regions.**
   - No 12-digit number (`\b[0-9]{12}\b`) anywhere in `infra/`, `scripts/`, `app/`, `Makefile`, or `config.env`.
   - No region literal (`\b(us|eu|ap|sa|ca|me|af)-[a-z]+-[0-9]\b`) in `infra/`, `scripts/`, `app/`, or `Makefile`. The default region appears **only** in `config.env`.
   - Templates use `AWS::AccountId`, `AWS::Region`, and `AWS::Partition`.
2. **Every tunable is configuration.**
   - In `infra/*.yaml`, a line ending in a bare integer (`:\s+[0-9]+\s*$`) is allowed only when its key is `Default`, `MinValue`, or `MaxValue`, inside `Parameters:`.
   - In `scripts/`, every numeric tunable comes from a `config.env` variable.
3. **Script header.**
   - Every `scripts/*.sh` has `set -euo pipefail` on line 2, after the shebang.
   - Every script except `lib.sh` sources `scripts/lib.sh`.
4. **Sandbox guard.**
   - Every script that runs an `aws` command calls `assert_sandbox` before its first `aws` call. The function is defined in `lib.sh`.
   - `assert_sandbox` exits 1 with a clear message when `EXPECTED_ACCOUNT_ID` is unset or empty, or when it differs from `aws sts get-caller-identity --query Account --output text`.
5. **Snapshot-safe base image.**
   - `app/Dockerfile` has exactly one `FROM` line, and it is `FROM public.ecr.aws/lambda/microvms:al2023-minimal`.
   - Node comes from `dnf install -y nodejs24`.
   - No `node:` image, no `curl`/`wget` of Node, no `nvm`.

   This keeps the base image's snapshot-patched system OpenSSL. See the notes.
6. **No runtime dependencies.**
   - `app/package.json` has no `dependencies` key.
   - `devDependencies` contains only `typescript` and `@types/node`.
   - Files in `app/src/` import only `node:*` modules and relative paths ending in `.ts`.
7. **Bind all interfaces.** No `localhost` or `127.0.0.1` in `app/src/`. Both servers listen on host `0.0.0.0`.
8. **Uniqueness after launch.**
   - No `Math.random` in `app/src/`.
   - `instanceId` is assigned only inside the `/run` hook handler, using `crypto.randomUUID()`. At module load it is `null`.
   - A unit test calls the run handler twice on fresh state and asserts different `instanceId`s.
9. **Least-privilege IAM.**
   - Both roles trust `lambda.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`, with `Condition: StringEquals: aws:SourceAccount: !Ref AWS::AccountId`.
   - No `Resource: '*'`.
   - No `Action` containing `*`.
10. **Always tear down.**
    - `smoke.sh` sets `trap` on `EXIT`, which terminates the MicroVM it started.
    - `destroy.sh` runs these steps in order, and each step tolerates "already gone":
      1. terminate the MicroVM in `.build/microvm.json`, if present;
      2. delete the image stack and wait;
      3. empty the artifact bucket;
      4. delete the bootstrap stack and wait.

## 4. Architecture

```
app/                      the code that runs inside the MicroVM; imports nothing outside app/
  src/main.ts             starts the app server (APP_PORT) and hooks server (HOOKS_PORT); reads ports from env
  src/app.ts              request handler for the app server (exported for tests)
  src/hooks.ts            request handler for the hooks server: POST /aws/lambda-microvms/runtime/v1/{ready,run}
  src/state.ts            in-memory state: instanceId, microvmId, requestCount, appListening
  test/*.test.ts          node:test tests calling the handlers directly (no network)
  Dockerfile              FROM al2023-minimal; dnf install nodejs24; COPY src; EXPOSE both ports; CMD node src/main.ts
  package.json, tsconfig.json, package-lock.json
infra/
  bootstrap.yaml          ArtifactBucket, BuildRole, ExecutionRole, LogGroup; Outputs exported as ${AWS::StackName}-<Name>
  image.yaml              the AWS::Lambda::MicrovmImage; imports bootstrap exports via Fn::ImportValue
scripts/
  lib.sh                  load config.env; assert_sandbox; stack_output <stack> <key>; log (stderr); die
  deploy.sh               deploy bootstrap → resolve base image version → zip app/ → sha256 key → s3 cp → deploy image → wait for image CREATED
  run.sh                  run-microvm; write .build/microvm.json
  call.sh                 mint auth token; curl the given path (default /); print response body
  microvm.sh              <status|suspend|resume|terminate> for the MicroVM in .build/microvm.json
  smoke.sh                end-to-end lifecycle check (section 6)
  destroy.sh              ordered teardown (principle 10)
config.env                committed, non-secret defaults (section 5)
Makefile                  deploy, run, call, status, suspend, resume, terminate, smoke, destroy, check
README.md                 walkthrough (G7)
```

**Boundaries and shared wiring:**

- `app/` never reads `config.env`. Ports reach the app through Dockerfile `ENV` lines whose values match `config.env` defaults. The hooks port also goes into `image.yaml` as a parameter.
- `Makefile`, `config.env`, and `scripts/lib.sh` are shared wiring. The planner keeps tasks that edit them serial.
- `app/` and `infra/` are independent and can be built in parallel.

### Stack layout

Two stacks are needed because the bucket must exist and contain the zip before the image resource is created:

- **`${STACK_PREFIX}-bootstrap`** (`infra/bootstrap.yaml`):
  - **ArtifactBucket**: SSE-S3 encryption, all public access blocked, no versioning. Keys are content-hashed.
  - **BuildRole**: `s3:GetObject` on `${ArtifactBucket.Arn}/artifacts/*`, plus `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` on the log group ARN and its `:*` streams.
  - **ExecutionRole**: the same `logs:*` actions on the same log group, and nothing else.
  - **LogGroup**: `/aws/lambda-microvms/${ImageName}`, with `RetentionInDays: !Ref LogRetentionDays`.
- **`${STACK_PREFIX}-image`** (`infra/image.yaml`):
  - `AWS::Lambda::MicrovmImage` with `Name: !Ref ImageName`.
  - `BaseImageArn` built as `arn:${AWS::Partition}:lambda:${AWS::Region}:aws:microvm-image:al2023-1`.
  - `BaseImageVersion: !Ref BaseImageVersion`.
  - `CodeArtifact.Uri: !Ref ArtifactUri`.
  - `CpuConfigurations: [{Architecture: ARM_64}]`.
  - `Resources: [{MinimumMemoryInMiB: !Ref MemoryMiB}]`.
  - `EgressNetworkConnectors`: the managed `INTERNET_EGRESS` connector ARN, built from `AWS::Partition` and `AWS::Region`.
  - `AdditionalOsCapabilities: []` and `EnvironmentVariables: []`.
  - `Logging.CloudWatch.LogGroup`: the imported log group name.
  - `Hooks`:
    - `Port: !Ref HooksPort`.
    - `MicrovmImageHooks`: `Ready: ENABLED`, `ReadyTimeoutInSeconds: !Ref ReadyTimeoutInSeconds`, `Validate: DISABLED`.
    - `MicrovmHooks`: `Run: ENABLED`, `RunTimeoutInSeconds: !Ref RunTimeoutInSeconds`; `Resume`, `Suspend`, and `Terminate` all `DISABLED`.
  - `Outputs`: `ImageArn` and `LatestActiveImageVersion`.

## 5. Data and configuration

`config.env` is committed and holds every tunable. CloudFormation parameters take their defaults from the same values, and `deploy.sh` passes them explicitly.

| Key (`config.env` / CFN param) | Default | Source |
|---|---|---|
| `REGION` | `us-west-2` | user choice. Exported as `AWS_REGION` by `lib.sh` unless already set. |
| `STACK_PREFIX` | `mvm-hello` | |
| `IMAGE_NAME` / `ImageName` | `mvm-hello` | |
| `APP_PORT` | `8080` | MicroVM proxy default target port |
| `HOOKS_PORT` / `HooksPort` | `9000` | documented hooks default |
| `MEMORY_MIB` / `MemoryMiB` | `2048` | documented default baseline (2 GB / 1 vCPU) |
| `READY_TIMEOUT_SECONDS` / `ReadyTimeoutInSeconds` | `30` | documented default |
| `RUN_TIMEOUT_SECONDS` / `RunTimeoutInSeconds` | `5` | ⚠️ ASSUMPTION. The documented default is 1 s; 5 s is headroom for a cold path. Tune in Phase 3 using `run` hook log timestamps. |
| `IDLE_MAX_SECONDS` | `300` | sandbox cost choice (minimum 60) |
| `SUSPENDED_SECONDS` | `600` | sandbox cost choice |
| `AUTO_RESUME` | `true` | |
| `MAX_DURATION_SECONDS` | `1800` | sandbox cost choice (max 28800) |
| `TOKEN_TTL_MINUTES` | `15` | max 60 |
| `LOG_RETENTION_DAYS` / `LogRetentionDays` | `7` | |
| `RESUME_WAIT_SECONDS` | `30` | how long `smoke.sh` waits for auto-resume before calling `resume` |
| `BASE_IMAGE_VERSION` / `BaseImageVersion` | *(empty)* | Resolved by `deploy.sh` (see Open question 1). If it can't be resolved and the value is empty, `deploy.sh` exits 1, saying to set it. |

These come from the environment and are never committed:

- `EXPECTED_ACCOUNT_ID` (required by `assert_sandbox`)
- `AWS_PROFILE` (optional)

Generated state goes in `.build/` (gitignored):

- `app-<sha256>.zip`
- `microvm.json`

## 6. Interfaces

### App server (`APP_PORT`)

- `GET /` returns `200 application/json`: `{"message":"hello from a Lambda MicroVM","instanceId":<string|null>,"microvmId":<string|null>,"requestCount":<int>}`. Each `GET /` increments `requestCount` before responding.
- Any other path returns `404 {"error":"not found"}`.

### Hooks server (`HOOKS_PORT`)

Paths are under `/aws/lambda-microvms/runtime/v1/`.

- `POST …/ready` returns `503` until the app server's `listening` event has fired, then `200`. It is called during the image build. The snapshot is taken after it returns `200`.
- `POST …/run`:
  - The body is JSON with `microvmId` and an optional `runHookPayload`. A missing or invalid body is tolerated.
  - The handler sets `state.microvmId` from the body (or `null`), sets `state.instanceId = crypto.randomUUID()`, and returns `200` immediately.
- Any other hook path returns `404`.
- Every hook request writes one stdout line of JSON: `{"hook":"ready"|"run","status":<code>,"ts":<ISO-8601>}`. These lines are how hooks are observed in CloudWatch.

### Scripts

- **Output convention.** Every script writes machine-readable output as JSON to stdout, and progress and errors to stderr through `log` and `die`.
- **`run.sh`**
  - Calls `aws lambda-microvms run-microvm` with:
    - `--image-identifier`: the `ImageArn` output;
    - `--image-version`: the `LatestActiveImageVersion` output;
    - `--execution-role-arn`;
    - `--idle-policy` built from config;
    - `--maximum-duration-in-seconds`;
    - `--logging` pointing at the log group;
    - ingress and egress managed connectors (see Open question 4).
  - Writes `.build/microvm.json` = `{"microvmId","endpoint"}`. Endpoints come back without a scheme; scripts prepend `https://`.
- **`call.sh [path]`**
  - Mints a token: `create-microvm-auth-token --allowed-ports '[{"port":APP_PORT}]' --expiration-in-minutes TOKEN_TTL_MINUTES`, reading `authToken."X-aws-proxy-auth"`.
  - Curls with `-fsS`, sending the header `X-aws-proxy-auth: $TOKEN` and printing the body.
  - The token is never echoed or written to disk.
- **`smoke.sh`**
  1. `run.sh`
  2. Retry `call.sh /` until it succeeds or 60 s pass. Readiness is checked by connecting, because `get-microvm` state is eventually consistent. Assert `instanceId` and `microvmId` are non-null, and record `requestCount`.
  3. `microvm.sh suspend`, then poll `microvm.sh status` until it reports `SUSPENDED`. The poll timeout is `RESUME_WAIT_SECONDS` × 2.
  4. `call.sh /`, with retries for up to `RESUME_WAIT_SECONDS`, expecting auto-resume. If that fails, run `microvm.sh resume`, then `call.sh /` again. Print `{"resumePath":"auto"|"explicit"}`.
  5. Assert the new `requestCount` is exactly the previous value + 1. This proves memory survived.
  6. `microvm.sh terminate`. The `EXIT` trap also does this.
  7. Print a JSON summary and exit 0 only if every assertion passed.

### Makefile

| Target | Runs | Needs AWS |
|---|---|---|
| `check` | the section 7 offline commands, in order | no |
| `deploy` | `scripts/deploy.sh` | yes |
| `run` | `scripts/run.sh` | yes |
| `call` | `scripts/call.sh` | yes |
| `status`, `suspend`, `resume`, `terminate` | `scripts/microvm.sh <target>` | yes |
| `smoke` | `scripts/smoke.sh` | yes |
| `destroy` | `scripts/destroy.sh` | yes |

## 7. Commands

All of these are offline and exit non-zero on failure. None exists until the Phase 1 scaffold task creates `app/package.json`, `infra/`, and `scripts/`. The planner gives each verify rule `from:` that scaffold task.

- setup (run once before verify): `npm --prefix app ci`
- typecheck: `npm --prefix app run typecheck`, where the script is `tsc --noEmit`.
  - `tsconfig.json` sets `strict`, `noEmit`, `erasableSyntaxOnly`, `allowImportingTsExtensions`, `module: nodenext`, `target: es2024`, and `types: ["node"]`.
- test: `npm --prefix app test`, where the script is `node --test 'test/**/*.test.ts'`. Node 24 runs `.ts` natively; there is no compile step.
- test, single (for `mutation.targeted`): `npm --prefix app test -- --test-name-pattern={filter}`
- infra lint: `cfn-lint infra/*.yaml`
- scripts syntax: `bash -n scripts/*.sh`
- extra, when `app/Dockerfile` or `app/src/` changes: `docker build --platform linux/arm64 -t mvm-hello:verify app`. It needs the Docker daemon, so the planner marks it exclusive.

**Live commands are never `verify` or `extraVerify` entries:** `make deploy`, `make smoke`, `make destroy`. They run only inside the Phase 3 sandbox task.

## 8. Phases

### Phase 1: App

- Scaffold `app/`, `infra/`, `scripts/` with `lib.sh`, `config.env`, and the `Makefile` with `check` working.
- Build the app server, hooks server, state, tests, and Dockerfile.
- Required tests:
  - `/ready` returns 503 before listening and 200 after.
  - `/run` sets `instanceId` and `microvmId`, and two runs differ (principle 8).
  - `GET /` increments `requestCount`.
  - An unknown path returns 404.
  - A malformed `/run` body is tolerated.
- Ends with `make check` and the Docker build passing.
- **Manual check:** `docker run --rm -p 8080:8080 -p 9000:9000 mvm-hello:verify`, then `curl -XPOST :9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'` and `curl :8080/`.

### Phase 2: Infra and packaging

- Write `bootstrap.yaml` and `image.yaml` as specified in section 4. They must be cfn-lint clean.
- Write `deploy.sh`. Packaging: zip the contents of `app/` without `node_modules/` or `test/`, so the zip root has `Dockerfile` and `src/`. Name it `.build/app-<sha256 of zip>.zip`.
- No AWS calls are made in this phase.
- **Manual check:** review both IAM roles against principle 9.

### Phase 3: Sandbox run and README

1. One task runs `make deploy`, then `make smoke`, then `make destroy`. `destroy` always runs, even after a failure.
   - It records in the log: the resolved `BaseImageVersion`, how long the image build took, `resumePath`, and the `run` hook timing from CloudWatch (`aws logs tail`).
   - It resolves Open questions 1–4 and records each answer under `Decisions`.
   - On failure, the task **blocks** with the error and the last 50 lines of the image build log. It does not retry in a loop.
2. A tuning task for `RUN_TIMEOUT_SECONDS`, using the measured `run` hook duration.
3. A `README.md` walkthrough covering:
   - prerequisites (IAM permissions, env vars);
   - each `make` target and the concept it demonstrates;
   - the two-stack and content-hash reasoning;
   - the cost model (baseline compute while running, storage while suspended, image versions cost storage);
   - how to fork;
   - a "Next experiments" section that points to the `next-experiment` issues.

**Manual check:** read the README, and confirm the `ready` and `run` lines in CloudWatch Logs.

No task depends on a manual check, and no Phase 1 or 2 task depends on Phase 3.

### Sandbox prerequisites (provided by the operator before the flight)

- The flight shell exports `EXPECTED_ACCOUNT_ID`, and optionally `AWS_PROFILE`.
- Those credentials can use these actions:
  - `lambda:CreateMicrovmImage`, `UpdateMicrovmImage`, `GetMicrovmImage`, `GetMicrovmImageVersion`, `ListMicrovmImageVersions`, `ListManagedMicrovmImages`, `DeleteMicrovmImage`, `DeleteMicrovmImageVersion`
  - `RunMicrovm`, `GetMicrovm`, `SuspendMicrovm`, `ResumeMicrovm`, `TerminateMicrovm`, `CreateMicrovmAuthToken`
  - `lambda:PassNetworkConnector`, `lambda:TagResource`, `lambda:ListTags`
  - `cloudformation:*` on `mvm-hello-*` stacks
  - `s3:*` on the artifact bucket
  - `iam:CreateRole`/`DeleteRole`/`PutRolePolicy`/`DeleteRolePolicy`/`GetRole`/`PassRole` on `mvm-hello-*` roles
  - `logs:*` on `/aws/lambda-microvms/*`

  If they're missing, the Phase 3 task blocks with the `AccessDenied` message. It is not a code bug.

## 9. Open questions

1. **How do we resolve `BaseImageVersion`?**
   - `list-managed-microvm-images` returns only `imageArn`. Try `list-microvm-image-versions --image-identifier <managed ARN>` (pick the latest `ACTIVE`), then `get-microvm-image`.
   - If neither works, `deploy.sh` requires `BASE_IMAGE_VERSION` in `config.env`, and the task records the value the operator must set.
2. **Does CloudFormation create return before the image reaches `CREATED`?** `deploy.sh` polls `get-microvm-image` until `CREATED` regardless, and fails on `CREATE_FAILED` or `UPDATE_FAILED`. Record the answer.
3. **Does the image-level `EgressNetworkConnectors` (documented as runtime) also give the Dockerfile's `dnf install` network access at build time?** If the build fails at `dnf`, record it and decide; for example, whether egress must be passed differently. `run.sh` passes `INTERNET_EGRESS` explicitly at run time either way.
4. **Which managed ingress connector should `run.sh` pass?**
   - The tutorial passes `ALL_INGRESS`; the AWS skill says `HTTP_INGRESS` is the default.
   - Start with no ingress flag (the default). If the call fails, pass `HTTP_INGRESS`.
   - Record which one worked.
5. **Does auto-resume trigger after an explicit `suspend-microvm`?** `smoke.sh` handles both answers and reports `resumePath`.

## Appendix: reference files

- [`docs/reference/microvms-notes.md`](reference/microvms-notes.md): verified service facts, CLI shapes, gotchas, and source URLs. The implementer should read this instead of searching the web.
- [`docs/reference/microvmimage-schema.json`](reference/microvmimage-schema.json): the authoritative `AWS::Lambda::MicrovmImage` registry schema from `cloudformation describe-type`, including handler IAM permissions.
