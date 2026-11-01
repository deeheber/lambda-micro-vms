# Review
Round: 2

**Verdict: CHANGES REQUESTED**

The only thing blocking approval is P3-01, the live sandbox run. It is still blocked by the permission system, and the agent loop can't clear that block. Categories 1-3 are clean across the branch. This round queues no code fix tasks. I unblocked P3-01 only because the submit tool requires a task or an unblock (see Blocked tasks).

Reviewed: `build/2026-11-01` against base `18029d32e177`. This round covers the round 1 fixes (`821d720..HEAD`: R1-01 `2466012` and R1-02 `6399524`) against `docs/SPEC.md`, `docs/PLAN.md` (Review fixes, round 1) and CLAUDE.md. Round 1's review of P1-01 to P3-03 still stands, and no code in those tasks has changed since.

What I checked myself:
- **`kukulu_verify`:** green.
  - All 19 constraints pass, with no fixture failures and no hits.
  - npm ci, typecheck, unit tests (16, up from 13), the package.json shape check, `bash -n`, the script-header check and cfn-lint all pass.
- **PR checks** (`prChecks` from `kukulu_status`): `pass`, with no failing checks.
- **Files changed since `lastReviewCommit` (821d720):**
  - `app/test/hooks.test.ts` and `scripts/deploy.sh`;
  - plus pipeline files (`.kukulu/state.json`, `docs/HANDOFF.md`, `docs/PROGRESS.md`).
  - No `.gitignore`, `.gitattributes`, editor config or CI config was edited.
- **R1-01:**
  - The three tests named in the plan exist and call `handleHook` directly on `createState()`.
  - They import only `node:*` and relative `.ts` files, and `app/src/hooks.ts` is unchanged.
  - The implementer applied the three mutations by hand because it couldn't use `kukulu_mutate`. I re-ran all three with `kukulu_mutate` (see the table): each was killed by the test written for it, and every kill was confirmed.
- **R1-02:**
  - `scripts/deploy.sh:157-164`: the first wait loop now breaks only when the state is CREATED/UPDATED and `latestActiveImageVersion` is non-empty.
  - It logs once otherwise, and keeps the same `deadline`, `POLL_INTERVAL_SECONDS` and `*_FAILED` handling.
  - No literal tunables, line 2 is unchanged, and `assert_sandbox` still comes before the first `aws` call.
  - I didn't trust the log, so I re-ran the offline aws-stub test from R1-02's acceptance criteria myself. It ran in a scratch copy with a stub `aws` on PATH, so no real AWS call was made.
    - Fixed `deploy.sh`: exit 0, `"imageVersion": "1.0"`, with the one-time "no active version yet" line.
    - Pre-fix `deploy.sh` (`6399524^`): exit 1, after the stub refused the empty `--image-version`.
  - The packaging code is untouched, so the `--package-only` sha is unaffected.

Mutation sample (targeted `unit` runner for hooks.ts; full verify set for deploy.sh):

| File | Mutation | Result |
|---|---|---|
| app/src/hooks.ts | ready: drop `method === "POST" &&` | killed (confirmed): `a non-POST request to ready returns 404 and logs nothing` |
| app/src/hooks.ts | `body: { ready: s.appListening }` to `{ ready: true }` | killed (confirmed): `ready returns body ready false at 503 and ready true at 200` |
| app/src/hooks.ts | `body: { ok: true }` to `{ ok: false }` | killed (confirmed): `run returns body ok true` |
| scripts/deploy.sh | `[ -z "$image_version" ] \|\| break` to `break` | survived (advisory, see Notes) |

## Findings

None in categories 1-8 for this round's changes.

## Blocked tasks

- **P3-01 (sandbox run: deploy, smoke, destroy): the blocker is real. I unblocked it anyway, because the submit tool gave me no other option.**
  - The auto-mode permission classifier denied `make deploy` ("Protected-Scope IaC Apply"), and nothing about that has changed.
  - `kukulu_review_submit` refuses CHANGES REQUESTED unless the submission has a fix task or an unblock, and APPROVED is not allowed while a task is blocked. With no code findings, unblocking P3-01 was the only submission the tool accepts. I logged this as pipeline feedback.
  - Round 1 had a second reason not to unblock: R1-02 would run after it. That reason no longer applies, because R1-02 has landed and I've verified it offline.
  - The implementer should run the preflight and then `make deploy` once. If permission is denied again, it should re-block straight away with the same reason and make no further attempts.
