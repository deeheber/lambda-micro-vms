# Review
Round: 6

**Verdict: APPROVED**

P3-01, the live sandbox run, is now done, and the logs back up what the implementer reported. Categories 1-3 are clean across the whole branch. No task is blocked or skipped (20 of 20 are done). PR checks pass.

Reviewed: `build/2026-11-01` against base `18029d32e177`, at head `5fb108a`.

What I checked myself:
- **Changes since `lastReviewCommit` (`afdb9a5`):** only docs and pipeline files changed.
  - `8be34e2` (P3-01) adds `## Answers from the first sandbox run` to `docs/reference/microvms-notes.md`. P3-01's "Files touched" list allows this file.
  - `7a691cc` and `875c19f` update `docs/PROGRESS.md` and `docs/HANDOFF.md`.
  - `df3786b` is an operator `kukulu_flight_options` commit. It changes `maxRounds` and `maxRoundsHard` in `docs/kukulu.json` and adds two dated lines to the `docs/PLAN.md` Decisions. The implementer did not make this edit, so it is not a boundary finding.
  - `git diff --stat 2ae6531..HEAD -- . ':!docs' ':!.kukulu'` is empty. So app, infra, scripts, Makefile, config.env and README are byte-identical to what the round 1 and round 2 reviews checked. `config.env` was not edited, because no `INGRESS_CONNECTOR` fallback was needed.
  - No `.gitignore`, `.gitattributes`, editor config or CI config changed.
- **`kukulu_verify`:** green.
  - All 19 constraints pass, with no fixture failures and no hits.
  - These pass too: npm ci, typecheck, the unit tests (16 of 16), the package.json shape check, `bash -n`, the script-header check and cfn-lint.
- **Account IDs in `docs/` and `README.md`:** the constraints do not scan these paths. A manual `\b[0-9]{12}\b` grep finds only the `198001010000` timestamp text and the `123456789012` constraint fixtures in `docs/kukulu.json`. No real account ID was recorded.
- **P3-01 evidence**, read from the gitignored `.build/` logs rather than taken from the progress log:
  - `deploy.log`:
    - The base image version resolved to 3.
    - The image stack deploy took 20:50:25Z to 20:53:02Z, and the script reported `buildSeconds` 157.
    - `imageStateAfterCfn` was `CREATED`, `imageVersion` was `1.0`, and the region in the ARN is the `config.env` region.
  - `smoke.log`:
    - The steps ran in order, and run.sh launched at 20:53:10Z.
    - `{"resumePath":"auto"}` appears, and the summary has `"ok":true` with `requestCountBefore` 1 and `requestCountAfter` 2.
  - `cloudwatch.log`:
    - `dnf install -y nodejs24` downloaded and installed 24.22.1 during the build.
    - It has two `"hook":"ready","status":200` lines (20:52:19.813Z and 20:52:19.954Z) and one `"hook":"run","status":200` line (20:53:12.399Z). The run line came about 2 s after launch.
  - `destroy.log`:
    - The four steps ran in principle 10's order.
    - The output was `{"terminated":[],"imageStack":"deleted","bucketEmptied":true,"bootstrapStack":"deleted"}`. `terminated` is empty because smoke's explicit terminate had already run.
  - All three P3-01 acceptance tests are met, and the four Decisions in the progress log match the logs.
- **PR checks** (`prChecks` from `kukulu_status`): state `pass`, no failing checks.
- **Mutation sampling:** I ran none this round, for two reasons.
  - The last fix round (P3-01) touched no source file, so `git diff --name-only afdb9a5..HEAD` lists nothing to mutate.
  - This review's round (6) is past `review.mutationFixRounds` (2), so a survivor could only go in Notes.
  - Every module was mutation-sampled in rounds 1 and 2, and none of that code has changed since.
- **Clean-room mode:** off (`cleanroom` is null in `kukulu_status`), so there are no denials to audit.

## Findings

None in categories 1-8. Two residues that do not block approval are under Notes, and the human has them as manual checks: the stale README status line and the wording for Open question 2.

## Blocked tasks

None. P3-01 went from blocked to done in round 5. The operator changed the permission setup, and `make deploy`, `make smoke` and `make destroy` each exited 0 on the first try.

## Interpretation choices (HANDOFF.md)

- **Round 1 choices:** P1-01, P1-03, P2-03, P2-05, the phase-end empty commits and the P3-02 README status note. I assessed these in round 1 and found them consistent with SPEC. They are unchanged.
- **R1-01 and R1-02:** assessed in round 2 and found consistent with SPEC. They are unchanged.
- **Round 5 (P3-01):** the commit records `Interpretation: none`, and I found nothing that needed one. The task stayed within its files, and it changed no code or config.

