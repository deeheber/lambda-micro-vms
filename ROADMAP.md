# Roadmap

Start with the [first hands-on lab](examples/hello-world/README.md#first-hands-on-lab-pause-and-restart-a-workspace),
then work through the GitHub issues below from top to bottom.

| GitHub issue | What to learn and why it comes here |
|---|---|
| [GitHub issue #8: Session configuration](https://github.com/deeheber/lambda-micro-vms/issues/8) | Pass different session data to VMs from one image to learn per-session configuration and state. |
| [GitHub issue #9: Image versions](https://github.com/deeheber/lambda-micro-vms/issues/9) | Use the first app change to learn how image releases and version cleanup work. |
| [GitHub issue #10: AWS access](https://github.com/deeheber/lambda-micro-vms/issues/10) | Read an S3 object to learn execution-role permissions and check access after suspend/resume. |
| [GitHub issue #5: Shell access](https://github.com/deeheber/lambda-micro-vms/issues/5) | Learn to inspect and debug a running VM before adding more moving parts. |
| [GitHub issue #17: Cleanup sweep](https://github.com/deeheber/lambda-micro-vms/issues/17) | Add a cleanup backstop before launching several VMs. |
| [GitHub issue #16: Multiple VMs](https://github.com/deeheber/lambda-micro-vms/issues/16) | Compare multiple VMs to observe separate identities and state, then explore launch latency and quotas. |
| [GitHub issue #4: Session launcher](https://github.com/deeheber/lambda-micro-vms/issues/4) | Automate session launch and token creation after practicing those steps manually. |
| [GitHub issue #7: WebSockets, HTTP/2 and gRPC](https://github.com/deeheber/lambda-micro-vms/issues/7) | Move from individual HTTP requests to interactive connections, starting with WebSockets. |
| [GitHub issue #2: Lifecycle hooks](https://github.com/deeheber/lambda-micro-vms/issues/2) | Learn how to manage connections across suspend/resume, then explore termination cleanup and startup optimization. |
| [GitHub issue #6: Private networking](https://github.com/deeheber/lambda-micro-vms/issues/6) | Reach a private endpoint after learning the basic lifecycle and permissions. |
| [GitHub issue #13: Agent sandbox](https://github.com/deeheber/lambda-micro-vms/issues/13) | Combine the earlier lessons into an agent's disposable execution environment. |

## One app, saved at each lesson

Use one folder per GitHub issue, plus `hello-world/` as the starting point.
Each folder contains the previous step's complete app, tests, infrastructure, scripts and npm package files,
plus that issue's changes and instructions. Keep earlier folders as runnable
references. Operational lessons, such as image versions, can carry forward
unchanged code and add the exercise to their README.

For example:

```text
examples/
  hello-world/            # starting point
  session-config/         # hello world + GitHub issue #8
  image-versions/         # session config + GitHub issue #9
  aws-access/             # previous stage + GitHub issue #10
```

Deploy each consecutive lesson using the same sandbox stack names and image name.
The deploy command updates the existing CloudFormation stacks; do not tear down
between lessons. Keep only one stage deployed at a time. When the app image
changes, launch new VMs from the new image version; existing VMs keep their old
code. Terminate VMs you no longer need.

Run the current stage's destroy command when ending a sandbox session, including
after a failure. To revisit an older stage, destroy the current deployment first,
then deploy that stage.

Each lesson's README explains what it adds, how to run it, what to observe and
how to clean up. The root README lists the available lessons in learning order.
Keep deployment records and generated files local to each stage; do not copy them
when starting the next lesson.

## Next step: start GitHub issue #8

Copy `examples/hello-world/` into `examples/session-config/` and implement
GitHub issue #8 there. Keep `STACK_PREFIX` and `IMAGE_NAME` unchanged to update
the existing sandbox stacks.
Create later lesson folders as their issues are started.

When adding the next folder, make CI a matrix with one job per lesson folder.
In each matrix job, run `npm ci` using that lesson's lockfile, then its offline
`npm run check`. Point the npm cache at the lesson's lockfile. Add each new lesson to the matrix and root README. Keep tests
inside their lesson folders. Run checks from each lesson folder locally too.
Do not copy the hello world's minimal-only `AGENTS.md` rules into advanced lessons.
