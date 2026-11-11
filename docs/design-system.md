# Harklight app design system

Status: candidate for independent spec review.
Scope: the Harklight iPhone and iPad app (`Sources/`), light and dark.
Supersedes: `Design/README.md` (the earlier Nordic direction).
Work item: `wi_44f29e86-6006-4513-97aa-cb147cb89fac`.

This document says what the app should look like after it adopts the Clawline
visual language, and what it looks like today. It changes no code. The restyle
itself is later work that lands in small batches against this document.

## 1. Spirit and sources

The product owner's fit ruling, revision 3 (`art_632564ba`, sha256
`a31d96f64e04053d5a4bc28d5653686b890a7527ba433276ce758a1569ba7344`), is the
governing intent. It supersedes revisions 1 (`art_95feab40`) and 2
(`art_f6c0202c`) by adding two rulings of 2026-11-11: importance washes
(section 8.1) and dormant list rules (section 8.2). Its core lines, quoted
where this document cites them:

- "Clawline supplies the foundation": type, spacing, squircle radii, warm
  top-lit elevation, grain, motion, neutrals and accent, in light and dark.
- "The app keeps one token source. Clawline values go into the existing token
  file and the Swift token layer."
- Harklight keeps three departures: the five message-type colors ("No other
  color carries meaning: not senders, not importance"), "Importance is shown by
  size, not color", and the list rules from `Design/README.md`.
- It is a restyle only. Behavior and wording do not change. Status wording
  follows `art_5a797432`. Text contrast stays at or above 4.5:1. Grain never
  reduces legibility. Reduce Motion and Reduce Transparency are respected.
  VoiceOver labels do not change. The large-text Search repair and its tests
  stay valid.
- One document covers iPhone and iPad, with iPad split view and pointer hover
  called out.

The product owner's correction of 2026-11-11 ([PO-C]) asks for six fixes, each
applied here: the missing states (6.19), the named dialogs (6.20), pressed and
keyboard focus (6.21, DS-31), terracotta as the accent measured against the
type colors (DS-28), the button radius citation (5.4) and the shadow source
(DS-29, Q-5).

The original request is Client PO transcript event 1810. Its highlights: light
mode by default with a full dark palette, DM Sans, a 4 pt spacing base, 28 pt
squircles, warm top-lit shadows, subtle grain, terracotta and sage.

Clawline sources: `clickety-clacks/clawline` at commit
`e1fc034a4d3daf0e9c18f7adde8dbb39da05be8f`, files
`docs/design-system/design-system.html` and `docs/design-system/demo.html`.
Clawline is not changed by this work.

Citation keys used below:

| Key | Source |
|---|---|
| [ASK] | Event 1810 and the work item brief |
| [FIT] | `art_632564ba` (fit ruling, revision 3) |
| [PO-C] | The product owner's correction of 2026-11-11, in the work item body |
| [CL] | Clawline `design-system.html` at `e1fc034a` |
| [CL-DEMO] | Clawline `demo.html` at `e1fc034a` |
| [README] | The superseded `Design/README.md` at `340c710` |
| [CODE] | This repository at `340c710` |

## 2. Terms

- **Token**: a named design value in `Design/tokens.json`, read by
  `Sources/HarklightDesignTokens.swift`. Views use tokens, not literals.
- **Token source**: `Design/tokens.json` plus the Swift layer that decodes it.
  It is the only normative home for values.
- **Neutral**: a token that carries no meaning (background, text, separator,
  glass).
- **Message type**: one of Request, Information, Completed, Warning, Error
  (`request`, `info`, `done`, `warning`, `error` in the token file).
- **Type color**: the per-type `background`. It fills the detail screen and
  colors the list icon.
- **Tier**: a row's attention tier (`top`, `middle`, `low`,
  `InboxAttentionTier`). It sets type size and body line limit.
- **Came-back row**: a row the user opened and returned from; [README] marks it.
- **Squircle**: a continuous-curvature rounded rectangle. In SwiftUI,
  `RoundedRectangle(cornerRadius:style: .continuous)`, which is also the
  default style.
- **Text pairing**: a foreground used as text or an informational icon on a
  background. Each pairing needs 4.5:1 (WCAG 2.x relative luminance).
- **Current**: what the code at `340c710` does. **Target**: what the restyle
  must produce.

## 3. How to read this document

Uppercase MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119 and
RFC 8174, and only when in uppercase. Requirements use EARS sentence forms. Each
requirement names what it serves and gives an acceptance example. Tables of
target values are normative. "Current" columns are descriptive and record the
starting point.

A restyle batch is acceptable when its changed surfaces meet every requirement
here that names them, and nothing it does not touch regresses.

## 4. Token source

**DS-1.** The app SHALL hold every color, type, spacing, radius, elevation,
glass, grain and motion value in `Design/tokens.json`, decoded through
`HarklightDesignTokens.swift`.
Serves: [FIT] "The app keeps one token source."
Accept: after a batch, `grep` of its changed view files finds no hex color
literal, `Color.blue`, or numeric font size that is not read from the token
layer. The system status colors listed in section 8.1 are current behavior
kept as they are and are the only exception.

**DS-2.** When a token is added for this system, the Swift layer SHALL decode
it and expose it as a typed value.
Serves: [FIT] "Clawline values go into the existing token file and the Swift
token layer."
Accept: after the foundation batch adds `raised` to `tokens.json`,
`Neutral.raised` exists and the views that use it read it.

**DS-3.** Color tokens SHALL keep the formats `Color(harklightToken:)` accepts
today: `#RRGGBB` or `rgba(r,g,b,a)`.
Serves: [CODE] any other string stops the app at launch
(`preconditionFailure`).
Accept: every color value in the target tables below is in one of those forms.

`Design/palettes.js` and `Design/index.html` are previews, not sources. They
are not normative and SHOULD be regenerated from `tokens.json` or removed in
the token batch. [FIT] one token source.

The token file gains these groups. Names are normative; JSON layout is the
coder's choice.

| Group | Tokens |
|---|---|
| `neutral` | existing, plus `raised` and `swipeNeutral`; `rowSelected` value re-derived, decoded when its rule goes live (section 8.2) |
| `accent` | existing |
| `detail` | existing |
| `types` | existing, unchanged keys |
| `type` | text styles in section 5.2 |
| `space` | section 5.3 |
| `radius` | section 5.4 |
| `elevation` | section 5.5 |
| `grain` | section 5.7 |
| `motion` | section 5.8 |

Non-color groups have one value for both appearances unless a table gives two.

## 5. (a) Tokens

### 5.1 Color

#### Neutrals

| Token | Current light | Target light | Current dark | Target dark | Clawline source |
|---|---|---|---|---|---|
| `bg` | #F1EEE9 | #F7F3EB | #161514 | #1C1917 | cream |
| `raised` (new) | none | #FDF6EE | none | #292524 | bubble-other |
| `rowTop` | #E6E2DA | #E8E0D4 | #201F1D | #292524 | surface gradient end, bubble-other |
| `rowSelected` | #E7EBE4 (not decoded) | #E3E7DA | #29302B | #2D3B2A | sage-light (light at 40% over cream) |
| `text` | #31302D | #3D3429 | #DDD9D1 | #E8E4E0 | text-primary |
| `text2` | #5C5854 | #5C4A3D | #9E9992 | #D4C4B0 | text-secondary |
| `separator` | #DEDAD3 | rgba(93,74,61,0.10) | #2C2A27 | rgba(255,255,255,0.08) | border-subtle |
| `replySurface` | #F1EFEB | #FDF6EE | #201F1D | #292524 | bubble-other |
| `glass` | rgba(250,246,238,0.74) | rgba(255,255,255,0.30) | rgba(46,42,37,0.74) | rgba(60,60,60,0.25) | input glass |
| `glassEdge` | rgba(60,45,30,0.10) | rgba(255,255,255,0.60) | rgba(240,230,215,0.10) | rgba(255,255,255,0.12) | input glass border |
| `swipeNeutral` (new) | `text2`, #5C5854 | #5C4A3D | `text2`, #9E9992 | #5C4A3D | text-secondary (light), as a fill under a white system label |
| `tabOn` | rgba(60,45,30,0.07) | rgba(61,52,41,0.07) | rgba(240,230,215,0.10) | rgba(232,228,224,0.10) | ink at low alpha |

`glass` is a tint for system Liquid Glass and for the Reduce Transparency
fallback, not a hand-built blur (section 9).

#### Accent

| Token | Current light | Target light | Current dark | Target dark |
|---|---|---|---|---|
| `accent` | #526657 | #A3553E | #A5BAA9 | #E07A5F |
| `onAccent` | #F3F0EA | #F7F3EB | #19211B | #1C1917 |
| `seen` | #587C60 | #3E7C50 | #9CBAA2 | #3E7C50 |

