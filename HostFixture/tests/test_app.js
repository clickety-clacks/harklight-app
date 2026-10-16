"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../assets/app.js"), "utf8");
const session = {token: "disposable-token", profile: "synthetic-A", generation: "generation-one"};

function page(storage, fetch, uuid) {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, {value: "", textContent: "", onclick: null});
    return elements.get(id);
  };
  const sessionStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
    removeItem: key => storage.delete(key)
  };
  vm.runInNewContext(source, {document: {getElementById: get}, sessionStorage,
    fetch, crypto: {randomUUID: uuid}, TextDecoder});
  return get;
}

function reply(body, status = 200) {
  return {ok: status >= 200 && status < 300, status, json: async () => body};
}

test("Send retains the original operation and text after lost submit and lookup responses", async () => {
  const storage = new Map([["attention-fixture-session", JSON.stringify(session)]]);
  const routes = [];
  let issued = 0;
  let lookups = 0;
  const fetch = async (route, options) => {
    if (route === "/api/pair" || route === "/api/stream") return reply({error: "rejected"}, 403);
    const body = JSON.parse(options.body);
    routes.push({route, body});
    if (route === "/api/lookup") {
      lookups++;
      if (lookups === 1) return reply({intent: null});
      if (lookups === 2) throw Error("lookup response lost");
      return reply({intent: {operation: "op-one", item: "fixture-one", text: "first answer", state: "fixture-committed"}});
    }
    if (route === "/api/submit") throw Error("submit response lost after commit");
    throw Error(`unexpected route: ${route}`);
  };
  const get = page(storage, fetch, () => { issued++; return "op-one"; });
  get("response").value = "first answer";
  await get("send").onclick();
  assert.match(get("result").textContent, /outcome unknown/);
  assert.equal(JSON.parse(storage.get("attention-fixture-pending-intent")).text, "first answer");
  get("response").value = "changed answer";
  await get("send").onclick();
  assert.equal(issued, 1);
  assert.deepEqual(routes.map(({route}) => route), ["/api/lookup", "/api/submit", "/api/lookup", "/api/lookup"]);
  assert.equal(routes.find(({route}) => route === "/api/submit").body.text, "first answer");
  assert.equal(routes.at(-1).body.operation, "op-one");
  assert.match(get("result").textContent, /fixture-committed/);
  assert.equal(storage.has("attention-fixture-pending-intent"), false);
});

test("reload preserves an unknown operation for same-profile lookup", async () => {
  const storage = new Map([
    ["attention-fixture-session", JSON.stringify(session)],
    ["attention-fixture-pending-intent", JSON.stringify({operation: "op-old", item: "fixture-one",
      text: "old answer", profile: "synthetic-A"})]
  ]);
  let minted = 0;
  const routes = [];
  const get = page(storage, async (route, options) => {
    if (route === "/api/pair" || route === "/api/stream") return reply({error: "rejected"}, 403);
    routes.push({route, body: JSON.parse(options.body)});
    return reply({intent: {operation: "op-old", item: "fixture-one", text: "old answer", state: "fixture-committed"}});
  }, () => { minted++; return "new-op"; });
  assert.match(get("result").textContent, /outcome unknown/);
  await get("send").onclick();
  assert.equal(minted, 0);
  assert.deepEqual(routes.map(({route}) => route), ["/api/lookup"]);
  assert.equal(routes[0].body.operation, "op-old");
  assert.equal(storage.has("attention-fixture-pending-intent"), false);
});

test("definite competing intent is shown as rejection, not an unknown result", async () => {
  const storage = new Map([["attention-fixture-session", JSON.stringify(session)]]);
  const get = page(storage, async route => {
    if (route === "/api/pair" || route === "/api/stream") return reply({error: "rejected"}, 403);
    if (route === "/api/lookup") return reply({intent: null});
    if (route === "/api/submit") return reply({error: "conflict"}, 409);
    throw Error(`unexpected route: ${route}`);
  }, () => "op-competing");
  await get("send").onclick();
  assert.match(get("result").textContent, /not accepted/);
  assert.equal(storage.has("attention-fixture-pending-intent"), false);
});

test("lookup with the same operation and changed content preserves pending response", async () => {
  const pending = {operation: "op-original", item: "fixture-one", text: "original text", profile: "synthetic-A"};
  const storage = new Map([
    ["attention-fixture-session", JSON.stringify(session)],
    ["attention-fixture-pending-intent", JSON.stringify(pending)]
  ]);
  const routes = [];
  const get = page(storage, async (route, options) => {
    if (route === "/api/pair" || route === "/api/stream") return reply({error: "rejected"}, 403);
    routes.push(route);
    assert.equal(JSON.parse(options.body).operation, "op-original");
    return reply({intent: {operation: "op-original", item: "fixture-one",
      text: "different text", state: "fixture-committed"}});
  }, () => { throw Error("must not mint a new operation"); });
  await get("send").onclick();
  assert.deepEqual(routes, ["/api/lookup"]);
  assert.match(get("result").textContent, /Conflict: stored intent differs/);
  assert.deepEqual(JSON.parse(storage.get("attention-fixture-pending-intent")), pending);
});

test("a mismatched submit success cannot clear the original pending response", async () => {
  const storage = new Map([["attention-fixture-session", JSON.stringify(session)]]);
  const routes = [];
  const get = page(storage, async route => {
    if (route === "/api/pair" || route === "/api/stream") return reply({error: "rejected"}, 403);
    routes.push(route);
    if (route === "/api/lookup" && routes.length === 1) return reply({intent: null});
    return reply({intent: {operation: "op-one", item: "fixture-one",
      text: "different text", state: "fixture-committed"}});
  }, () => "op-one");
  get("response").value = "original text";
  await get("send").onclick();
  assert.deepEqual(routes, ["/api/lookup", "/api/submit", "/api/lookup"]);
  assert.match(get("result").textContent, /Conflict: stored intent differs/);
  assert.equal(JSON.parse(storage.get("attention-fixture-pending-intent")).text, "original text");
});
