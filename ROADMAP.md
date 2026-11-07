# Roadmap

Start with the [first hands-on lab](README.md#first-hands-on-lab-pause-and-restart-a-workspace),
then work through these `next-experiment` issues in order.

| Experiment order | GitHub issue | What to try and why it goes here |
|---|---|---|
| 1 | [GitHub issue #8 Pass per-tenant config with `runHookPayload`](https://github.com/deeheber/lambda-micro-vms/issues/8) | Pass Alice's session ID at launch, then Bob's using the same image version. Compare session IDs and counters to learn how one image serves separate sessions. |
| 2 | [GitHub issue #9 Image version management](https://github.com/deeheber/lambda-micro-vms/issues/9) | Record the existing image version before deploying GitHub issue #8, then inspect that release here. Compare versions, check which version new launches use, and see whether CloudFormation retained old ones. Try activation, deactivation, deletion and a managed base image update. This separates code releases from session configuration. |
| 3 | [GitHub issue #10 Call AWS APIs with the execution role](https://github.com/deeheber/lambda-micro-vms/issues/10) | Read one specific S3 object with scoped role permissions before and after suspend/resume. Learn the difference between client auth and the app's AWS credentials. If credentials fail after resume, investigate the resume hook from GitHub issue #2 here. |
| 4 | [GitHub issue #4 SAM launcher Lambda function](https://github.com/deeheber/lambda-micro-vms/issues/4) | Automate the launch practiced manually: accept a session through an IAM-authenticated Function URL and return its endpoint and short-lived token. Builds on GitHub issue #8. |
| 5 | [GitHub issue #17 `npm run microvm:sweep`](https://github.com/deeheber/lambda-micro-vms/issues/17) | Add region-wide discovery before running several VMs. Existing `destroy.sh` already finds VMs from the stack's image when the local record is lost. The sweep is a backstop for leftovers; preview exact targets before confirming cleanup. |
| 6 | [GitHub issue #16 Fan out: many MicroVMs from one image](https://github.com/deeheber/lambda-micro-vms/issues/16) | Start with two VMs and keep both endpoints: `run.sh` overwrites its single local record. Call Alice twice and Bob once to compare independent counters and IDs. Then explore launch latency and quotas, with GitHub issue #17 available for cleanup. |
| 7 | [GitHub issue #5 Shell access](https://github.com/deeheber/lambda-micro-vms/issues/5) | Inspect a running VM's app process. Learn this debugging tool before introducing long-lived connections. |
| 8 | [GitHub issue #7 WebSockets, HTTP/2 and gRPC](https://github.com/deeheber/lambda-micro-vms/issues/7) | Start with a WebSocket echo endpoint, then try a second port and HTTP/2 or gRPC. WebSockets prepare for GitHub issue #13. |
| 9 | [GitHub issue #2 Remaining lifecycle hooks](https://github.com/deeheber/lambda-micro-vms/issues/2) | Use the connections from GitHub issue #7 to test closing and reopening across suspend/resume, then termination cleanup. Measure launch time with and without `validate` last. |
| 10 | [GitHub issue #6 Private VPC egress](https://github.com/deeheber/lambda-micro-vms/issues/6) | Reach one private endpoint after learning IAM and lifecycle behavior. This is independent of the agent sandbox, so GitHub issue #13 can come first if preferred. |
| 11 | [GitHub issue #13 Claude Managed Agents sandbox](https://github.com/deeheber/lambda-micro-vms/issues/13) | Run one agent's tools in one disposable VM, combining session identity (GitHub issue #8), launch (GitHub issue #4), WebSockets (GitHub issue #7), AWS access (GitHub issue #10) and teardown. |

## Example folders: reorganize before the first experiment

When starting GitHub issue #8 (the first experiment above), move the current
working example into `examples/01-hello-world/`, then copy it into
`examples/02-session-workspace/`. Keep the hello world runnable as a baseline. Update the root README, npm scripts,
workspace configuration and CI paths as part of the move so the documented commands
and offline checks still work. Scope the minimal-example rules in `AGENTS.md`
to the hello world so they do not conflict with later SAM, hook or VPC experiments.

Turn the root README into an example index with learning goals and run
instructions. Move the current example's setup instructions and first lab into
`examples/01-hello-world/README.md`. Add later examples to the root index when
they become runnable. Keep future plans and their rationale in this roadmap.

Organize by runnable example. Create later folders when their experiments begin:

```text
examples/
  01-hello-world/
  02-session-workspace/
  03-interactive-connections/
  04-private-networking/
  05-agent-sandbox/
```

- `01-hello-world`: preserve the first lab and its minimal app and infrastructure.
- `02-session-workspace`: build GitHub issue #8, GitHub issue #10 and GitHub issue #4 here, then use it for GitHub issue #16 and GitHub issue #5.
- `03-interactive-connections`: explore GitHub issue #7 and connection lifecycle hooks from GitHub issue #2.
- `04-private-networking`: keep the VPC infrastructure from GitHub issue #6 in its own example.
- `05-agent-sandbox`: combine the earlier lessons for GitHub issue #13.

Each example gets its own README, app, infrastructure and configuration, with
distinct stack and image names so it can be deployed and destroyed independently.
Keep launch records and build artifacts separate too. Allow duplication to keep
each example understandable on its own; extract shared scripts only when
maintaining copies becomes a problem.

Image version management (GitHub issue #9) is an exercise applicable to multiple examples.
Share cleanup tooling (GitHub issue #17) where practical, while keeping each example's teardown
independently usable.

## Keeping the roadmap current

When an issue closes, delete its row and renumber the remaining rows so row 1
is always the next experiment.
