// Entry point: two HTTP servers in one process, wired to the pure handlers.
//
// MicroVM concepts shown here:
//   - Both servers bind 0.0.0.0 (all interfaces). The MicroVM proxy reaches the
//     app, and the platform reaches the hooks, from outside the process's own
//     loopback interface, so a loopback-only bind would be unreachable.
//   - Hooks get their own port, separate from the app port, so platform
//     lifecycle calls never mix with (or get exposed as) user traffic.

import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { handleApp } from "./app.ts";
import type { Reply } from "./app.ts";
import { handleHook } from "./hooks.ts";
import { state } from "./state.ts";

// Ports come from the environment (the Dockerfile ENV lines, which mirror
// config.env). There is deliberately no fallback number here.
function readPort(name: string): number {
  const raw = process.env[name];
  const port = Number(raw);
  if (raw === undefined || !Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`${name} must be an integer from 1 to 65535, got: ${raw ?? "(unset)"}`);
    process.exit(1);
  }
  return port;
}

const appPort = readPort("APP_PORT");
const hooksPort = readPort("HOOKS_PORT");

function send(res: ServerResponse, reply: Reply): void {
  res.writeHead(reply.status, { "content-type": "application/json" });
  res.end(JSON.stringify(reply.body));
}

function pathOf(req: IncomingMessage): string {
  return (req.url ?? "/").split("?")[0];
}

// App server: user-facing traffic that arrives through the MicroVM proxy.
const appServer = createServer((req, res) => {
  send(res, handleApp(state, req.method ?? "", pathOf(req)));
});
// Once this fires, the `ready` hook starts answering 200, which lets the image
// build take its snapshot with the app already running.
appServer.on("listening", () => {
  state.appListening = true;
});
appServer.listen(appPort, "0.0.0.0");

// Hooks server: lifecycle calls from the platform.
const hooksServer = createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (chunk: Buffer) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    const reply = handleHook(state, req.method ?? "", pathOf(req), body);
    // One JSON line per hook call: this is how hooks show up in CloudWatch Logs.
    if (reply.log !== null) console.log(reply.log);
    send(res, reply);
  });
});
hooksServer.listen(hooksPort, "0.0.0.0");
