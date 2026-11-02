# Agent instructions

## Working boundaries

- Every npm script except `check`, `typecheck` and `test` calls AWS. Run them only when asked, only against a sandbox account, and always finish with `npm run destroy`, even after a failure.
- Single test: `cd app && node --test --test-name-pattern=<name> 'test/**/*.test.ts'`. Don't use `npm test -- --test-name-pattern=…`: the flag goes after the glob and filters nothing.
- Check CLI shapes offline with `aws lambda-microvms <command> help`.

## Design decisions

- Minimal on purpose: no SAM, Lambda functions, VPC connectors, extra hooks or run hook payload, no runtime dependencies in `app/`, and no app build or test tooling beyond `tsc` and `node --test`. Bigger ideas go in `ROADMAP.md` and `next-experiment` issues.
- Least-privilege IAM: no bare `*` in `Action` or `Resource` (a scoped path like `artifacts/*` is fine).

## Commits

No `Co-Authored-By`, "Generated with" or other attribution trailers.
