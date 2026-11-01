// Lifecycle hooks: the platform calls these on HOOKS_PORT, not the app port.
// Pure handler; main.ts adapts HTTP requests to it and prints `log` to stdout.
//
// MicroVM concepts shown here:
//   ready - called during the image build. The snapshot is taken only after it
//           returns 200, so the app is fully started inside every snapshot.
//   run   - called once per MicroVM, after the snapshot is restored. Anything
//           unique to one MicroVM must be created here, never earlier.

import { randomUUID } from "node:crypto";
import type { Reply } from "./app.ts";
import type { State } from "./state.ts";

export const HOOK_PREFIX = "/aws/lambda-microvms/runtime/v1/";

// A Reply plus the one JSON line main.ts writes to stdout (null when nothing
// should be logged). CloudWatch Logs shows these lines, which is how you see
// hooks firing.
export type HookReply = Reply & { log: string | null };

function logLine(hook: "ready" | "run", status: number, now: Date): string {
  return JSON.stringify({ hook, status, ts: now.toISOString() });
}

export function handleHook(
  s: State,
  method: string,
  path: string,
  rawBody: string,
  now: Date = new Date(),
): HookReply {
  if (method === "POST" && path === `${HOOK_PREFIX}ready`) {
    // 503 until the app server's `listening` event has fired. The image build
    // keeps asking; only a 200 triggers the snapshot.
    const status = s.appListening ? 200 : 503;
    return { status, body: { ready: s.appListening }, log: logLine("ready", status, now) };
  }

  if (method === "POST" && path === `${HOOK_PREFIX}run`) {
    // A missing or malformed body must never fail the hook: the MicroVM would
    // not start. Anything unusable just leaves microvmId null.
    let microvmId: string | null = null;
    try {
      const parsed: unknown = JSON.parse(rawBody);
      if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
        const id = (parsed as Record<string, unknown>).microvmId;
        if (typeof id === "string") microvmId = id;
      }
    } catch {
      // Not JSON: tolerated.
    }
    s.microvmId = microvmId;
    // Snapshot safety: generated here, after restore, so every MicroVM started
    // from the same image gets its own ID. At module load it would be baked
    // into the snapshot and shared by all of them.
    s.instanceId = randomUUID();
    return { status: 200, body: { ok: true }, log: logLine("run", 200, now) };
  }

  return { status: 404, body: { error: "not found" }, log: null };
}
