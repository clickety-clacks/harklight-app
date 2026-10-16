"use strict";

// This pane renders native-scoped snapshots and retains only its presentation
// token. Answer literals and durable intent/outbox state stay in AttentionDomain.
const pairForm = document.getElementById("pair-form");
const pairSecret = document.getElementById("pair-secret");
const pairState = document.getElementById("pair-state");
const hostState = document.getElementById("host-state");
const workspace = document.getElementById("workspace");
const pairing = document.getElementById("pairing");
const requestList = document.getElementById("request-list");
const requestDetail = document.getElementById("request-detail");
const requestDetails = document.getElementById("request-details");
const taskHeading = document.getElementById("task-heading");
const detailsHeading = document.getElementById("details-heading");
const instructionsPanel = document.getElementById("instructions-panel");
const appStatus = document.getElementById("app-status");
const senderScene = document.getElementById("sender-scene");
const receiptPanel = document.getElementById("receipt");
const actionRow = document.getElementById("action-row");
const stored = sessionStorage.getItem("attention-host-session");
let session = null;
try {
  const parsed = JSON.parse(stored);
  if (typeof parsed.token === "string" && typeof parsed.hostGeneration === "string") {
    session = parsed;
  }
} catch (_) { sessionStorage.removeItem("attention-host-session"); }
let selectedKey = null;
let revision = 0;
let currentSnapshot = null;
let streamAbort = null;
let draftWrites = Promise.resolve();
const unsavedDraftEdits = new Map();
let draftEditSerial = 0;
let instructionsExpanded = false;
const attemptKey = "attention-host-attempt-hint";
// The hint contains no answer or credential; keep it across pane reloads so
// a newly paired view can recover an in-flight operation on the same host.
const attemptStorage = typeof localStorage === "undefined" ? sessionStorage : localStorage;

async function call(route, body, authenticated = true, signal = undefined) {
  const headers = {"Content-Type": "application/json"};
  if (authenticated) {
    if (!session) throw Error("Connect this pane first");
    headers.Authorization = `Bearer ${session.token}`;
  }
  const response = await fetch(route, {
    method: "POST", mode: "same-origin", credentials: "omit", cache: "no-store",
    headers, body: JSON.stringify(body), signal
  });
  const data = await response.json();
  if (!response.ok) {
    const error = Error(`Request failed (${response.status})`);
    error.status = response.status;
    error.details = data;
    throw error;
  }
  return data;
}

function text(parent, tag, content) {
  const node = document.createElement(tag);
  node.textContent = content;
  parent.appendChild(node);
  return node;
}

function keyOf(request) {
  return `${request.senderID.length}:${request.senderID}${request.messageID.length}:${request.messageID}`;
}

function disconnected() {
  streamAbort?.abort();
  streamAbort = null;
  session = null;
  sessionStorage.removeItem("attention-host-session");
  // A session expiry or explicit disconnect cannot prove an in-flight answer
  // did not commit. Preserve the opaque hint for a later same-host pairing.
  selectedKey = null;
  currentSnapshot = null;
  revision = 0;
  draftWrites = Promise.resolve();
  unsavedDraftEdits.clear();
  requestList.replaceChildren();
  taskHeading.textContent = "";
  appStatus.replaceChildren();
  instructionsPanel.replaceChildren();
  senderScene.replaceChildren();
  receiptPanel.replaceChildren();
  actionRow.replaceChildren();
  requestDetails.hidden = true;
  requestDetail.hidden = false;
  workspace.setAttribute("data-details-open", "false");
  instructionsExpanded = false;
  workspace.hidden = true;
  pairing.hidden = false;
  hostState.textContent = "Connect this pane";
}

function statusLabel(request) {
  return request.status.charAt(0).toUpperCase() + request.status.slice(1);
}

