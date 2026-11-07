# lambda-micro-vms

Learn [AWS Lambda MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html)
through one app that builds on itself. Each lesson keeps its own code and tests
so you can revisit earlier stages.

| Example | What it teaches |
|---|---|
| [Hello world](examples/hello-world/README.md) | Build an image, launch a VM, call it over HTTPS, suspend, resume and terminate it. Start with its [hands-on lab](examples/hello-world/README.md#first-hands-on-lab-pause-and-restart-a-workspace). |

See [ROADMAP.md](ROADMAP.md) for the remaining lessons and GitHub issue order.

## Run checks

Each example owns its npm scripts and lockfile. Using Node 24 and `cfn-lint`:

```sh
cd examples/hello-world
npm ci
npm run check
```

This runs the hello world's offline checks. See its README for AWS prerequisites
and deployment instructions. Run all npm commands from the lesson folder.