## Spec issues

- **Resolved: SPEC Phase 3 assumed the agent could run an IaC apply.** Rounds 0-4 were denied. Round 5 ran after the operator changed the permission setup. Future flights should be launched with that permission in place from the start, or SPEC should say that the operator grants it before Phase 3.
- **Still open: PLAN P2-03 and the `no-account-id` constraint disagree.**
  - The plan prescribes `touch -t 198001010000` literally, and that matches `\b[0-9]{12}\b`.
  - The implementer built the stamp with `tr` instead (`scripts/deploy.sh:55`). That works, but the rule still flags any 12-digit run, timestamps included.
  - Either the plan should prescribe a form the rule allows, or the rule should exempt it.
- **Still open: scripts have no offline test net beyond `bash -n` and the constraints.**
  - SPEC section 2 forbids tooling beyond `tsc` and `node --test`, so any mutation in `scripts/*.sh` survives offline by construction.
  - The live run is now the only behavioral evidence for the scripts. To cover them offline, change SPEC section 2 to allow a committed aws-stub harness.
- **Partly open: Open question 2, the update path.**
  - The live run answered the create path: CloudFormation returned after `CREATED`.
  - It did not exercise a re-deploy with changed source. So it is still unknown whether CloudFormation returns while the image still reads `UPDATED` from the previous deploy, with a stale `latestActiveImageVersion`.
  - If it does, both waits in deploy.sh pass on the old version, and the `imageVersion` the script prints is stale.

## Manual checks still owed

- **Phase 1** (from HANDOFF.md):
  1. `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`
  2. `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'`
  3. `curl http://127.0.0.1:8080/`
  4. `docker stop mvm-hello-verify`
- **Phase 2:** review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against principle 9. The reviewer read them in round 1 and found them compliant, but the human check is still owed. The live run gave more evidence: the build role was assumed and the build logged to CloudWatch.
- **Phase 3:**
  - Read `README.md` end to end.
  - Confirm the `ready` and `run` hook lines in `.build/cloudwatch.log`. The log group was deleted by `make destroy`. The lines are at `cloudwatch.log:71-73`.
  - Confirm in the sandbox console that no `mvm-hello*` stacks or MicroVMs remain (from HANDOFF round 5).
  - **Delete the stale status line at `README.md:7`.** It still says the live sandbox run "has not been recorded yet". Optionally replace it with the recorded results, as PLAN P3-02 allows: image build about 157 s on base image version 3, and `resumePath` `auto`.
- **Open question 2:** on a later re-deploy with changed source, check whether the image passes through `UPDATING` and whether `imageVersion` advances.

## Notes

- **`README.md:7` is stale.** The README was written in P3-02 before P3-01 ran, and P3-01's file list did not include README.md. So no task owned removing the status note. The round 5 review and HANDOFF had already given this to the human, and it is listed under Manual checks above.
  - This is not a fix task, because it is a one-line documentation residue and not a category 1-3 finding.
- **The Open question 2 wording overstates what was tested.** The new bullet in `docs/reference/microvms-notes.md` says "no extra polling is needed". That rests on a single create-path observation, and the update path was not exercised. Soften it to "on create" when the notes are next edited.
- **Ids left out of the progress log:** the P3-01 progress entry quotes smoke's summary JSON with the ids left out ("ids omitted"). PLAN asked for the summary JSON as printed. The full line is in `.build/smoke.log`. This is harmless.
- **Stale count in `docs/HANDOFF.md:5`:** the header still says "13 unit tests", but the suite has 16.
- **Advisory survivor in `scripts/deploy.sh:159`** (found in round 2). Reverting `[ -z "$image_version" ] || break` to `break` passes every configured verify command.
  - It is not a fix task, because SPEC section 2 forbids shell test tooling.
  - The live create-path run returned `imageVersion` `1.0`, which is consistent with the R1-02 fix.
- **Duplicate log line in `scripts/deploy.sh:160-166`.** On the first CREATED/UPDATED poll with no version yet, the loop logs both the "no active version yet" line and the generic "waiting" line. This is harmless.
- **Carried from round 1, still unchanged:**
  - `scripts/smoke.sh:68`: if `microvm.sh status` fails inside the SUSPENDED poll, the script aborts without printing the `{"ok":false,...}` line.
  - `scripts/deploy.sh:70`: uses `jq` before `require_cmd`.
  - `scripts/deploy.sh:55`: `fixed_stamp` is a global.
  - `app/src/hooks.ts:45`: the `!Array.isArray(parsed)` check is redundant.