function accessibleStatus(request) {
  const state = statusLabel(request);
  if (attemptFor(request) && !request.receipt) {
    return `${state}. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.`;
  }
  if (request.receipt && request.receiptFacts?.ownOutcome === "accepted") {
    return `${state}. Your submission is recorded as accepted.`;
  }
  if (request.receipt && request.receiptFacts?.originalOperationUncertainty) {
    return `${state}. Your submission outcome is unconfirmed; the original operation outcome remains unresolved.`;
  }
  if (request.status === "open" && !request.receipt) return `${state}. No answer has been submitted.`;
  if (["answered", "cleared", "expired", "superseded"].includes(request.status)) {
    return `${state}. No result for this device's submission is established.`;
  }
  return state;
}

function showRequestDetails() {
  requestDetail.hidden = true;
  requestDetails.hidden = false;
  workspace.setAttribute("data-details-open", "true");
  detailsHeading.focus?.();
}

function hideRequestDetails() {
  requestDetails.hidden = true;
  requestDetail.hidden = false;
  workspace.setAttribute("data-details-open", "false");
  appStatus.children[0]?.focus?.();
}

function field(parent, label, value) {
  const row = document.createElement("p");
  row.className = "meta-field";
  text(row, "strong", label);
  text(row, "span", value);
  parent.appendChild(row);
}

function senderDraft(request) {
  const saved = Object.fromEntries((request.draft?.inputs || []).map(input => [input.id, input]));
  return Object.fromEntries((request.projection?.inputs || []).map(input => {
    const entry = saved[input.id] || {};
    const selected = entry.selectedAction;
    const answer = (entry.textByAction || []).find(item => item.action === selected);
    const coordinate = value => typeof value === "string" && /^[0-9]+$/.test(value) ? Number(value) : null;
    const x = entry.horizontalText == null ? entry.point?.x : coordinate(entry.horizontalText);
    const y = entry.verticalText == null ? entry.point?.y : coordinate(entry.verticalText);
    const point = Number.isInteger(x) && Number.isInteger(y) &&
      x >= 0 && x <= 1000 && y >= 0 && y <= 1000 ? {x, y} : null;
    return [input.id, {action: selected, text: input.kind === "response" ? answer?.text : entry.text,
      point}];
  }));
}

function typedInputs(request) {
  const draft = senderDraft(request);
  if (request.projection.kind === "sender") {
    return request.projection.inputs.map(input => {
      const saved = draft[input.id] || {};
      if (input.kind === "response") {
        const action = input.actions.find(item => item.id === saved.action);
        if (!action) throw Error("Choose a response first");
        return action.kind === "text" ?
          {kind: "responseText", input: input.id, action: action.id, text: saved.text ?? ""} :
          {kind: "responseValue", input: input.id, action: action.id};
      }
      if (input.kind === "text") return {kind: "text", input: input.id, text: saved.text ?? ""};
      if (!saved.point) throw Error("Choose a valid point first");
      return {kind: "point", input: input.id, x: saved.point.x, y: saved.point.y};
    });
  }
  throw Error("This request cannot be submitted here");
}

function attemptFor(request) {
  try {
    const attempt = JSON.parse(attemptStorage.getItem(attemptKey));
    return attempt?.hostGeneration === session?.hostGeneration &&
      attempt?.key === keyOf(request) ? attempt : null;
  } catch (_) { return null; }
}

function receiptMatches(receipt, request, intentID) {
  return typeof receipt?.intentID === "string" &&
    receipt.intentID.toLowerCase() === intentID.toLowerCase() &&
    receipt.senderID === request.senderID && receipt.messageID === request.messageID;
}

