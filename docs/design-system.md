# Harklight app design system

Status: implemented in the app from the revision 7 build contract (draft `art_809c8f37`, revised as `art_566f0250`); its sequencing rule R7 is excluded by the work item.
Scope: the Harklight iPhone and iPad app only, light and dark.
Work item: `wi_773084da-3133-4d10-b91e-d54b770c06a9`.
Supersedes: `docs/design-system.md` (the Clawline-based design system, work item `wi_44f29e86`) and the Clawline values in `Design/tokens.json`.

This is the Phase 0 contract. It turns the accepted drawings into tokens, a component list and one acceptance check per component. It adds no design. Where this contract and the page differ, the page wins, except where section 8 records a resolved conflict.

## 1. Spirit and sources

**Design truth.** The product owner accepted design revision 7 on 2026-11-13. The page is artifact `art_29916506`, SHA-256 `366fea603aab5a69fc6e109a255dafaeaa1fd584661e38579e2ae3f1192a32c9`. Part A of the page (A1 to A6), its coder notes and its closing tables govern. Parts B and C do not apply to this work.

The governing intent is the work item body ([WI]). Its core lines:

- "Implement the accepted drawings in light and dark following system setting: Liquid Glass harmonized with the harklight.net theme."
- "bottom-left ordinary tabs with separate round bottom-right search per the page's Apple-checked coder notes; one-card reply; three-line New items; answered card; Seen beneath text; iPad selection bar and indent; readable dark labels."
- "Preserve the page's invented choices unless the owner rules otherwise. No features beyond the drawings."
- "This design supersedes warm-paper Clawline restyle wi_44f29e86 ... remove already-merged Clawline-restyle code replaced by this design when UI implementation begins. No legacy or leftovers."
- "Done when app ships in TestFlight matching the page, hand-verified on iPhone and iPad simulators in both modes, clean independent review; the owner's phone is the final acceptance check."

The Phase 0 brief ([BRIEF], assignment `asg_4f478d50`) asks for "the light/dark color and type tokens, component list, and one acceptance check per component", to "Add no design or features" and to "point to the page".

The Client PO's intent verdict ([PO-V], `att_0143a180`, recorded in the work item body) confirmed the draft, C1 to C11 and bundling Fraunces, and decided Q1 and Q2 (section 8).

Citation keys: [WI] work item body; [PO-V] the PO's intent verdict; [BRIEF] the Phase 0 brief; [A1] to [A6] the page's part A sections and their "What is drawn here" and "For the coder" notes; [SITE], [INV], [APPLE], [LIGHT], [READ] the page's closing tables "Taken from the site as is", "Invented beyond the site", "Apple system parts on iPhone and iPad", "Light mode, value by value" and "How readable it is". [CSS] the page's own stylesheet, the exact values the drawings use.

## 2. Terms

- **Page**: the accepted revision 7 drawings above.
- **System part**: a control Apple draws: top bar buttons, the position pill, tab bar, search, sheets, grouped form, iPad sidebar panel, red badge. The app supplies only tint and content [APPLE].
- **Content layer**: everything that scrolls under the system parts: background, rows, cards, text. It takes the site's colors and type [A1].
- **Type color**: the beam color for a message's type: request violet, information sky, done teal, warning amber, error coral [INV].
- **Type tint**: the faint fill of an open message, made from its type color (4.2).
- **Small label**: times, status lines, section headings, the "Delivered" status.
- **Mode**: light or dark, following the system setting [WI].

## 3. Rules for every component

