# Review
Round: 4

**Verdict: CHANGES REQUESTED**

P3-01, the live sandbox run, is still the only thing blocking approval. Round 3 unblocked it, and the permission system denied `make deploy` again ("Production Deploy"), the same way as in rounds 0 and 2. Categories 1-3 are clean across the branch. This round queues no fix tasks. It unblocks P3-01 once more, because that is the only submission the tool accepts. This is the third re-unblock in a row with no change to the branch content. A human operator has to act before this flight can reach APPROVED (see Blocked tasks).

Reviewed: `build/2026-11-01` against base `18029d32e177`, at head `56525cf`, plus the feedback commit `f71078b` from this review.

What I checked myself:
- **Changes since `lastReviewCommit` (`5f09618`):** only pipeline files changed: `.kukulu/state.json`, `docs/HANDOFF.md` (the round 3 section) and `docs/PROGRESS.md` (the P3-01 re-block entry).
  - No source, test, script, template, config, README or notes file changed.
  - No `.gitignore`, `.gitattributes`, editor config or CI config was edited this round.
  - The branch tree is the same one that the round 2 and round 3 reviews verified. The round 2 review re-checked R1-01 and R1-02. The round 1 review covered P1-01 to P3-03.
- **`kukulu_verify`:** green.
  - All 19 constraints pass, with no fixture failures and no hits.
  - These all pass: npm ci, typecheck, the unit tests (16 of 16), the package.json shape check, `bash -n`, the script-header check and cfn-lint.
- **PR checks** (`prChecks` from `kukulu_status`): state `pass`, no failing checks.
- **Mutation sampling:** I ran none this round, for two reasons.
  - Round 3 queued no fix tasks, so `git diff --name-only 5f09618..HEAD` lists no source files to mutate.
  - This review's round (4) is past `review.mutationFixRounds` (2), so a survivor could only go in Notes anyway.
- **The P3-01 re-block:** the implementer followed the round 3 unblock instructions.
  - It ran the preflight, tried `make deploy` once, and re-blocked as soon as the classifier denied it. It did not retry or work around the denial.
  - No AWS call ran and nothing was created, so no destroy was needed.
- **Clean-room mode:** off (`cleanroom` is null in `kukulu_status`), so there are no denials to audit.

## Findings

None in categories 1-8.

## Blocked tasks

- **P3-01 (sandbox run: deploy, smoke, destroy): the blocker is real, and no fix task can clear it.**
  - The auto-mode permission classifier has now denied `make deploy` three times: in round 0, round 2 and round 3. Each time the result was the same, and the branch did not change in between.
  - I am unblocking it again only because `kukulu_review_submit` refuses CHANGES REQUESTED without a task or an unblock. The skill forbids APPROVED while a task is blocked, and SPEC section 1 says the repo is not done until deploy, smoke and destroy pass.
  - I will not queue a task that turns the live run into a manual check, or one that adds a permission rule. The first would change what "done" means for a SPEC requirement. The second would mean the agent works around its own denial.
  - I logged the loop as pipeline feedback again (`f71078b`). The controller already marked round 3 `nonConverging`.
- **What unblocks it is a human operator.** Do one of these:
  - (a) Add a Bash permission rule that allows `make deploy`, `make smoke` and `make destroy` for this repo. Then let the flight continue.
  - (b) Run P3-01 yourself in the sandbox account with `EXPECTED_ACCOUNT_ID` set. Run each step on its own, and always run destroy:
    1. `bash -c 'set -o pipefail; mkdir -p .build; make deploy 2>&1 | tee .build/deploy.log'`
    2. The same for `smoke`.
    3. Save the CloudWatch logs before you destroy anything: `bash -c 'source scripts/lib.sh; assert_sandbox; aws logs tail "/aws/lambda-microvms/$IMAGE_NAME" --since 3h --format short' > .build/cloudwatch.log 2>&1`
    4. The same as step 1 for `destroy`.
  - After the run:
    - Record the answers to Open questions 2-5 under `## Answers from the first sandbox run` in `docs/reference/microvms-notes.md`, tagged `[tested <date>]`. Include the resolved base image version and the image build time.
    - Remove the README status note.
- **Until one of those happens, no round of the fix loop can reach APPROVED.**

