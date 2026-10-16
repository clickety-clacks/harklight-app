"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname,
  "../Sources/AttentionHostBoundary/Assets/app.js"), "utf8");

class Element {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.events = {};
    this.attributes = {};
    this.textContent = "";
    this.value = "";
    this.hidden = false;
  }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this.children = children; }
  addEventListener(event, handler) { this.events[event] = handler; }
  setAttribute(name, value) { this.attributes[name] = value; }
}

const allText = node => [node.textContent, ...node.children.flatMap(allText)].join(" ");
const response = (body, status = 200) => ({
  ok: status >= 200 && status < 300, status, json: async () => body
});
const snapshot = title => ({revision: 1, requests: [{
  senderID: "same-sender", messageID: "same-message", title, status: "open",
  originalContentJSON: JSON.stringify({title})
}]});

test("late A inspect cannot replace B content after profile switch", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token-A", hostGeneration: "generation-A"})]]);
  let releaseA;
  const oldInspect = new Promise(resolve => { releaseA = resolve; });
  const fetch = async (route, options) => {
    const authorization = options.headers.Authorization || "";
    if (route === "/api/stream") return new Promise(() => {});
    if (route === "/api/pair") return response({token: "token-B", hostGeneration: "generation-B"});
    if (route === "/api/logout") return response({disconnected: true});
    if (route === "/api/observe") {
      return response(snapshot(authorization.includes("token-B") ? "B title" : "A title"));
    }
    if (route === "/api/inspect") {
      return authorization.includes("token-B") ?
        response({...snapshot("B title"), requests: [{...snapshot("B title").requests[0],
          body: "B only"}]}) : oldInspect;
    }
    throw Error(`Unexpected route: ${route}`);
  };
  const sessionStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
    removeItem: key => storage.delete(key)
  };
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => { throw Error("Unexpected sender scene"); }}},
    sessionStorage, fetch, AbortController, TextDecoder, setTimeout
  });
  const flush = () => new Promise(resolve => setImmediate(resolve));
  await flush();
  await flush();
  get("request-list").children[0].events.click();

  await get("disconnect").events.click();
  assert.equal(get("request-details").hidden, true);
  get("pair-secret").value = "B code";
  await get("pair-form").events.submit({preventDefault() {}});
  await get("request-list").children[0].events.click();
  assert.equal(get("task-heading").textContent, "B title");
  get("app-status").children[0].events.click();
  assert.equal(get("request-details").hidden, false);

  releaseA(response(snapshot("A title")));
  await flush();
  assert.equal(get("task-heading").textContent, "B title");
  assert.doesNotMatch(allText(get("receipt")), /A title/);
});

test("task chrome keeps one visible title, compact status and exact details", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const request = {
    accountID: "fictional-sample-account", senderID: "fixture:Facilities", messageID: "opaque-message", title: "Facilities desk",
    body: "Choose the location shown on the floor plan.", status: "answered",
    originalContentJSON: '{"body":"Choose the location shown on the floor plan."}',
    projection: {kind: "sender", scene: {kind: "text", style: "title", text: "Closed"}},
    receiptFacts: {evidence: "Item closed; acceptance unconfirmed",
      originalOperationUncertainty: true},
    receipt: {intentID: "original-intent", opID: "original-operation", exactAnswerJSON: "null"}
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const sessionStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
    removeItem: key => storage.delete(key)
  };
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: mount => {
      const scene = new Element("div"); scene.textContent = "Closed floor plan";
      mount.appendChild(scene);
    }}},
    sessionStorage,
    fetch: async route => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request]});
      }
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();

  assert.equal(get("request-list").children[0].textContent, "Facilities desk");
  assert.equal(get("task-heading").textContent, "Facilities desk");
  assert.match(allText(get("sender-scene")), /Closed floor plan/);
  assert.doesNotMatch(allText(get("sender-scene")), /Choose the location/);
  const instructions = get("instructions-panel").children[0];
  assert.equal(instructions.tag, "details");
  assert.equal(instructions.open, false);
  assert.match(allText(instructions), /Choose the location/);
  instructions.open = true;
  instructions.events.toggle();
  await get("request-list").children[0].events.click();
  assert.equal(get("instructions-panel").children[0].open, true);
  assert.doesNotMatch(allText(get("sender-scene")), /fixture:Facilities/);
  const badge = get("app-status").children[0];
  assert.equal(badge.tag, "button");
  assert.equal(badge.textContent, "Answered");
  assert.match(badge.attributes["aria-label"], /Show request details/);
  badge.events.click();
  assert.equal(get("request-detail").hidden, true);
  assert.equal(get("request-details").hidden, false);
  assert.match(allText(get("receipt")), /acceptance unconfirmed/);
  assert.match(allText(get("receipt")), /original operation outcome is unconfirmed/);
  assert.match(allText(get("receipt")), /fictional-sample-account/);
  assert.match(allText(get("receipt")), /fixture:Facilities/);
  assert.match(allText(get("receipt")), /original-operation/);
  get("details-back").events.click();
  assert.equal(get("request-detail").hidden, false);
  assert.equal(get("request-details").hidden, true);
  request.receiptFacts = {evidence: "Relay accepted original operation",
    ownOutcome: "accepted", originalOperationUncertainty: false};
  await get("request-list").children[0].events.click();
  assert.equal(get("app-status").children[0].textContent, "Answered");
  assert.doesNotMatch(allText(get("request-list")), /fixture:Facilities/);
});