- **R1. Page fidelity.** Each component in section 5 SHALL match its page drawing in both modes in layout, wording, color and type. Serves: "Done when app ships in TestFlight matching the page" [WI].
- **R2. Stock system parts.** System parts SHALL be Apple's stock SwiftUI controls, tinted with the values in section 4; the app SHALL NOT draw its own glass, hand-position a system button or stack glass on glass. Serves: [APPLE], [A1] "Stock SwiftUI, nothing custom" and "Do not draw a glass button or position it by hand."
- **R3. Mode.** The app SHALL follow the system's light or dark setting and SHALL show every component with that mode's values. Serves: "light and dark following system setting" [WI].
- **R4. Readable text.** All text SHALL measure at least 4.5:1 against what is directly behind it in both modes. The only exception is the count on Apple's red badge, which stays Apple's. Serves: "readable dark labels" [WI]; [READ].
- **R5. No new features or wording.** The work SHALL add no behavior, control or wording the page does not draw, and SHALL remove only what the page removes (section 5). Behavior the page does not draw stays as it is today. Serves: "No features beyond the drawings" [WI].
- **R6. One live design.** When UI implementation begins, the app SHALL keep one token source holding section 4's values. Clawline-restyle tokens, code and `docs/design-system.md` that this design replaces SHALL be removed or replaced, so no second live design remains. Serves: "No legacy or leftovers" [WI].
- **R8. Undrawn surfaces.** Surfaces the page does not draw SHALL take section 4's color and type tokens, with today's layout, wording and behavior unchanged, and none SHALL keep the Clawline look. These are the Progress section, enrollment, release notes, alerts and confirmations, loading, empty and unavailable states, the foreground chat banner and recovery screens. Serves: [PO-V] "take the new color and type tokens while preserving today's layout, wording and behavior. No surface keeps the old Clawline look; no extra drawings are required."

*Example*: in dark mode the inbox time "9:41 AM" is #9aa4b8 on #070b14 (7.9:1). The Settings Done button is a stock tinted button in amber, not a custom shape. The release notes sheet keeps its layout and words in the new colors and Fraunces headings.

## 4. Tokens

Points equal the page's CSS pixels. A percentage means that color mixed at that share over the named surface. The values come from [CSS], [SITE] and [LIGHT].

### 4.1 Color

| Token | Dark | Light | Used for |
|---|---|---|---|
| `background` | #070b14 | #e9edf5 | Page behind lists and the iPad chat column |
| `text` | #e9edf5 | #070b14 | Main text, row titles, glass symbols |
| `secondary` | #9aa4b8 | #3b444d | Senders, row bodies, choice descriptions, placeholders |
| `label` | #9aa4b8 | #4f5a6e | Small labels: times, status lines, section and form headings, "Delivered" |
| `line` | white 10% | #070b14 14% | 1 pt dividers and borders |
| `raised` | white 2.5% | white 55% | Choices, the unpicked reply card, your chat turns |
| `field` | white 4% | white 85% | Initials circles, attachment thumbnail fill |
| `panel` | #101725 | #ffffff | Chat and Settings sheets |
| `group` | white 4.5% | #ffffff | Settings form groups |
| `amber` | #ffc857 | #7d5100 | Warning type; selected tab; unread chat flag; High urgency |
| `teal` | #5fd3bc | #0f6657 | Done type; Seen; the check on a Seen row |
| `sky` | #62b6ff | #125aa8 | Information type |
| `violet` | #9d8cff | #5240cc | Request type |
| `coral` | #ff8a5c | #a13811 | Error type; Urgent; "Disconnect this phone…" |
| `on-beam` | #070b14 | #ffffff | Text and symbols on a filled beam color |
| `inverse` / `on-inverse` | #e9edf5 / #0b1020 | #070b14 / #e9edf5 | The send-answer button |
| `accent-fill` / `on-accent` | #ffc857 / #070b14 | #ffc857 / #070b14 | Send in chat, Settings Done |