- **What unblocks it: a human operator.** Either:
  - (a) allow the Bash permission for the three `make` targets, then re-queue P3-01; or
  - (b) run it yourself in the sandbox account with `EXPECTED_ACCOUNT_ID` set. Run each step on its own and always destroy:
    1. `bash -c 'set -o pipefail; mkdir -p .build; make deploy 2>&1 | tee .build/deploy.log'`
    2. The same for `smoke`.
    3. Save the CloudWatch logs before destroying: `bash -c 'source scripts/lib.sh; assert_sandbox; aws logs tail "/aws/lambda-microvms/$IMAGE_NAME" --since 3h --format short' > .build/cloudwatch.log 2>&1`
    4. The same for `destroy`.
  - After the run, record the answers to Open questions 2-5 (plus the base image version and the build time) under `## Answers from the first sandbox run` in `docs/reference/microvms-notes.md`, tagged `[tested <date>]`. Then remove the README status note.
- **No round of fix tasks can reach APPROVED while P3-01 is blocked.**

## Interpretation choices (HANDOFF.md)

- **Round 1 choices (P1-01, P1-03, P2-03, P2-05, phase-end empty commits, P3-02 README status note):** I assessed these in round 1 and found them consistent with SPEC; they are unchanged. The non-POST-on-ready behaviour from P1-03 is now tested (R1-01).
- **R1-01, mutations run by hand:** resolved. `kukulu_mutate` reproduces all three kills (table above).
- **R1-02, logs once when there is no active version yet and reuses the same deadline:** consistent with SPEC section 4 and with the R1-02 design constraints.
- **R1-02, update-path stale-version question left for the live run:** consistent, since R1-02 put it out of scope. It remains under Spec issues below.

## Spec issues

Carried forward from round 1; none are resolved yet.

- **PLAN P2-03 and the `no-account-id` constraint disagree.**
  - The plan prescribes `touch -t 198001010000` literally, and that matches `\b[0-9]{12}\b`.
  - The implementer built the stamp with `tr` (`scripts/deploy.sh:55`). That works, but the rule flags any 12-digit run, timestamps included.
  - Either the plan should prescribe a form the rule allows, or the rule should exempt it.
- **Scripts have no offline test net beyond `bash -n` and the constraints.**
  - SPEC section 2 forbids tooling beyond `tsc` and `node --test`, so any mutation in `scripts/*.sh` survives by construction. This round's deploy.sh survivor shows it again.
  - Until the live P3-01 run, the only behavioral check on R1-02 is the reviewer's uncommitted stub run.
  - If you want the scripts covered, change SPEC section 2 to allow a committed aws-stub harness.
- **Open question 2, update path.**
  - Suppose CloudFormation returns while the image still reads `UPDATED` from the previous deploy, and `latestActiveImageVersion` still holds the old version. Both waits then pass on the old version, and `imageVersion` in deploy.sh's JSON is stale.
  - R1-02 doesn't cover this. Whoever runs P3-01 should check whether the image passes through `UPDATING` when you re-deploy with changed source.

## Manual checks still owed (from HANDOFF.md)

- Phase 1:
  - `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`
  - `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'`
  - `curl http://127.0.0.1:8080/`
  - `docker stop mvm-hello-verify`
- Phase 2: review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against principle 9. The reviewer read them in round 1 and found them compliant, but the human check is still owed.
- Phase 3, with sandbox credentials:
  - run `make deploy`, `make smoke` and `make destroy`, each teed to `.build/<target>.log`;
  - save the `aws logs tail` output before destroy;
  - confirm the `ready` and `run` lines;
  - record Open questions 2-5 in `docs/reference/microvms-notes.md`;
  - remove the README status note;
  - read README.md end to end.
- R1-02: the update-path stale-version check (Open question 2), during the live run.

## Notes

- **Advisory survivor in `scripts/deploy.sh:159`.** Reverting `[ -z "$image_version" ] || break` to `break` passes every configured verify command.
  - It is not a fix task. R1-02 puts committing shell test tooling out of scope, and SPEC section 2 forbids it, so no task could kill this mutant.
  - The reviewer's scratch stub run (above) shows the fix works.
- **Duplicate log line in `scripts/deploy.sh:160-166`.** On the first CREATED/UPDATED poll with no version yet, the loop logs "image state CREATED but no active version yet; waiting" and then the generic "image state CREATED; waiting" on the same pass. It's harmless and cosmetic.
- **Carried from round 1.** These still apply and are unchanged:
  - `scripts/smoke.sh:68`: a failing `microvm.sh status` inside the SUSPENDED poll aborts without the `{"ok":false,...}` line.
  - `scripts/deploy.sh:70`: uses `jq` before `require_cmd`.
  - `scripts/deploy.sh:55`: `fixed_stamp` is a global.
  - `app/src/hooks.ts:45`: the redundant `!Array.isArray(parsed)`.
