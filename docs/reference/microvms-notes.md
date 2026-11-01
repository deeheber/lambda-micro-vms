# Lambda MicroVMs: verified notes

These notes were compiled on 2026-10-31 (updated 2026-11-01) from AWS documentation and checks run against the live APIs and local tools. Each item is tagged with how it was verified:

- **[tested]**: run locally or against AWS.
- **[schema]**: from `cloudformation describe-type`.
- **[docs]**: from the sources listed at the end.

## Mental model

- **MicroVM image.** A versioned artifact. You give Lambda a zip in S3 that contains a `Dockerfile` at its root, plus a managed base image. Lambda then:
  1. runs the Dockerfile,
  2. starts the app (`CMD`),
  3. waits for the `/ready` hook,
  4. takes a Firecracker **memory and disk snapshot**.

  Every MicroVM starts from that snapshot. **[docs]**
- **MicroVM.** One running instance launched from an image version with `run-microvm`. It runs for up to 8 h (`maximumDurationInSeconds` ≤ 28800) and has its own HTTPS endpoint. It can be suspended (memory and disk are kept, and you pay only storage) and resumed. **[docs]**
- **Only the image is a CloudFormation resource** (`AWS::Lambda::MicrovmImage`). MicroVMs are launched and managed at runtime through the `aws lambda-microvms` CLI or the SDK. `AWS::Lambda::NetworkConnector` also exists, for VPC egress. **[schema] [docs]**
- **Two IAM roles:**
  - The **build role** (`BuildRoleArn` on the image) is used during the image build: S3 read and CloudWatch Logs writes.
  - The **execution role** (`--execution-role-arn` on `run-microvm`) is assumed at runtime and exposed to the guest through IMDSv2.
  - Without an execution role, app stdout is **not** shipped to CloudWatch. **[docs]**
