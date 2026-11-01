# Agent instructions

## Working boundaries

- `make deploy`, `run`, `call`, `smoke`, `destroy` and the lifecycle targets call AWS. Run them only when asked, only against a sandbox account, and always finish with `make destroy`, even after a failure.
- `make check` runs every offline check. Single test: `cd app && node --test --test-name-pattern=<name> 'test/**/*.test.ts'`.
- Read `docs/reference/microvms-notes.md` for service facts instead of searching the web. Check CLI shapes offline with `aws lambda-microvms <command> help`.

## Design decisions

- Minimal on purpose: no SAM, Lambda functions, VPC connectors, extra hooks or run hook payload, and no tooling beyond `tsc` and `node --test`. Bigger ideas go in `ROADMAP.md` and `next-experiment` issues.
- No account IDs or region literals outside `config.env`. Every tunable lives in `config.env` (scripts) or a CloudFormation parameter (templates), never as a literal in code.
- Every script calls `assert_sandbox` before its first `aws` call.
- Create per-MicroVM values (like `instanceId`) in the `run` hook, never at module load: anything created earlier is baked into the snapshot and shared by every MicroVM.
- No runtime dependencies in `app/`; Node 24 runs `.ts` directly.
- Least-privilege IAM: no `*` in `Action` or `Resource`.
- Comments teach: say which MicroVM concept each piece demonstrates.

## Commits

No `Co-Authored-By`, "Generated with" or other attribution trailers.
