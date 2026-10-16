"use strict";
const $ = id => document.getElementById(id);
let session = null;
try { session = JSON.parse(sessionStorage.getItem("attention-fixture-session") || "null"); } catch (_) {}
const pendingKey = "attention-fixture-pending-intent";
let pendingIntent = null;
let sendInFlight = false;
try {
  const saved = JSON.parse(sessionStorage.getItem(pendingKey) || "null");
  if (saved && typeof saved.operation === "string" && typeof saved.text === "string" &&
      typeof saved.profile === "string") pendingIntent = saved;
} catch (_) {}
const setStatus = value => { $("status").textContent = value; };
if (pendingIntent) $("result").textContent = "Original response outcome unknown; Send will recover it";
async function probeGuestBoundary() {
  const requests = [["/api/pair", {profile: "synthetic-A", secret: "invalid-probe"}],
                    ["/api/stream", {profile: "synthetic-A", generation: "invalid-probe"}]];
  const results = [];
  for (const [route, body] of requests) {
    try {
      const response = await fetch(route, {method: "POST", mode: "same-origin", credentials: "omit",
        headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
      results.push(`${route}: ${response.status}`);
    } catch (_) { results.push(`${route}: fetch failed`); }
  }
  $("probe-status").textContent = `Unauthenticated guest probes: ${results.join("; ")}`;
}
probeGuestBoundary();
async function call(route, body, authenticated = true) {
  if (authenticated && !session) throw Error("Connect this pane first");
  const response = await fetch(route, {
    method: "POST", mode: "same-origin", credentials: "omit", cache: "no-store",
    headers: {"Content-Type": "application/json", ...(authenticated ? {Authorization: `Bearer ${session.token}`} : {})},
    body: JSON.stringify({...body, profile: authenticated ? session.profile : "synthetic-A",
      ...(authenticated ? {generation: session.generation} : {})})
  });
  if (!response.ok) {
    const error = Error(`Host rejected ${route} (${response.status})`);
    error.status = response.status;
    throw error;
  }
  return response;
}
async function json(route, body = {}, authenticated = true) { return (await call(route, body, authenticated)).json(); }
function displayError(error) { setStatus(error.message); }
$("pair").onclick = async () => {
  const input = $("secret");
  const candidate = input.value; input.value = "";
  try {
    session = await json("/api/pair", {secret: candidate}, false);
    sessionStorage.setItem("attention-fixture-session", JSON.stringify(session));
    setStatus("Connected to synthetic profile");
  } catch (error) { displayError(error); }
};
$("inspect").onclick = async () => {
  try {
    const snapshot = await json("/api/inspect");
    $("item").textContent = snapshot.item.text;
    $("result").textContent = `Revision ${snapshot.revision}; intent ${snapshot.intent ? snapshot.intent.state : "none"}`;
  } catch (error) { displayError(error); }
};
$("stream").onclick = async () => {
  try {
    const response = await call("/api/stream", {});
    const reader = response.body.getReader(); const decoder = new TextDecoder();
    let buffer = "", count = 0;
    while (true) {
      const {value, done} = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, {stream: true});
      while (buffer.includes("\n")) {
        const cut = buffer.indexOf("\n");
        const line = buffer.slice(0, cut); buffer = buffer.slice(cut + 1);
        if (line) { const snap = JSON.parse(line); count++; $("stream-status").textContent = `Snapshot ${snap.snapshot + 1} received (${count} incremental)`; }
      }
    }
    $("stream-status").textContent += "; stream ended; reconnect is available";
  } catch (error) { displayError(error); }
};
function resolved(intent) {
  if (!intent || intent.operation !== pendingIntent.operation ||
      intent.item !== pendingIntent.item || intent.text !== pendingIntent.text) {
    const error = Error("Stored intent differs from the original response");
    error.code = "intent_mismatch";
    throw error;
  }
  $("result").textContent = `Synthetic local intent: ${intent.state}`;
  clearPending();
}
function clearPending() {
  pendingIntent = null;
  sessionStorage.removeItem(pendingKey);
}
async function lookupPending() {
  const found = await json("/api/lookup", {operation: pendingIntent.operation});
  if (found.intent) { resolved(found.intent); return true; }
  return false;
}
function unresolved(error) {
  $("result").textContent = error?.code === "intent_mismatch"
    ? "Conflict: stored intent differs from the original response; pending answer retained"
    : "Original response outcome unknown; retry Send to look up the same operation";
}
async function recoverPending() {
  if (!session) { setStatus("Connect this pane to recover the original response"); return; }
  if (pendingIntent.profile !== session.profile) {
    setStatus("Pending response belongs to another profile"); return;
  }
  try {
    if (await lookupPending()) return;
  } catch (error) {
    unresolved(error);
    return;
  }
  try {
    const result = await json("/api/submit", {operation: pendingIntent.operation,
      item: "fixture-one", text: pendingIntent.text});
    resolved(result.intent);
  } catch (error) {
    if (error.status === 409) {
      try {
        if (await lookupPending()) return;
      } catch (lookupError) { unresolved(lookupError); return; }
      clearPending();
      $("result").textContent = "Another synthetic intent exists; this response was not accepted";
      return;
    }
    try { if (await lookupPending()) return; } catch (lookupError) { unresolved(lookupError); return; }
    unresolved(error);
  }
}
$("send").onclick = async () => {
  if (sendInFlight) return;
  if (!session) { setStatus("Connect this pane first"); return; }
  if (!pendingIntent) {
    pendingIntent = {operation: crypto.randomUUID(), item: "fixture-one",
      text: $("response").value, profile: session.profile};
    sessionStorage.setItem(pendingKey, JSON.stringify(pendingIntent));
  }
  sendInFlight = true;
  try { await recoverPending(); } finally { sendInFlight = false; }
};
$("logout").onclick = async () => {
  try { if (session) await json("/api/logout"); } catch (_) {}
  session = null; sessionStorage.removeItem("attention-fixture-session");
  $("item").textContent = "";
  $("result").textContent = pendingIntent ? "Original response outcome unknown; reconnect to recover it" : "";
  setStatus("Disconnected");
};