test("visible badge stays lifecycle-only while assistive status retains outcome", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const hints = new Map();
  const request = {senderID: "fixture:Facilities", messageID: "m1",
    title: "Facilities desk", status: "answered", originalContentJSON: "{}",
    projection: {kind: "sender", scene: {kind: "text", style: "title", text: "Closed"}},
    receipt: {intentID: "original-intent", opID: "original-operation", exactAnswerJSON: "null"},
    receiptFacts: {evidence: "Item closed; acceptance unconfirmed",
      originalOperationUncertainty: true}};
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => {}}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    localStorage: {getItem: key => hints.get(key) ?? null,
      setItem: (key, value) => hints.set(key, value), removeItem: key => hints.delete(key)},
    fetch: async route => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect")
        return response({revision: 1, requests: [request]});
      throw Error(`Unexpected route: ${route}`);
    }, AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  const show = async () => get("request-list").children[0].events.click();
  const assertStatus = (visible, spoken) => {
    const [badge, announcement] = get("app-status").children;
    assert.equal(badge.textContent, visible);
    assert.doesNotMatch(badge.textContent, /accepted|unconfirmed|Details/i);
    assert.equal(badge.attributes["aria-label"], `Show request details: ${spoken}`);
    assert.equal(announcement.attributes.role, "status");
    assert.equal(announcement.textContent, spoken);
  };

  await show();
  assertStatus("Answered", "Answered. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.");
  assert.match(allText(get("receipt")), /acceptance unconfirmed/);
  request.receiptFacts = {evidence: "Relay accepted original operation",
    ownOutcome: "accepted", originalOperationUncertainty: false};
  await show();
  assertStatus("Answered", "Answered. Your submission is recorded as accepted.");
  request.status = "pending";
  delete request.receipt;
  delete request.receiptFacts;
  hints.set("attention-host-attempt-hint", JSON.stringify({hostGeneration: "generation",
    key: `${request.senderID.length}:${request.senderID}${request.messageID.length}:${request.messageID}`,
    intentID: "original-intent"}));
  await show();
  assertStatus("Pending", "Pending. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.");
  hints.delete("attention-host-attempt-hint");
  request.status = "open";
  await show();
  assertStatus("Open", "Open. No answer has been submitted.");
  request.status = "answered";
  await show();
  assertStatus("Answered", "Answered. No result for this device's submission is established.");
});

test("lost send response keeps only an opaque recovery hint and finds native receipt", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const sessionStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
    removeItem: key => storage.delete(key)
  };
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  let receiptFound = false;
  let submits = 0;
  let minted = 0;
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", body: "Keep this instruction", status: receiptFound ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: "Exact draft", textByAction: []}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(receiptFound ? {receipt: {intentID: "original-intent", opID: "native-operation",
      exactAnswerJSON: '"Exact draft"'}} : {})});
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: mount => {
      const scene = new Element("div"); scene.textContent = "Answer";
      mount.appendChild(scene);
    }}},
    sessionStorage, crypto: {randomUUID: () => { minted++; return "original-intent"; }},
    fetch: async (route, options) => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request()]});
      }
      if (route === "/api/submit") {
        submits++;
        assert.deepEqual(JSON.parse(options.body).inputs,
          [{kind: "text", input: "note", text: "Exact draft"}]);
        throw Error("response dropped");
      }
      if (route === "/api/lookup") {
        assert.equal(JSON.parse(options.body).intentID, "original-intent");
        receiptFound = true;
        return response({intentID: "original-intent", opID: "native-operation",
          senderID: selector.senderID, messageID: selector.messageID});
      }
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  await get("action-row").children[0].events.click();
  const hint = JSON.parse(storage.get("attention-host-attempt-hint"));
  assert.equal(hint.intentID, "original-intent");
  assert.equal(JSON.stringify(hint).includes("Exact draft"), false);
  assert.match(get("host-state").textContent, /outcome unknown/);
  await get("action-row").children[0].events.click();
  assert.equal(submits, 1);
  assert.equal(minted, 1);
  assert.equal(storage.has("attention-host-attempt-hint"), false);
  assert.match(allText(get("receipt")), /native-operation/);
});

