# Roadmap

The order to work through the `next-experiment` issues after the hello world. Common use cases come first: what nearly every MicroVMs app ends up doing. Niche and costly experiments come last.

| # | Issue | Why |
|---|---|---|
| 1 | [#9 Image version management](https://github.com/deeheber/lambda-micro-vms/issues/9) | Every app ships new code. An update creates a new image version and ends in `UPDATED`. |
| 2 | [#8 Pass per-tenant config with `runHookPayload`](https://github.com/deeheber/lambda-micro-vms/issues/8) | One MicroVM per user or session is the main reason to use the service. The payload tells each MicroVM who it belongs to. |
| 3 | [#10 Call AWS APIs with the execution role](https://github.com/deeheber/lambda-micro-vms/issues/10) | Most apps call S3, DynamoDB or Secrets Manager. If credentials go stale after a suspend, #2 has the fix. |
| 4 | [#4 SAM launcher Lambda function](https://github.com/deeheber/lambda-micro-vms/issues/4) | The control plane most apps need: start a MicroVM per session and return its endpoint and a token. Builds on #8. |
| 5 | [#16 Fan out](https://github.com/deeheber/lambda-micro-vms/issues/16) + [#17 `make sweep`](https://github.com/deeheber/lambda-micro-vms/issues/17) | A per-user app runs many MicroVMs at once. Build the sweep in the same flight, before starting N of them. |
| 6 | [#5 Shell access](https://github.com/deeheber/lambda-micro-vms/issues/5) | A common way to debug, and handy once there are several MicroVMs. |
| 7 | [#7 WebSockets, HTTP/2 and gRPC](https://github.com/deeheber/lambda-micro-vms/issues/7) | Interactive apps and agents use long-lived connections. Needed for #13. |
| 8 | [#6 Private VPC egress](https://github.com/deeheber/lambda-micro-vms/issues/6) | Common in company setups, but the heaviest item and the only one with ongoing cost (VPC plus a private resource). |
| 9 | [#2 Remaining lifecycle hooks](https://github.com/deeheber/lambda-micro-vms/issues/2) | `suspend` and `resume` matter once the app holds connections or credentials (#7, #10). `validate` is a startup-speed optimization. |
| 10 | [#13 Claude Managed Agents sandbox](https://github.com/deeheber/lambda-micro-vms/issues/13) | Capstone. Uses #4, #7, #8 and #10. |

Items that pair well as one Kūkulu flight: #8 with #4, and #16 with #17.

When every issue in a row has closed, delete the row, so row 1 is always the next one to do.
