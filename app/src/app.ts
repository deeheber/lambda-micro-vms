// The app server's request handler: a pure function, so tests call it directly
// without opening a socket.
//
// MicroVM concept: memory survives suspend/resume. `requestCount` lives only in
// process memory. A suspended MicroVM keeps its memory, so after resume the
// count continues where it stopped; a fresh MicroVM would start again at 1.

import type { State } from "./state.ts";

export type Reply = { status: number; body: Record<string, unknown> };

// `path` arrives with any query string already removed.
export function handleApp(s: State, method: string, path: string): Reply {
  if (method === "GET" && path === "/") {
    // Increment first so the reply includes this request.
    s.requestCount += 1;
    return {
      status: 200,
      body: {
        message: "hello from a Lambda MicroVM",
        instanceId: s.instanceId,
        microvmId: s.microvmId,
        requestCount: s.requestCount,
      },
    };
  }
  return { status: 404, body: { error: "not found" } };
}
