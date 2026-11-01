# Review
Round: 1

**Verdict: CHANGES REQUESTED**

Reviewed: `build/2026-11-01` against base `18029d32e177`, every task commit P1-01 to P3-03, plus `docs/SPEC.md` v0.2 and `docs/PLAN.md`.

What I checked myself:
- `kukulu_verify`: green. All 19 constraints pass, with no fixture failures and no hits. npm ci, typecheck, 13 unit tests, the package.json shape check, `bash -n`, the script-header check and cfn-lint all pass.
- PR checks: `pass`.
- I read every script for the ordering rules that can't be grepped:
  - `assert_sandbox` comes before the first `aws` call in deploy, run, call, microvm, smoke and destroy.
  - Both servers bind `0.0.0.0`.
  - `instanceId` is `null` at load and set only in the run handler.
  - Both roles trust `lambda.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession` with the `aws:SourceAccount` condition.
  - smoke's `EXIT` trap is set.
  - destroy runs principle 10's four steps in order.
- I checked CLI output field names offline with `aws lambda-microvms <cmd> help`. These all match what the scripts read: `items[].microvmId/state`, `latestActiveImageVersion`, `state`/`status`/`stateReason` on image versions, and the `authToken` map.

Mutation sample (targeted `unit` runner; cfn-lint for infra):

| File | Mutation | Result |
|---|---|---|
| app/src/hooks.ts | ready: drop the `method === "POST"` check | **survived** |
| app/src/hooks.ts | ready body `{ ready: s.appListening }` to `{ ready: true }` | **survived** |
| app/src/hooks.ts | run body `{ ok: true }` to `{ ok: false }` | **survived** |
| app/src/hooks.ts | ready status always 200 | killed (confirmed) |
| app/src/hooks.ts | `instanceId = randomUUID()` to a constant | killed (confirmed) |
| app/src/hooks.ts | `typeof id === "string"` to `id !== undefined` | killed (confirmed) |
| app/src/app.ts | delete `s.requestCount += 1` | killed (confirmed) |
| app/src/app.ts | drop the `method === "GET"` check | killed (confirmed) |
| app/src/state.ts | `instanceId: null` to `"baked"` | killed (confirmed) |
| infra/image.yaml | delete `AdditionalOsCapabilities: []` | killed (cfn-lint E3003) |

## Findings

### 1. Category 3 (tests): hooks.ts mechanics no test covers. Fix task R1-01 (source: mutation)

- `app/src/hooks.ts:33`: the `ready` route ignores the HTTP method under test. Removing `method === "POST" &&` leaves every test green. SPEC section 6 defines `POST …/ready`, and PLAN Decisions say a non-POST to a hook path is 404 with no log. `app/test/hooks.test.ts:48` checks this only for `GET run`.
  - What breaks: a `GET` to `ready` could answer 200 and write a hook log line, and nothing would notice.
- `app/src/hooks.ts:37`: the `ready` reply body (`{ ready: false }` at 503, `{ ready: true }` at 200, per PLAN P1-03) is never asserted.
- `app/src/hooks.ts:57`: the `run` reply body `{ ok: true }` is never asserted.
- Minimal fix: add tests to `app/test/hooks.test.ts` only. No change to `hooks.ts`.

### 2. Category 5 (spec drift): deploy.sh stops waiting before an active image version exists. Fix task R1-02 (source: review)

- `scripts/deploy.sh:146-178`: the first wait loop breaks as soon as `state` is `CREATED` or `UPDATED`, whether or not `latestActiveImageVersion` is set (line 149 maps a missing value to `""`). The second loop then calls `get-microvm-image-version --image-version ""`.
  - SPEC section 4 says deploy.sh waits for CREATED/UPDATED, *then* for its LatestActiveImageVersion to be SUCCESSFUL and ACTIVE.
  - `docs/reference/microvms-notes.md` says image state, version state and version activation are independent. So CREATED with no active version yet is a real possibility. It is exactly what Open question 2 asks.
- What would break: the first live `make deploy` could exit non-zero with a CLI parameter-validation error while the build is still in progress, instead of waiting. P3-01 would then block on a script bug rather than a service answer.
- Minimal fix: in the first loop, `break` only when the state is CREATED/UPDATED **and** `image_version` is non-empty. Keep polling within the same `deadline`, keep the `_FAILED` handling, and `log` when the image is created but has no active version yet. This should land before a human runs P3-01.

## Blocked tasks