`amber` in light (#7d5100) is the darker beam used for symbols, text and lines. The two filled amber buttons keep #ffc857 in both modes [CSS].

### 4.2 Derived colors

| Token | Dark | Light |
|---|---|---|
| Type tint, open message background | type color 8% over `background`: request #131527, info #0e1927, done #0e1b21, warning #1b1a19, error #1b151a | bright (dark-mode) type color 16% over `background`: request #ddddf7, info #d3e4f7, done #d3e9ec, warning #ede7dc, error #eddddd |
| Urgent row wash | coral 16%: #2f1f20 | bright coral 24%: #eed5d0 |
| High row wash | amber 12%: #25221c | bright amber 26%: #efe3cc |
| Urgent and high row edge | 2 pt line in `coral` or `amber` on the leading edge | same, light values |
| Picked choice, picked reply card, answered card | 1 pt border in the type color; fill type color 9% over what is behind | same, light values |
| Reply text pane | black 24% over the card | white 48% over the card |
| iPad open row | fill type color 15%; 8 pt leading bar of type color 55% over `background` | same, light values |
| Sheet dimming | #02050b at 91% | #070b14 at 32% |

### 4.3 Type

Headings use Fraunces, the site's serif. Everything else uses the system font. Sizes are at the default text size.

| Role | Face, weight | Size / line height | Color |
|---|---|---|---|
| Harklight name | Fraunces 400, tracking +0.01 em | 18.4 | `text` |
| Inbox row title | Fraunces 400, tracking -0.01 em | 18.4 / 1.3 | `text` |
| Open message title | Fraunces 300, tracking -0.015 em | 28 / 1.15 | type text (`text`) |
| Message body | system regular | 16 / 1.5 | `text` |
| Row body | system regular, at most 2 lines | 15 / 1.45 | `secondary` |
| New item summary | system regular, at most 2 lines | 16 / 1.36 | `text` |
| New status line | system regular | 12.5 / 1.35 | `label` |
| Urgency pill | system semibold | 11 / 1.5 | `on-beam` on `coral` or `amber` |
| Row priority line | system semibold, 12 pt symbol | 13.5 / 1.3 | row text color |
| Sender (row) | system regular | 12.8 | `secondary` |
| Sender and time (open message) | system semibold, tracking 0.3 | 12 | `secondary` |
| Row time | system regular | 11 | `label` |
| Section heading ("New · 3 of 3") | system medium, ordinary capitals | 13 / 1.3 | `label` |
| More… | system semibold | 15 / 1.3 | `text` |
| Choice title / description | system medium / regular | 16 / 15 | `text` / `secondary` |
| "Suggested" | system regular, uppercase, tracking 0.08 em | 12 | `secondary` |
| Chat turn / speaker | system regular | 15 / 1.45 and 12.8 | `text` / `secondary` |
| "Delivered" | system regular, 12 pt check | 12 / 1.3 | `label` |
| Position pill ("2 of 6") | system semibold, tabular figures | 15 | `text` |
| Settings row / detail / heading | system regular / regular / semibold | 16 / 13 / 14 | `text` / `secondary` / `label` |

### 4.4 Shape

Cards (choices, reply card, answered card, chat turns): 12 pt corners. Small parts (thumbnails, inputs): 8 pt. Urgency pill: fully round. Settings groups: 24 pt. Initials circles: 24 pt in rows, 28 pt in an open message. Inbox rows: 12 pt top and bottom padding, 16 pt side padding, a 1 pt `line` between rows. Top bar glass buttons: 44 pt. Sheet corners and grabber: Apple's [CSS], [SITE], [APPLE].

## 5. Components

Each entry names the page section that draws it, what today's code calls it (a place to start, from `docs/design-system.md`), the requirement and its acceptance check. Run every check on an iPhone simulator, and also on an iPad simulator where the iPad differs, in both modes.

### C1. Tab bar and search [A1], [A6], [APPLE]

Today: the root tab bar, with `.searchable(text:placement: .sidebar, prompt: "Search messages")` on each tab's list.

WHEN the inbox is showing on iPhone, THE app SHALL show a stock tab bar with the Inbox and Replied tabs grouped at the bottom leading end and a search-role tab that the system shows as a separate round button at the trailing end. The selected tab SHALL take `amber` and the other `text`. Search SHALL be one `.searchable` on the tab view with the prompt "Search messages". One tap on search SHALL focus the field above the keyboard on iPhone, and leaving search SHALL return to the previous tab. The search field that floats above the tab bar today SHALL be removed. On iPad the system SHALL place the tab bar, with its search tab, near the top, and the list panel SHALL have no search field. WHILE a message is open on iPhone, the tab bar SHALL be hidden. Serves: [WI] "bottom-left ordinary tabs with separate round bottom-right search per the page's Apple-checked coder notes"; [A1]; [A6].

*Check*: on iPhone, Inbox and Replied sit together at the bottom left and a round magnifier sits at the bottom right, with no field above them. One tap on the magnifier raises the keyboard with "Search messages" focused just above it. Dismissing it returns to Inbox. In dark the selected tab label is #ffc857, in light #7d5100. On iPad the search tab is in the top bar and the list panel has no search field.

### C2. Inbox row [A1], [INV]

Today: `InboxRowContent`.

THE prioritized list row SHALL show, top to bottom: the initials circle, sender and time; the title in the row title type with the 17 pt type symbol in its type color centered on the title's first line, and a trailing 16 pt flag (filled `amber` while the chat has an unread turn) or check (`teal` once Seen); for an urgent or high row, a plain priority line ("Urgent", "High priority") under the title, aligned with the title text; and at most two lines of body. An urgent row SHALL take the urgent wash with a 2 pt `coral` leading edge, and a high row the high wash with a 2 pt `amber` edge. Serves: [A1] "the priority is plain text under the title, lined up with the title text, and the type symbol is centered on the title's first line"; [INV] "Urgent and high rows".

*Check*: "Production deploy failed" shows a coral wash, a 2 pt coral left edge and "Urgent" under the title. The Lisbon row shows a filled amber flag. "Your week ahead" after Seen shows a teal check. Each row's body stops at two lines, and in dark each time reads #9aa4b8.

### C3. New item [A1], [INV]

Today: `NewMessageArea`.

WHEN the New section has items, THE section SHALL show the heading "New · *n* of *m*" in ordinary capitals, then each item on the plain background as at most three lines: two lines of summary and one status line with the time leading and, when it applies, a right-aligned urgency pill ("Urgent" on `coral`, "High priority" on `amber`, text `on-beam`) on the text baseline. The section's existing rules stay: the newest five, then a "More…" row, each item leaving the section when tapped or an hour after first seen, and the message's first two lines when no summary exists. The prioritized list SHALL start under the New section on the first screen. Serves: [WI] "three-line New items"; [A1].

*Check*: with seven new messages the section shows "New · 5 of 7", five items of at most three lines, "More…", and the top of the prioritized list on the same first screen of a 6.1-inch iPhone simulator, 852 pt tall, the size the page draws. The 7:30 AM item's "High priority" pill is right-aligned on the status line. No item has a colored background.

### C4. Open message [A2], [A3]

Today: `MessageCardSurface`, `LiveRequestDetail`, `MessageHeading`, `MessageChoiceLabel`.

WHEN a message is open, THE screen SHALL fill to every edge, behind the bars, with its type tint. It SHALL show the sender initials, "*Sender* · *day*, *time*", the title in the open message title type with its 24 pt type symbol, and the body. The top bar SHALL hold stock glass Back, the position pill ("2 of 6") and the send-answer button, a stock tinted button in `inverse` / `on-inverse` that is disabled until something is picked. A glass chat button SHALL sit at the bottom trailing corner with Apple's red badge counting unread turns. Choices SHALL be `raised` cards with a 1 pt `line` border and a round mark. A picked choice SHALL take the picked treatment (4.2) with its mark as a 6 pt ring in the type color. The "Choose one" label and the line and colored mark above the sender SHALL NOT appear. Serves: [A2]; [A3] "Pick a choice and the checkmark at the top right turns solid."

*Check*: opening the Lisbon request in light shows #ddddf7 behind the status bar and under the top bar, a disabled send button, two choices and a Reply card, and a chat button badged "1". Picking Hotel Avenida gives it a violet border and fill and enables the send button. Nothing reads "Choose one".

### C5. One-card reply [A3], [INV]

Today: `ReplyChoiceCard`.

WHILE Reply is not picked, THE reply card SHALL show only its mark and the label "Reply" in a `raised` card with a 1 pt dashed `line` border. WHEN Reply is picked, THE same card SHALL take the picked treatment and open a text pane below the label inside the same border: edge to edge, no border of its own, square top corners, at least 92 pt tall, message body type in `text`, on the reply text pane fill. Serves: [WI] "one-card reply"; [A3] "one rounded border holds the Reply label on top and the text field below it".

*Check*: tapping Reply on the Lisbon message turns its border violet and opens a pane inside it. Typing "Book the Avenida, and ask for a quiet room" shows dark ink in light mode and light text in dark mode. There is one rounded border, not two boxes.

### C6. Answered card [A3], [INV]

Today: `AnswerConfirmationCard`.

WHEN a message has been answered, THE choices and reply card SHALL be replaced by one card with the picked border and fill, an 18 pt checkmark in the type color, the word "Answered", and the answer under it, semibold and indented to the text after the checkmark. The top bar SHALL have no send-answer button. Serves: [WI] "answered card"; [A3] "After an answer the choices disappear and one card remains. The top bar has nothing where the checkmark was."

*Check*: after sending "Book the Avenida, and ask for a quiet room", reopening the message from Replied shows one violet-bordered card reading "Answered" with that text under it. No choices remain and the top-right check is gone.

### C7. Seen [A3]

Today: the Seen control.

WHEN an open message asks for nothing, THE screen SHALL show a normal-size stock glass button tinted `teal` with `on-beam` content, holding a check and "Seen", left aligned under the message text, and a `teal` tinted check button at the top right. Serves: [WI] "Seen beneath text"; [A3] "The Seen button under the text is a normal-size glass button, left aligned."

*Check*: "Your week ahead" shows a teal "Seen" button directly under its last paragraph at the leading edge, and a teal check at the top right. In light the teal is #0f6657 with white content, in dark #5fd3bc with #070b14.

### C8. Chat sheet [A4], [A6]

Today: `ConversationPanel`.

WHEN the chat button is tapped on iPhone, THE chat SHALL open in a stock sheet in `panel` with a grabber, the message dimmed behind it, no heading and no close button, closing when pulled down. The agent's turns SHALL have no fill and show the speaker name. Your turns SHALL sit on a `raised` card with a 1 pt `line` border and show "Delivered" with a small check under the text, kept after the agent replies. The composer SHALL be stock glass: the plus button, the message field with the placeholder "Write a message…" and Send tinted `accent-fill`, with the buttons no taller than a one-line field. An attached file SHALL show as a thumbnail with a remove control until sent. On iPad in landscape the chat SHALL be its own column on the right on `background`, with a 1 pt `line` at its leading edge and no heading. Serves: [A4]; [A6].

*Check*: tapping the chat button opens a sheet in #101725 (dark) or white (light) with a grabber and no title. "Does the Avenida have a desk in the room?" sits in a bordered card with "Delivered" under it in #9aa4b8 (dark) or #4f5a6e (light). Send is amber, and attaching a PDF shows a thumbnail with ×.

### C9. Settings [A5]

Today: `LiveInboxSettings`.

WHEN Settings opens, THE app SHALL show it as a stock sheet titled "Settings" with a Done check tinted `accent-fill` at the top right and a stock grouped form whose groups are `group` with a 1 pt `line`. Group headings SHALL be in ordinary capitals, never all capitals, in `label`. "Disconnect this phone…" SHALL be `coral`. The groups and rows SHALL stay as today: connection status, account and server, the disconnect control, diagnostics and release notes. Serves: [A5].

*Check*: Settings in light shows white rounded groups on a white sheet, headings such as "Account" and "Diagnostics" in #4f5a6e and not in all capitals, "Disconnect this phone…" in #a13811, and an amber Done check that closes the sheet.

### C10. iPad split [A6], [APPLE]

Today: the iPad split in the root navigation.

WHILE the app runs on iPad, THE list SHALL sit in the system's floating glass sidebar on the left with the open message beside it, and the open message's type tint SHALL run behind the panel to the screen edge. The New section SHALL top the list as on iPhone. In landscape the chat SHALL take the right column (C8). Serves: [A6] "The list is a floating glass panel, and the message's tint runs behind it to the edge of the screen."

*Check*: on an iPad simulator in landscape with the Lisbon request open, the list floats as a glass panel with violet tint visible behind and around it, the message is in the middle and the chat is on the right, with the tab bar and search at the top.

### C11. iPad selection bar [A6]

Today: the selection bar in `HarklightWorkspace.swift` (section 6.2 of the superseded doc).

WHEN a message is open on iPad, THE row for it in the prioritized list SHALL take the iPad open row fill, an 8 pt bar at its leading edge and its contents indented 16 pt further than other rows. Serves: [WI] "iPad selection bar and indent"; [A6] "a bar on its left edge in a brighter shade of the message's tint, and the row's contents are indented."

*Check*: with Lisbon open, its row in the list shows a violet-tinted fill, an 8 pt violet bar at the left edge and its initials, title and body starting 16 pt to the right of the other rows' contents. No other row has the bar.

## 6. Non-goals

- The web client, the hosted account pages, the marketing site and any Part B or C drawing [WI].
- What search shows before the first letter is typed: the page leaves it undecided, so it stays as today [A1].
- New surfaces, controls or wording: new layouts for the undrawn surfaces in R8, avatars, new settings, sign-in screens [WI] "No features beyond the drawings".
- Behavior changes to Seen, reply, swipe or the New section rules [WI].
- Custom glass, hand-drawn tab bars, or matching Apple's keyboard row and close button to the drawing. The system draws those [A1].

## 7. Assumptions

- **A1.** Fraunces at weights 300 and 400 can be bundled with the app. The site already serves it, and it is under the SIL Open Font License. False if that license or the site's copy prevents bundling.
- **A2.** The sizes in 4.3 are at the default text size, and text keeps scaling with Dynamic Type as it does today, Fraunces included. The page draws one size only.
- **A3.** The app's iOS 27.0 minimum (`project.yml`) covers every API the coder notes name. `tabViewSearchActivation` is iOS 26 and later.
- **A4.** On iPad in portrait, where the page draws no chat column, the chat opens as it does today.
- **A5.** Apple's design and SwiftUI pages describe the same one-tap search, but neither names the other [A1]. Confirm on a simulator that `.tabViewSearchActivation(.searchTabSelection)` gives the button appearance. On iPad with only a virtual keyboard, keep it to iPhone if it raises the keyboard on arrival [A6].
- **A6.** Glass contrast figures in [READ] assume the plain page behind the glass and move as content scrolls under it. R4 applies to the content layer and the tinted buttons. Glass itself is the system's.

## 8. Open questions

None is open. Both questions raised in the draft were decided by the Client PO in [PO-V].

- **Q1. Dark "Delivered" color. RESOLVED (Client PO, 2026-11-13).** The drawings color "Delivered" in the site's faint gray #5f6b82, which is 3.3:1 on the dark sheet. The PO ruled that a drafting slip against the page's own small-label rule and the November 12 readability ruling. Dark "Delivered" uses `label`, #9aa4b8 (7.2:1), as in 4.1 and C8. Light #4f5a6e (7.0:1) is unchanged.
- **Q2. Surfaces the page does not draw. RESOLVED (Client PO, 2026-11-13).** They take the new color and type tokens with today's layout, wording and behavior, and no surface keeps the Clawline look. No extra drawings are needed (R8).

## 9. Where it lives in the code

- `Design/tokens.json` is the one token source: section 4's colors, derived tints, type roles and shapes.
- `Sources/HarklightDesignTokens.swift` decodes it and derives the picked fill, the iPad open row and type colors. `HarklightColor` resolves a token for the current appearance wherever a shape style is accepted.
- `Sources/HarklightTypography.swift` resolves type roles, including the bundled Fraunces (`Resources/Fraunces.ttf`, SIL Open Font License in `Resources/Fraunces-OFL.txt`) with its optical size following the point size.
- `Sources/HarklightSurfaces.swift` holds the shared form section, sheet surface and Done button used by Settings and other sheets.

## 10. Where the page and this contract differed

The page governs (section 1). The build follows it in these places; each is recorded on the work item for a ruling.

- C7 Seen: the drawing shows a plain glass button with an eye symbol under the text; the teal tint is on the top-right check.
- Today's "FYI" label above a legacy Seen button is kept; the page does not list it as removed.
- A read chat keeps an outline flag in `label`; the page draws only the filled amber flag for an unread turn.
- The open message heading no longer carries a chat icon; the chat button's badge carries it, as drawn.
- `.searchable` sits on the search tab's content rather than the tab view, because on the tab view it also floated a field over the Inbox tab. There is still one search, reached from the search tab; it searches the list the person came from.