function draftChanged(request, inputID, value) {
  const input = request.projection.inputs.find(item => item.id === inputID);
  if (!input || !request.selector) return;
  const edit = input.kind === "response" ? {kind: "response", action: value.action,
    ...(Object.hasOwn(value, "text") ? {text: value.text} : {})} :
    input.kind === "text" ? {kind: "text", text: value.text} :
      {kind: "point", x: value.point.x, y: value.point.y};
  const scopedSession = session;
  const scopedKey = keyOf(request);
  let unsavedInputs = unsavedDraftEdits.get(scopedKey);
  if (!unsavedInputs) {
    unsavedInputs = new Map();
    unsavedDraftEdits.set(scopedKey, unsavedInputs);
  }
  const editSerial = ++draftEditSerial;
  unsavedInputs.set(inputID, editSerial);
  draftWrites = draftWrites.catch(() => {}).then(async () => {
    if (session !== scopedSession || selectedKey !== scopedKey) return;
    try {
      await call("/api/draft", {hostGeneration: scopedSession.hostGeneration,
        selector: request.selector, input: inputID, edit});
      if (unsavedInputs.get(inputID) === editSerial) {
        unsavedInputs.delete(inputID);
        if (unsavedInputs.size === 0 && unsavedDraftEdits.get(scopedKey) === unsavedInputs) {
          unsavedDraftEdits.delete(scopedKey);
        }
      }
      if (session === scopedSession && selectedKey === scopedKey &&
          !(input.kind === "text" || Object.hasOwn(value, "text"))) await inspect(request);
    } catch (error) {
      if (session !== scopedSession) return;
      if (error.status === 403) disconnected();
      else hostState.textContent = "Unable to save this draft";
    }
  });
}

async function submitOrRecover(request) {
  const scopedSession = session;
  const scopedKey = keyOf(request);
  const current = () => session === scopedSession && selectedKey === scopedKey;
  const pendingWrites = draftWrites;
  await pendingWrites;
  if (!current()) return;
  if (draftWrites !== pendingWrites) {
    hostState.textContent = "Draft changed; review it before sending";
    return;
  }
  if (unsavedDraftEdits.get(scopedKey)?.size) {
    hostState.textContent = "Draft was not saved; edit the affected field before sending";
    return;
  }
  const fresh = await call("/api/inspect", {hostGeneration: scopedSession.hostGeneration,
    senderID: request.senderID, messageID: request.messageID});
  if (!current()) return;
  const latest = fresh.requests[0];
  if (latest?.receipt) {
    if (attemptFor(request) && latest.receipt.intentID !== attemptFor(request).intentID) {
      attemptStorage.removeItem(attemptKey);
      renderDetail(latest);
      hostState.textContent = "A different submission was recorded for this request; review details";
      return;
    }
    attemptStorage.removeItem(attemptKey);
    renderDetail(latest);
    return;
  }
  let attempt = attemptFor(request);
  if (attempt) {
    try {
      const recovered = await call("/api/lookup", {hostGeneration: scopedSession.hostGeneration,
        intentID: attempt.intentID});
      if (!current()) return;
      if (!receiptMatches(recovered, request, attempt.intentID)) {
        hostState.textContent = "Original submission outcome unknown; check again before sending";
        return;
      }
      attemptStorage.removeItem(attemptKey);
      await inspect(request);
      return;
    } catch (error) {
      if (!current()) return;
      if (error.status !== 404) {
        if (error.status === 403) disconnected();
        else hostState.textContent = "Original submission outcome unknown; check again before sending";
        return;
      }
      // A lookup miss can race a submit whose HTTP body has not entered the
      // native handler yet. Only the durable native fence proves no commit.
      try {
        const resolution = await call("/api/fence-intent", {
          hostGeneration: scopedSession.hostGeneration,
          senderID: request.senderID, messageID: request.messageID,
          intentID: attempt.intentID
        });
        if (!current()) return;
        if (receiptMatches(resolution, request, attempt.intentID)) {
          attemptStorage.removeItem(attemptKey);
          await inspect(request);
          return;
        }
        if (resolution?.fenced !== true) {
          hostState.textContent = "Original submission outcome unknown; check again before sending";
          return;
        }
        attemptStorage.removeItem(attemptKey);
        await inspect(request);
        if (current()) hostState.textContent =
          "Original send was safely canceled; review the current draft before sending again";
        return;
      } catch (fenceError) {
        if (!current()) return;
        if (fenceError.status === 403) disconnected();
        else hostState.textContent = "Original submission outcome unknown; check again before sending";
        return;
      }
    }
  }
  if (latest?.status !== "open" || !latest.selector) {
    renderDetail(latest);
    return;
  }
  if (draftWrites !== pendingWrites || unsavedDraftEdits.get(scopedKey)?.size) {
    hostState.textContent = "Draft changed or was not saved; review it before sending";
    return;
  }
  const inputs = typedInputs(latest);
  attempt = {hostGeneration: scopedSession.hostGeneration, key: scopedKey,
    intentID: crypto.randomUUID()};
  // Only an opaque attempt handle lives in the pane. The native port owns the
  // exact inputs, answer, receipt and outbox; this hint cannot replay a send.
  attemptStorage.setItem(attemptKey, JSON.stringify(attempt));
  try {
    await call("/api/submit", {hostGeneration: scopedSession.hostGeneration,
      selector: latest.selector, intentID: attempt.intentID, inputs});
    if (current() && attemptFor(request)?.intentID === attempt.intentID) {
      attemptStorage.removeItem(attemptKey);
      await inspect(request);
    }
  } catch (error) {
    if (!current() || attemptFor(request)?.intentID !== attempt.intentID) return;
    if (error.status === 403) { disconnected(); return; }
    const activeID = error.details?.activeIntentID;
    if (error.status === 409 && error.details?.error === "competing_intent" &&
        typeof activeID === "string") {
      try {
        const winner = await call("/api/lookup", {hostGeneration: scopedSession.hostGeneration,
          intentID: activeID});
        if (!current()) return;
        if (!receiptMatches(winner, request, activeID)) throw Error("Mismatched competing receipt");
        attemptStorage.removeItem(attemptKey);
        await inspect(request);
        if (current()) hostState.textContent =
          "A different submission was recorded for this request; review details";
      } catch (lookupError) {
        if (!current()) return;
        if (lookupError.status === 403) disconnected();
        else hostState.textContent = "Original submission outcome unknown; check again before sending";
      }
      return;
    }
    if (error.status === 400 || error.status === 409) {
      // A definite validation/conflict response cannot have committed this send.
      attemptStorage.removeItem(attemptKey);
      hostState.textContent = "Submission was not accepted";
      return;
    }
    hostState.textContent = "Original submission outcome unknown; check again before sending";
  }
}

