# Hello-world instructions

Keep this baseline minimal: no SAM, Lambda functions, VPC connectors, extra hooks
or run hook payload, no runtime dependencies in `app/`, and no app build or test
tooling beyond `tsc` and `node --test`. Add those capabilities in later lesson
folders as described in the root `ROADMAP.md`.

From this folder, a single test is:
`cd app && node --test --test-name-pattern=<name> 'test/**/*.test.ts'`.
