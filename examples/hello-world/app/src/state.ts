// In-memory state shared by the app server and the hook server.
//
// MicroVM concept: snapshot safety. A MicroVM image is a memory snapshot taken
// after the `ready` hook succeeds, and every MicroVM started from it resumes
// that exact memory. Anything set before the snapshot is therefore identical in
// every MicroVM.

export type State = {
  // Starts null on purpose: a value generated at module load would be baked
  // into the snapshot and shared by every MicroVM. It is set only in the `run`
  // hook, which runs once per MicroVM after the snapshot is restored.
  instanceId: string | null;
  // The MicroVM ID, when the platform supplies one in the run hook.
  microvmId: string | null;
  // Requests served by the app server; survives suspend/resume (memory is kept).
  requestCount: number;
  // True once the app server is listening; the ready hook reports on it.
  appListening: boolean;
};

export function createState(): State {
  return { instanceId: null, microvmId: null, requestCount: 0, appListening: false };
}

// The one shared instance used by main.ts.
export const state: State = createState();
