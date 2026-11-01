# Review
Round: 3

**Verdict: CHANGES REQUESTED**

The only thing blocking approval is still P3-01, the live sandbox run. Round 2 unblocked it, and the permission system denied `make deploy` again within a minute, the same way as before. Categories 1-3 are clean across the branch. This round queues no fix tasks and unblocks P3-01 once more, because that is the only submission the tool accepts. A human operator has to act before this flight can reach APPROVED (see Blocked tasks).

Reviewed: `build/2026-11-01` against base `18029d32e177`, with head `a36480b` (plus the feedback commit `fcd4256` from this review).

What I checked myself:
- **Changes since `lastReviewCommit` (`2ae6531`):** only pipeline files changed: `.kukulu/state.json`, `docs/HANDOFF.md` and `docs/PROGRESS.md` (the P3-01 re-block entry).
  - No source, test, script, template, config, README or notes file changed.
  - No `.gitignore`, `.gitattributes`, editor config or CI config was edited.
  - The branch content is the same tree that the round 2 review verified. That review re-checked R1-01 and R1-02, and the round 1 review covered P1-01 to P3-03.
- **`kukulu_verify`:** green.
  - All 19 constraints pass, with no fixture failures and no hits.
  - npm ci, typecheck, unit tests (16 of 16 pass), the package.json shape check, `bash -n`, the script-header check and cfn-lint all pass.
- **PR checks** (`prChecks` from `kukulu_status`): `pass`, with no failing checks.
- **Mutation sampling:** none this round, for two reasons.
  - Round 2 queued no fix tasks, so `git diff --name-only 2ae6531..HEAD` lists no source files to mutate.
  - This review's round (3) is past `review.mutationFixRounds` (2), so a survivor could only go in Notes anyway.
- **The P3-01 re-block:** the implementer followed the round 2 unblock instructions.
  - It ran the preflight and tried `make deploy` once. The permission classifier denied it before it ran, and the implementer re-blocked immediately without retrying or working around the denial.
  - Nothing was created, so no destroy was needed.
- **Clean-room mode:** off (`cleanroom` is null in `kukulu_status`), so there are no denials to audit.

## Findings

None in categories 1-8.

## Blocked tasks

- **P3-01 (sandbox run: deploy, smoke, destroy): the blocker is real, and no fix task can clear it.**
  - Twice in a row (rounds 0 and 2), the auto-mode permission classifier denied `make deploy` as an IaC apply, with the same result each time and no branch change in between.
  - I am unblocking it again only because `kukulu_review_submit` refuses CHANGES REQUESTED without a task or an unblock. The skill also forbids APPROVED while a task is blocked, and SPEC section 1 says the repo is not done until deploy, smoke and destroy pass.
  - The implementer should try `make deploy` at most once, following the sandbox-run protocol. If the permission system denies it, it should re-block at once with the same reason: no retry, no workaround.
  - I logged the loop as pipeline feedback again.
- **What unblocks it is a human operator.** Do one of these:
  - (a) Add a Bash permission rule that allows `make deploy`, `make smoke` and `make destroy` for this repo, then let the flight continue.
  - (b) Run P3-01 yourself in the sandbox account with `EXPECTED_ACCOUNT_ID` set. Run each step on its own, and always run destroy:
    1. `bash -c 'set -o pipefail; mkdir -p .build; make deploy 2>&1 | tee .build/deploy.log'`
    2. The same for `smoke`.
    3. Save the CloudWatch logs before destroying: `bash -c 'source scripts/lib.sh; assert_sandbox; aws logs tail "/aws/lambda-microvms/$IMAGE_NAME" --since 3h --format short' > .build/cloudwatch.log 2>&1`
    4. The same as step 1 for `destroy`.
  - After the run, record the answers to Open questions 2-5 (plus the resolved base image version and the image build time) under `## Answers from the first sandbox run` in `docs/reference/microvms-notes.md`, tagged `[tested <date>]`. Then remove the README status note.
- **Until one of those happens, no round of the fix loop can reach APPROVED.**

## Interpretation choices (HANDOFF.md)

- **Round 1 choices (P1-01, P1-03, P2-03, P2-05, the phase-end empty commits, the P3-02 README status note):** I assessed these in round 1 and found them consistent with SPEC. They are unchanged.
- **R1-01 and R1-02:** I assessed these in round 2 and found them consistent with SPEC. They are unchanged.
- **Round 2 HANDOFF (P3-01 re-blocked, no workaround, no code changes):** this is consistent with SPEC Phase 3 and with the round 2 unblock instructions.

## Spec issues

Carried forward from round 2, none resolved yet, plus one new issue.

- **New: SPEC Phase 3 step 1 assumes the agent can run an IaC apply, but the agent's permission policy denies it every time.**
  - SPEC section 8 Phase 3 (and PLAN P3-01) has the implementer run `make deploy/smoke/destroy`. Under auto mode, the classifier denies `make deploy` on every attempt, so the flight cannot finish as specified.
  - Change one of two things:
    - (a) SPEC and PLAN: make the live run an operator-run manual check, and reduce the agent's role to recording the results the operator hands it (the Decisions, the notes section, removing the README note); or
    - (b) the flight setup: launch it with a permission rule that allows those three `make` targets.
- **PLAN P2-03 and the `no-account-id` constraint disagree.**
  - The plan prescribes `touch -t 198001010000` literally, and that matches `\b[0-9]{12}\b`.
  - The implementer built the stamp with `tr` (`scripts/deploy.sh:55`). That works, but the rule flags any 12-digit run, timestamps included.
  - Either the plan should prescribe a form the rule allows, or the rule should exempt it.
- **Scripts have no offline test net beyond `bash -n` and the constraints.**
  - SPEC section 2 forbids tooling beyond `tsc` and `node --test`, so any mutation in `scripts/*.sh` survives by construction.
  - If you want the scripts covered, change SPEC section 2 to allow a committed aws-stub harness.
- **Open question 2, update path.**
  - Suppose CloudFormation returns while the image still reads `UPDATED` from the previous deploy, and `latestActiveImageVersion` still holds the old version. Both waits in deploy.sh then pass on the old version, and the `imageVersion` it prints is stale.
  - Whoever runs P3-01 should check whether the image passes through `UPDATING` when you re-deploy with changed source.

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
- R1-02: during the live run, check the update path for a stale image version (Open question 2).

## Notes

- **Advisory survivor in `scripts/deploy.sh:159`** (found in round 2). Reverting `[ -z "$image_version" ] || break` to `break` passes every configured verify command.
  - It is not a fix task: SPEC section 2 forbids shell test tooling.
  - The reviewer's scratch stub run in round 2 showed that the R1-02 fix works.
- **Duplicate log line in `scripts/deploy.sh:160-166`.** On the first CREATED/UPDATED poll with no version yet, the loop logs both the "no active version yet" line and the generic "waiting" line. It's harmless and cosmetic.
- **Carried from round 1.** These still apply and are unchanged:
  - `scripts/smoke.sh:68`: a failing `microvm.sh status` inside the SUSPENDED poll aborts without the `{"ok":false,...}` line.
  - `scripts/deploy.sh:70`: uses `jq` before `require_cmd`.
  - `scripts/deploy.sh:55`: `fixed_stamp` is a global.
  - `app/src/hooks.ts:45`: the redundant `!Array.isArray(parsed)`.
