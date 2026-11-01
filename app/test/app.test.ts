import { test } from "node:test";
import assert from "node:assert/strict";
import { handleApp } from "../src/app.ts";
import { createState } from "../src/state.ts";

test("GET / returns 200 with message, instanceId, microvmId and requestCount", () => {
  const s = createState();
  s.instanceId = "i-1";
  s.microvmId = "m-1";
  const r = handleApp(s, "GET", "/");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, {
    message: "hello from a Lambda MicroVM",
    instanceId: "i-1",
    microvmId: "m-1",
    requestCount: 1,
  });
  assert.deepEqual(Object.keys(r.body), ["message", "instanceId", "microvmId", "requestCount"]);
});

test("GET / increments requestCount on every call", () => {
  const s = createState();
  handleApp(s, "GET", "/");
  handleApp(s, "GET", "/");
  assert.equal(handleApp(s, "GET", "/").body.requestCount, 3);
  assert.equal(s.requestCount, 3);
});

test("an unknown path returns 404 not found", () => {
  const r = handleApp(createState(), "GET", "/nope");
  assert.equal(r.status, 404);
  assert.deepEqual(r.body, { error: "not found" });
});

test("a non-GET request to / returns 404 and does not increment requestCount", () => {
  const s = createState();
  const r = handleApp(s, "POST", "/");
  assert.equal(r.status, 404);
  assert.equal(s.requestCount, 0);
});