The accent is terracotta. [PO-C] "deepened terracotta #A3553E as interface
accent"; [ASK] terracotta and sage. In light it is Clawline terracotta
(#C4785C, 3.07:1 on cream) deepened to pass as text on `bg` and `raised`; in
dark it is Clawline's dark terracotta #E07A5F unchanged. `seen` is sage,
deepened so the white label the system draws on a `seen` fill (swipe action,
detail Seen button) passes; it is one value in both appearances. `seen` is a
fill, never a text color.

**DS-28.** The `accent` and `seen` tokens SHALL each measure a CIEDE2000
difference (dE00) of at least 10 from every type `background` and type
`listIcon`, in light and in dark. If a pairing falls short, the type color
or the token is retuned (DS-5) until it passes.
Serves: [PO-C] "measured separation from Request/Error hues, retuning those
hues if too close, and sage measured against Completed"; [FIT] "No other
color carries meaning", so a neutral color must not read as a type.
Accept: recomputed from the token file, the closest pairings are:

| Pairing | Light dE00 | Dark dE00 |
|---|---|---|
| `accent` to Error | 10.0 (background and listIcon) | 10.0 (listIcon) |
| `accent` to Request | 10.7 | 16.6 (listIcon) |
| `seen` to Completed | 10.1 | 25.0 (listIcon) |
| `accent` to `seen` | 44.7 | 50.3 |

Light Error moved from #A63A2A to #A42A20 and dark Error `listIcon` from
#EE8B75 to #FE9C8A to reach this. At the old values the light accent was 7.0
from Error. dE00 10 is this document's line for "clearly a different color";
it is not a WCAG figure.

#### Detail

| Token | Current light | Target light | Current dark | Target dark |
|---|---|---|---|---|
| `selectedChoice` | rgba(255,255,255,0.16) | rgba(0,0,0,0.10) | rgba(255,255,255,0.07) | unchanged |
| `replyField` | rgba(0,0,0,0.18) | unchanged | rgba(0,0,0,0.28) | unchanged |
| `replyInput` (new) | rgba(255,255,255,0.10), literal | rgba(0,0,0,0.08) | rgba(0,0,0,0.10), literal | rgba(0,0,0,0.10) |

These sit on type colors, which this document does not change. Light type
text is pale cream, so a white overlay lowers its contrast: the current light
`selectedChoice` leaves type `text` at 3.82:1 and `secondaryText` at 3.15:1 on
Information, and fails DS-6. A dark overlay raises it, so both light overlays
turn dark. `replyInput` is the inline reply editor's surface, today a literal
in `ReplyInputSurfaceStyle` (LiveContentView.swift); it moves into the token
file (DS-1). The unused `ReplyInputSurfaceStyle.darkPlaceholder` goes with it.

#### Message types

Values are those of [README] and the current token file, except Error, which
is retuned under DS-5 to keep its distance from the accent (DS-28): light
`background` #A63A2A becomes #A42A20, and dark `listIcon` #EE8B75 becomes
#FE9C8A. Light: every type has `text` #F6F1E7 and `secondaryText` #E3DCCF;
`listIcon` and `cameBackBar` equal `background`.

| Type | Light background | Dark background | Dark text | Dark secondary | Dark listIcon |
|---|---|---|---|---|---|
| Request | #7A5540 | #2C2019 | #E4D3C4 | #B09A88 | #C9A891 |
| Information | #4D6470 | #1D252A | #CFD9DE | #93A3AB | #9FB4BF |
| Completed | #4E6547 | #1E261C | #D3DDCC | #99A891 | #A5BC9C |
| Warning | #73592A | #2B2516 | #E6D9B8 | #AEA283 | #D8BE84 |
| Error | #A42A20 (current #A63A2A) | #3A1A14 | #F2C9BE | #C0948A | #FE9C8A (current #EE8B75) |

Dark `cameBackBar` equals dark `background`, as in light.

**DS-4.** The app SHALL use type colors only to identify a message's type: the
detail background, the list icon, the selected iPad row's fill (section 8.2)
and, once activated, the came-back bar.
Serves: [FIT] "No other color carries meaning: not senders, not importance."
Accept: no sender avatar, badge or button takes a type color except as
listed. The importance washes in section 8.1 are current behavior that
conflicts with this rule and are kept by ruling.

**DS-5.** If a type color is retuned, the change SHALL keep that type
recognizable, keep every text pairing at or above 4.5:1, and keep Error the
strongest.
Serves: [FIT] hues "may be retuned but keep their identity", "Error stays the
strongest".
Accept: a retune that moves Error's light background below Warning's in
saturation or contrast fails.

#### Contrast

**DS-6.** Every text pairing in the target palette SHALL measure at least
4.5:1, in light and in dark.
Serves: [FIT] 4.5:1.
Accept: the figures below, recomputed from the token file after each batch,
stay at or above 4.5.

Measured target pairings (lowest per row). Live neutrals are `bg` and
`raised`; `rowTop` and `rowSelected` are the dormant row shades (section 8.2).

| Foreground | Light, lowest | Dark, lowest |
|---|---|---|
| `text` on live neutrals | 11.02 (bg) | 11.99 (raised) |
| `text` on dormant shades | 9.32 (rowTop) | 9.38 (rowSelected) |
| `text2` on live neutrals | 7.58 (bg) | 8.90 (raised) |
| `text2` on dormant shades | 6.41 (rowTop) | 6.96 (rowSelected) |
| `accent` on live neutrals | 4.83 (bg; 4.99 on raised) | 5.14 (raised; 5.93 on bg) |
| `accent` on dormant shades | 4.09 (rowTop), fails | 4.02 (rowSelected), fails |
| `onAccent` on `accent` | 4.83 | 5.93 |
| system white label on `seen` fill | 5.00 | 5.00 |
| system white label on `swipeNeutral` fill | 8.39 | 8.39 |
| type `text` on type background | 5.53 (Information) | 10.37 (Error) |
| type `secondaryText` on type background | 4.57 (Information) | 5.86 (Error) |
| type `listIcon` on live neutrals | 5.63 (Information on bg) | 6.86 (Request on raised) |
| type `listIcon` on all four neutrals | 4.76 (Information on rowTop) | 5.36 (Request on rowSelected) |

The `accent` failures on the dormant shades do not show today, because no
live row uses those shades (DS-25). They are Q-6.

Composed detail pairings. Each surface is the overlay drawn over the type
background, in the order the views stack them. Lowest of the five types:

| Text | Surface | Light, lowest | Dark, lowest |
|---|---|---|---|
| type `text` | `selectedChoice` | 6.43 (Information) | 8.50 (Error) |
| type `secondaryText` | `selectedChoice` | 5.31 (Information) | 4.77 (Request) |
| type `text` | `replyInput` over `selectedChoice` | 7.16 (Information) | 9.11 (Error) |
| type `secondaryText` | `replyInput` over `selectedChoice` | 5.91 (Information) | 5.13 (Request) |
| type `text` | `replyField` | 7.25 (Information) | 11.58 (Error) |
| type `text` | `replyField` over `selectedChoice` | 8.19 (Information) | 10.30 (Error) |
| type `secondaryText` | `replyField` over `selectedChoice` | 6.76 (Information) | 5.76 (Request) |

**DS-26.** Every choice state (unselected, selected, own answer, editing,
read-only) SHALL show its text at full opacity in type `text` or
`secondaryText`, on a surface from the table above, so each pairing measures
at least 4.5:1.
Serves: [FIT] "Text contrast stays at or above 4.5:1."
Accept: in light mode on an Information message, a selected choice measures
at least 6.4:1 for its title and 5.3:1 for its detail; an unselected reply
choice card measures the base pairing (5.53 and 4.57), not a faded one. The
current light white overlay (3.82 and 3.15) and the unselected card's 0.55
opacity (as low as 2.44 light) both fail this check.

**DS-30.** Where a control is filled with `accent` (a `.borderedProminent` or
`.glassProminent` button under the app's `accent` tint, such as Send, Retry
and the enrollment primary buttons), its label and symbol SHALL be drawn in
`onAccent`, not the system's default white.
Serves: [FIT] "Text contrast stays at or above 4.5:1"; [PO-C] terracotta
accent.
Accept: in dark mode the chat Send arrow and an enrollment primary button
label measure 5.93:1 on the accent fill. White on the dark accent measures
2.95:1 and fails; white on the light accent measures 5.35:1, and `onAccent`
4.83:1.

Clawline's `text-muted` (stone, #A69B8D light) measures 2.47:1 on cream and
is not used for text (D-5). Clawline's light terracotta (#C4785C) measures
3.07:1 on cream, which is why the accent is the deepened #A3553E (D-4).

### 5.2 Typography

**DS-7.** The app SHALL render text in DM Sans, bundled with the app.
Serves: [ASK] DM Sans; [FIT] typography.
Accept: a debug or test probe of a row title, a message title and a chat
turn reports the font family "DM Sans". Current: system font only; DM Sans is
not bundled.

**DS-8.** Each DM Sans style SHALL scale with Dynamic Type through every
content size the app supports today, including accessibility sizes.
Serves: [FIT] "scaling with Dynamic Type at every size the app supports today".
Accept: at Accessibility XXXL, every text style on the inbox, detail and chat
screens is visibly larger than at Large. The large-text Search test
(`testFloatingSearchKeepsNormalReplyTextVisibleAtLargeContentSizes`) still
passes.

**DS-9.** Where text currently uses a fixed point size, the restyle SHALL
replace it with a scaled style.
Serves: [FIT] Dynamic Type at every size.
Accept: `MessageHeading` title (fixed 26 bold), its symbol (fixed 21) and the
row symbol (fixed 15) grow with Dynamic Type.

**DS-27.** Where a native UIKit text view draws text (the message body in
6.18, the chat editor in 6.11), the app SHALL set DM Sans scaled through
`UIFontMetrics` for the matching text style and keep
`adjustsFontForContentSizeCategory` on. Monospaced text (inline code, the
approval code, file hashes) SHALL keep the system monospaced face at the
scaled size of its style, since DM Sans has no monospaced cut.
Serves: [ASK] DM Sans; [FIT] "scaling with Dynamic Type at every size the app
supports today".
Accept: a message body containing bold, italic, inline code and a link shows
DM Sans bold and italic and system monospaced code, at Large and at
Accessibility XXXL; the chat editor's typed text is DM Sans at both sizes.

Type scale. Size is the reference size at the default content size; the
"Relative to" style sets the scaling curve
(`Font.custom(_:size:relativeTo:)` in SwiftUI; `UIFontMetrics(forTextStyle:)`
for UIKit text views, DS-27).

| Token | Size / weight / line height | Relative to | Clawline source | Used for |
|---|---|---|---|---|
| `brandLarge` | 34 / 600 | `.largeTitle` | none (app brand) | "Harklight" on the empty detail |
| `messageTitle` | 26 / 600 / 1.25 | `.title` | Short 22/600, scaled for the detail heading | Detail heading title |
| `rowTitleTop` | 22 / 600 / 1.3 | `.title2` | Short 22/600/1.3 | Top-tier row title |
| `rowTitleMiddle` | 17 / 600 / 1.3 | `.headline` | Medium 17/500 at 600 | Middle-tier row title |
| `rowTitleLow` | 15 / 600 / 1.3 | `.subheadline` | Body 15 at 600 | Low-tier row title |
| `body` | 17 / 400 / 1.5 | `.body` | Medium 17, at 400 | Message body, choices, chat turns |
| `bodySmall` | 15 / 400 / 1.5 | `.subheadline` | Body 15/400/1.5 | Row body, secondary prose |
| `label` | 15 / 600 | `.subheadline` | none | Buttons, pills, tab labels |
| `sender` | 12 / 600, tracking 0.3 | `.caption` | Sender 12/600/0.3 | Sender names, section headers |
| `caption` | 12 / 400 | `.caption` | Date separator .caption | Metadata, status lines |
| `timestamp` | 11 / 400 | `.caption2` | Timestamp .caption2 | Dates, counts |

Weights come from DM Sans's variable axis (300 to 700). Monospaced digits stay
where the code uses them today ("N of M").

Clawline draws sender names at 70% opacity. Harklight does not, because that
drops `text2` below 4.5:1 on `rowTop`; use `text2` at full opacity.

Clawline limits body text to 65 characters per line. The detail card's
existing 680 pt maximum width does that job on iPad; no new limit is added.

### 5.3 Spacing

4 pt base. [ASK] "4px spacing base"; [CL] spacing scale.

| Token | Value | Current uses it maps |
|---|---|---|
| `space.tiny` | 4 | Icon to label gaps |
| `space.small` | 8 | Toolbar item gaps, header top |
| `space.compact` | 12 | Detail VStack spacing, chat turn padding, choice gaps |
| `space.base` | 16 | Row horizontal padding, detail horizontal padding, choice label padding (current 14) |
| `space.comfortable` | 20 | Detail vertical padding (current 18), top-tier row vertical padding (current 18) |
| `space.generous` | 24 | Detail section gaps, iPad container margin |
| `space.large` | 40 | Empty-state spacing |

**DS-10.** The restyle SHALL draw paddings, gaps and margins from the spacing
tokens, rounding current values to the nearest step, and a value halfway
between two steps to the larger.
Serves: [FIT] "spacing on a 4px base".
Accept: row vertical padding becomes 20 (top tier, current 18) and 12 (other
tiers, current 13); the detail padding 16 by 18 becomes 16 by 20; choice label
padding 14 becomes 16.

Values that are touch-target or layout sizes, not spacing, keep their meaning:
44 pt targets, 80 pt paging and search clearance, 680 pt card width, 620 pt
enrollment width, 360 pt chat panel.

### 5.4 Radii

All shapes are squircles (`.continuous`). [ASK] "28px squircles"; [CL] radii.

| Token | Value | Clawline source | Used for |
|---|---|---|---|
| `radius.card` | 28 | demo bubble 28 | Enrollment cards, sheet sections |
| `radius.field` | 24 | [CL] "Border radius (field) 24px" | Composer field |
| `radius.button` | 24 | [CL] field 24 (Clawline has no rectangular button) | Rectangular buttons |
| `radius.panel` | 20 | card 20 | Foreground chat banner, popover content |
| `radius.inset` | 16 | link card 16 | Choice labels, reply choice card and its editor, answer confirmation card, chat turns |
| `radius.small` | 12 | code 12 | Saved reply text, projected text field (current 8), badges that are not capsules |
| `radius.check` | 4 | bubble sharp corner 4 | Multi-select checkbox |

Capsules and circles stay capsules and circles.

Clawline's only button radius is "Border radius (button) 50% (circle)" ([CL],
the send button), so Harklight's send and plus buttons stay circles. Its
rectangular buttons (enrollment) have no Clawline counterpart and take the
field radius, 24. [PO-C] "Clawline field is 24, demo iPhone input is 22, send
button is circular". The 22 in [CL-DEMO] is the demo's iPhone input and is not
used.