test("uncommitted lost send needs a native fence before a new reviewed draft intent", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const opaqueHints = new Map();
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  const ids = ["00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000002"];
  const sends = [];
  let committed = false;
  let draftText = "Saved exact draft";
  let fencedID = null;
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", status: committed ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: draftText}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(committed ? {receipt: {intentID: ids[1], opID: "committed-operation",
      exactAnswerJSON: JSON.stringify(draftText)}} : {})});
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => {}}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    localStorage: {getItem: key => opaqueHints.get(key) ?? null,
      setItem: (key, value) => opaqueHints.set(key, value),
      removeItem: key => opaqueHints.delete(key)},
    crypto: {randomUUID: () => ids[sends.length]},
    fetch: async (route, options) => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request()]});
      }
      if (route === "/api/submit") {
        sends.push(JSON.parse(options.body));
        if (sends.length === 1) throw Error("response dropped before commit");
        assert.equal(fencedID, ids[0], "A new ID requires a durable fence for the first send");
        committed = true;
        return response({intentID: ids[1], opID: "committed-operation"});
      }
      if (route === "/api/lookup") return response({error: "intent_missing"}, 404);
      if (route === "/api/fence-intent") {
        fencedID = JSON.parse(options.body).intentID;
        return response({fenced: true});
      }
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  await get("action-row").children[0].events.click();
  assert.equal(sends.length, 1);
  assert.equal(JSON.parse(opaqueHints.get("attention-host-attempt-hint")).intentID, ids[0]);
  assert.equal(storage.has("attention-host-attempt-hint"), false);
  await get("action-row").children[0].events.click();
  assert.equal(sends.length, 1);
  assert.equal(fencedID, ids[0]);
  assert.equal(opaqueHints.has("attention-host-attempt-hint"), false);
  assert.match(get("host-state").textContent, /safely canceled/);
  draftText = "Changed after fence";
  await get("action-row").children[0].events.click();
  assert.equal(sends.length, 2);
  assert.deepEqual(sends.map(item => item.intentID), ids);
  assert.deepEqual(sends.map(item => item.inputs), [
    [{kind: "text", input: "note", text: "Saved exact draft"}],
    [{kind: "text", input: "note", text: "Changed after fence"}]
  ]);
  assert.equal(opaqueHints.has("attention-host-attempt-hint"), false);
  assert.match(allText(get("receipt")), /committed-operation/);
});

test("late original HTTP completion cannot clear a newer intent after durable fence", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const ids = ["00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000002"];
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  let releaseOriginal;
  let sends = 0;
  let fenced = false;
  let committed = false;
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", status: committed ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: "Exact saved draft"}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(committed ? {receipt: {intentID: ids[1], opID: "second-operation",
      exactAnswerJSON: '"Exact saved draft"'}} : {})});
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => {}}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    crypto: {randomUUID: () => ids[sends]},
    fetch: async (route, options) => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect")
        return response({revision: 1, requests: [request()]});
      if (route === "/api/lookup") return response({error: "intent_missing"}, 404);
      if (route === "/api/fence-intent") {
        assert.equal(JSON.parse(options.body).intentID, ids[0]);
        fenced = true;
        return response({fenced: true});
      }
      if (route === "/api/submit") {
        const body = JSON.parse(options.body);
        sends++;
        if (body.intentID === ids[0])
          return new Promise(resolve => { releaseOriginal = () => resolve(response({error: "intentConflict"}, 409)); });
        assert.equal(fenced, true);
        committed = true;
        return response({intentID: ids[1], opID: "second-operation"});
      }
      throw Error(`Unexpected route: ${route}`);
    }, AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  const first = get("action-row").children[0].events.click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(sends, 1);
  await get("action-row").children[0].events.click();
  assert.equal(fenced, true);
  assert.equal(sends, 1);
  await get("action-row").children[0].events.click();
  assert.equal(sends, 2);
  releaseOriginal();
  await first;
  assert.equal(storage.has("attention-host-attempt-hint"), false);
  assert.match(allText(get("receipt")), /second-operation/);
});

