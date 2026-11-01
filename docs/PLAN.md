# Lambda MicroVMs Hello World build plan

Derived from docs/SPEC.md v0.2 on 2026-11-01. SPEC.md wins over this file.

## Decisions

- Phases → SPEC section 8's three phases, kept in order and numbered as SPEC numbers them (task ids `P1-..`, `P2-..`, `P3-..`). SPEC section 7 calls the first task "the Phase 1 scaffold task", so it is `P1-01`.
- Parallel streams → none; every task is serial. SPEC section 4 says `app/` and `infra/` are independent, but SPEC's own phases put them on opposite sides of a phase-end task (a wave barrier), and the Docker build that `app/` tasks trigger is an exclusive command. The plan is 18 tasks; a partition would save little.
- Scripts other than `deploy.sh` (`run.sh`, `call.sh`, `microvm.sh`, `smoke.sh`, `destroy.sh`) → written in Phase 2. SPEC's Phase 2 names only `deploy.sh`, but Phase 3 runs `make smoke` and `make destroy`, so they must exist before it, and writing them makes no AWS call.
- Shared wiring (`Makefile`, `config.env`, `scripts/lib.sh`) → written in full by `P1-01`, including every Makefile target and every config key, so later tasks do not each append to them. Only `P2-01` (adds cfn-lint to `make check`) and `P3-01` (may set `INGRESS_CONNECTOR`) edit them again.
- Open question 1 → already resolved by SPEC (base version resolved at deploy time). `P2-03` implements it.
- Open questions 2–5 → resolved empirically by `P3-01`. Its progress-log entry carries a `Decisions:` list with one answer per question, and it appends the answers to `docs/reference/microvms-notes.md` tagged `[tested <date>]`. The implementer does not edit this file.
- Missing tunables → principle 2 requires every numeric tunable in `scripts/` to come from `config.env`, and the scripts need four values SPEC's table omits. Added to `config.env` by `P1-01`: `POLL_INTERVAL_SECONDS=5` (sleep between every poll), `IMAGE_WAIT_SECONDS=1800` (bound on `deploy.sh`'s image wait), `TERMINATE_WAIT_SECONDS=120` (bound on `destroy.sh`'s wait for MicroVMs to reach `TERMINATED` before deleting the image stack), `INGRESS_CONNECTOR=` (Open question 4: empty means no ingress flag; the only other allowed value is `HTTP_INGRESS`). Open question 4's fallback is then a one-line config edit, not a code change.
- Config precedence → `lib.sh` sources `config.env`, then `.env` if present (so `.env` overrides both), with `set -a`. `AWS_REGION` is exported from `REGION` only when `AWS_REGION` is not already set (SPEC section 5). Simple and predictable for a learner.
- Handler shape → `app.ts` and `hooks.ts` export pure functions that take a `State`, a method, a path (and a raw body for hooks) and return `{ status, body }` (hooks add `log`). `main.ts` adapts `node:http`. Tests need no network (SPEC section 4: "calling the handlers directly").
- Fresh state for the principle 8 test → `state.ts` exports a `createState()` factory and the shared `state` singleton built from it.
- Hook log lines → only `ready` and `run` requests log (SPEC section 6 types `hook` as `"ready"|"run"`). An unknown hook path returns 404 and logs nothing.
- Non-matching methods → a non-`GET` to `/` and a non-`POST` to a hook path are "any other" requests: 404, no state change.
- TypeScript → `typescript@^7` (7.0.2 is `latest`; verified on 2026-11-01 that it accepts SPEC's tsconfig and enforces `erasableSyntaxOnly`) and `@types/node@^24` (matches the Node 24 runtime). `tsconfig.json` also sets `verbatimModuleSyntax: true`, so a type-only import must say `import type`, which Node's type stripping requires.
- `package.json` sets `"type": "module"`. The Dockerfile copies only `src/` (SPEC section 4); Node 24 detects ESM syntax in a `.ts` file with no `package.json` (verified locally).
- `make check` → runs `npm --prefix app ci` only when `app/node_modules` is missing or older than the lockfile, then typecheck, test, `bash -n scripts/*.sh`, and (from `P2-01`) `cfn-lint infra/*.yaml`. It does not run the Docker build, which needs the Docker daemon; that stays a separate extra verify.
- Deterministic packaging → `deploy.sh` stages `app/` without `node_modules/`, `test/` and `.DS_Store`, fixes every mtime and mode, and zips the files in sorted order with `zip -X -D`, so the same source always gives the same sha256 key. Without this, every re-run uploads a new key and builds a new image version, which breaks "safe to re-run". `deploy.sh --package-only` packages and prints the result with no AWS call, so packaging can be verified before Phase 3.
- Image version for `run.sh` → the image stack's `LatestActiveImageVersion` output, as SPEC section 6 says. If that output is empty or `None` (possible if CloudFormation returns before the build finishes, Open question 2), `run.sh` falls back to `get-microvm-image`'s `latestActiveImageVersion` and logs which source it used.
- Log group ARN in IAM → built with `!Sub 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${LogGroup}'` plus the same with `:*`. `!GetAtt LogGroup.Arn` already ends in `:*` and would not name the group itself.
- CloudWatch evidence → `P3-01` saves `aws logs tail` output to `.build/cloudwatch.log` before `make destroy`, because the log group belongs to the bootstrap stack and is deleted with it. The Phase 3 manual check reads that file.
- `mutation.targeted` → `cd app && node --test --test-name-pattern={filter} 'test/**/*.test.ts'`. SPEC's `npm --prefix app test -- --test-name-pattern={filter}` appends the option after the glob, where Node ignores it (verified: the non-matching test still ran).
- Lifecycle logging → `lib.sh`'s `log` prefixes each stderr line with an ISO-8601 UTC timestamp, so `P3-01` can time the `run` hook against the moment `run.sh` launched the MicroVM.

## Conventions

- Commit title `<ID>: <title>`; body per CLAUDE.md's commit template; no `Co-Authored-By` or generated-by trailers.
- Every script follows the script protocol in CLAUDE.md; every phase-end task follows the phase-end protocol in CLAUDE.md.
- Config key names are exactly those in SPEC section 5 plus the four added under Decisions.
- No task in Phases 1 and 2 makes an AWS call. CLI parameter and output names are confirmed with `aws lambda-microvms <command> help`, which is offline.

## Phase 1 — App

### P1-01: Scaffold app package, config, lib.sh and Makefile

**Goal:** Create the app package with its in-memory state module, the committed `config.env`, the shared `scripts/lib.sh`, and a `Makefile` whose `check` target works.
**Files touched:** `app/package.json`, `app/package-lock.json`, `app/tsconfig.json`, `app/src/state.ts`, `app/test/state.test.ts`, `config.env`, `scripts/lib.sh`, `Makefile`
**Design constraints:**
- `app/package.json` (SPEC section 3 principle 6, section 7): `"name": "mvm-hello"`, `"private": true`, `"type": "module"`, scripts `"typecheck": "tsc --noEmit"` and `"test": "node --test 'test/**/*.test.ts'"`, `"engines": { "node": ">=24" }`. No `dependencies` key. `devDependencies` exactly `typescript` (`^7`) and `@types/node` (`^24`); create them with `npm --prefix app install --save-dev typescript@^7 @types/node@^24`, which also writes `app/package-lock.json`.
- `app/tsconfig.json`: `compilerOptions` `strict: true`, `noEmit: true`, `erasableSyntaxOnly: true`, `allowImportingTsExtensions: true`, `verbatimModuleSyntax: true`, `module: "nodenext"`, `target: "es2024"`, `types: ["node"]`; `include: ["src", "test"]`.
- `app/src/state.ts` (SPEC section 4, principle 8): `export type State = { instanceId: string | null; microvmId: string | null; requestCount: number; appListening: boolean }`; `export function createState(): State` returning all `null`, `0`, `false`; `export const state: State = createState();`. No `randomUUID`, no `Math.random` here. Comment why `instanceId` starts `null` (anything set before the snapshot is shared by every MicroVM).
- Imports in `app/` are only `node:*` and relative paths ending in `.ts`; type-only imports use `import type`.
- `config.env`: plain `KEY=value` lines readable by both bash and POSIX `sh`, values with spaces double-quoted, a comment above each key saying what it controls and where its default comes from. Keys and defaults exactly as SPEC section 5's table, in its order: `REGION=us-west-2`, `STACK_PREFIX=mvm-hello`, `IMAGE_NAME=mvm-hello`, `IMAGE_DESCRIPTION="Lambda MicroVMs hello world"`, `APP_PORT=8080`, `HOOKS_PORT=9000`, `MEMORY_MIB=2048`, `READY_TIMEOUT_SECONDS=30`, `RUN_TIMEOUT_SECONDS=5`, `IDLE_MAX_SECONDS=300`, `SUSPENDED_SECONDS=600`, `AUTO_RESUME=true`, `MAX_DURATION_SECONDS=1800`, `TOKEN_TTL_MINUTES=15`, `LOG_RETENTION_DAYS=7`, `RESUME_WAIT_SECONDS=30`, `CALL_READY_TIMEOUT_SECONDS=60`, `CURL_MAX_TIME_SECONDS=60`, `BASE_IMAGE_VERSION=`; then the four plan-added keys `POLL_INTERVAL_SECONDS=5`, `IMAGE_WAIT_SECONDS=1800`, `TERMINATE_WAIT_SECONDS=120`, `INGRESS_CONNECTOR=` (comment: empty means no ingress flag, `HTTP_INGRESS` is the only other allowed value, see SPEC Open question 4). `config.env` is the only file that names the region. No account ID, no `EXPECTED_ACCOUNT_ID` value.
- `scripts/lib.sh` (SPEC section 4 `lib.sh`, principles 1, 3, 4): line 1 `#!/usr/bin/env bash`, line 2 `set -euo pipefail`. It defines `REPO_ROOT` (parent of the script's own directory via `BASH_SOURCE`), `BUILD_DIR="$REPO_ROOT/.build"`, `MICROVM_FILE="$BUILD_DIR/microvm.json"`; sources `config.env` then `$REPO_ROOT/.env` if present, inside `set -a` / `set +a`; then `export AWS_REGION="${AWS_REGION:-$REGION}"`; sets `BOOTSTRAP_STACK="${STACK_PREFIX}-bootstrap"` and `IMAGE_STACK="${STACK_PREFIX}-image"`. Functions:
  - `log <msg…>`: one stderr line `[<date -u +%Y-%m-%dT%H:%M:%SZ>] <calling script basename>: <msg>`.
  - `die <msg…>`: `log` then `exit 1`.
  - `require_cmd <name…>`: `die` naming the first command not on `PATH`.
  - `assert_sandbox`: `die` with a message naming `EXPECTED_ACCOUNT_ID`, `.env` and `export` when `EXPECTED_ACCOUNT_ID` is unset or empty, **before** any `aws` call; otherwise reads `aws sts get-caller-identity --output json` once, takes `.Account` with `jq`, and `die`s with both account IDs when it differs; on success exports `AWS_PARTITION` (the second `:` field of `.Arn`).
  - `stack_output <stack> <key>`: prints that CloudFormation output value via `aws cloudformation describe-stacks`, printing an empty string when the key is missing (normalize `None` to empty); returns non-zero when the stack does not exist.
  - `managed_connector_arn <NAME>`: prints `arn:${AWS_PARTITION}:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:<NAME>`.
  - `base_image_arn`: prints `arn:${AWS_PARTITION}:lambda:${AWS_REGION}:aws:microvm-image:al2023-1`.
  Every function has a comment explaining what it is for. No region literal, no numeric tunable.
- `Makefile` (SPEC section 6 Makefile): `.PHONY` targets `deploy run call status suspend resume terminate smoke destroy check`. `deploy run smoke destroy` run `scripts/<target>.sh`; `call` runs `scripts/call.sh $(CALL_PATH)` with `CALL_PATH ?= /`; `status suspend resume terminate` run `scripts/microvm.sh <target>`. Scripts are invoked as `scripts/<name>.sh` (they are committed executable). `check` depends on a file target `app/node_modules: app/package-lock.json` whose recipe is `npm --prefix app ci`, then runs in order `npm --prefix app run typecheck`, `npm --prefix app test`, `bash -n scripts/*.sh`. Do not add cfn-lint yet (no template exists until P2-01). A comment above each target says which MicroVM concept it demonstrates. No region literal, no account ID.
- `.gitignore` already ignores `node_modules/`, `.build/` and `.env`; do not change it.
**Acceptance tests:** `app/test/state.test.ts` with tests named `createState returns null ids, zero requestCount and appListening false`, `createState returns a new object each call`, and `the shared state starts with instanceId null at module load`. All pass under `npm --prefix app test`.
**Out of scope:** `app.ts`, `hooks.ts`, `main.ts`, the Dockerfile, any `infra/` file, any script other than `lib.sh`, any AWS call. Do not add linters, formatters or bundlers.
**Verification:** `npm --prefix app ci && npm --prefix app run typecheck && npm --prefix app test`; `bash -n scripts/lib.sh`; `make check`. Sandbox guard without AWS, in a copy that has no `.env`: `tmp=$(mktemp -d) && cp -R scripts config.env "$tmp"/ && (cd "$tmp" && env -u EXPECTED_ACCOUNT_ID bash -c 'source scripts/lib.sh; assert_sandbox'); test $? -eq 1` and the stderr names `EXPECTED_ACCOUNT_ID`. Region export: `(cd "$tmp" && env -u AWS_REGION bash -c 'source scripts/lib.sh; printf "%s\n" "$AWS_REGION"')` prints the `config.env` region. Then `kukulu_verify`.
**Depends on:** none

### P1-02: App server request handler

**Goal:** Implement the app server's `GET /` and 404 behavior as a pure handler with unit tests.
**Files touched:** `app/src/app.ts`, `app/test/app.test.ts`
**Design constraints:**
- SPEC section 6 "App server". Export `export type Reply = { status: number; body: Record<string, unknown> }` and `export function handleApp(s: State, method: string, path: string): Reply` (import `type State` from `./state.ts`). `path` arrives with any query string already removed.
- `GET /`: increment `s.requestCount` **before** building the reply, then return `200` with body `{ message: "hello from a Lambda MicroVM", instanceId: s.instanceId, microvmId: s.microvmId, requestCount: s.requestCount }` (keys in this order).
- Any other path, or any method other than `GET` on `/`: `404` with body `{ error: "not found" }`, and `requestCount` unchanged.
- Principles 6, 7, 8: imports only `node:*` and `./*.ts`; no `localhost`/`127.0.0.1`; no `Math.random`; no `randomUUID` outside `app/src/hooks.ts`. Heavy comments: explain that `requestCount` lives in memory and survives suspend/resume.
**Acceptance tests:** `app/test/app.test.ts`, each test using `createState()` for fresh state: `GET / returns 200 with message, instanceId, microvmId and requestCount`, `GET / increments requestCount on every call`, `an unknown path returns 404 not found`, `a non-GET request to / returns 404 and does not increment requestCount`.
**Out of scope:** the HTTP server and port handling (`main.ts`, P1-04); hooks.
**Verification:** `npm --prefix app run typecheck && npm --prefix app test`, then `kukulu_verify`.
**Depends on:** P1-01

### P1-03: Hooks server request handler

**Goal:** Implement the `ready` and `run` lifecycle hooks as a pure handler with unit tests, including principle 8's uniqueness test.
**Files touched:** `app/src/hooks.ts`, `app/test/hooks.test.ts`
**Design constraints:**
- SPEC section 6 "Hooks server", G6, principle 8. Export `export const HOOK_PREFIX = "/aws/lambda-microvms/runtime/v1/"`, `export type HookReply = Reply & { log: string | null }` (`import type { Reply } from "./app.ts"`), and `export function handleHook(s: State, method: string, path: string, rawBody: string, now: Date = new Date()): HookReply`.
- `POST <prefix>ready`: `503` with body `{ ready: false }` while `s.appListening` is false, else `200` with `{ ready: true }`. Comment: the image build calls this and takes the snapshot only after a 200.
- `POST <prefix>run`: parse `rawBody` with `JSON.parse` inside `try/catch`; a missing, empty, non-JSON, non-object body, or a `microvmId` that is not a string, all give `s.microvmId = null`. Otherwise `s.microvmId` is the body's `microvmId`. Then `s.instanceId = randomUUID()` (from `node:crypto`), return `200` with `{ ok: true }` immediately. Read only `microvmId` from the body; never read, name or mention the run hook's payload field anywhere in `app/src/` (the `no-run-hook-payload` constraint scans comments too). Comment why the ID is generated here and not at module load (snapshot uniqueness, see `docs/reference/microvms-notes.md`).
- Any other path or method: `404` with `{ error: "not found" }`, `log: null`, no state change.
- `log` for `ready` and `run` is `JSON.stringify({ hook, status, ts: now.toISOString() })` with keys in that order, e.g. `{"hook":"run","status":200,"ts":"2026-11-01T12:00:00.000Z"}`. `main.ts` prints it; the handler does not write to stdout.
- `randomUUID` may appear only in this file (constraint `randomuuid-only-in-hooks`). No `Math.random`, no `localhost`.
**Acceptance tests:** `app/test/hooks.test.ts`, each test on `createState()`: `ready returns 503 before the app server is listening and 200 after`, `run sets microvmId from the body and assigns an instanceId`, `run on two fresh states assigns different instanceIds`, `run tolerates a malformed body` (cases: `""`, `"not json"`, `"[]"`, `"null"`, `'{"microvmId":42}'`; each returns 200, `microvmId` null, `instanceId` a string), `an unknown hook path returns 404 and logs nothing`, `ready and run each return one JSON log line with hook, status and ts`.
**Out of scope:** the HTTP servers (`main.ts`); the `validate`, `suspend`, `resume` and `terminate` hooks (non-goals); any use of the run hook payload.
**Verification:** `npm --prefix app run typecheck && npm --prefix app test`, then `kukulu_verify`.
**Depends on:** P1-01

### P1-04: Entry point starting both servers

**Goal:** Start the app server and the hooks server on `0.0.0.0`, wiring `node:http` to the pure handlers.
**Files touched:** `app/src/main.ts`
**Design constraints:**
- SPEC section 4 (`main.ts`), section 6, principle 7. Read `APP_PORT` and `HOOKS_PORT` from `process.env`; each must be an integer from 1 to 65535, otherwise write one error line to stderr and `process.exit(1)`. No fallback port number in code (`app/` never reads `config.env`; the Dockerfile `ENV` lines supply the values).
- Two servers from `node:http` `createServer`, both `listen(port, "0.0.0.0")`. Strip the query string with `(req.url ?? "/").split("?")[0]`.
- App server: call `handleApp(state, req.method ?? "", path)` from `./app.ts`. On the app server's `listening` event set `state.appListening = true` (this is what turns `ready` from 503 to 200).
- Hooks server: collect the request body as a UTF-8 string, then call `handleHook(state, method, path, body)` from `./hooks.ts`; if `reply.log` is not null, `console.log(reply.log)` (one stdout line per hook, how hooks are observed in CloudWatch).
- Both: `res.writeHead(reply.status, { "content-type": "application/json" })` and `res.end(JSON.stringify(reply.body))`. Use the shared `state` from `./state.ts`.
- Principles 6–8: only `node:*` and `./*.ts` imports; no `localhost`/`127.0.0.1` anywhere in `app/src/` (including comments); no `Math.random`, no `randomUUID`. Heavy comments explaining why both servers bind all interfaces and why hooks get their own port.
**Acceptance tests:** none new (`main.ts` opens sockets, and SPEC section 4 keeps unit tests network-free). Existing `app/test/*.test.ts` still pass and typecheck covers `main.ts`.
**Out of scope:** the Dockerfile (P1-05); changing handler behavior; adding a test that opens a port.
**Verification:** `npm --prefix app run typecheck && npm --prefix app test`. Smoke it locally on spare ports: `APP_PORT=18080 HOOKS_PORT=19000 node app/src/main.ts & pid=$!; sleep 1; curl -s -XPOST http://127.0.0.1:19000/aws/lambda-microvms/runtime/v1/ready; curl -s -XPOST http://127.0.0.1:19000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'; curl -s http://127.0.0.1:18080/; kill $pid` — expect `{"ready":true}`, `{"ok":true}`, then a body with `"microvmId":"local"` and `"requestCount":1`, and two hook lines on stdout. `env -u APP_PORT HOOKS_PORT=19000 node app/src/main.ts; test $? -eq 1`. Then `kukulu_verify`.
**Depends on:** P1-02, P1-03

### P1-05: Dockerfile on the snapshot-safe base image

**Goal:** Write `app/Dockerfile` that installs Node 24 from `dnf` on the MicroVM base image and runs `src/main.ts`, and confirm it builds for arm64.
**Files touched:** `app/Dockerfile`
**Design constraints:**
- SPEC section 3 principle 5, section 4 (`Dockerfile`, boundaries). Exactly one `FROM`, and it is the line `FROM public.ecr.aws/lambda/microvms:al2023-minimal`.
- `RUN dnf install -y nodejs24 && dnf clean all`. No `node:` image, no `curl`/`wget`, no `nvm` outside comment lines.
- `ENV APP_PORT=8080` and `ENV HOOKS_PORT=9000` as two separate lines in exactly that form (the values must equal `config.env`'s `APP_PORT` and `HOOKS_PORT`; a verify command and `deploy.sh` compare them).
- `WORKDIR /opt/app`, `COPY src/ ./src/` (only `src/`; Node 24 runs `.ts` directly), `EXPOSE ${APP_PORT} ${HOOKS_PORT}`, `CMD ["node", "src/main.ts"]`.
- Comment every line: why this base image (its system OpenSSL is patched for snapshot safety; `nodejs24` links it, official Node builds bundle their own), why both ports are exposed, that changing a port means editing both this file and `config.env`.
**Acceptance tests:** none (no unit-testable code). The image must build: `docker build --platform linux/arm64 -t mvm-hello:verify app`.
**Out of scope:** `.dockerignore`; multi-stage builds; any change to `app/src/`.
**Verification:** `docker build --platform linux/arm64 -t mvm-hello:verify app` (needs the Docker daemon; `kukulu_verify` runs it as the exclusive extra verify for `app/Dockerfile`, with a 20-minute timeout, so call `kukulu_verify` rather than a long foreground shell command). The Dockerfile structure check in `docs/kukulu.json` (one `FROM`, `dnf install -y nodejs24`, ports match `config.env`) must pass. If the Docker daemon is not running, block with that reason.
**Depends on:** P1-01

### P1-06: Phase 1 push and manual container check

**Goal:** Push the branch and record the manual container check for Phase 1.
**Files touched:** `docs/PROGRESS.md`
**Design constraints:** Follow the phase-end protocol in CLAUDE.md. SPEC section 8 Phase 1 manual check.
**Acceptance tests:** none; `make check` and the Docker build pass.
**Out of scope:** any code change; running the container yourself as a substitute for the human check.
**Verification:** `make check`; `docker build --platform linux/arm64 -t mvm-hello:verify app`; `git push origin HEAD`. Log `Manual check: NOT VERIFIED (human)` with the steps for the human (default ports from `config.env`): `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`, then `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'` and `curl http://127.0.0.1:8080/`, then `docker stop mvm-hello-verify`.
**Depends on:** none

## Phase 2 — Infra and packaging

### P2-01: Bootstrap stack template

**Goal:** Write `infra/bootstrap.yaml` (artifact bucket, build role, execution role, log group) and add cfn-lint to `make check`.
**Files touched:** `infra/bootstrap.yaml`, `Makefile`
**Design constraints:**
- SPEC section 4 "Stack layout" (`${STACK_PREFIX}-bootstrap`), principles 1, 2, 9.
- Parameters: `ImageName` (`Type: String`, `Default: mvm-hello`, `AllowedPattern: '^[a-zA-Z0-9-_]+$'`), `LogRetentionDays` (`Type: Number`, `Default: 7`). The only keys in the template that may end in a bare integer are `Default`, `MinValue`, `MaxValue` inside `Parameters:`; do not use `MinLength`, `MaxLength` or numeric `AllowedValues` lists.
- `ArtifactBucket` (`AWS::S3::Bucket`): no `BucketName` (no account ID or region in a name), `BucketEncryption` SSE-S3 (`AES256`), `PublicAccessBlockConfiguration` with all four flags `true`, no versioning.
- `LogGroup` (`AWS::Logs::LogGroup`): `LogGroupName: !Sub '/aws/lambda-microvms/${ImageName}'`, `RetentionInDays: !Ref LogRetentionDays`.
- `BuildRole` and `ExecutionRole` (`AWS::IAM::Role`, no `RoleName`): trust policy `Effect: Allow`, `Principal: { Service: lambda.amazonaws.com }`, `Action: [sts:AssumeRole, sts:TagSession]`, `Condition: { StringEquals: { 'aws:SourceAccount': !Ref AWS::AccountId } }`. Inline policies only:
  - BuildRole: `s3:GetObject` on `!Sub '${ArtifactBucket.Arn}/artifacts/*'`; `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` on the log group ARN and its streams.
  - ExecutionRole: the same three `logs:` actions on the same two resources, nothing else.
  - The log group ARN is `!Sub 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${LogGroup}'` and the streams ARN is the same string ending in `:*`. Do not use `!GetAtt LogGroup.Arn` (it already ends in `:*`).
  - No `Resource: '*'`, no `Action` containing `*`.
- Outputs `ArtifactBucketName` (`!Ref ArtifactBucket`), `BuildRoleArn`, `ExecutionRoleArn` (`!GetAtt <Role>.Arn`), `LogGroupName` (`!Ref LogGroup`), each with `Export: { Name: !Sub '${AWS::StackName}-<OutputKey>' }`.
- Heavy comments: why two stacks, why the bucket key prefix `artifacts/` is the only readable path, why each permission exists.
- `Makefile`: append `cfn-lint infra/*.yaml` to `check`, after `bash -n scripts/*.sh`. Nothing else in the Makefile changes.
**Acceptance tests:** none (no test framework for templates). `cfn-lint infra/*.yaml` exits 0 with no errors or warnings.
**Out of scope:** `infra/image.yaml`; any script; any AWS call (`aws cloudformation validate-template` is an AWS call, do not use it).
**Verification:** `cfn-lint infra/*.yaml`; `make check`; then `kukulu_verify` (its constraints cover principles 1, 2 and 9 for `infra/`).
**Depends on:** none

### P2-02: Image stack template

**Goal:** Write `infra/image.yaml` with the `AWS::Lambda::MicrovmImage` resource and its outputs.
**Files touched:** `infra/image.yaml`
**Design constraints:**
- SPEC section 4 "Stack layout" (`${STACK_PREFIX}-image`), principles 1, 2; `docs/reference/microvmimage-schema.json` is authoritative for shapes.
- Parameters (types and defaults; defaults equal `config.env`): `BootstrapStackName` (String, `Default: mvm-hello-bootstrap`), `ImageName` (String, `Default: mvm-hello`, `AllowedPattern: '^[a-zA-Z0-9-_]+$'`), `ImageDescription` (String, `Default: Lambda MicroVMs hello world`), `BaseImageVersion` (String, no `Default`, `AllowedPattern: '^\S+$'`; `deploy.sh` always passes it), `ArtifactUri` (String, no `Default`, `AllowedPattern: '^s3://\S+$'`), `MemoryMiB` (Number, `Default: 2048`), `HooksPort` (Number, `Default: 9000`, `MinValue: 1`, `MaxValue: 65535`), `ReadyTimeoutInSeconds` (Number, `Default: 30`, `MinValue: 1`, `MaxValue: 3600`), `RunTimeoutInSeconds` (Number, `Default: 5`, `MinValue: 1`, `MaxValue: 60`). Only `Default`, `MinValue`, `MaxValue` may end in a bare integer.
- Resource `Image`, `Type: AWS::Lambda::MicrovmImage`, all 13 required properties exactly as SPEC section 4 lists them: `Name: !Ref ImageName`; `Description: !Ref ImageDescription`; `BuildRoleArn: !ImportValue` of `!Sub '${BootstrapStackName}-BuildRoleArn'`; `BaseImageArn: !Sub 'arn:${AWS::Partition}:lambda:${AWS::Region}:aws:microvm-image:al2023-1'`; `BaseImageVersion: !Ref BaseImageVersion`; `CodeArtifact: { Uri: !Ref ArtifactUri }`; `CpuConfigurations: [{ Architecture: ARM_64 }]`; `Resources: [{ MinimumMemoryInMiB: !Ref MemoryMiB }]`; `EgressNetworkConnectors: [!Sub 'arn:${AWS::Partition}:lambda:${AWS::Region}:aws:network-connector:aws-network-connector:INTERNET_EGRESS']`; `AdditionalOsCapabilities: []`; `EnvironmentVariables: []`; `Logging: { CloudWatch: { LogGroup: !ImportValue of '${BootstrapStackName}-LogGroupName' } }`; `Hooks: { Port: !Ref HooksPort, MicrovmImageHooks: { Ready: ENABLED, ReadyTimeoutInSeconds: !Ref ReadyTimeoutInSeconds, Validate: DISABLED }, MicrovmHooks: { Run: ENABLED, RunTimeoutInSeconds: !Ref RunTimeoutInSeconds, Resume: DISABLED, Suspend: DISABLED, Terminate: DISABLED } }`. Use `Fn::ImportValue` with `!Sub` inside (the long form, since `!ImportValue !Sub` is not valid YAML short-form nesting).
- Outputs (stack outputs, not exported): `ImageArn` (`!GetAtt Image.ImageArn`), `LatestActiveImageVersion` (`!GetAtt Image.LatestActiveImageVersion`).
- Comments: `Name` is create-only (changing it replaces the image); every other change creates a new image version; the content-hashed `ArtifactUri` is what triggers a rebuild; only the `ready` and `run` hooks are on.
- No `AWS::Serverless`, no `AWS::Lambda::NetworkConnector`, no `AWS::Lambda::Function`; `Validate`/`Resume`/`Suspend`/`Terminate` never `ENABLED`.
**Acceptance tests:** none. `cfn-lint infra/*.yaml` exits 0 (cfn-lint 1.58 knows this resource type and reports `E3003` for a missing required property).
**Out of scope:** `infra/bootstrap.yaml`; scripts; tags; any AWS call.
**Verification:** `cfn-lint infra/*.yaml`; `make check`; `kukulu_verify`.
**Depends on:** none

### P2-03: deploy.sh with deterministic packaging

**Goal:** Write `scripts/deploy.sh`: port check, both stacks, base-version resolution, deterministic content-hashed zip upload, and the wait for an active image version.
**Files touched:** `scripts/deploy.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 4 (`deploy.sh`, boundaries), section 5 (`BASE_IMAGE_VERSION`), section 8 Phase 2 (packaging), Open questions 1 and 2.
- Order of work:
  1. Port check, before anything else: read `ENV APP_PORT=` and `ENV HOOKS_PORT=` values from `app/Dockerfile` and `die` (exit 1) naming the key, both values and both files when either differs from `config.env`.
  2. Packaging (a function). Stage into `$BUILD_DIR/stage` (delete it first): copy `app/` excluding `node_modules`, `test` and `.DS_Store` (e.g. `tar -C app --exclude node_modules --exclude test --exclude .DS_Store -cf - . | tar -C "$stage" -xf -`); `chmod` files 644 and directories 755; `touch -t 198001010000` every entry; then `(cd "$stage" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -X -D -q "$tmp" -@)`. Hash with `sha256sum`, or `shasum -a 256` when `sha256sum` is absent. Move to `$BUILD_DIR/app-<sha256>.zip`. The zip root holds `Dockerfile`, `package.json`, `package-lock.json`, `tsconfig.json` and `src/`; never `node_modules/` or `test/`.
  3. `--package-only` (the only accepted argument): after steps 1–2, print `{"zip":"<path>","sha256":"<hex>"}` and exit 0 without any AWS call. Any other argument: `die` with usage.
  4. `assert_sandbox`, `require_cmd aws jq zip`.
  5. `aws cloudformation deploy --stack-name "$BOOTSTRAP_STACK" --template-file infra/bootstrap.yaml --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --parameter-overrides ImageName=… LogRetentionDays=…`.
  6. Resolve the base version: if `BASE_IMAGE_VERSION` is empty, run `aws lambda-microvms list-managed-microvm-image-versions --image-identifier "$(base_image_arn)" --output json` and pick with `jq -r '[.items[]|select(.status=="AVAILABLE" or .status=="DEPRECATED")]|max_by(.imageVersion|tonumber).imageVersion'`; `die` if the result is empty or `null`. `log` the chosen value (say whether it was resolved or pinned).
  7. `aws s3 cp` the zip to `s3://<ArtifactBucketName>/artifacts/app-<sha256>.zip` (bucket from `stack_output "$BOOTSTRAP_STACK" ArtifactBucketName`). Only the `artifacts/` prefix is readable by `BuildRole`.
  8. `aws cloudformation deploy --stack-name "$IMAGE_STACK" --template-file infra/image.yaml --no-fail-on-empty-changeset --parameter-overrides` with every image parameter from config: `BootstrapStackName=$BOOTSTRAP_STACK ImageName ImageDescription BaseImageVersion ArtifactUri=s3://<bucket>/artifacts/app-<sha256>.zip MemoryMiB HooksPort ReadyTimeoutInSeconds RunTimeoutInSeconds`. Quote `ImageDescription` (it has spaces). Confirm the `CodeArtifact` URI form with `aws lambda-microvms create-microvm-image help` (offline).
  9. Wait: right after step 8, `log` the image state seen first (this answers Open question 2). Poll `aws lambda-microvms get-microvm-image --image-identifier <ImageArn>` (`state`, `latestActiveImageVersion`) until `state` is `CREATED` or `UPDATED`; `die` on any state ending in `_FAILED`. Then poll `get-microvm-image-version --image-identifier <ImageArn> --image-version <latestActiveImageVersion>` until `state` is `SUCCESSFUL` and `status` is `ACTIVE`; `die` on `state` `FAILED`. Sleep `POLL_INTERVAL_SECONDS` between polls; `die` when `IMAGE_WAIT_SECONDS` have passed (`deadline=$((SECONDS + IMAGE_WAIT_SECONDS))`). `ImageArn` comes from `stack_output "$IMAGE_STACK" ImageArn`.
  10. stdout: one JSON object `{"imageArn","imageVersion","baseImageVersion","artifactUri","imageStateAfterCfn","buildSeconds"}`, where `buildSeconds` is the time from the start of step 8 to the end of step 9.
- Safe to re-run: unchanged source gives the same key, an unchanged changeset is not an error, and a finished image passes the waits at once. A failed `cloudformation deploy` exits non-zero with a `log` line telling the user to run `make destroy` before retrying.
- No region literal, no account ID, no numeric literal tunable (constraint `scripts-no-literal-tunables`).
**Acceptance tests:** none in `node --test` (SPEC allows no shell test tooling). The checks under Verification must pass.
**Out of scope:** running the AWS path; the other scripts; changing `lib.sh`, `config.env` or the templates.
**Verification:** `bash -n scripts/deploy.sh`. Determinism: `scripts/deploy.sh --package-only` twice, then `touch app/src/*.ts` and once more; all three print the same `sha256`. `unzip -l` of the zip lists `Dockerfile` and `src/main.ts` at the root and no `node_modules/` or `test/` entry. Port check, in a scratch copy: `tmp=$(mktemp -d) && cp -R app scripts config.env "$tmp"/ && sed -i.bak 's/^ENV HOOKS_PORT=.*/ENV HOOKS_PORT=1/' "$tmp/app/Dockerfile" && (cd "$tmp" && scripts/deploy.sh --package-only); test $? -eq 1`, with stderr naming `HOOKS_PORT`. Then `kukulu_verify`.
**Depends on:** P1-01

### P2-04: run.sh launches one MicroVM

**Goal:** Write `scripts/run.sh`, which launches a MicroVM from the active image version and records it in `.build/microvm.json`.
**Files touched:** `scripts/run.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 6 `run.sh`, G2, Open question 4, section 2 non-goals.
- `assert_sandbox`, `require_cmd aws jq`. Read `ImageArn` and `LatestActiveImageVersion` with `stack_output "$IMAGE_STACK" …`; if the version is empty, fall back to `aws lambda-microvms get-microvm-image --image-identifier <ImageArn>`'s `latestActiveImageVersion` and `log` that the fallback was used; `die` if still empty. Read `ExecutionRoleArn` and `LogGroupName` from `stack_output "$BOOTSTRAP_STACK" …`.
- Build JSON with `jq -cn`: `--idle-policy` `{maxIdleDurationSeconds: IDLE_MAX_SECONDS, suspendedDurationSeconds: SUSPENDED_SECONDS, autoResumeEnabled: AUTO_RESUME}` (numbers via `--argjson`, the boolean via `--argjson` from `AUTO_RESUME`); `--logging` `{cloudWatch: {logGroup: <LogGroupName>}}`.
- Call `aws lambda-microvms run-microvm --image-identifier --image-version --execution-role-arn --idle-policy --maximum-duration-in-seconds "$MAX_DURATION_SECONDS" --logging --egress-network-connectors "$(managed_connector_arn INTERNET_EGRESS)" --output json`. Add `--ingress-network-connectors "$(managed_connector_arn "$INGRESS_CONNECTOR")"` only when `INGRESS_CONNECTOR` is non-empty; `die` if it is set to anything but `HTTP_INGRESS`. Never pass a run hook payload. Confirm option shapes with `aws lambda-microvms run-microvm help`.
- If `.build/microvm.json` already exists, `log` a warning naming the old `microvmId` (`make destroy` terminates it if it is still running), then overwrite. `mkdir -p "$BUILD_DIR"`. Write `{"microvmId":…,"endpoint":…}` from the response with `jq`, and print the same object to stdout. The endpoint is stored without a scheme.
- Comment the idle policy (auto-suspend after `IDLE_MAX_SECONDS` without inbound traffic, auto-resume on traffic) and why an unrecorded MicroVM is still bounded (idle policy, `MAX_DURATION_SECONDS`, and `destroy.sh` step 1).
**Acceptance tests:** none in `node --test`; `bash -n` and the constraints pass.
**Out of scope:** calling the MicroVM; waiting for readiness (that is `smoke.sh`); any AWS call while building this task.
**Verification:** `bash -n scripts/run.sh`; `env -u EXPECTED_ACCOUNT_ID` run in a scratch copy without `.env` exits 1 before any AWS call (as in P1-01's verification); `kukulu_verify`.
**Depends on:** P1-01

### P2-05: call.sh mints a token and calls the MicroVM

**Goal:** Write `scripts/call.sh [path]`, which mints an auth token and makes one HTTPS request to the MicroVM without exposing the token.
**Files touched:** `scripts/call.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 6 `call.sh`, G3.
- `path` defaults to `/` and must start with `/` (else `die`). `die` with "run make run first" when `$MICROVM_FILE` is missing. `assert_sandbox`, `require_cmd aws jq curl`.
- Token: `TOKEN=$(aws lambda-microvms create-microvm-auth-token --microvm-identifier "$id" --allowed-ports "$(jq -cn --argjson p "$APP_PORT" '[{port: $p}]')" --expiration-in-minutes "$TOKEN_TTL_MINUTES" --query 'authToken."X-aws-proxy-auth"' --output text)`. The variable is named `TOKEN`.
- Request: `printf 'X-aws-proxy-auth: %s\nX-aws-proxy-port: %s\n' "$TOKEN" "$APP_PORT" | curl -fsS --max-time "$CURL_MAX_TIME_SECONDS" -H @- "https://${endpoint}${path}"`; the body goes to stdout. The token is never echoed, logged, written to disk or placed in a command's arguments.
- Comment why the token travels on stdin (`ps` shows arguments) and why `X-aws-proxy-port` is sent (it routes to `APP_PORT` when that is not 8080; `--allowed-ports` only authorizes).
**Acceptance tests:** none in `node --test`; `bash -n` and the constraints (`token-not-in-args-or-output`) pass.
**Out of scope:** retries (`smoke.sh` retries); any AWS call while building this task.
**Verification:** `bash -n scripts/call.sh`; in a scratch copy with no `.build/microvm.json`, `scripts/call.sh` exits 1 with the "make run" message; `kukulu_verify`.
**Depends on:** P1-01

### P2-06: microvm.sh status, suspend, resume, terminate

**Goal:** Write `scripts/microvm.sh <status|suspend|resume|terminate>` for the MicroVM recorded in `.build/microvm.json`.
**Files touched:** `scripts/microvm.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 4 (`microvm.sh`), section 6, principle 10.
- Exactly one argument from the four; anything else `die`s with usage.
- `terminate` with no `$MICROVM_FILE`: `log` "nothing to terminate" and exit 0 (the `smoke.sh` trap may run before `run.sh` wrote it). `status`, `suspend`, `resume` with no file: `die`.
- `assert_sandbox`, `require_cmd aws jq` (after the no-file check for `terminate`).
- `status`: `aws lambda-microvms get-microvm --microvm-identifier <id> --output json`; print `{"microvmId","state"}`.
- `suspend` / `resume`: `suspend-microvm` / `resume-microvm`; print `{"microvmId","action":"suspend"|"resume"}`.
- `terminate`: first `get-microvm`; if `state` is `TERMINATING` or `TERMINATED`, or the call fails with a not-found error (stderr matching `ResourceNotFound` or `not found`, case-insensitive), print `{"microvmId","action":"terminate","result":"already-gone"}` and exit 0. Otherwise `terminate-microvm`; a not-found error there is also exit 0. Success prints `"result":"terminated"`. Any other error exits non-zero. Leave `.build/microvm.json` in place.
- Comment the state machine (`PENDING → RUNNING ⇄ SUSPENDING → SUSPENDED → TERMINATING → TERMINATED`), that `get-microvm` state is eventually consistent, and that suspend keeps memory and disk.
**Acceptance tests:** none in `node --test`; `bash -n` and the constraints pass.
**Out of scope:** polling loops (`smoke.sh` polls); any AWS call while building this task.
**Verification:** `bash -n scripts/microvm.sh`; in a scratch copy with no `.build/microvm.json` and no `.env`: `scripts/microvm.sh terminate` exits 0, `scripts/microvm.sh status` exits 1, `scripts/microvm.sh bogus` exits 1; `kukulu_verify`.
**Depends on:** P1-01

### P2-07: smoke.sh end-to-end lifecycle check

**Goal:** Write `scripts/smoke.sh`, the end-to-end run → call → suspend → resume → terminate check from SPEC section 6.
**Files touched:** `scripts/smoke.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 6 `smoke.sh` (steps 1–7), G2–G5, principle 10. Call sibling scripts as `"$SCRIPT_DIR/<name>.sh"` and capture their stdout; smoke's own stdout carries only its JSON lines.
- Interfaces it relies on (restated): `run.sh` prints `{"microvmId","endpoint"}` and writes `.build/microvm.json`; `call.sh [path]` prints the app body `{"message","instanceId","microvmId","requestCount"}` and exits non-zero on failure; `microvm.sh status` prints `{"microvmId","state"}`; `microvm.sh terminate` exits 0 when the MicroVM is already gone or unrecorded.
- `assert_sandbox` first, then `trap '"$SCRIPT_DIR/microvm.sh" terminate >/dev/null || true' EXIT` set **before** step 1.
- Steps: (1) `run.sh`. (2) Retry `call.sh /` every `POLL_INTERVAL_SECONDS` until success or `CALL_READY_TIMEOUT_SECONDS` pass (readiness is checked by connecting; `get-microvm` state is eventually consistent); assert `instanceId` and `microvmId` non-null; record `instanceId` and `requestCount`. (3) `microvm.sh suspend`, then poll `microvm.sh status` every `POLL_INTERVAL_SECONDS` until `SUSPENDED`, timeout `RESUME_WAIT_SECONDS * 2`. (4) Retry `call.sh /` for up to `RESUME_WAIT_SECONDS`; success means `resumePath` `auto`; otherwise `microvm.sh resume`, then retry `call.sh /` for up to `CALL_READY_TIMEOUT_SECONDS`, `resumePath` `explicit`. Print `{"resumePath":"auto"|"explicit"}`. (5) Assert `instanceId` unchanged and the new `requestCount` greater than the recorded one (not exactly +1; comment why). (6) `microvm.sh terminate`. (7) Print `{"ok":true,"microvmId","instanceId","requestCountBefore","requestCountAfter","resumePath"}` and exit 0.
- Any failed assertion or timeout prints `{"ok":false,"step":<n>,"reason":"…"}` to stdout and exits 1 (the trap still terminates).
- Every wait uses `deadline=$((SECONDS + <CONFIG_VAR>))`; no numeric literal tunable. Comment which MicroVM concept each step demonstrates.
**Acceptance tests:** none in `node --test`; `bash -n` and the constraints pass.
**Out of scope:** changing the other scripts; any AWS call while building this task.
**Verification:** `bash -n scripts/smoke.sh`; in a scratch copy without `.env`, `env -u EXPECTED_ACCOUNT_ID scripts/smoke.sh` exits 1 before any AWS call; `kukulu_verify`.
**Depends on:** P1-01

### P2-08: destroy.sh ordered teardown

**Goal:** Write `scripts/destroy.sh`, the ordered teardown from principle 10 in which every step tolerates "already gone".
**Files touched:** `scripts/destroy.sh`
**Design constraints:**
- Follow the script protocol in CLAUDE.md. SPEC section 3 principle 10, section 6 (`run.sh` unrecorded-MicroVM note), G5.
- `assert_sandbox`, `require_cmd aws jq`. Steps in order:
  1. `"$SCRIPT_DIR/microvm.sh" terminate` (exit 0 when there is no file or it is gone). Then, if the image stack exists, `ImageArn` from `stack_output`, `aws lambda-microvms list-microvms --image-identifier <ImageArn> --output json`, and `terminate-microvm` every item whose `state` is not `TERMINATING` or `TERMINATED` (a not-found error is fine). Then poll `list-microvms` every `POLL_INTERVAL_SECONDS` until none is in a state other than `TERMINATED`, for at most `TERMINATE_WAIT_SECONDS`; on timeout `log` a warning and continue. Remove `$MICROVM_FILE`.
  2. `aws cloudformation delete-stack --stack-name "$IMAGE_STACK"` and `aws cloudformation wait stack-delete-complete --stack-name "$IMAGE_STACK"` (both succeed when the stack is absent; `die` with the stack status if the wait fails).
  3. If the bootstrap stack exists and has an `ArtifactBucketName`, `aws s3 rm "s3://<bucket>" --recursive`; a missing bucket is fine.
  4. Delete the bootstrap stack and wait, as in step 2.
- stdout: `{"terminated":[<ids>],"imageStack":"deleted"|"absent","bucketEmptied":true|false,"bootstrapStack":"deleted"|"absent"}`.
- Comment that a MicroVM launched from this repo's image is found by `list-microvms --image-identifier` even when `run.sh` died before recording it, and that the log group goes with the bootstrap stack.
**Acceptance tests:** none in `node --test`; `bash -n` and the constraints pass.
**Out of scope:** retaining any resource; deleting anything not created by these two stacks or `run.sh`; any AWS call while building this task.
**Verification:** `bash -n scripts/destroy.sh`; in a scratch copy without `.env`, `env -u EXPECTED_ACCOUNT_ID scripts/destroy.sh` exits 1 before any AWS call; `kukulu_verify`.
**Depends on:** P1-01

### P2-09: Phase 2 push and IAM review

**Goal:** Push the branch and record the manual IAM review for Phase 2.
**Files touched:** `docs/PROGRESS.md`
**Design constraints:** Follow the phase-end protocol in CLAUDE.md. SPEC section 8 Phase 2 manual check; principle 9.
**Acceptance tests:** none; `make check` passes.
**Out of scope:** any code change; any AWS call.
**Verification:** `make check`; `git push origin HEAD`. Log `Manual check: NOT VERIFIED (human)` with the step for the human: review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against SPEC principle 9 (trust `lambda.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession` with `aws:SourceAccount` = `AWS::AccountId`; no `Resource: '*'`; no `Action` with `*`).
**Depends on:** none

## Phase 3 — Sandbox run and README

### P3-01: Sandbox run: deploy, smoke, destroy

**Goal:** Run `make deploy`, `make smoke` and an unconditional `make destroy` against the sandbox account, record the measurements, and resolve Open questions 2–5.
**Files touched:** `docs/reference/microvms-notes.md`, `config.env` (only for the Open question 4 fallback), `docs/PROGRESS.md`
**Design constraints:**
- SPEC section 8 Phase 3 item 1, "Sandbox prerequisites", section 9 Open questions 2–5, principles 9 and 10. Follow the sandbox-run protocol in CLAUDE.md for how each `make` target is run (background, `tee` to `.build/<target>.log`, wait for the exit notification).
- Preflight, no AWS call: `bash -c 'source scripts/lib.sh; test -n "${EXPECTED_ACCOUNT_ID:-}"'`. If it fails, block with "operator must set EXPECTED_ACCOUNT_ID (exported or in .env)"; nothing was created, so no destroy is needed. Never print or record the account ID.
- Sequence:
  1. `make deploy`. If the Bash call was cut off before the command finished (no exit status), run `make deploy` once more (it is safe to re-run). A non-zero exit is a failure.
  2. `make smoke`. If it fails at step 1 or 2 (`run.sh` errors, or the first call never connects), apply Open question 4's fallback once: set `INGRESS_CONNECTOR=HTTP_INGRESS` in `config.env` and run `make smoke` once more. Any other failure, or a second failure, is a failure.
  3. Before destroying, save CloudWatch: `bash -c 'source scripts/lib.sh; assert_sandbox; aws logs tail "/aws/lambda-microvms/$IMAGE_NAME" --since 3h --format short' > .build/cloudwatch.log 2>&1` (the log group is deleted with the bootstrap stack).
  4. `make destroy`, always, including after any failure in steps 1–2. If destroy fails, block saying resources may still exist, with the error and the last 50 lines of `.build/destroy.log`.
- Record in the progress log: the `baseImageVersion` and `buildSeconds` from `deploy.sh`'s stdout JSON, `imageStateAfterCfn`, `resumePath`, smoke's summary JSON, and the `run` hook timing: the `{"hook":"run",…}` line's `ts` from `.build/cloudwatch.log` against the timestamp of `run.sh`'s launch `log` line in `.build/smoke.log`. Quote the `ready` and `run` hook lines verbatim.
- Under a `Decisions:` list in the progress-log entry, one answer per question: (2) did `cloudformation deploy` return before the image reached `CREATED` (from `imageStateAfterCfn`)? (3) did `dnf install` have network access at build time (build log in `.build/cloudwatch.log`)? (4) which ingress setting worked (none, or `HTTP_INGRESS`)? (5) did auto-resume trigger after an explicit suspend (`resumePath`)? Append the same answers to `docs/reference/microvms-notes.md` in a new section `## Answers from the first sandbox run`, each bullet tagged `[tested <YYYY-MM-DD>]`, plus the base image version and build time. Do not edit `docs/PLAN.md`.
- On any failure in steps 1–2: first copy the last 50 lines of the image build log (`tail -n 50 .build/cloudwatch.log` after step 3) into the block reason, then run step 4, then block with the error and those lines. Do not retry beyond the two single re-runs above, and do not edit scripts or templates to make it pass. Record in the notes any open question that was answered before the failure.
- If the logs show the build role could not be assumed, or any call returns `AccessDenied`, block the same way with the exact error. Do **not** change trust policies or any IAM (principle 9; that is the operator's decision).
- Live commands (`make deploy`, `make smoke`, `make destroy`) run only in this task and are never added to `docs/kukulu.json`.
**Acceptance tests:** `make smoke` exits 0 and prints `"ok":true`; `make destroy` exits 0; `.build/cloudwatch.log` contains at least one `"hook":"ready"` line and one `"hook":"run"` line.
**Out of scope:** code changes of any kind other than the single `INGRESS_CONNECTOR` edit; loosening IAM; running more than one MicroVM; leaving any stack or MicroVM running.
**Verification:** the sequence above; then `make check` and `kukulu_verify` (constraints still pass after a `config.env` edit). Commit message records base image version, build time, `resumePath`, the run hook timing and the four answers.
**Depends on:** P1-04, P1-05, P2-01, P2-02, P2-03, P2-04, P2-05, P2-06, P2-07, P2-08

### P3-02: README walkthrough

**Goal:** Rewrite `README.md` as the walkthrough SPEC G7 and Phase 3 item 2 describe.
**Files touched:** `README.md`
**Design constraints:**
- SPEC G7, section 8 Phase 3 item 2, section 4 (stack layout), section 5, `docs/reference/microvms-notes.md` "Pricing". Replace the current "Status: the spec is in progress" note.
- Sections, in order: what this is (one paragraph); prerequisites (an AWS account with admin access; `EXPECTED_ACCOUNT_ID` exported or in a gitignored `.env`, optionally `AWS_PROFILE`; AWS CLI v2, `jq`, `zip`, Node 24, Docker; region set in `config.env`); quick start (`make check`, `make deploy`, `make smoke`, `make destroy`); a table or list of every `make` target (`deploy`, `run`, `call`, `status`, `suspend`, `resume`, `terminate`, `smoke`, `destroy`, `check`) with what it does and the MicroVM concept it demonstrates (image build and snapshot, `ready` hook, `run` hook and per-instance uniqueness, idle policy with auto-suspend and auto-resume, auth token and `X-aws-proxy-auth`, memory preserved across suspend, terminate and teardown); the two-stack layout and why the bucket must exist first; content-hashed artifact keys and deterministic packaging (unchanged code means no new image version); the cost model (baseline compute while running, storage only while suspended, each image version costs storage, data transfer at standard rates); `config.env` and how to change a port (edit both `config.env` and the Dockerfile `ENV` line); how to fork (rename `STACK_PREFIX` and `IMAGE_NAME`, replace `app/src/`); "Next experiments" linking `https://github.com/deeheber/lambda-micro-vms/issues?q=is%3Aissue+label%3Anext-experiment` and `ROADMAP.md`.
- If `P3-01` is done, you may cite its recorded results (resumePath, build time) from the progress log; if it is not, describe the behavior without numbers. Do not invent measurements.
- Never write an account ID. Plain language for a developer new to MicroVMs.
**Acceptance tests:** none (documentation). Every `make` target in the `Makefile` appears in the README.
**Out of scope:** changing code, `ROADMAP.md`, or `docs/`.
**Verification:** `for t in deploy run call status suspend resume terminate smoke destroy check; do grep -q "make $t" README.md || echo "missing $t"; done` prints nothing; `kukulu_verify`.
**Depends on:** none

### P3-03: Phase 3 push and final manual checks

**Goal:** Push the branch and record the final manual checks.
**Files touched:** `docs/PROGRESS.md`
**Design constraints:** Follow the phase-end protocol in CLAUDE.md. SPEC section 8 Phase 3 manual check.
**Acceptance tests:** none; `make check` passes.
**Out of scope:** any code change; any AWS call.
**Verification:** `make check`; `git push origin HEAD`. Log `Manual check: NOT VERIFIED (human)` with the steps for the human: read `README.md` end to end; confirm the `ready` and `run` hook lines in CloudWatch Logs — the log group was deleted by `make destroy`, so read the copy P3-01 saved in `.build/cloudwatch.log` (or run `make deploy && make run`, view `/aws/lambda-microvms/mvm-hello` in the console, then `make destroy`).
**Depends on:** none

## Spec issues

- **`make check` and the cfn-lint verify before any template exists.** SPEC section 7 asks for every verify rule to start at the scaffold task, and section 8 has Phase 1 end with `make check` passing, but `cfn-lint infra/*.yaml` exits 2 when the glob matches nothing (verified, cfn-lint 1.58.0, `E0003`), and no template exists until Phase 2. Resolution: the cfn-lint verify rule has `from: P2-01`, and `P2-01` adds cfn-lint to `make check`. `bash -n scripts/*.sh` is safe from `P1-01` because the scaffold writes `lib.sh`.
- **SPEC's single-test command does not filter.** `npm --prefix app test -- --test-name-pattern={filter}` puts the option after the glob, where Node ignores it (verified). `mutation.targeted` uses `cd app && node --test --test-name-pattern={filter} 'test/**/*.test.ts'`.
- **Phase 2 names only `deploy.sh`.** The other five scripts are needed by Phase 3 and are placed in Phase 2 (see Decisions).
- **Principle 2 needs keys SPEC's table lacks.** Poll interval, image-wait bound, terminate-wait bound and the Open question 4 ingress choice are added to `config.env` (see Decisions).
- **Phase 3 failure order loses the build log.** "Runs `make destroy` first, then blocks with … the last 50 lines of the image build log", but destroy deletes the bootstrap stack and with it the log group. Resolution: `P3-01` saves CloudWatch to `.build/cloudwatch.log` before destroying and quotes it in the block reason. The Phase 3 manual check ("confirm the `ready` and `run` lines in CloudWatch Logs") reads that file for the same reason.
- **"Records each answer under `Decisions`" is ambiguous.** `PLAN.md` belongs to the planner. Resolution: a `Decisions:` list in `P3-01`'s progress-log entry, plus the `[tested <date>]` section in `docs/reference/microvms-notes.md`.
- **`BaseImageVersion`'s default.** SPEC section 5 gives an empty default, but the schema requires `minLength: 1`. Resolution: the CFN parameter has no `Default`, and `deploy.sh` always passes a resolved value.
- **Stale `LatestActiveImageVersion` output.** If Open question 2's answer is "yes, CloudFormation returns early", the stack output may be empty. Resolution: `run.sh` falls back to `get-microvm-image` (see Decisions).
- **Hook log line for a 404.** Section 6 says "every hook request writes one stdout line", with `hook` typed `"ready"|"run"`. Resolution: unknown paths are not hook requests and log nothing.
- **`LogGroup.Arn`.** CloudFormation's `Arn` attribute for a log group ends in `:*`, so "the log group ARN and its `:*` streams" is built with `!Sub` (see Decisions).
- **Packaging determinism.** "sha256 of zip" with default `zip` settings embeds mtimes, so the key would change on every fresh checkout or touch. Resolution: the normalized staging described in `P2-03`.
- **`lib.sh` and principle 3.** Line 2 `set -euo pipefail` in a sourced `lib.sh` changes the caller's shell options; this is harmless because every caller sets the same options. Kept as SPEC says.

## Review fixes (round 1)

### R1-01: hooks.test.ts: cover ready method check and hook reply bodies

**Goal:** Add unit tests so that the ready route's POST-only check, the ready reply body and the run reply body in app/src/hooks.ts are each covered: removing any of them makes a test fail.
**Files touched:** app/test/hooks.test.ts
**Design constraints:** SPEC section 6 Hooks server; PLAN P1-03 design constraints (ready: 503 {ready:false} / 200 {ready:true}; run: 200 {ok:true}; any other path or method: 404 {error:"not found"}, log null, no state change). Tests call handleHook directly on createState(); no network. Imports only node:* and relative .ts paths. Never name the run hook payload field (constraint no-run-hook-payload covers app/src/ only, but keep tests consistent). Do not change app/src/hooks.ts.
**Acceptance tests:** New tests in app/test/hooks.test.ts: `a non-POST request to ready returns 404 and logs nothing` (GET to `${HOOK_PREFIX}ready` with appListening true gives status 404, body {error:"not found"}, log null); `ready returns body ready false at 503 and ready true at 200` (deepEqual on r.body both before and after setting appListening); `run returns body ok true` (deepEqual r.body to {ok:true}). These would have caught the R1 review survivors.
**Out of scope:** Any change to app/src/; tests for main.ts or anything that opens a socket; new test tooling.
**Verification:** npm --prefix app run typecheck && npm --prefix app test. Then kukulu_mutate on app/src/hooks.ts with targeted 'unit', filter '.', for each of: find `  if (method === "POST" && path === `${HOOK_PREFIX}ready`) {` replace `  if (path === `${HOOK_PREFIX}ready`) {`; find `body: { ready: s.appListening }` replace `body: { ready: true }`; find `body: { ok: true }` replace `body: { ok: false }`. All three must return killed: true. Then kukulu_verify.
**Depends on:** none

### R1-02: deploy.sh: keep waiting until the image has an active version

**Goal:** Make deploy.sh's first wait loop finish only when the image state is CREATED or UPDATED and latestActiveImageVersion is non-empty, so it never calls get-microvm-image-version with an empty --image-version and instead keeps polling as SPEC section 4 requires.
**Files touched:** scripts/deploy.sh
**Design constraints:** SPEC section 4 deploy.sh (wait for image CREATED or UPDATED, then for its LatestActiveImageVersion to be SUCCESSFUL and ACTIVE), Open question 2, docs/reference/microvms-notes.md (image state, version state and activation are independent). Script protocol in CLAUDE.md: keep set -euo pipefail on line 2, assert_sandbox before the first aws call, no numeric literal tunable (reuse the same deadline from IMAGE_WAIT_SECONDS and sleep POLL_INTERVAL_SECONDS), jq only, progress via log to stderr. Keep the *_FAILED die and the existing stdout JSON shape. log once when the image is CREATED/UPDATED but has no active version yet. Make no AWS call while building this task.
**Acceptance tests:** Offline stub test in a scratch copy (no AWS call): tmp=$(mktemp -d); cp -R app scripts infra config.env "$tmp"/; write an executable stub "$tmp/bin/aws" that answers `sts get-caller-identity` with {"Account":"$EXPECTED_ACCOUNT_ID","Arn":"arn:aws:iam::...:user/x"} (build the account from a variable, never a literal 12-digit number in the repo), `cloudformation deploy` with exit 0, `cloudformation describe-stacks` with the queried output value, `s3 cp` with exit 0, `lambda-microvms list-managed-microvm-image-versions` with {"items":[{"imageVersion":"3","status":"AVAILABLE"}]}, `lambda-microvms get-microvm-image` with {"state":"CREATED"} (no latestActiveImageVersion) for the first 2 calls (counter file) and then {"state":"CREATED","latestActiveImageVersion":"1.0"}, and `lambda-microvms get-microvm-image-version` with exit 1 if --image-version is empty, else {"state":"SUCCESSFUL","status":"ACTIVE"}. Run with POLL_INTERVAL_SECONDS=0 in a .env override and PATH="$tmp/bin:$PATH" EXPECTED_ACCOUNT_ID=<any 12-char value built at runtime>: deploy.sh exits 0 and prints imageVersion "1.0". The same stub against the pre-fix deploy.sh exits non-zero (this is the test that would have caught the finding). Do not commit the stub.
**Out of scope:** The update-path stale-version question (SPEC Open question 2 on re-deploy; left for the live run); any other script; lib.sh, config.env or templates; committing any shell test tooling; any real AWS call.
**Verification:** bash -n scripts/deploy.sh; scripts/deploy.sh --package-only still prints the same sha256 as before the change; the stub test above passes with the fix and fails without it; kukulu_verify (constraints, especially scripts-no-literal-tunables and no-account-id).
**Depends on:** none
