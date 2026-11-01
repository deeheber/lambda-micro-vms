import { test } from "node:test";
import assert from "node:assert/strict";
import { HOOK_PREFIX, handleHook } from "../src/hooks.ts";
import { createState } from "../src/state.ts";

const READY = `${HOOK_PREFIX}ready`;
const RUN = `${HOOK_PREFIX}run`;

test("ready returns 503 before the app server is listening and 200 after", () => {
  const s = createState();
  assert.equal(handleHook(s, "POST", READY, "").status, 503);
  s.appListening = true;
  assert.equal(handleHook(s, "POST", READY, "").status, 200);
});

test("run sets microvmId from the body and assigns an instanceId", () => {
  const s = createState();
  const r = handleHook(s, "POST", RUN, '{"microvmId":"mvm-123"}');
  assert.equal(r.status, 200);
  assert.equal(s.microvmId, "mvm-123");
  assert.equal(typeof s.instanceId, "string");
});

test("run on two fresh states assigns different instanceIds", () => {
  const a = createState();
  const b = createState();
  handleHook(a, "POST", RUN, "{}");
  handleHook(b, "POST", RUN, "{}");
  assert.notEqual(a.instanceId, b.instanceId);
});

test("run tolerates a malformed body", () => {
  for (const body of ["", "not json", "[]", "null", '{"microvmId":42}']) {
    const s = createState();
    const r = handleHook(s, "POST", RUN, body);
    assert.equal(r.status, 200, body);
    assert.equal(s.microvmId, null, body);
    assert.equal(typeof s.instanceId, "string", body);
  }
});

test("an unknown hook path returns 404 and logs nothing", () => {
  const s = createState();
  const r = handleHook(s, "POST", `${HOOK_PREFIX}validate`, "{}");
  assert.equal(r.status, 404);
  assert.equal(r.log, null);
  assert.equal(s.instanceId, null);
  assert.equal(handleHook(s, "GET", RUN, "").status, 404);
});

test("ready and run each return one JSON log line with hook, status and ts", () => {
  const s = createState();
  const now = new Date("2026-11-01T12:00:00.000Z");
  assert.equal(
    handleHook(s, "POST", READY, "", now).log,
    '{"hook":"ready","status":503,"ts":"2026-11-01T12:00:00.000Z"}',
  );
  assert.equal(
    handleHook(s, "POST", RUN, "{}", now).log,
    '{"hook":"run","status":200,"ts":"2026-11-01T12:00:00.000Z"}',
  );
});