**DS-11.** Every rounded rectangle the restyle touches SHALL use a radius token
and continuous corners.
Serves: [ASK] squircles.
Accept: `MessageChoiceLabel` uses `radius.inset` (16, unchanged value); the
enrollment card uses `radius.card` (28, current 12).

Clawline's single sharp bubble corner is a chat-bubble feature. Harklight has
no bubbles (D-6), so `radius.check` is the only place 4 appears.

### 5.5 Elevation

Warm, top-lit shadows: light from above, so the shadow falls below and is
tinted warm brown in light mode. [ASK] "warm top-lit shadows".

| Token | Light | Dark |
|---|---|---|
| `elevation.raised` | y 4 blur 20 rgba(60,45,30,0.08); y 1 blur 3 rgba(60,45,30,0.05) | y 4 blur 20 rgba(0,0,0,0.3); y 1 blur 3 rgba(0,0,0,0.2) |
| `elevation.hover` | y 8 blur 30 rgba(60,45,30,0.12); y 2 blur 6 rgba(60,45,30,0.08) | y 8 blur 30 rgba(0,0,0,0.4); y 2 blur 6 rgba(0,0,0,0.3) |
| `elevation.flat` | none | none |

Source: [CL] `--shadow-bubble` and `--shadow-bubble-hover` (light and dark
theme blocks). [PO-C] "prefer design-system.html shadow-bubble over
demo.html". Clawline's sources disagree on shadow values; `demo.html` is not
used. CSS blur is roughly twice a SwiftUI shadow radius, so the SwiftUI layer
uses radius = blur / 2.

**DS-29.** A restyle batch SHALL NOT use any `elevation.*` value until one
shared shadow source has been agreed with the Chat and Tuner product owners,
through their delivery owners, and recorded against this work item.
Serves: [PO-C] "agree one shared source with Chat and Tuner POs through their
delivery owners before restyle use"; "no restyle may use an unresolved shadow
source".
Accept: while the agreement is not recorded, a batch's diff adds no shadow
read from `elevation.*`; a batch that does is rejected. If the agreed source
differs from the table above, only `elevation.*` values change (Q-5).

**DS-12.** Once the shadow source is agreed (DS-29), raised surfaces on the
neutral background (`raised` cards, the foreground chat banner, the
enrollment card) SHALL use `elevation.raised`. Until then they keep their
current shadow, which is none for the cards; the same holds for
`elevation.hover` in section 9.
Serves: [FIT] warm top-lit elevation.
Accept: in light mode a raised card shows a soft brown shadow below it and
none above it.

Detail screens on a type color stay flat; shadows on saturated fields read as
dirt and are not part of the type color departure's look. List rows stay
flat.

### 5.6 Glass

**DS-13.** Where the app uses glass, it SHALL use the system Liquid Glass
material, tinted by `glass` and edged by `glassEdge` where the API allows.
Serves: [FIT] foundation; section 9 platform constraint.
Accept: the composer field and "N of M" pill render with `.glassEffect`.

Clawline's glass recipe (blur 16, saturation 180%, white 30% light, gray 25%
dark, white edge) is the look the tint approximates; it is not rebuilt by hand
(D-7).

### 5.7 Grain