function renderDetail(request) {
  appStatus.replaceChildren();
  instructionsPanel.replaceChildren();
  senderScene.replaceChildren();
  receiptPanel.replaceChildren();
  actionRow.replaceChildren();
  if (!request) { taskHeading.textContent = ""; return; }
  if (request.receipt && attemptFor(request)?.intentID === request.receipt.intentID) {
    attemptStorage.removeItem(attemptKey);
  }
  taskHeading.textContent = request.title || "Request";
  const lifecycle = text(appStatus, "button", statusLabel(request));
  lifecycle.type = "button";
  lifecycle.className = "lifecycle-badge";
  lifecycle.setAttribute("aria-label", `Show request details: ${accessibleStatus(request)}`);
  lifecycle.addEventListener("click", showRequestDetails);
  const announcement = text(appStatus, "span", accessibleStatus(request));
  announcement.className = "visually-hidden";
  announcement.setAttribute("role", "status");

  if (request.body !== undefined) {
    if (request.projection?.kind === "sender") {
      const instructions = document.createElement("details");
      instructions.open = instructionsExpanded;
      text(instructions, "summary", "Message instructions");
      text(instructions, "p", request.body);
      instructions.addEventListener("toggle", () => { instructionsExpanded = instructions.open; });
      instructionsPanel.appendChild(instructions);
    } else {
      text(instructionsPanel, "p", request.body);
    }
  }
  if (request.projection?.kind === "sender") {
    const scene = document.createElement("div");
    senderScene.appendChild(scene);
    window.AttentionSender.renderSenderScene(scene, request.projection,
      request.projection.scene, request.status === "open" && request.selector && !request.receipt ?
        {editable: true, draft: senderDraft(request),
          onDraft: (id, value) => draftChanged(request, id, value)} : {});
  } else if (request.projection?.kind === "unsupported") {
    text(senderScene, "p", request.projection.reason === "missing" ?
      "No supported sender interface was supplied." :
      "This sender interface is not supported here.");
  }

  const outcome = document.createElement("section");
  text(outcome, "h3", "Outcome");
  field(outcome, "Item status", request.status);
  if (request.receiptFacts) {
    text(outcome, "p", request.receiptFacts.evidence);
    if (request.receiptFacts.originalOperationUncertainty) {
      text(outcome, "p", "The original operation outcome is unconfirmed.");
    }
  } else if (attemptFor(request)) {
    text(outcome, "p", "The original submission outcome is unconfirmed; check the same intent.");
  } else {
    text(outcome, "p", "No original submission outcome is confirmed here.");
  }
  receiptPanel.appendChild(outcome);
  const original = document.createElement("section");
  text(original, "h3", "Original message");
  field(original, "Title", request.title === undefined ? "Absent" : request.title);
  field(original, "Body", request.body === undefined ? "Absent" : request.body);
  text(original, "pre", request.originalContentJSON);
  receiptPanel.appendChild(original);
  const provenance = document.createElement("section");
  text(provenance, "h3", "Identity and receipt");
  field(provenance, "Account ID", request.accountID === undefined ? "Unavailable" : request.accountID);
  field(provenance, "Sender ID", request.senderID);
  field(provenance, "Message ID", request.messageID);
  if (request.receipt) {
    field(provenance, "Original intent", request.receipt.intentID);
    field(provenance, "Operation", request.receipt.opID);
    text(provenance, "h4", "Your submitted answer · exact JSON");
    text(provenance, "pre", request.receipt.exactAnswerJSON);
  }
  const copy = text(provenance, "button", "Copy reference");
  copy.type = "button";
  copy.addEventListener("click", async () => {
    const reference = {accountID: request.accountID, senderID: request.senderID,
      messageID: request.messageID};
    try {
      await navigator.clipboard.writeText(JSON.stringify(reference));
      copy.textContent = "Reference copied";
    } catch (_) { copy.textContent = "Copy unavailable"; }
  });
  receiptPanel.appendChild(provenance);
  if (request.status === "open" && request.selector && !request.receipt &&
      request.projection?.kind === "sender") {
    const send = text(actionRow, "button", attemptFor(request) ?
      "Check original submission" : request.projection.submissionLabel || "Send");
    send.type = "button";
    send.addEventListener("click", async () => {
      send.disabled = true;
      try { await submitOrRecover(request); }
      catch (error) {
        if (error.status === 403) disconnected();
        else hostState.textContent = error.message || "Unable to submit this request";
      } finally { send.disabled = false; }
    });
    if (!attemptFor(request)) {
      const cancel = text(actionRow, "button", "Cancel draft");
      cancel.type = "button";
      cancel.addEventListener("click", async () => {
        await draftWrites;
        if (!session || selectedKey !== keyOf(request)) return;
        try {
          const result = await call("/api/cancel-draft", {
            hostGeneration: session.hostGeneration, selector: request.selector});
          unsavedDraftEdits.delete(keyOf(request));
          renderDetail(result.requests[0]);
        } catch (error) {
          if (error.status === 403) disconnected();
          else hostState.textContent = "Unable to cancel this draft";
        }
      });
    }
  }
}