- **P3-01 (sandbox run: deploy, smoke, destroy): the blocker is real. I did not unblock it.**
  - The auto-mode permission classifier denied `make deploy` ("Protected-Scope IaC Apply"). No resource was created.
  - No fix task, plan change or spec change can clear it. Unblocking would only repeat the denial. It would also run before R1-02, because fix tasks are appended after it.
  - What unblocks it is a human operator. Either:
    - (a) grant the Bash permission for the three `make` targets and re-queue P3-01; or
    - (b) run it yourself in the sandbox account with `EXPECTED_ACCOUNT_ID` set, after R1-02 is merged into the branch. Run each step on its own and always destroy:
      - `bash -c 'set -o pipefail; mkdir -p .build; make deploy 2>&1 | tee .build/deploy.log'`
      - then the same for `smoke`
      - save CloudWatch before destroying: `bash -c 'source scripts/lib.sh; assert_sandbox; aws logs tail "/aws/lambda-microvms/$IMAGE_NAME" --since 3h --format short' > .build/cloudwatch.log 2>&1`
      - then the same for `destroy`
    - After the run:
      - record the answers to Open questions 2-5 (plus base image version and build time) under `## Answers from the first sandbox run` in `docs/reference/microvms-notes.md`, tagged `[tested <date>]`;
      - drop the README status note.
- **APPROVED can't be reached until that happens, however many fix rounds pass**, because approval requires no blocked tasks.

## Interpretation choices (HANDOFF.md)

- P1-01, `AWS_PARTITION` exported only by `assert_sandbox`: consistent. Every caller of `managed_connector_arn`/`base_image_arn` (deploy.sh, run.sh) calls `assert_sandbox` first.
- P1-03, `ready` logs on 503 as well as 200; non-POST is 404: consistent with "every hook request writes one stdout line". The non-POST-on-ready part is untested (finding 1).
- P2-03, zip stamp built with `tr`; zip also holds `package.json`, `package-lock.json`, `tsconfig.json`: consistent with PLAN P2-03. The workaround is needed because the constraint and the plan disagree (see Spec issues).
- P2-05, `call.sh` checks the path and file before `assert_sandbox`: consistent. No `aws` call comes before it.
- P1-06, P2-09, P3-03, empty phase-end commits: fine.
- P3-02, README status note and no measurements: correct while P3-01 is blocked. The note must be removed after the live run.

## Spec issues

- **PLAN P2-03 and the `no-account-id` constraint disagree.** The plan prescribes `touch -t 198001010000` literally, which matches `\b[0-9]{12}\b`. The implementer built the stamp with `tr` (`scripts/deploy.sh:55`). That is correct behavior, but the rule flags any 12-digit run, including timestamps. Either the plan should prescribe a form the rule allows, or the rule should exempt it.
- **Scripts have no offline test net beyond `bash -n` and the constraints.** SPEC section 2 forbids tooling beyond `tsc` and `node --test`, so script logic can't be mutation-tested offline. A mutation in any `scripts/*.sh` survives by construction. The live P3-01 run is the only behavioral test of the scripts, which makes the human run above more important.
- **Open question 2, update path.** If CloudFormation returns while the image still reads `UPDATED` from the previous deploy and `latestActiveImageVersion` is still the old version, both waits pass on the old version and `imageVersion` in deploy.sh's JSON is stale. R1-02 doesn't cover this. P3-01's operator should check whether the image passes through `UPDATING` on a re-deploy with changed source.

## Manual checks still owed (from HANDOFF.md)

- Phase 1:
  - `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`
  - `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'`
  - `curl http://127.0.0.1:8080/`
  - `docker stop mvm-hello-verify`
- Phase 2: review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against principle 9. The reviewer read them and found them compliant; the human check is still owed.
- Phase 3, with sandbox credentials:
  - run `make deploy`, `make smoke`, `make destroy`, each teed to `.build/<target>.log`;
  - save `aws logs tail` before destroy;
  - confirm the `ready` and `run` lines;
  - record Open questions 2-5 in `docs/reference/microvms-notes.md`;
  - drop the README status note;
  - read README.md end to end.

## Notes

- `.gitignore` gained `.kukulu/implement.lock` in `ee78bd0 chore: start implementation run`. That commit is the pipeline's own, not an implementer edit, so it is not a boundary finding.
- `scripts/smoke.sh:68`: if `microvm.sh status` fails inside the SUSPENDED poll, `set -e` aborts without printing the `{"ok":false,...}` line. The trap still terminates and the exit is non-zero. The implementer flagged this.
- `scripts/deploy.sh:70` uses `jq` in the `--package-only` path before any `require_cmd jq`. `require_cmd aws jq zip` (line 76) also runs after `assert_sandbox`, which itself needs `aws` and `jq`. Cosmetic: a missing tool gives a shell error rather than the friendly message.
- `scripts/deploy.sh:55`: `fixed_stamp` is a global set inside `package_app`. Harmless.
- `app/src/hooks.ts:46`: `!Array.isArray(parsed)` is redundant, since a JSON array has no `microvmId` property. Removing it is an equivalent mutant, so it was not counted as a survivor.