| Token | Light | Dark |
|---|---|---|
| `grain.opacity` | 0.025 | 0.04 |
| `grain.frequency` | 0.9 | 0.9 |
| `grain.octaves` | 4 | 4 |

Source: [CL] fractal noise. The app ships a pre-rendered tile (any method)
that matches this noise at these opacities.

**DS-14.** The app SHALL draw grain only on the neutral `bg` behind screens,
never over text and never on type-color detail screens.
Serves: [FIT] "Grain never reduces legibility"; [ASK] subtle grain.
Accept: a screenshot of the inbox shows grain in the empty area under the list
at 0.025 opacity; the detail screen shows none.

**DS-15.** While Reduce Transparency is on, the app SHALL omit grain.
Serves: [FIT] Reduce Transparency respected.
Accept: with Reduce Transparency on, the inbox background is a flat `bg`.

### 5.8 Motion

| Token | Value | Clawline source |
|---|---|---|
| `motion.interaction` | 0.2 s ease-in-out | 0.2s ease |
| `motion.theme` | 0.3 s ease-in-out | 0.3s ease |
| `motion.press` | scale 0.95 | send :active |
| `motion.hoverScale` | scale 1.05 | send :hover |
| `motion.hoverLift` | y -2 | hover translateY |

**DS-16.** When Reduce Motion is on, the app SHALL replace every scale, lift
and movement animation the restyle adds or touches with an opacity change or no
animation.
Serves: [FIT] Reduce Motion respected; [CL] honors reduced motion.
Accept: with Reduce Motion on, pressing Send shows no scale change; the reply
card opens without the `.smooth(0.25)` spring (current code does not gate it).

Existing animations keep their timing unless the batch touching them maps
them to these tokens. Animation is not added to things that do not animate
today. [FIT] restyle only.

## 6. (b) Components

Each entry lists anatomy, states, current tokens and the target. "Light/dark"
notes only differences beyond the token swap. File references are to `Sources/`
at `340c710`.

**DS-17.** A restyle batch SHALL change only the visual treatment of the
components it touches: not their wording, accessibility labels, order, gestures
or which states exist.
Serves: [FIT] "Restyle only; behavior and wording do not change", VoiceOver
labels unchanged.
Accept: a batch's UI test and accessibility-label snapshots, if any, pass
unchanged; its diff changes no user-visible string.

### 6.1 Inbox row (`InboxRowContent`, HarklightWorkspace.swift)

Anatomy, top to bottom:
1. Header: 24 pt initials circle, sender name, date.
2. Title line: retracted pill (when retracted), type symbol (fixed 15 pt,
   `listIcon`), warning icons (red), title, chat flag, seen check.
3. Priority flag and due phrase.
4. Metadata badges (section 6.4).
5. Body, limited to 8, 4 or 2 lines by tier.
6. Ordering reason and status lines.
Padding 16 horizontal; vertical 18 (top tier) or 13 (others); 0.5 pt separator.

States: tier top, middle, low; seen; unread chat; retracted; history (whole row
at 0.7 opacity); selected; came back.

Current tokens: `text`, `text2`, `listIcon`, `seen`, `separator`. Title font by
tier: `.title2.bold()`, `.headline`, `.subheadline.weight(.semibold)`. Live rows
are always tier middle (NativeAppLaunch.swift, `tier: .middle`).

Target:
- Title by tier: `rowTitleTop`, `rowTitleMiddle`, `rowTitleLow`. Body
  `bodySmall`, sender `sender`, date `timestamp`, status `caption`.
- Type symbol scales with `rowTitle*` (DS-9) in `listIcon`.
- Initials circle. Current: `caption2` bold in `text2` on a `separator`
  circle; the importance wash tints both on high and urgent rows; on a
  selected row the initials take type `text`. Target: `timestamp` at 700 in
  `text2` on `raised`, never tinted by sender. On high and urgent rows the
  importance wash tint stays as it is today (section 8.1).
- Selected row (iPad sidebar, while its message shows in the detail). Current:
  the row fills with the selected message's type background, text in type
  `text`. Target: the same fill and text, read from the retuned type tokens
  (section 8.2).