test("pane reload retains original intent while a changed draft waits for a late submit fence", async () => {
  const sessions = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const hints = new Map();
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  const ids = ["00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000002"];
  const sends = [];
  let minted = 0;
  let savedText = "Original exact answer";
  let fenced = false;
  let committed = false;
  let releaseOriginal;
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", status: committed ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: savedText}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(committed ? {receipt: {intentID: ids[1], opID: "changed-operation",
      exactAnswerJSON: JSON.stringify(savedText)}} : {})});
  const fetch = async (route, options) => {
    if (route === "/api/stream") return new Promise(() => {});
    if (route === "/api/observe" || route === "/api/inspect")
      return response({revision: 1, requests: [request()]});
    if (route === "/api/lookup") {
      assert.equal(JSON.parse(options.body).intentID, ids[0]);
      return response({error: "intent_missing"}, 404);
    }
    if (route === "/api/fence-intent") {
      assert.equal(JSON.parse(options.body).intentID, ids[0]);
      fenced = true;
      return response({fenced: true});
    }
    if (route === "/api/submit") {
      const body = JSON.parse(options.body);
      sends.push(body);
      if (body.intentID === ids[0]) {
        return new Promise(resolve => {
          releaseOriginal = () => resolve(response({error: "intentConflict"}, 409));
        });
      }
      assert.equal(fenced, true, "A replacement cannot pass a late original without a fence");
      committed = true;
      return response({intentID: ids[1], opID: "changed-operation"});
    }
    throw Error(`Unexpected route: ${route}`);
  };
  const openPane = () => {
    const elements = new Map();
    const get = id => {
      if (!elements.has(id)) elements.set(id, new Element(id));
      return elements.get(id);
    };
    vm.runInNewContext(source, {
      document: {getElementById: get, createElement: tag => new Element(tag)},
      window: {AttentionSender: {renderSenderScene: () => {}}},
      sessionStorage: {getItem: key => sessions.get(key) ?? null,
        setItem: (key, value) => sessions.set(key, value),
        removeItem: key => sessions.delete(key)},
      localStorage: {getItem: key => hints.get(key) ?? null,
        setItem: (key, value) => hints.set(key, value),
        removeItem: key => hints.delete(key)},
      crypto: {randomUUID: () => ids[minted++]},
      fetch, AbortController, TextDecoder, setTimeout
    });
    return get;
  };

  const originalPane = openPane();
  await new Promise(resolve => setImmediate(resolve));
  await originalPane("request-list").children[0].events.click();
  const originalSend = originalPane("action-row").children[0].events.click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(sends.length, 1);
  assert.deepEqual(sends[0].inputs,
    [{kind: "text", input: "note", text: "Original exact answer"}]);
  assert.equal(JSON.parse(hints.get("attention-host-attempt-hint")).intentID, ids[0]);
  assert.doesNotMatch(hints.get("attention-host-attempt-hint"), /Original exact answer/);

  savedText = "Changed after reload";
  const reloadedPane = openPane();
  await new Promise(resolve => setImmediate(resolve));
  await reloadedPane("request-list").children[0].events.click();
  assert.match(reloadedPane("action-row").children[0].textContent, /Check/);
  await reloadedPane("action-row").children[0].events.click();
  assert.equal(fenced, true);
  assert.equal(sends.length, 1, "Recovery cannot submit changed text on its own");
  assert.match(reloadedPane("host-state").textContent, /safely canceled/);
  await reloadedPane("action-row").children[0].events.click();
  assert.equal(sends.length, 2);
  assert.deepEqual(sends.map(send => send.intentID), ids);
  assert.deepEqual(sends[1].inputs,
    [{kind: "text", input: "note", text: "Changed after reload"}]);
  releaseOriginal();
  await originalSend;
  assert.equal(hints.has("attention-host-attempt-hint"), false);
  assert.match(allText(reloadedPane("receipt")), /changed-operation/);
});

