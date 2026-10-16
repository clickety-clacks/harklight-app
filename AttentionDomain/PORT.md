# Harklight native semantic port (`AttentionDomain`)

This historically named Swift package is the single Harklight native domain/store module for the iOS UI and the foreground macOS host. C owns exact descriptors, drafts, original intents, outbox operations, replay state and sender authority. H owns its presentation session and consumes committed C snapshots; it must not keep a second answer, draft, intent or relay store.

## Public API

The Swift-facing types are `PortContext`, `BoundDocumentSelector`, `TypedInputRecord`, `SubmitIntent`, `IntentReceipt`, `PresentationSnapshot` and `ApplyEventResult` in `Sources/AttentionDomain/AttentionPort.swift`. The admitted visual surface also includes `ProjectedSceneNode`/`ProjectedSceneKind`. The main calls are:

```swift
port.context
try port.observe(context: context)
try port.inspect(context: context, request: requestKey)
try port.saveDraft(context: context, selector: selector, completeDraft: draft)
try port.cancelDraft(context: context, selector: selector)
try port.preview(context: context, selector: selector, inputs: typedRecords)
try port.submit(SubmitIntent(context: context,
                             selector: selector,
                             intentID: intentUUIDv4,
                             inputs: typedRecords))
try port.lookupIntent(context: context, intentID: intentUUID)
try port.fenceUncommittedIntent(context: context, requestKey: requestKey,
                                intentID: intentUUID)
try port.retryIntent(context: context, intentID: intentUUID)
try port.snapshots(context: context, afterRevision: lastRevision)
```

`PortContext` is minted from the native profile store. H passes it back unchanged; it must never build trusted account scope from an HTTP body. `inspect` returns a C-minted selector whose document ID binds the complete immutable descriptor and whose submission ID binds the result constructor. Every mutation revalidates both IDs, exact request key and current profile generation inside C.

`TypedInputRecord` follows H's proposal: response action, response text, text and point records carry only input/action IDs and typed user edits. Compatibility-action cases preserve the already-supported fixture shape. `SubmitIntent` has no answer JSON, sender literal replacement, operation UUID or relay frame. C composes the answer from its exact retained descriptor and these records, mints one operation UUID, and atomically persists the immutable receipt and outbox entry before returning.

`IntentReceipt` retains the exact typed records, exact `JSONValue` answer and generated operation UUID. Native consumers use `exactAnswerJSON` when rendering or bridging across a web boundary; arbitrary answer numbers must stay in that exact UTF-8 JSON string. `lookupIntent` needs the current trusted profile context and intent UUID, not a stale host-generation selector. `retryIntent` returns the same pending outbox receipt by ID; it never creates or edits an operation.

There is no separate pre-commit reservation record. Hosts first durably save the complete typed draft, then call `submit`. If the response is lost, `inspect` and `lookupIntent` may reveal the immutable receipt, but a missing receipt is only a snapshot: an earlier HTTP request may enter the native route later. Before a host may abandon that UUID and offer a new submit, it must call `fenceUncommittedIntent` under the current trusted profile and request key. The store serializes that call with `submit`: it returns the original receipt if submit won, or durably records a fence if submit did not win. A late submit bearing a fenced UUID then conflicts, including after process restart. A lost fence response is retried with the same UUID. The host retains only an opaque attempt hint and does not copy the answer into pane storage. After a confirmed fence, the person reviews the current saved draft before choosing a new operation ID. If another intent committed in the meantime, `.competingIntent(activeID)` names it and `lookupIntent` returns its receipt. A committed receipt always has its corresponding outbox row.

`PresentationSnapshot` is revisioned and contains requests in C's durable `acceptanceOrder`, typed drafts, one app-owned lifecycle status, separate receipt facts, exact original content as an inert UTF-8 JSON string, an optional durable intent receipt and a C-admitted sender projection. Relay order is assigned from the first contiguous delivery-event sequence; fixture order follows the fixture source order. Consumers render the array as supplied and do not sort by identifiers or timestamps.

The sender projection includes the admitted finite `SenderIllustration` resources, action illustration references and sender `submissionLabel`. Its `ProjectedSceneNode` tree preserves the accepted scene structure, but replaces each authorized `result-point` path with a C-resolved integer `PointValue`. If any binding fails, C selects the complete neutral scene; H never reads the answer or original payload to resolve graphics. `snapshots` emits the newest committed state and later committed revisions. During replay, the published request state remains at its prior coherent image until `finishReplay` crosses the resync barrier. Raw relay input, cursor persistence and acknowledgements stay on the C side.

## Conformance examples

1. **Dropped response and restart:** durably save the facilities point `(240, 610)` and exact note `"  Near the door\n  "`, then submit under UUID `I`. After the file store is reopened with a fresh profile generation, request inspection exposes the same immutable receipt and lookup of `I` returns the same generated operation UUID, exact answer and typed records. Retrying identical content returns that receipt; changing the note or document with `I` conflicts before another operation/outbox write. If lookup misses while the original request is delayed, a durable fence for `I` must win before a new UUID is offered. Restart preserves that fence, so the late original fails even if the saved draft later changes.
2. **Profile isolation:** A and B may use the same sender/message IDs under distinct trusted scopes. A's context/selector cannot read or mutate B's request; a selector from an old device generation expires. Each profile keeps its own draft and intent.
3. **Replay convergence:** delivery and terminal events received through a replay barrier do not publish a partially rebuilt terminal view. Cursor advances only contiguously; a gap is not acknowledged. Terminal lifecycle does not reopen, compatible classification repeats do not create another acceptance, and a local receipt at a later sequence does not jump the relay cursor.
4. **Answer authority:** only a C-admitted authorized origin answer or this request's confirmed original operation may choose known answer graphics. A bare non-origin closure, explicit null, mismatched point or unresolved operation selects the neutral terminal scene. Receipt facts do not repeat the lifecycle heading or invent relay acceptance.
5. **Projection and order:** sender projections retain finite illustration primitives, action-art references and the submission label; a known accepted answer projects only validated integer result points, while an unknown closure exposes none. Request snapshots preserve the durable first-acceptance order across restart, even when lexical sender/message order differs.

## Local fixture boundary

The SwiftUI app uses the same durable domain module with `transportMode == .fixture`, a fictional account/device identity and app-owned file storage. Demo controls disclose fictional data, local persistence and that no relay/source is connected; terminal outcomes are fixture simulations. Fixture state cannot enter relay retry/apply methods. The `relay` mode in the domain package is a persistence/conformance boundary only until an authenticated owner-approved relay integration is implemented. No credential, enrollment or live-source behavior is claimed here.

SR-1/SR-2 of the reviewed single-status addendum apply without changing the sender scenes: lifecycle appears once, receipt facts remain separate, and authorized-known versus neutral graphics remain unchanged. The current b77 SwiftUI paths already meet the narrow duplicate-heading correction, so this increment makes no copy churn for it.