async function inspect(request) {
  const key = keyOf(request);
  const scopedSession = session;
  const newlySelected = selectedKey !== key;
  if (newlySelected) {
    instructionsExpanded = false;
    hideRequestDetails();
  }
  selectedKey = key;
  renderList();
  try {
    const inspected = await call("/api/inspect", {
      hostGeneration: session.hostGeneration,
      senderID: request.senderID, messageID: request.messageID
    });
    if (session !== scopedSession || key !== selectedKey) return;
    renderDetail(inspected.requests[0]);
    if (newlySelected && requestDetail.hidden === false) taskHeading.focus?.();
  } catch (error) {
    if (session !== scopedSession) return;
    if (error.status === 403) disconnected();
    else if (key === selectedKey) hostState.textContent = "Unable to inspect this request";
  }
}

function renderList() {
  requestList.replaceChildren();
  for (const request of currentSnapshot?.requests || []) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = request.title || request.messageID;
    if (keyOf(request) === selectedKey) button.setAttribute("aria-current", "true");
    button.addEventListener("click", () => inspect(request));
    requestList.appendChild(button);
  }
}

function useSnapshot(snapshot) {
  if (!snapshot || !Array.isArray(snapshot.requests)) return;
  if (snapshot.revision < revision) return;
  const changed = snapshot.revision !== revision || currentSnapshot === null;
  revision = snapshot.revision;
  currentSnapshot = snapshot;
  renderList();
  if (selectedKey) {
    const request = snapshot.requests.find(item => keyOf(item) === selectedKey);
    if (request && changed && !["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)) inspect(request);
    else if (!request) {
      selectedKey = null;
      renderDetail(null);
    }
  }
}

async function watch(scopedSession) {
  while (session === scopedSession) {
    const controller = new AbortController();
    streamAbort = controller;
    try {
      const response = await fetch("/api/stream", {
        method: "POST", mode: "same-origin", credentials: "omit", cache: "no-store",
        headers: {"Content-Type": "application/json",
          Authorization: `Bearer ${scopedSession.token}`},
        body: JSON.stringify({hostGeneration: scopedSession.hostGeneration, afterRevision: revision}),
        signal: controller.signal
      });
      if (response.status === 403) { disconnected(); return; }
      if (!response.ok || !response.body) throw Error("Stream unavailable");
      hostState.textContent = "Connected to this device";
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (session === scopedSession) {
        const {value, done} = await reader.read();
        if (session !== scopedSession) return;
        if (done) break;
        buffer += decoder.decode(value, {stream: true});
        let split;
        while ((split = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, split);
          buffer = buffer.slice(split + 1);
          if (!line) continue;
          const event = JSON.parse(line);
          if (event.type === "snapshot") useSnapshot(event.snapshot);
        }
      }
    } catch (error) {
      if (session === scopedSession && error.name !== "AbortError") {
        hostState.textContent = "Connecting to this device";
      }
    }
    if (session !== scopedSession) return;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
}

async function connected() {
  if (!session) return;
  const scopedSession = session;
  try {
    const snapshot = await call("/api/observe", {hostGeneration: session.hostGeneration});
    if (session !== scopedSession) return;
    pairing.hidden = true;
    workspace.hidden = false;
    hostState.textContent = "Connected to this device";
    useSnapshot(snapshot);
    void watch(scopedSession);
  } catch (error) {
    if (session !== scopedSession) return;
    if (error.status === 403) disconnected();
    else hostState.textContent = "Connecting to this device";
  }
}

pairForm.addEventListener("submit", async event => {
  event.preventDefault();
  const secret = pairSecret.value;
  pairSecret.value = "";
  pairState.textContent = "Connecting";
  try {
    const result = await call("/api/pair", {secret}, false);
    session = {token: result.token, hostGeneration: result.hostGeneration};
    sessionStorage.setItem("attention-host-session", JSON.stringify(session));
    pairState.textContent = "";
    await connected();
  } catch (error) {
    pairState.textContent = error.status === 503 ?
      "Harklight is available, but this profile is not ready to connect" :
      "Unable to connect this pane";
  }
});

document.getElementById("disconnect").addEventListener("click", async () => {
  try { if (session) await call("/api/logout", {hostGeneration: session.hostGeneration}); }
  catch (_) { /* Local token removal still prevents this pane from sending. */ }
  disconnected();
});

document.getElementById("details-back").addEventListener("click", hideRequestDetails);

senderScene.addEventListener("focusout", () => {
  const request = currentSnapshot?.requests.find(item => keyOf(item) === selectedKey);
  if (request) void draftWrites.then(() => {
    if (session && selectedKey === keyOf(request)) return inspect(request);
  });
});

hostState.textContent = "Connect this pane";
if (session) void connected();