- Padding per DS-10. Separator `separator`, 0.5 pt.
- Top-tier and came-back row shades: approved, not yet live (section 6.3).
- Seen check: current and target `text2` (the row's secondary text color;
  on a selected or washed row, that row's secondary text). Chat flag per
  DS-20.
- Warning icons: system red, kept as they are (section 8.1).

### 6.2 Importance wash and selection bar (HarklightWorkspace.swift 2255 to 2295)

Current: high and urgent rows have a background gradient (the importance
wash) whose hue comes from the Warning or Error type color. An 8 pt bar on the
leading edge is always the neutral level (#B3A389 light, #756B61 dark), since
it is called with no level. Importance capsules in `NewMessageArea` and reply
rows use Warning and Error hex literals.

**DS-24.** The restyle SHALL keep the importance washes and capsules on the
same rows with the same meaning, derived from the Warning and Error type
tokens so they retune with those hues, and SHALL keep their existing tests.
Serves: [FIT] ruling of 2026-11-11: "the washes stay as they are: same rows,
same meaning, retuned along with the Warning and Error hues. Their existing
tests stay."
Accept: an urgent row still shows the Error-hued wash after the list batch;
changing the Error token changes the wash; the wash tests pass unchanged.

The wash is an opaque top-to-bottom gradient with its own text colors
(`InboxPriorityRowTreatment`). With the Error retune (DS-28), the light urgent
wash moves from #A63A2A to #8A2C1E to #A42A20 to #881E16, with text #F6F1E7
and secondary #E3DCCF unchanged: 6.37:1 and 5.26:1 at the top, 8.31:1 and
6.86:1 at the bottom. The light urgent capsule in `NewMessageArea` becomes
#A42A20. The dark urgent wash (#5A2219 to #3A1A14), the dark capsule and both
high (Warning) washes are unchanged. The leading 8 pt bar stays where it shows today; its neutral color is
re-derived from the Clawline neutrals (section 8.2).

### 6.3 List rules (kept from [README])

The came-back bar, the selected-row shade and the top-tier shade are approved
but not yet live (section 8.2). They are recorded here so the follow-up item
(`wi_40e646fc`) builds them as approved; this restyle does not.

- **Came-back bar (approved, not yet live; was DS-18).** The row the user came
  back from shows a bar on its right edge in that message's `cameBackBar`
  color, with its left corners rounded, on a `rowSelected` background.
- **Top-tier shade (approved, not yet live; was DS-19).** A top-tier row uses
  the `rowTop` background.

**DS-25.** The restyle SHALL NOT draw the came-back bar or the selected-row
shade, and SHALL NOT make any live row top tier.
Serves: [FIT] ruling of 2026-11-11 (dormant list rules): "The restyle keeps
what the app does today ... and does not add the missing rules."
Accept: after the list batch, open a Warning message and go back; its row has
no right-edge bar and no sage background. Live rows stay middle tier.

**DS-20.** While a message has an unread chat, its row SHALL show the chat flag
filled in `accent`; otherwise a message with chat shows it outlined in `text2`.
On a selected row the filled flag takes type `text`, and on a washed row the
wash's text color, as today.
Serves: [FIT] "the chat flag"; [README] chat flag rule; [PO-C] terracotta
accent.
Accept: an unread chat row on `bg` shows a filled terracotta flag; after
reading, an outline in `text2`.

Row shade token values are re-derived from Clawline neutrals (the target
`rowTop` and `rowSelected` above) so they are ready when the rules go live.
[FIT] "Their colors may be re-derived."

### 6.4 Badges (MessageMetadataPresentation.swift, InboxBadge.swift)

- **Type badge**: `caption` text in `text2` on a capsule of `text2` at 0.10.
  Target: same anatomy; `label` style at `caption` size, `radius` capsule.
- **Kind badge**: Blocker uses system `.orange`, Success uses `.green`, with a
  sparkles bounce gated on Reduce Motion. Target: colors kept as they are
  (section 8.1); type style `label` at `caption` size. The bounce keeps its
  Reduce Motion gate.
- **Retracted pill**: capsule, `caption2` semibold. Target: `timestamp` style at
  600, `text2` on `tabOn`.
- **Refreshing badge** (toolbar): a small spinner and "Refreshing" in
  `caption2` semibold, both in `accent`, on a capsule of `accent` at 0.14.
  Target: label in `text` at `timestamp` size and 600, spinner tinted
  `accent`, capsule `accent` at 0.14. With the target light accent, accent
  text on its own 0.14 capsule measures 4.03:1 and fails; `text` measures
  9.19:1 light and 11.26:1 dark.
- **App icon badge** (InboxBadge.swift): a count, not drawn by the app.
  Unchanged.

### 6.5 New area and replied rows (NewMessageArea.swift, ReplyItemArea.swift, HarklightWorkspace.swift)

Anatomy: section header "New · x of y" on `rowTop`; up to 5 rows; More… /
Less. Replied rows show an AI summary, a 3 pt reply capsule in `accent` at
0.55, and importance capsules.

Current: `quietTitle` and separator colors are hex literals; importance
capsules use Warning and Error hex.

Target: header `sender` style on `rowTop`; rows follow section 6.1; reply
capsule `accent` at 0.55; literals replaced by `text2` and `separator` (DS-1);
importance capsules read the Warning and Error type tokens (DS-24).

### 6.6 Inbox structure inside the list

- **Basic order marker, free-order headings**: `caption` semibold in `text2`.
  Target: `sender` style, `text2`.
- **Thread groups**: `DisclosureGroup` with "square.stack". Target: header row
  follows 6.1; disclosure chevron in `text2`.
- **Retracted history**: rows at 0.7 opacity. Target: keep 0.7 only if the
  faded `text2` still passes 4.5:1; otherwise use `text2` without fading.
  Measured: `text2` light at 0.7 over `bg` is 3.61:1 and fails, so the
  target draws history rows in `text2` without opacity.
- **Notification pending rows and detail**
  (`InboxNotificationPending*`): `text2` captions. Target: `caption`, `text2`;
  status wording per `art_5a797432`, unchanged.
- **Swipe actions**: Clear and No comment tinted `text2`, Seen tinted `seen`.
  The system draws a white label on each tint (A5). Current white on dark
  `text2` measures 2.83:1 and fails; on the target dark `text2` it would be
  1.70:1. Target: Clear and No comment tinted `swipeNeutral` (white label
  8.39:1), Seen tinted `seen` (5.00:1). System swipe buttons draw their own
  shape. [FIT] 4.5:1.

### 6.7 Detail card (`MessageCardSurface`, InboxMessageSurface.swift)

Anatomy: scroll view, content at most 680 pt wide, flat type-color background
to the safe-area edges, "N of M" glass capsule in the navigation bar,
72 pt bottom control clearance.

States: each message type; reply editor open; with and without position.

Target: unchanged structure. The type background stays (D-1). "N of M" uses
`label` with monospaced digits on system glass. No grain, no shadow.

### 6.8 Detail content (`LiveRequestDetail`, `MessageHeading`, LiveContentView.swift)

Anatomy: VStack spacing 12, padding 16 by 18. Heading: 28 pt initials circle
(type `text` at 0.18), type symbol fixed 21 pt, title fixed 26 pt bold. Then
body, choices, response controls, related-message links (section 7.8),
historical version access.

Current tokens: type `text` and `secondaryText`.

Target: spacing `space.compact`, padding `space.base` by `space.comfortable`.
Title `messageTitle`; symbol scales with it. Initials 28 pt circle on
`selectedChoice` with type `text`. Body per 6.18. Section labels
("Supersedes", "Replaced by") `sender` in type `secondaryText`.

### 6.9 Choices (`MessageChoiceLabel`, `NoCommentChoiceRow`, `ReplyChoiceCard`, `AnswerConfirmationCard`)

Anatomy (`MessageChoiceLabel`): a mark, then title (`.headline`), optional
"Suggested" (`.caption` semibold, secondary) and detail (`.subheadline`,
secondary). The mark is a 20 pt checkbox (multi-select, radius 4, 1.5 stroke)
or a radio circle (stroke 6 selected, 2 not). Padding 14, radius 16.

States and current treatment:

| State | Mark | Fill | Stroke |
|---|---|---|---|
| Unselected | empty, `secondaryText` | none | type `text` at 0.30, 1 pt |
| Selected | filled, type `text` | `selectedChoice` | type `text`, 1.5 pt |
| Own answer | as selected or not | as selected or not | dashed 5 on 4 |

`ReplyChoiceCard` wraps the label. Selected and not read-only, it opens an
inline `TextEditor` (`.body`, literal white text and caret, minimum height
120, padding 12 by 10) on the reply input surface, with only its bottom
corners rounded. With saved text and the editor closed, the text shows in
`.body` literal white on `replyField`, radius 12. The whole card draws at 0.55
opacity when unselected and animates with `.smooth(0.25)`. A read-only card
shows its state without a button. `AnswerConfirmationCard` uses the selected
fill, a 1.5 pt type `text` stroke, radius 16 and padding 14.
`NoCommentChoiceRow` follows the label recipe.

Target:
- Padding `space.base` (DS-10); radius `radius.inset` for labels, reply cards,
  the editor's bottom corners and the confirmation card; checkbox
  `radius.check`. Title `body` at 600, "Suggested" `sender`, detail
  `bodySmall` in `secondaryText`.
- Selected fill `selectedChoice` at its target value; editor surface
  `replyInput`; saved text on `replyField` at `radius.small` (DS-26).
- The unselected reply card draws at full opacity. Its unselected state shows
  through the empty mark and the 0.30 stroke, as `MessageChoiceLabel` already
  does. The 0.55 fade goes because it drops text below 4.5:1 (DS-26).
- Editor text, caret and saved text use type `text`, not literal white (DS-1).
- The open animation is `motion.interaction`, gated by DS-16.

### 6.10 Detail sheets and dialogs

- Request details sheet, `FailedResponseDialog` (medium and large detents),
  `HistoricalMessageVersionSheet`: system sheets on `bg`. Target: `bg` with
  `raised` sections, `radius.card`, `elevation.flat`. Detents unchanged.
- `LiveCompatibilityActions`, `LiveProjectedSceneView`, `SceneTextView`:
  projected message content using `.title2` semibold, `.body`, `.caption`.
  Target: `rowTitleTop`, `body`, `caption` in type colors.
- `SenderIllustrationCanvas`: a drawn illustration. Unchanged.

#### Projected input (`LiveProjectedInputView`, LiveContentView.swift)

Each form has a `.headline` label above its control. Forms:

- **Response**: a column of action buttons (spacing 10). Text actions open the
  reply choice card (6.9); others are choice rows.
- **Text**: a vertical `TextField` (4 to 8 lines, plain style) whose text,
  caret and prompt are literal white, padding 8, on `replyField` with radius 8.
- **Point**: the sender's illustration with a tap-or-drag gesture that sets a
  point. Accessibility hint "Tap or drag to select a point.", an action "Set
  point at center", and a value "Horizontal x, vertical y".
- **Read-only**: when answer controls are hidden, a response form lists its
  action labels (with any illustration) as plain text, a text form shows
  nothing, and a point form shows the illustration with the chosen point and
  its "Horizontal x, vertical y" line. Where the point form is shown but
  disabled, its hint reads "Read-only illustration."

Target: labels `rowTitleMiddle` in type `text`; response buttons per 6.9; the
text field's text and caret in type `text` and its prompt in `secondaryText`
(DS-1), padding `space.small`, on `replyField` at `radius.small`; read-only
text `body` in type `text`. The point form's gesture, hints, action and value
are unchanged (DS-17); the illustration keeps its fixed frame.

### 6.11 Chat (`ConversationPanel` and children, ConversationView.swift)

Anatomy: turn list, composer, status lines. Person turns have a 12 pt radius
fill of system blue at 0.06; turns pad 12. Composer: circular `.glass` plus
button (30), text input with `.glassEffect` radius 20, `.glassProminent` send
button (30). Status texts: `text2`, orange, red. Attachment thumbnails 72 by 48.

States: empty, drafting, sending, sent, failed, unavailable, read-only draft,
upload cleanup.

Target:
- Person turns on `raised`, radius `radius.inset`, padding `space.compact`; the
  other party's turns on `bg` with no fill. System blue goes (DS-1, DS-4).
- Composer field `radius.field` on system glass; plus and send stay circles.
  Send uses `accent` through `.glassProminent` tint, with its arrow in
  `onAccent` (DS-30). On iPad with a pointer,
  send uses `motion.hoverScale`; pressing uses `motion.press` (DS-16 applies).
- Status lines `caption`. Their `text2`, orange and red colors are kept as
  they are (section 8.1).
- Avatars and flow layout from Clawline are not adopted (D-6).

#### Chat editor (`ConversationReturnTextView`, `ConversationComposerTextInput`)

Anatomy: a native `UITextView` inside the glass composer field, vertical
padding 11. Font `.body` (scales with Dynamic Type), text color system
`.label`, clear background, return key "Send". It grows from 1 to 5 lines,
then scrolls. A SwiftUI placeholder "Write a message…" in `.secondary` shows
while empty; VoiceOver reads the same words as the value.

States: enabled; disabled (frozen or chat not allowed; not editable);
unavailable, where a lock and the reason in `.callout` secondary replace the
composer; read-only, where the saved draft under a "Saved discussion draft"
heading with a lock replaces it and its files still open the inspector.

Behavior that stays: Return sends only when the typed change is a single
newline, not part of a paste and with no marked (in-progress IME) text;
pasted newlines stay as text.

Target: the editor font per DS-27 at the `body` style; text and caret `text`;
placeholder `text2`; the 1 to 5 line sizing and the Return, paste and marked
text behavior unchanged (DS-17). The read-only heading and unavailable reason
use `bodySmall` in `text2`.

#### Attachments in the composer

The plus button opens the system file importer (any file type, several at
once). In the local example, it opens a "Add a local example" dialog (Sample
photo, Sample file, Sample camera image, Cancel). Each attachment shows as a
72 by 48 thumbnail button that opens the file inspector (section 7.9), with a
"Remove" button (`xmark.circle.fill`) on its corner. Target: thumbnails at
`radius.small`; the remove symbol in `text2` on `raised`. The importer and
dialog are system-drawn (section 9).

### 6.12 Foreground chat banner (`ForegroundChatNotificationIndicatorView`)

Anatomy: top safe-area inset, HStack spacing 10, `.regularMaterial` in a
16 pt shape, padding 12, outer padding 12/6/4. No Reduce Transparency branch.

Target: system glass, `radius.panel`, `elevation.raised` (DS-29), padding
`space.compact`, spacing `space.compact`. Under Reduce Transparency, an opaque
`raised` fill (DS-23).

### 6.13 Enrollment (`NativeEnrollmentView`, `UnconfirmedAccountRemovalNotice`)

Anatomy: content at most 620 pt wide; a navigation title per state; a heading
(`.title2` semibold label with a symbol); prose in `.body`, captions and
footnotes in `.secondary`; in the pending state, the last approval code in
`.title` monospaced bold, selectable; cards padded 16, spacing 12, stroked in
`.secondary` at 0.25, radius 12; one `.borderedProminent` capsule primary
button per state, disabled while busy; `.bordered` secondary buttons.

Fields:
- **Full invitation**: a `SecureField` in the welcome card, with no
  autocapitalization and no autocorrection, so the pasted invitation is
  never shown.
- **Device name**: a `TextField` under a "This device" caption in the
  confirmation card.

Progress: "Contacting the invited server" (`ProgressView` with a label) while
busy, and a bare `ProgressView` while an approved device connects.

States (each a screen of the same anatomy): welcome, verifying, confirmation,
joining, pending, unreachable, approved and finishing, connected,
notifications, invitation expired, approval expired, invitation used,
declined, revoked, cancelled, refused, existing account, replacement
confirmation. Secondary buttons by state: "Cancel this request" (pending,
unreachable, approval expired; disabled while busy), "Not now"
(notifications, replacement), "Use another invitation", "Back to saved
messages", "Replace with this invitation…", "Keep current account".
`UnconfirmedAccountRemovalNotice` has a "Retry removal" button that reads
"Retrying removal…" and is disabled while busy.

Target: cards on `raised`, `radius.card`, `elevation.raised` (DS-29), no stroke.
Prominent buttons `accent` with `onAccent`; bordered buttons `text` on `tabOn`;
both `radius.button`, `label` style, at least 44 pt tall. A disabled button
keeps the system disabled treatment over these colors. Fields: text `body` in
`text` on `bg` inside the card, prompt `text2`, system field chrome; the secure
field stays secure. Headings `rowTitleTop`, prose `body`, captions and
footnotes `caption` in `text2`. The approval code keeps the system monospaced
face at a size relative to `.title` (DS-27). Progress views tinted `text2`,
labels `bodySmall`. Card padding `space.base`, spacing `space.compact`.
Wording, state order and which button each state shows are unchanged (DS-17).

### 6.14 Release notes (`ReleaseNotesSheet`, `ReleaseNotesHistoryView`, `ReleaseNoteRow`)

Sheet and list on system styles. Target: `bg`, section headers `sender`, rows
`body` and `caption`. Auto-presentation unchanged.

### 6.15 Settings (`LiveInboxSettings`, `InboxDiagnosticsSettingsSection`, `ReleaseNotesSettingsSection`)

A system `Form`. Target: inset grouped form on `bg` with `raised` rows;
`label` and `caption` styles; toggles tinted `accent`. `InboxSettings` is
unused and out of scope.

### 6.16 Recovery and reference screens

`DisconnectedAccountRecoveryView` and `InboxTierReferenceScreen` follow the
neutral recipes above (`bg`, `text`, `text2`, `sender` headers). The tier
reference screen is a fixture of tier sizes and SHALL show the target tier
styles once the list batch lands.

### 6.17 Debug-only sample views

`SampleCardScreen`, `SampleMedia` views and `SampleChatView` are debug fixtures.
They follow the same tokens when touched. No requirement is placed on them.

### 6.18 Message body text (`SystemDetectedMessageBody`, SharedMessageRendering.swift)

Anatomy: a native `UITextView`, not editable but selectable, with a clear
background, no insets, no scrolling, and system data detection of every type
(links, phone numbers, addresses, dates and the rest). It renders the message's Markdown: strong as bold,
emphasis as italic, inline code in the system monospaced face at the body
size (bold or italic where nested). Font `.body`, scaled with Dynamic Type.
Text color, caret and link color are all the passed foreground (type `text`
on the detail); links are underlined. Used for the detail body
(LiveContentView.swift).

States: plain; with detected links or data; with a text selection.

Target: DM Sans at the `body` style per DS-27, with bold and italic from DM
Sans and code in system monospaced. Text, link and selection tint stay type
`text`; links stay underlined, so they never rely on a second color (DS-4).
Data detection and selection unchanged (DS-17).

### 6.19 Loading, empty and unavailable states

Serves: [PO-C] (1). Each state below is drawn by the system
(`ContentUnavailableView` or `ProgressView`, section 9); the restyle sets only
its colors and the type of text it supplies. Wording, symbols, order and when
each state shows are unchanged (DS-17). No state gains a new screen or message
(section 10).

| Surface | State (wording as in the code) | Current |
|---|---|---|
| Chat panel (ConversationView.swift, `ConversationPanelEmptyState`) | "No chat" (`bubble.left.and.bubble.right`): "The agent that sent this didn't open a chat for it. You can still respond to the message itself." | system unavailable view |
| | "Checking chat availability…" | labeled `ProgressView` |
| | "Chat unavailable" (`bubble.left.and.bubble.right`): "Chat is not available on this server yet." | system unavailable view |
| | "Chat status unavailable" (`wifi.slash`): "The server connection could not confirm whether a chat was opened." | system unavailable view |
| | "Chat status unavailable offline" (`wifi.slash`): "This offline view cannot confirm whether a chat was opened." | system unavailable view |
| | "Chat status not confirmed" (`questionmark.bubble`): "The server has not confirmed whether a chat was opened yet." | system unavailable view |
| Detail column (LiveContentView.swift) | "Request unavailable" (`questionmark.folder`), when the open message is no longer on the device | system unavailable view |
| Historical version sheet (`HistoricalMessageVersionSheet`) | "This version is unavailable now" (`questionmark.folder`): "No saved copy of this message version is available on this device." | on the type background; foreground and tint type `text` |
| Workspace (local example only) | Load error: the store's error text, or "The local example could not be opened." (`exclamationmark.triangle`), in place of the inbox | system unavailable view |
| Saved-messages archive (HarklightApp.swift) | "Saved messages are unavailable" (`exclamationmark.triangle`) with two prominent buttons | system unavailable view; buttons per DS-30 |
| Inbox | Loading or refreshing: the toolbar Refreshing badge (6.4) | badge |
| | Pull to refresh, offered only when the inbox can refresh | system refresh control |
| | Loading an older page: a spinner below the last row | `ProgressView` |
| | Empty: an empty plain list on `bg`, with no message | list |
| | Notification being opened or checked again: a large spinner, the target title and a `.secondary` line; pending list rows with a small spinner or a `.secondary` symbol | `ProgressView` |
| Replied rows | "Loading reply": a small spinner in place of the reply text | `ProgressView` |

Target:
- An unavailable view on a neutral screen sits on `bg`: title `text`, symbol
  and description `text2` (as section 7.8).
- An unavailable view on a type background (the historical version sheet)
  keeps type `text` for its title and symbol and uses type `secondaryText` for
  its description, since a faded `text` is not a measured pairing (DS-6).
- Spinners are tinted `text2` on neutral screens and the row's or screen's
  secondary text color on a type or washed surface. A spinner's label uses
  `bodySmall` in that same color.
- The pull-to-refresh control takes `text2` where the system accepts a tint.
- The empty inbox stays an empty list on `bg` with grain.
- The notification pending title uses `text` and its lines `text2`.

Accept: in light and dark, the chat panel's six states, "Request
unavailable", "This version is unavailable now" and the inbox spinners show
the colors above, and every text in them passes DS-6.

### 6.20 Alerts and confirmation dialogs

Serves: [PO-C] (2). The system draws these (section 9). The restyle sets only
their tint; titles, messages, button wording, order and roles are unchanged
(DS-17).

| Dialog | Kind and place | Buttons | Current tint |
|---|---|---|---|
| "The message changed" | `.alert` on the workspace (HarklightWorkspace.swift), when an answer was sent against an older version | "Review message", "Dismiss" (cancel) | its host sets `.tint(text)` |
| "Connection needs attention" | `.alert` over the live content (LiveContentView.swift), after a foreground connect failure | "Copy details", "Dismiss" (cancel) | none set; the system default |
| "Switch this connection?" | `.confirmationDialog` with visible title, from Settings "Switch connection to new server…" (reads "Checking new server…" and is disabled while busy) | "Switch connection to new server", "Cancel" | the settings tint |
| "Disconnect this phone?" | `.confirmationDialog` with visible title, from the destructive Settings button "Disconnect this phone…" | "Disconnect this phone" (destructive), "Cancel" | destructive in system red |

Target:
- Non-destructive and cancel buttons in every alert and dialog are tinted
  `text`, as "The message changed" is today. The tint is set where the system
  reads it for that presentation.
- Destructive buttons, and the destructive Settings trigger, keep the system
  destructive red (section 8.1). The disconnect result footnote keeps `.red`;
  the switch result footnote is `caption` in `text2`.
- The local example's "Add a local example" dialog (6.11) follows the same
  target.

Accept: in light and dark, each of the four dialogs shows its non-destructive
buttons in `text`, and "Disconnect this phone" in system red.

### 6.21 Pressed and keyboard focus

Serves: [PO-C] (3). At `340c710` the app has no custom button style, hover
effect or focus code beyond reply-action focus. It relies on the system
pressed and focus treatment of each style:

| Component | Style | Pressed today | Keyboard focus today |
|---|---|---|---|
| Inbox and replied rows | `.plain`, tint `.clear` (HarklightWorkspace.swift) | list row highlight | system focus in the row's tint |
| New area rows, foreground chat banner, choice rows | `.plain` | label dims | system focus |
| Enrollment, retry and choice primary buttons | `.borderedProminent` | system darken | system focus |
| Enrollment and detail secondary buttons | `.bordered` | system darken | system focus |
| Send | `.glassProminent` circle | system glass press | system focus |
| Plus, detail toolbar and loading-reply buttons | `.glass` | system glass press | system focus |
| Swipe actions, toggles, tab bar, search, dialogs | system | system | system |

**DS-31.** When an interactive component is pressed or receives keyboard focus,
it SHALL show its system pressed or focus treatment, and that treatment SHALL
be visible in both appearances. The restyle SHALL NOT remove, hide or replace
it, except that Send adds `motion.press` (5.8).
Serves: [PO-C] (3) "pressed and keyboard-focus states for interactive
components"; [FIT] restyle only.
Accept: on iPad with a hardware keyboard and Full Keyboard Access on, in light
and dark, moving focus through an inbox row, a toolbar button, a choice, the
composer, Send and an enrollment button shows a visible focus indicator on
each; pressing each shows its pressed treatment.

Target per component: rows keep the list highlight; if a row's focus indicator
does not show because its tint is `.clear` (A6), its focus color is `text`; prominent buttons darken `accent` with `onAccent` labels
(DS-30); bordered buttons per 6.13; glass buttons keep the system glass press
in their tint (7.4 for the detail toolbar). Hover is section 9's.

## 7. (c) Navigation

### 7.1 Root routing (HarklightApp.swift)

Order: tier reference, selected archive, guided join, disconnected archive,
inbox, then launch state. Unchanged; no visual of its own.

### 7.2 Tab bar

Anatomy: `TabView` with Inbox ("envelope.badge") and Replied ("envelope.open").
Selected tint `accent`; outer tint `text`; `tabOn` unused. On compact width the
tab bar hides while a message is open.

Target: system tab bar (Liquid Glass), selected tint target `accent`, labels in
the system tab style. `tabOn` is either used for the selected item background
where the system allows it, or removed from the token file in the token batch.
Hiding behavior unchanged.

### 7.3 Split view (iPad)

Anatomy: `NavigationSplitView`; sidebar is the inbox list; detail is a
`NavigationStack` with the message card. With width at least 820 in landscape,
chat shows inline: a `Divider` and a panel `min(360, width × 0.34)` wide.

**DS-21.** While the app runs in iPad split view or Slide Over, every screen
SHALL meet this document at the width it gets, in both appearances.
Serves: [FIT] "iPad split view ... called out"; acceptance screenshots
"including split view".
Accept: a half-width split view screenshot in light and dark shows the
sidebar on `bg` with grain, the detail on its type color, and no clipped text.

Target: sidebar on `bg`; the divider in `separator`; the inline chat panel on
`bg` with turns per 6.11. The 820 and 360 thresholds are layout, not tokens,
and do not change.

### 7.4 Navigation bar and toolbars

- Inbox principal: `HarklightBrand` small (24 by 30 mark, "Harklight" title)
  plus the Refreshing badge. Target: title in `label` at 600; badge per 6.4.
- Inbox trailing: Settings gear (icon only) and Warnings button (44 by 44) with
  a popover (320 wide, 88 to 440 tall, a popover even on iPhone). Target: icons
  `text`; popover content on `raised`, `radius.panel`, `bodySmall`.
- Detail: confirmationAction Seen / Finish / Submit with a checkmark; bottomBar
  chat button with an unread badge; topBarTrailing warning. Target: system
  glass buttons tinted from type `text` as today; Done and Send stay inverted
  ([README]). The Seen button, while it can still be marked, is tinted `seen`
  under the system's white symbol (5.00:1), as today with the target value.
  The chat button's unread badge is the system badge (`.badge`), not tinted;
  it keeps the system badge colors (section 8.1).
- The navigation bar background stays hidden on detail screens.
- The inbox toolbar keeps its minimize-on-scroll behavior.

### 7.5 Empty detail (`HarklightBrand` large)

Lighthouse mark 64 by 78, "Harklight" in `.largeTitle` and "Select a message".
Target: `brandLarge` and `bodySmall` in `text2`, on `bg` with grain. The mark
keeps its fixed frame (an illustration, not text).

### 7.6 Search

`searchable` with sidebar placement and prompt "Search messages"; compact width
adds `CompactSearchScrollClearance` (`@ScaledMetric` 80).

**DS-22.** The restyle SHALL keep the compact-width search clearance and its
large-text test passing.
Serves: [FIT] "The large-text Search repair and its tests stay valid."
Accept: `testFloatingSearchKeepsNormalReplyTextVisibleAtLargeContentSizes`
passes after every batch.

Target: system search field; no custom styling beyond tint `accent`.

### 7.7 Sheets

Chat (from the bottom bar on iPhone), settings, release notes, request details,
failed response, historical version, file inspector (7.9). Target: sheets on
`bg`, system grabber and detents unchanged.

### 7.8 Related-message links (LiveContentView.swift, HarklightWorkspace.swift)

Anatomy: in the detail, a "Supersedes" section and a "Replaced by" section
(`ReplacedByMessagesSection`), each a `.caption` semibold label in type
`secondaryText` above one `NavigationLink` per message ID. The ID shows in
`.subheadline`, selectable, in the link tint.

Path: a link pushes onto the detail's navigation stack. The pushed screen is
that message's detail. If the message is not on the device, it is a system
`ContentUnavailableView`: "Message not available" (`questionmark.folder`) for
a superseded message, or "Replacement not available yet" (`clock`) with "The
original message is still available." for a replacement. Back is the system
back button. On iPad the stack lives in the split view's detail column and
empties when the sidebar selection changes. On compact width the tab bar stays
hidden while a message, or a message pushed from it, is open. A notification
whose message is gone shows "Notification no longer available" (`bell.slash`).

Target: section labels `sender` in type `secondaryText`; IDs `bodySmall` in
type `text`, underlined, so the link does not depend on a second color (DS-4).
Pushed details follow 6.7 to 6.9 on their own type color. Unavailable screens
on `bg`, system layout, symbol and description in `text2`, title in `text`.
The back button keeps the system style with tint per 7.4. Stack, emptying and
tab bar behavior unchanged (DS-17).

### 7.9 File import and inspection (ConversationView.swift)

Path: composer plus button, then the system file importer (or the local
example dialog), then a thumbnail in the composer (6.11). Tapping a thumbnail,
or a file in a read-only draft, opens the file inspector as a sheet. It holds a
`NavigationStack` with a system `Form`:

- "File" and "Original bytes" as `LabeledContent` rows.
- "SHA-256" in `.headline`, then the hash in `.caption` monospaced, selectable.
- "Open file", or "Open saved file" when read-only; it reads "Opening…" and is
  disabled while opening, and is disabled when read-only and the file is not
  saved on the device, with a `.caption` secondary note saying so.
- An error line and a note on transfer facts, `.caption` secondary.
- "Done" as the confirmation action.

"Open file" hands the file to system Quick Look, which draws itself.

Target: per 6.15's form recipe (`raised` rows on `bg`); labels `body`, values
`bodySmall` in `text2`; "SHA-256" `label`; hash `caption` size in system
monospaced (DS-27); notes `caption` in `text2`; buttons tinted `accent`. Quick
Look, the importer and the dialog are system-drawn (section 9). Wording and
enable rules unchanged (DS-17).

## 8. (d) Departures from Clawline

| ID | Departure | Reason |
|---|---|---|
| D-1 | Five message-type colors stay, as detail background, list icon, selected iPad row fill and came-back bar (the bar is approved but not yet live, section 8.2). | [FIT] keeps them; they identify type at a glance. |
| D-2 | Importance is shown by size (tier type styles and line limits), never color. | [FIT] "Importance is shown by size, not color." |
| D-3 | The [README] list rules stay: came-back bar, `rowTop` top tier, `rowSelected` came-back row, chat flag. The first three are approved but not yet live (section 8.2). | [FIT] keeps them; shades re-derived from Clawline neutrals. |
| D-4 | Accent is terracotta deepened to #A3553E in light; dark keeps Clawline #E07A5F. Error is retuned to stay apart from it (DS-28). | Clawline #C4785C measures 3.07:1 on cream, below [FIT] 4.5:1. [PO-C] keeps terracotta as the interface accent; DS-28 keeps it from reading as a type. |
| D-5 | Clawline's muted text (stone) is not adopted; `text2` is the lowest text tone. | Stone measures 2.47:1 on cream. [FIT] 4.5:1. |
| D-6 | Chat avatars, bubble shapes with a sharp corner, and flow layout are not adopted. | Harklight chat is a reply thread under a message, not a messenger; [FIT] restyle only, no layout change. |
| D-7 | System Liquid Glass replaces Clawline's CSS glass recipe. | iOS 26 owns glass rendering; a hand-built blur would fight it and lose Reduce Transparency handling. |
| D-8 | Clawline's metal, caustic and dust-mote effects are not adopted. | Not part of the requested highlights; motion beyond the restyle is behavior change. |
| D-9 | Sender names at full `text2`, not 70% opacity. | 70% fails 4.5:1 on `rowTop`. |
| D-10 | Detail screens get no grain and no shadow. | Grain on saturated type fields lowers legibility ([FIT]); shadows read as dirt there. |

### 8.1 Current behavior kept that conflicts with a rule

The code at `340c710` uses color for meaning in ways the departures above do
not allow. This work is a restyle, so these stay as they are. They are
recorded here as current behavior, not as design choices.

- **Importance washes.** High and urgent inbox rows, and the importance
  capsules in the new area and replied rows, use Warning and Error washes
  (commits `0dc30f3`, `1d52cf7`, pinned by tests). Every live row is middle
  tier, so these washes are the only importance signal users see today. This
  conflicts with D-2 ("Importance is shown by size, not color") and DS-4. They
  stay on the same rows with the same meaning, retuned with the Warning and
  Error hues (DS-24). Replacing them with size-based importance is a behavior
  change and a separate item after the Client freeze lifts. [FIT] ruling of
  2026-11-11.
- **System status and kind colors.** Kind badges (Blocker system orange,
  Success system green), row warning icons (system red) and chat send status
  (system orange and red), the detail warning buttons (system red), the
  detail chat button's unread badge (system badge), destructive dialog and settings buttons (system destructive red)
  and the disconnect footnote (`.red`) use system colors outside the token
  file. They are kept as they are. [FIT]: "Other status and kind colors found in the code are
  documented as they are."

### 8.2 Approved list rules not yet live

At `340c710`, three [README] list rules were never switched on: the came-back
bar is decoded but never drawn, the selected-row shade (`rowSelected`) is in
the token file but never read, and no live row is ever top tier, so `rowTop`
never shows on a live row. On iPad, the selected sidebar row is filled with
the open message's type background, and an 8 pt neutral bar marks the leading
edge.

The restyle keeps what the app does today (DS-25). It restyles the selected
iPad row's current fill and does not add the missing rules. The three rules
are approved but not yet live (section 6.3). Turning them on is a separate
item, `wi_40e646fc`, after the Client freeze lifts. [FIT] ruling of
2026-11-11 (dormant list rules).

## 9. (e) Platform constraints

**DS-23.** While Reduce Transparency is on, every glass or material surface the
restyle touches SHALL render as an opaque fill: `raised` on neutral screens,
the type `background` on detail screens.
Serves: [FIT] Reduce Transparency respected.
Accept: with Reduce Transparency on, the foreground chat banner and the
composer field show no blur.

Other constraints the restyle works within:

- **Fonts.** DM Sans ships in the app bundle, is listed under `UIAppFonts`, and
  is used through `Font.custom(_:size:relativeTo:)` in SwiftUI and through
  `UIFont` scaled by `UIFontMetrics` in UIKit text views (DS-27). The font license file
  ships with it. Variable or static files are the coder's choice.
- **Dynamic Type.** Every text style is relative to a system style (DS-8).
  Illustrations and the brand mark keep fixed frames. Touch targets stay at
  least 44 by 44 at every size.
- **Liquid Glass.** System-owned on iOS 26 and later; the app targets iOS 27. Tint and shape are the
  app's; blur and refraction are not.
- **Pointer hover.** iPad with a pointer only. Hover uses `motion.hoverLift` or
  `motion.hoverScale`, and `elevation.hover` once DS-29 allows it, through
  `.hoverEffect` or `onHover`. iPhone has no hover state; nothing may depend
  on one. Pressed and keyboard focus are DS-31.
- **Appearance.** Light is the default appearance in design and screenshots;
  the app follows the system setting at runtime and does not add a picker.
  [ASK] "light mode by default with a full dark palette"; [FIT] restyle only.
- **Squircles.** `RoundedRectangle` with `.continuous` corners (the default).
- **Split view.** See DS-21.
- **System-drawn controls.** The file importer, confirmation dialogs, Quick
  Look, `ContentUnavailableView` layout, `SecureField` and `TextField` chrome,
  progress views, toggles, pickers and disabled-button dimming are drawn by the
  system. The restyle sets only their tint and the colors of text it supplies;
  it does not rebuild them. Native UIKit text views (the message body and the
  chat editor) take the app font through DS-27.
- **Shared files.** `LiveContentView.swift` is restyled only in a slot agreed
  with its current holder. [FIT] nothing in flight is held up.
- **In-flight work.** Build 153, TestFlight review, privacy, the chat-closing
  fix, cache work and CI are not blocked by restyle batches. [FIT].
- **Evidence.** Each batch carries light and dark before and after screenshots
  on iPhone and iPad, including split view. [FIT] acceptance.

## 10. Non-goals

- No behavior, wording, ordering, gesture or VoiceOver label change.
- No new screens, settings, appearance pickers or animations beyond those
  listed.
- No change to message-type identity, tier rules or what drives a tier.
- No replacement of the importance washes with size-based importance (section
  8.1).
- No activation of the came-back bar, the selected-row shade or top-tier rows
  (section 8.2, `wi_40e646fc`).
- No work on the website, the Mac app, notifications' system appearance, or
  Clawline itself.
- No release, TestFlight or installation action.

## 11. Assumptions

Falsifiable statements this document relies on:

- A1. The app's deployment target is iOS 27 (`project.yml`), so `.glassEffect`
  is available everywhere. False if the target drops below 26.
- A2. DM Sans may be bundled under its open font license. False if the license
  file forbids app embedding.
- A3. No live row reaches the top or low tier today, so tier size changes are
  only visible in fixtures until tiers are wired. False if
  `NativeAppLaunch.swift` assigns a tier other than `.middle` to live rows.
- A4. System sheets, tab bars, search fields and swipe buttons accept tint but
  not custom shapes. False if a batch finds a supported API for more.
- A5. Swipe actions and tinted `.borderedProminent`, `.glassProminent` and
  `.glass` buttons draw a white label on their tint unless the app sets the
  label color. False if a screenshot at `340c710` shows a non-white label on
  any of them.
- A6. The system keyboard focus effect draws in the component's tint, so a
  row tinted `.clear` may show none. False if, at `340c710`, a focused inbox
  row shows a visible indicator; then rows need no focus color.

## 12. Open questions

Q-1 (importance color) and Q-2 (system status colors) were settled by the
[FIT] rulings of 2026-11-11 and are recorded in section 8.1. Q-3 (list rules not
live in code) was settled the same day and is recorded in section 8.2.

**Q-4. Floating reply field (NON-BLOCKING).** [README] describes a floating
reply field that grows to 30% and no "Not now" button. The code's reply surface
differs. This document describes the code; the reply field's behavior is not
restyle scope.

**Q-5. Shadow source (NON-BLOCKING).** Clawline's three sources disagree on
shadow values. This document uses [CL] `--shadow-bubble`, as [PO-C] prefers.
One source shared with the Chat and Tuner products is being agreed through
their delivery owners; until it is recorded against this work item, no batch
uses `elevation.*` (DS-29). If the agreed source differs, only `elevation.*`
changes.

**Q-6. Accent on the dormant shades (NON-BLOCKING).** The accent fails 4.5:1 on
the dormant `rowTop` and `rowSelected` shades (light 4.09 and 4.26, dark 4.02
on `rowSelected`; DS-6). No live row shows those shades (section 8.2), so no
restyle batch is affected. Turning them on under `wi_40e646fc` has to re-derive
the shades or the flag color first. Lightening light `rowTop` enough would put
it about dE00 1.7 from `bg`, too close to tell apart.
