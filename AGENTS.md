# Agent instructions

## Working boundaries

- Every npm script except `check`, `typecheck` and `test` calls AWS. Run them only when asked, only against a sandbox account, and finish each AWS sandbox session with that lesson's `npm run destroy`, including after a failure.
- Single test: `cd examples/hello-world/app && node --test --test-name-pattern=<name> 'test/**/*.test.ts'`. Don't use `npm test -- --test-name-pattern=…`: the flag goes after the glob and filters nothing.
- Check CLI shapes offline with `aws lambda-microvms <command> help`.

## Design decisions

- Lessons live in `examples/`; each includes its app, tests, infrastructure, scripts and instructions. Follow `ROADMAP.md` for the learning sequence.
- Keep the same stack prefix and image name between consecutive lessons. Deploy updates the existing stacks; do not destroy between lessons in one sandbox session.
- Run `npm ci` and `npm run check` inside each lesson folder. Each lesson owns its package files and lockfile; there are no root npm scripts.
- Least-privilege IAM: no bare `*` in `Action` or `Resource` (a scoped path like `artifacts/*` is fine).

## Commits

No `Co-Authored-By`, "Generated with" or other attribution trailers.
