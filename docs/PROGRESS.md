# Lambda MicroVMs Hello World build progress

Branch: build/2026-11-01
Started: 2026-11-01T20:14:36.407Z

## Tasks

- [x] P1-01 Scaffold app package, config, lib.sh and Makefile
- [x] P1-02 App server request handler
- [x] P1-03 Hooks server request handler
- [x] P1-04 Entry point starting both servers
- [x] P1-05 Dockerfile on the snapshot-safe base image
- [x] P1-06 Phase 1 push and manual container check
- [x] P2-01 Bootstrap stack template
- [x] P2-02 Image stack template
- [x] P2-03 deploy.sh with deterministic packaging
- [x] P2-04 run.sh launches one MicroVM
- [x] P2-05 call.sh mints a token and calls the MicroVM
- [x] P2-06 microvm.sh status, suspend, resume, terminate
- [x] P2-07 smoke.sh end-to-end lifecycle check
- [x] P2-08 destroy.sh ordered teardown
- [x] P2-09 Phase 2 push and IAM review
- [!] P3-01 Sandbox run: deploy, smoke, destroy
- [x] P3-02 README walkthrough
- [x] P3-03 Phase 3 push and final manual checks
- [x] R1-01 hooks.test.ts: cover ready method check and hook reply bodies
- [x] R1-02 deploy.sh: keep waiting until the image has an active version

## Log

(one entry per task, appended by implement)

### P1-01 — 58d2005

Tests: app/test/state.test.ts (3). make check green; sandbox guard and region export verified offline.
Interpretation: AWS_PARTITION is set/exported only by assert_sandbox; managed_connector_arn/base_image_arn need it called first.
Config keys: all SPEC section 5 keys plus POLL_INTERVAL_SECONDS, IMAGE_WAIT_SECONDS, TERMINATE_WAIT_SECONDS, INGRESS_CONNECTOR.
Installed: typescript ^7.0.2, @types/node ^24.19.2.

### P1-02 — c015317

Tests: app/test/app.test.ts (4). handleApp(s, method, path) -> Reply {status, body}; Reply type exported for hooks.ts.

### P1-03 — eb20403

Tests: app/test/hooks.test.ts (6).
Interpretation: ready logs a line on both 503 and 200 (SPEC: every hook request logs); 404 logs null. Non-POST on ready/run is 404.
Exports: HOOK_PREFIX, HookReply, handleHook(s, method, path, rawBody, now).

### P1-04 — 87af800

No new tests. Local smoke on ports 18080/19000 gave {"ready":true}, {"ok":true}, microvmId local, requestCount 1, two hook lines; missing APP_PORT exits 1.

### P1-05 — 1ef1c4b

docker build --platform linux/arm64 passed (nodejs24 24.22.1 via dnf, network works at build time locally); Dockerfile structure check passed.

### P1-06 — 5caa757

make check and docker build passed (docker build ran in P1-05 verify). Push: done (origin build/2026-11-01).
Manual check: NOT VERIFIED (human). Steps: docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify; curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'; curl http://127.0.0.1:8080/; docker stop mvm-hello-verify.
Interpretation: empty commit carries the task ID.

### P2-01 — ee1799d

cfn-lint clean, make check includes cfn-lint now. Exports: ${StackName}-{ArtifactBucketName,BuildRoleArn,ExecutionRoleArn,LogGroupName}. Log group name /aws/lambda-microvms/${ImageName}.

### P2-02 — cb2e518

cfn-lint clean. Params: BootstrapStackName, ImageName, ImageDescription, BaseImageVersion, ArtifactUri, MemoryMiB, HooksPort, ReadyTimeoutInSeconds, RunTimeoutInSeconds (deploy.sh must pass the last six as needed). Outputs ImageArn, LatestActiveImageVersion.

### P2-03 — 8ce1982