test("competing native intent is looked up instead of sending a third answer", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  const intentID = "00000000-0000-4000-8000-000000000001";
  const winnerID = "00000000-0000-4000-8000-000000000003";
  let sends = 0;
  let winnerFound = false;
  const lookups = [];
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", status: winnerFound ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: "Saved exact draft"}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(winnerFound ? {receipt: {intentID: winnerID, opID: "winner-operation",
      exactAnswerJSON: '"Different answer"'}} : {})});
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => {}}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    crypto: {randomUUID: () => intentID},
    fetch: async (route, options) => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request()]});
      }
      if (route === "/api/submit") {
        sends++;
        return response({error: "competing_intent", activeIntentID: winnerID}, 409);
      }
      if (route === "/api/lookup") {
        const id = JSON.parse(options.body).intentID;
        lookups.push(id);
        assert.equal(id, winnerID);
        winnerFound = true;
        return response({intentID: winnerID, opID: "winner-operation",
          senderID: selector.senderID, messageID: selector.messageID});
      }
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  await get("action-row").children[0].events.click();
  assert.equal(sends, 1);
  assert.deepEqual(lookups, [winnerID]);
  assert.equal(storage.has("attention-host-attempt-hint"), false);
  assert.match(allText(get("receipt")), /winner-operation/);
  assert.match(get("host-state").textContent, /different submission/);
});

test("a failed native draft save blocks send until that field is saved", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const selector = {senderID: "fixture:Facilities", messageID: "m1",
    documentID: "doc", submissionID: "submit"};
  const intentID = "00000000-0000-4000-8000-000000000001";
  let editDraft;
  let draftSaves = 0;
  let storedText = "Old answer";
  let submitted = null;
  const request = () => ({senderID: selector.senderID, messageID: selector.messageID,
    title: "Facilities desk", status: submitted ? "pending" : "open",
    originalContentJSON: "{}", selector,
    draft: {inputs: [{id: "note", text: storedText}]},
    projection: {kind: "sender", inputs: [{id: "note", kind: "text"}],
      scene: {kind: "text", style: "title", text: "Answer"}, submissionLabel: "Send"},
    ...(submitted ? {receipt: {intentID, opID: "saved-operation",
      exactAnswerJSON: '"New answer"'}} : {})});
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: (_mount, _projection, _scene, options) => {
      editDraft = options.onDraft;
    }}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    crypto: {randomUUID: () => intentID},
    fetch: async (route, options) => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request()]});
      }
      if (route === "/api/draft") {
        draftSaves++;
        if (draftSaves === 1) return response({error: "durable_store_unavailable"}, 503);
        storedText = JSON.parse(options.body).edit.text;
        return response({saved: true});
      }
      if (route === "/api/submit") {
        submitted = JSON.parse(options.body);
        return response({intentID, opID: "saved-operation"});
      }
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  editDraft("note", {text: "New answer"});
  await new Promise(resolve => setImmediate(resolve));
  await get("action-row").children[0].events.click();
  assert.equal(submitted, null);
  assert.match(get("host-state").textContent, /Draft was not saved/);
  editDraft("note", {text: "New answer"});
  await new Promise(resolve => setImmediate(resolve));
  await get("action-row").children[0].events.click();
  assert.equal(draftSaves, 2);
  assert.deepEqual(submitted.inputs, [{kind: "text", input: "note", text: "New answer"}]);
  assert.match(allText(get("receipt")), /saved-operation/);
});

test("blank point coordinate is not coerced to zero for submission", async () => {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element(id));
    return elements.get(id);
  };
  const storage = new Map([["attention-host-session",
    JSON.stringify({token: "token", hostGeneration: "generation"})]]);
  const request = {senderID: "fixture:Facilities", messageID: "m1", title: "Location",
    status: "open", originalContentJSON: "{}",
    selector: {senderID: "fixture:Facilities", messageID: "m1", documentID: "d", submissionID: "s"},
    draft: {inputs: [{id: "location", point: {x: 400, y: 500},
      horizontalText: "", verticalText: ""}]},
    projection: {kind: "sender", inputs: [{id: "location", kind: "point"}],
      scene: {kind: "text", style: "title", text: "Location"}, submissionLabel: "Send"}};
  let submits = 0;
  vm.runInNewContext(source, {
    document: {getElementById: get, createElement: tag => new Element(tag)},
    window: {AttentionSender: {renderSenderScene: () => {}}},
    sessionStorage: {getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)},
    crypto: {randomUUID: () => "not-used"},
    fetch: async route => {
      if (route === "/api/stream") return new Promise(() => {});
      if (route === "/api/observe" || route === "/api/inspect") {
        return response({revision: 1, requests: [request]});
      }
      if (route === "/api/submit") submits++;
      throw Error(`Unexpected route: ${route}`);
    },
    AbortController, TextDecoder, setTimeout
  });
  await new Promise(resolve => setImmediate(resolve));
  await get("request-list").children[0].events.click();
  await get("action-row").children[0].events.click();
  assert.equal(submits, 0);
  assert.match(get("host-state").textContent, /valid point/);
  assert.equal(storage.has("attention-host-attempt-hint"), false);
});
