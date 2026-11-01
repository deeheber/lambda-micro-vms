# Handoff

- Branch: `build/2026-11-01`, base `main` (merge-base from `git merge-base HEAD main`).
- Tasks: 18 total; 17 done, 1 blocked (P3-01), 0 skipped.
- Offline checks: `kukulu_verify` and `make check` are green (13 unit tests, typecheck, cfn-lint, script syntax, all constraints, arm64 Docker build).

## Blocked tasks

- P3-01 (sandbox run: deploy, smoke, destroy): BLOCKED: the permission system denied `make deploy` (auto mode classifier, "Protected-Scope IaC Apply"). No AWS resource was created, so no destroy was needed. No live script path (`deploy.sh`, `run.sh`, `call.sh`, `microvm.sh`, `smoke.sh`, `destroy.sh`) has ever been executed against AWS; only offline checks ran. Open questions 2-5 in SPEC section 9 are unanswered, and `docs/reference/microvms-notes.md` has no "Answers from the first sandbox run" section.

## Interpretation choices

- P1-01: `AWS_PARTITION` is exported only by `assert_sandbox`; `managed_connector_arn` and `base_image_arn` need it called first.
- P1-03: the `ready` hook logs a line on both 503 and 200; non-POST requests to hook paths are 404.
- P2-03: the zip mtime stamp is built with `tr` from `1980-01-01 00:00`, because the literal 12-digit form trips the `no-account-id` constraint. The zip also contains `package.json`, `package-lock.json` and `tsconfig.json`.
- P2-05: `call.sh` checks the path and `microvm.sh` file before `assert_sandbox` (no AWS call precedes it), so the "run make run first" message is reachable without `EXPECTED_ACCOUNT_ID`.
- P1-06, P2-09, P3-03: phase-end tasks used empty commits carrying the task ID.
- P3-02: README has a status note that the live run is unrecorded and quotes no measurements.

## Config keys (SPEC section 5 defaults, none tuned)

All keys in `config.env` are at their SPEC defaults; none were tuned because no live run happened. Plan-added keys: `POLL_INTERVAL_SECONDS=5`, `IMAGE_WAIT_SECONDS=1800`, `TERMINATE_WAIT_SECONDS=120`, `INGRESS_CONNECTOR=` (empty; fallback is `HTTP_INGRESS`, see Open question 4).

## Manual checks (NOT VERIFIED, human)

- Phase 1: `docker run -d --rm --name mvm-hello-verify -p 8080:8080 -p 9000:9000 mvm-hello:verify`; `curl --retry 10 --retry-connrefused -XPOST http://127.0.0.1:9000/aws/lambda-microvms/runtime/v1/run -d '{"microvmId":"local"}'`; `curl http://127.0.0.1:8080/`; `docker stop mvm-hello-verify`.
- Phase 2: review `BuildRole` and `ExecutionRole` in `infra/bootstrap.yaml` against principle 9.
- Phase 3: with sandbox credentials, run `make deploy`, `make smoke`, `make destroy` (each teed to `.build/<target>.log`, save `aws logs tail` before destroy), confirm `ready` and `run` lines, record Open questions 2-5 in `docs/reference/microvms-notes.md`, and drop the README status note.

## Codebase notes

- Constraint `no-account-id` matches any 12-digit run, including timestamps like `198001010000`; build such values from parts.
- Constraint `no-run-hook-payload` scans comments too; never name the run hook payload field in `app/src/` or `scripts/`.
- Under `set -e`, a failure inside a `< <(...)` process substitution is not seen; capture command output into a variable first.
- bash 3.2 (macOS) and `set -u`: expand optional arrays as `${arr[@]+"${arr[@]}"}`.
- `npm install typescript@^7` resolved to 7.0.2 and `tsc --noEmit` works with `erasableSyntaxOnly` and Node 24 type stripping.

## For the reviewer

- Unverified against the real service: CLI response field names were checked only through `aws lambda-microvms <cmd> help`. The most likely live failures are in `deploy.sh` waits (state names), `run.sh` option shapes (connector list args) and `smoke.sh` timing.

## Round 1

Both fix tasks done; counts: 19 done, 1 blocked, 0 open.

- R1-01 (app/test/hooks.test.ts): added tests for the ready POST-only check, ready reply bodies and run reply body. kukulu_mutate was not available to the implementer, so the three specified mutations were applied by hand with sed; each made the suite fail (killed). hooks.ts is unchanged.
- R1-02 (scripts/deploy.sh): the first wait loop now breaks only when the image state is CREATED/UPDATED and latestActiveImageVersion is non-empty, with a one-time log line otherwise. Checked with an offline aws stub (not committed): fixed script exits 0 with imageVersion 1.0, pre-fix script exits 1.
- Not verified: the update-path stale-version question (SPEC Open question 2) is left for the live run. Manual check: NOT VERIFIED (human).

## Round 2

Counts: 19 done, 1 blocked (P3-01), 0 open. Head 4ace9ab.

- P3-01 (sandbox deploy, smoke, destroy) is BLOCKED: preflight passed (EXPECTED_ACCOUNT_ID set), but the permission classifier denied `make deploy` as a production deploy before it ran. Nothing was created, so no destroy was needed. I did not work around the denial.
- Open questions 2-5 stay unanswered. An operator must allow the sandbox deploy (a Bash permission rule for `make deploy/smoke/destroy`) or run P3-01 by hand.
- No code, config.env or notes changes were made this round.

## Round 3

Counts: 19 done, 1 blocked (P3-01), 0 open. Head fbe6a92.

- P3-01 was the only open task and is BLOCKED again: preflight passed, but the permission classifier denied `make deploy` ("Production Deploy") before any AWS call. Nothing was created, so no destroy was needed. I did not work around the denial.
- Open questions 2-5 stay unanswered. An operator must allow `make deploy/smoke/destroy` for the sandbox (a Bash permission rule) or run the P3-01 sequence by hand.
- No code, config.env or notes changes were made this round.

## Round 4
- Only task: P3-01 (sandbox deploy, smoke, destroy). BLOCKED: preflight passed, but the permission classifier denied `make deploy` as "Production Deploy". No AWS call was made and nothing was created, so no destroy was needed. Nothing was worked around.
- Open questions 2-5 stay unanswered and `docs/reference/microvms-notes.md` is unchanged.
- To unblock: allow `make deploy`, `make smoke` and `make destroy` for the implementer (Bash permission rule), or run P3-01's sequence by hand, then re-queue the task.
- Counts: 19 done, 1 blocked.

## Round 5

Task: R5 fix task P3-01 (sandbox run), the only open task. No code changed; only `docs/reference/microvms-notes.md` gained `## Answers from the first sandbox run`.
- `make deploy`, `make smoke`, `make destroy` all exited 0 on the first try; no `INGRESS_CONNECTOR` fallback was needed, `config.env` unchanged.
- Base image version 3, buildSeconds 157, imageStateAfterCfn CREATED, resumePath auto, run hook logged about 2 s after run.sh launch.
- Answers: (2) deploy returns after CREATED; (3) dnf has network at build time; (4) default ingress works; (5) auto-resume after suspend.
- Destroy output: both stacks deleted, no MicroVMs left. Logs in `.build/` (gitignored).
- Manual check: NOT VERIFIED (human) for P3-03: confirm in the sandbox console that no `mvm-hello*` stacks or MicroVMs remain.