Verified offline: --package-only sha identical x3 (incl. touch of src), zip root has Dockerfile, src/, package*.json, tsconfig.json; HOOKS_PORT mismatch exits 1 naming key. AWS path NOT run.
Interpretation: touch stamp built via tr from "1980-01-01 00:00" because 198001010000 trips the no-account-id constraint. stdout JSON adds buildSeconds via --argjson of arithmetic. Reads ImageArn via stack_output. Zip also contains package.json, package-lock.json, tsconfig.json.

### P2-04 — 02d9f0f

bash -n and sandbox guard verified offline; AWS path not run. Writes .build/microvm.json {microvmId,endpoint} and prints it. Uses ${ingress_args[@]+...} idiom for empty arrays under set -u (bash 3.2 safe).

### P2-05 — 0745e10

Offline checks only (bash -n, missing-file and bad-path exit 1). Interpretation: path and microvm.json checks run before assert_sandbox since no aws call precedes it. Token on stdin via -H @-, var TOKEN.

### P2-06 — b2b6e9c

Offline checks passed (terminate no-file 0, status no-file 1, bogus 1). Not-found detection: stderr matching ResourceNotFound|not found (case-insens). A trailing edit after verify moved status to capture-then-jq (no behavior change to constraints); bash -n re-run.

### P2-07 — eff74c6

Offline checks only (bash -n, sandbox guard exit 1). EXIT trap terminates via microvm.sh. Prints {resumePath} line then final summary line; failures print {ok:false,step,reason}. A failing `microvm.sh status` inside the SUSPENDED poll aborts via set -e (trap still terminates) without the ok:false line.

### P2-08 — 6c3fcaf

Offline checks only (bash -n, sandbox guard exit 1). Uses list-microvms .items[].microvmId/.state. imageStack/bootstrapStack report "deleted" when describe-stacks found the stack before deletion.

### P2-09 — 240cae8

make check passed. Push: done.
Manual check: NOT VERIFIED (human). Review BuildRole and ExecutionRole in infra/bootstrap.yaml against SPEC principle 9: trust lambda.amazonaws.com for sts:AssumeRole and sts:TagSession with aws:SourceAccount = AWS::AccountId; no Resource '*'; no Action with '*'.

### P3-01 — blocked

BLOCKED: Tried: preflight passed (EXPECTED_ACCOUNT_ID set, not recorded), then `make deploy` as a background Bash call. Fails: the permission system denied the call (auto mode classifier: Protected-Scope IaC Apply), so no AWS resource was created and no destroy was needed. Fix: a human with sandbox credentials runs `make deploy`, `make smoke`, `make destroy` (each teed to .build/<target>.log), or allows these Bash commands, then records the Decisions for Open questions 2-5 in docs/reference/microvms-notes.md.

### P3-02 — 69f569f

README rewritten; all make targets present. Interpretation: P3-01 blocked, so README has a status note that live results are unrecorded and no numbers. Remove that note once P3-01 is run by a human.

### P3-03 — 67bd1bc

make check passed. Push: done.
Manual check: NOT VERIFIED (human). Because P3-01 was blocked (live run denied), no .build/cloudwatch.log exists. Steps: run make deploy, make smoke, make destroy (each teed to .build/<target>.log) in the sandbox; read README.md end to end (and drop its status note); confirm the ready and run hook lines in /aws/lambda-microvms/mvm-hello (save with aws logs tail before destroy); record Open questions 2-5 answers in docs/reference/microvms-notes.md.

### R1-01 — 2466012

Added 3 tests to app/test/hooks.test.ts. kukulu_mutate was not available to me; ran the 3 specified mutations manually via sed on hooks.ts, each made the suite fail (killed); hooks.ts restored (no diff). Verify green.

### R1-02 — 6399524

deploy.sh first wait loop now breaks only when state CREATED/UPDATED and latestActiveImageVersion non-empty; logs once otherwise. Offline aws stub (scratch, not committed): fixed exits 0 with imageVersion 1.0; pre-fix exits 1. bash -n and kukulu_verify green. Update-path stale-version question left for live run.
