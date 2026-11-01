# Lambda MicroVMs Hello World build progress

Branch: build/2026-11-01
Started: 2026-11-01T20:14:36.407Z

## Tasks

- [x] P1-01 Scaffold app package, config, lib.sh and Makefile
- [ ] P1-02 App server request handler
- [ ] P1-03 Hooks server request handler
- [ ] P1-04 Entry point starting both servers
- [ ] P1-05 Dockerfile on the snapshot-safe base image
- [ ] P1-06 Phase 1 push and manual container check
- [ ] P2-01 Bootstrap stack template
- [ ] P2-02 Image stack template
- [ ] P2-03 deploy.sh with deterministic packaging
- [ ] P2-04 run.sh launches one MicroVM
- [ ] P2-05 call.sh mints a token and calls the MicroVM
- [ ] P2-06 microvm.sh status, suspend, resume, terminate
- [ ] P2-07 smoke.sh end-to-end lifecycle check
- [ ] P2-08 destroy.sh ordered teardown
- [ ] P2-09 Phase 2 push and IAM review
- [ ] P3-01 Sandbox run: deploy, smoke, destroy
- [ ] P3-02 README walkthrough
- [ ] P3-03 Phase 3 push and final manual checks

## Log

(one entry per task, appended by implement)

### P1-01 — 58d2005

Tests: app/test/state.test.ts (3). make check green; sandbox guard and region export verified offline.
Interpretation: AWS_PARTITION is set/exported only by assert_sandbox; managed_connector_arn/base_image_arn need it called first.
Config keys: all SPEC section 5 keys plus POLL_INTERVAL_SECONDS, IMAGE_WAIT_SECONDS, TERMINATE_WAIT_SECONDS, INGRESS_CONNECTOR.
Installed: typescript ^7.0.2, @types/node ^24.19.2.