## Interpretation choices (HANDOFF.md)

- **Round 1 choices:** P1-01, P1-03, P2-03, P2-05, the phase-end empty commits and the P3-02 README status note. I assessed these in round 1 and found them consistent with SPEC. They are unchanged.
- **R1-01 and R1-02:** assessed in round 2 and found consistent with SPEC. They are unchanged.
- **Round 2 and round 3 HANDOFF entries:** P3-01 was re-blocked with no workaround and no code changes. This is consistent with SPEC Phase 3 and with the unblock instructions.

## Spec issues

These are carried forward from round 3, and none is resolved yet.

- **SPEC Phase 3 step 1 assumes the agent can run an IaC apply, but the agent's permission policy denies it every time.**
  - SPEC section 8 Phase 3 (and PLAN P3-01) has the implementer run `make deploy/smoke/destroy`.
  - Under auto mode, the classifier has denied `make deploy` on all three attempts, so the flight cannot finish as specified.
  - Change one of two things:
    - (a) SPEC and PLAN: make the live run an operator-run manual check. The agent then only records the results the operator hands it: the Decisions, the notes section, and removing the README note.
    - (b) The flight setup: launch it with a permission rule that allows those three `make` targets.
- **PLAN P2-03 and the `no-account-id` constraint disagree.**
  - The plan prescribes `touch -t 198001010000` literally, and that matches `\b[0-9]{12}\b`.
  - The implementer built the stamp with `tr` instead (`scripts/deploy.sh:55`). That works, but the rule still flags any 12-digit run, timestamps included.
  - Either the plan should prescribe a form the rule allows, or the rule should exempt it.
- **Scripts have no offline test net beyond `bash -n` and the constraints.**
  - SPEC section 2 forbids tooling beyond `tsc` and `node --test`, so any mutation in `scripts/*.sh` survives by construction.
  - To cover the scripts, change SPEC section 2 to allow a committed aws-stub harness.
- **Open question 2, the update path.**
  - Suppose CloudFormation returns while the image still reads `UPDATED` from the previous deploy, and `latestActiveImageVersion` still holds the old version.
  - Both waits in deploy.sh then pass on the old version, and the `imageVersion` the script prints is stale.
  - Whoever runs P3-01 should check whether the image passes through `UPDATING` on a re-deploy with changed source.

## Manual checks still owed (from HANDOFF.md)

- Phase 1:
  - `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`
  - `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'`
  - `curl http://127.0.0.1:8080/`
  - `docker stop mvm-hello-verify`
- Phase 2: review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against principle 9. The reviewer read them in round 1 and found them compliant, but the human check is still owed.
- Phase 3, with sandbox credentials:
  - Run `make deploy`, `make smoke` and `make destroy`, each teed to `.build/<target>.log`.
  - Save the `aws logs tail` output before destroy.
  - Confirm the `ready` and `run` lines.
  - Record Open questions 2-5 in `docs/reference/microvms-notes.md`.
  - Remove the README status note.
  - Read README.md end to end.
- R1-02: during the live run, check the update path for a stale image version (Open question 2).

## Notes

- **Advisory survivor in `scripts/deploy.sh:159`** (found in round 2). Reverting `[ -z "$image_version" ] || break` to `break` passes every configured verify command.
  - It is not a fix task, because SPEC section 2 forbids shell test tooling.
  - The reviewer's scratch stub run in round 2 showed that the R1-02 fix works.
- **Duplicate log line in `scripts/deploy.sh:160-166`.** On the first CREATED/UPDATED poll with no version yet, the loop logs both the "no active version yet" line and the generic "waiting" line. This is harmless.
- **The `.gitignore` line on the branch** (`.kukulu/implement.lock`) came from the pipeline commit `ee78bd0 chore: start implementation run`, not from a task. It is not a boundary finding.
- **Carried from round 1, still unchanged:**
  - `scripts/smoke.sh:68`: if `microvm.sh status` fails inside the SUSPENDED poll, the script aborts without printing the `{"ok":false,...}` line.
  - `scripts/deploy.sh:70`: uses `jq` before `require_cmd`.
  - `scripts/deploy.sh:55`: `fixed_stamp` is a global.
  - `app/src/hooks.ts:45`: the `!Array.isArray(parsed)` check is redundant.
