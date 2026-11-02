import { test } from "node:test";
import assert from "node:assert/strict";
import { createState, state } from "../src/state.ts";

test("createState returns null ids, zero requestCount and appListening false", () => {
  assert.deepEqual(createState(), {
    instanceId: null,
    microvmId: null,
    requestCount: 0,
    appListening: false,
  });
});

test("createState returns a new object each call", () => {
  assert.notEqual(createState(), createState());
});

test("the shared state starts with instanceId null at module load", () => {
  assert.equal(state.instanceId, null);
});