- **Base OS.** The only managed base image is `arn:aws:lambda:<region>:aws:microvm-image:al2023-1` (Amazon Linux 2023), and there is nothing newer. `list-managed-microvm-images` returns only `imageArn`, `createdAt`, and `updatedAt`, with no version string. **[tested]**
- **Base image versions are listed by `list-managed-microvm-image-versions`.** `aws lambda-microvms list-managed-microvm-image-versions --image-identifier arn:aws:lambda:us-west-2:aws:microvm-image:al2023-1` returns `items[]` of `{imageArn, imageVersion, status, createdAt, updatedAt}`. In us-west-2 it returned `imageVersion` `"0"`–`"3"`, all `AVAILABLE`. Versions are strings holding integers, so compare them numerically. **[tested 2026-11-01]**
- **Base image version lifecycle.** If you omit a version, the latest one is used (the API allows that; the CFN schema doesn't). Versions go `AVAILABLE` → `DEPRECATED` (60 days, can still build) → `EXPIRING` (30 days, can't build new images) → `EXPIRED` (can't build or run). `RECALLED` is immediate and rare. Rebuild onto a newer version to patch. **[docs]**
- **You can't read AWS-owned base images through the regular image APIs.** `get-microvm-image` and `list-microvm-image-versions` on `…:aws:microvm-image:al2023-1` return `AccessDenied`, even for an admin user. Use the `*-managed-*` calls above instead. Calls on images you own work. **[tested]**
- **Architecture.** `CpuConfigurations` allows only `ARM_64`. Build and test containers locally with `--platform linux/arm64`. **[schema]**

## `AWS::Lambda::MicrovmImage` (CloudFormation)

**[schema]**: full schema in `microvmimage-schema.json`.

- **All 13 properties are required.** See `microvmimage-schema.json` for the exact shapes, and SPEC section 4 for the values this repo uses. Two things worth knowing:
  - `AdditionalOsCapabilities: []` and `EnvironmentVariables: []` are valid; neither has `minItems`.
  - `Name` is create-only, so changing it replaces the image.
- **`Ref`** returns the image ARN.
- **`GetAtt`:** `ImageArn`, `State`, `LatestActiveImageVersion`, `LatestFailedImageVersion`, `CreatedAt`, `UpdatedAt`.
- **States:** `CREATING`, `CREATED`, `CREATE_FAILED`, `UPDATING`, `UPDATED`, `UPDATE_FAILED`, `DELETING`, `DELETE_FAILED`, `DELETED`. These match `get-microvm-image help`. The developer guide's prose says `CREATION_FAILED`/`DELETION_FAILED`; the API doesn't use those spellings. **[tested]**
  - After an update, the image settles in **`UPDATED`**, not `CREATED`. Anything that waits for the image must accept both. **[docs]**
  - Image state, version state (`PENDING`, `IN_PROGRESS`, `SUCCESSFUL`, `FAILED`) and version activation (`ACTIVE`/`INACTIVE`) are independent. Running a MicroVM needs image `CREATED`/`UPDATED`, version `SUCCESSFUL`, and `ACTIVE`. **[docs]**
- **Updates.** Changing any property except `Name` is "No interruption" and creates a **new image version**. The update handler's permissions include `lambda:DeleteMicrovmImageVersion`, so CloudFormation may clean up old versions on update.
- **Permissions CloudFormation needs (the caller's own):**
  - Create: `lambda:CreateMicrovmImage`, `lambda:GetMicrovmImage`, `lambda:PassNetworkConnector`, `iam:PassRole`, `lambda:TagResource`.
  - Delete: `lambda:DeleteMicrovmImage`, `lambda:GetMicrovmImage`.
- **cfn-lint 1.58.0 knows this resource** and reports `E3003` for each missing required property. **[tested]**
- **There is no SAM or `aws cloudformation package` support** for `CodeArtifact.Uri`; `package help` mentions MicroVMs zero times. You must zip and upload the artifact yourself and pass the URI in as a parameter. **[tested]**
- **Content-hash the S3 key.** If the URI never changes, CloudFormation sees no diff, and the image never rebuilds.

## Dockerfile and runtime inside the VM

- **Use `FROM public.ecr.aws/lambda/microvms:al2023-minimal`.** Its OpenSSL is patched for snapshot safety, so randomness is reseeded after restore. **[docs]**
- **`dnf install -y nodejs24` works in that image:**
  - It installs `node` v24.22.1 at `/usr/bin/node` (and `/usr/bin/node-24`). **[tested]**
  - That Node **dynamically links the system OpenSSL 3.5.8** (`/lib64/libssl.so.3`, `/lib64/libcrypto.so.3`). **[tested]**
  - Official Node tarballs and `node:*` images bundle their own OpenSSL, which defeats this.
  - Plain `nodejs` in AL2023 is v18. The image's `dnf` is a thin wrapper, so `microdnf repoquery 'nodejs*'` shows the streams: `nodejs20`, `nodejs22`, `nodejs24`. **[tested]**
- **Node 24 runs `.ts` files directly** (type stripping). `node --test` and `--test-name-pattern` work on `.test.ts` files. Imports must use the `.ts` extension, and only erasable TypeScript syntax is allowed: no enums, no namespaces, no parameter properties. **[tested]**
- **The app listens on port 8080 by default.** The proxy forwards to 8080 unless the request carries `X-aws-proxy-port: <n>`. **[docs]**
- **Hooks run on their own port**, 9000 by convention, set by `Hooks.Port`. **[docs]**
- **Bind to `0.0.0.0` and `EXPOSE` both ports.** Localhost-only listeners can't be reached. **[docs]**

## Lifecycle hooks

**[docs]** Every hook is `POST /aws/lambda-microvms/runtime/v1/<hook>` on the hooks port.

| Hook | When | Contract |
|---|---|---|
| `ready` | Image build, before the snapshot | Return 503 until initialized, then 200. Non-200/503 or a timeout fails the build. **Required if any runtime hook is enabled.** |
| `validate` | Image build, on a test run from the snapshot | 200 means the image is valid. Also used to sample pages for prefetch. *(Out of scope for v1.)* |
| `run` | Once, right after a MicroVM starts from the snapshot | The body includes `microvmId` and any `runHookPayload`. Keep it fast (1–60 s timeout, default 1 s). External traffic only begins after it returns 200. |
| `resume` / `suspend` / `terminate` | Lifecycle transitions | Fast notifications. *(Out of scope for v1.)* |

**Snapshot uniqueness.** Anything generated before the snapshot (IDs, random seeds, secrets) is **shared by every MicroVM** launched from that image, so generate per-instance values in `/run`. Credentials and connections opened before a snapshot or suspend may be stale afterwards. **[docs]**

## Running, connecting, lifecycle (CLI)

**[docs]**

```bash
# Run (returns microvmId + endpoint without scheme; prepend https://)
aws lambda-microvms run-microvm \
  --image-identifier <imageArn> --image-version <major.minor, e.g. 1.0> \
  --execution-role-arn <roleArn> \
  --idle-policy '{"maxIdleDurationSeconds":300,"suspendedDurationSeconds":600,"autoResumeEnabled":true}' \
  --maximum-duration-in-seconds 1800 \
  --logging '{"cloudWatch":{"logGroup":"/aws/lambda-microvms/<name>"}}'
#   optional: --ingress-network-connectors / --egress-network-connectors with managed ARNs:
#   arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:{HTTP_INGRESS|ALL_INGRESS|SHELL_INGRESS|INTERNET_EGRESS}

# Token (max 60 min) + call
TOKEN=$(aws lambda-microvms create-microvm-auth-token --microvm-identifier <id> \
  --expiration-in-minutes 15 --allowed-ports '[{"port":8080}]' \
  --query 'authToken."X-aws-proxy-auth"' --output text)
curl -fsS "https://<endpoint>/" -H "X-aws-proxy-auth: $TOKEN"

aws lambda-microvms get-microvm       --microvm-identifier <id>   # state is eventually consistent
aws lambda-microvms suspend-microvm   --microvm-identifier <id>
aws lambda-microvms resume-microvm    --microvm-identifier <id>
aws lambda-microvms terminate-microvm --microvm-identifier <id>
aws lambda-microvms get-microvm-image --image-identifier <imageArn>   # image state
```

- **Idle policy.** The whole `idlePolicy` block is optional; leave it out to disable auto-suspend. If it's present, all three fields are required.
  - `maxIdleDurationSeconds` must be ≥ 60.
  - `suspendedDurationSeconds` is the time spent suspended before termination. `0` means terminate when suspended.
  - With `autoResumeEnabled`, inbound traffic wakes a suspended VM.
- **Idle is measured as inbound proxy traffic only.** A VM that's busy with outbound-only work still counts as idle.
- **MicroVM states:** `PENDING` → `RUNNING` ⇄ `SUSPENDING` → `SUSPENDED` → `TERMINATING` → `TERMINATED`.
- **Check readiness by connecting.** Don't trust `get-microvm` state alone.
- **`lambda:PassNetworkConnector`** is required for every `RunMicrovm` call, even with default connectors.
- **IAM actions use the `lambda:` prefix** (for example `lambda:RunMicrovm`, `lambda:CreateMicrovmImage`), even though the CLI namespace is `lambda-microvms`.
- **S3 artifact region.** The artifact bucket must be in the image's region; otherwise the build fails with `S3_CROSS_REGION_ACCESS_DENIED`.
- **Build failures:** look in CloudWatch under `/aws/lambda-microvms/<image-name>`.

## IAM

**[docs]**

- **Trust policy.** Both roles use the same trust policy:

  ```json
  {"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
   "Action":["sts:AssumeRole","sts:TagSession"],
   "Condition":{"StringEquals":{"aws:SourceAccount":"<account>"}}}
  ```

- **Build role:**
  - `s3:GetObject` on the artifact keys.
  - `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents` on the log group.
  - Add ECR pull permissions only if the `FROM` image is in private ECR.
- **Execution role:** `logs:CreateLogGroup`, `logs:CreateLogStream`, and `logs:PutLogEvents` on the log group, plus whatever AWS APIs the app calls.

## Pricing (for the README)

**[docs]** While running, you pay the baseline compute rate (default 2 GB / 1 vCPU, with bursts up to 4× billed only while in use). While suspended, you pay storage only. Each image version costs storage. Data transfer is billed at standard rates.

## Sources

- Developer guide: https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html
- MicroVM images (base versions, states, build hooks): https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html
- Getting started: https://docs.aws.amazon.com/lambda/latest/dg/microvms-getting-started.html
- Running MicroVMs and hooks: https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html
- Networking and auth: https://docs.aws.amazon.com/lambda/latest/dg/microvms-networking.html
- CloudFormation resource: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-lambda-microvmimage.html
- Launch blog: https://aws.amazon.com/blogs/compute/announcing-lambda-microvms-serverless-compute-environments-with-vm-level-isolation-and-near-instant-startup/
- The AWS agent skill `aws-lambda-microvms` (through the AWS MCP server): SKILL.md, getting-started, lifecycle-model, iam-and-security.
