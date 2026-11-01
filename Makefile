# Each target maps to one MicroVM concept. Live targets (all but check) call AWS.
.PHONY: deploy run call status suspend resume terminate smoke destroy check

CALL_PATH ?= /

# Image build: package the app, create the stacks, wait for the snapshot-based image.
deploy:
	scripts/deploy.sh

# Launch: start one MicroVM from the image's latest version.
run:
	scripts/run.sh

# Auth and proxy: mint a token, call the app over HTTPS through the MicroVM proxy.
call:
	scripts/call.sh $(CALL_PATH)

# Lifecycle: read the MicroVM's current state.
status:
	scripts/microvm.sh status

# Lifecycle: suspend, keeping memory so no work is lost.
suspend:
	scripts/microvm.sh suspend

# Lifecycle: resume from the suspended memory snapshot.
resume:
	scripts/microvm.sh resume

# Lifecycle: terminate, ending compute and storage charges.
terminate:
	scripts/microvm.sh terminate

# End to end: run, call, suspend, resume, prove memory survived, terminate.
smoke:
	scripts/smoke.sh

# Teardown: terminate MicroVMs, then remove the stacks and artifacts.
destroy:
	scripts/destroy.sh

app/node_modules: app/package-lock.json
	npm --prefix app ci

# Offline checks only: no AWS calls.
check: app/node_modules
	npm --prefix app run typecheck
	npm --prefix app test
	bash -n scripts/*.sh
	cfn-lint infra/*.yaml
