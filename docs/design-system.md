# Harklight app design system

Status: candidate for independent spec review.
Scope: the Harklight iPhone and iPad app (`Sources/`), light and dark.
Supersedes: `Design/README.md` (the earlier Nordic direction).
Work item: `wi_44f29e86-6006-4513-97aa-cb147cb89fac`.

This document says what the app should look like after it adopts the Clawline
visual language, and what it looks like today. It changes no code. The restyle
itself is later work that lands in small batches against this document.

## 1. Spirit and sources

The product owner's fit ruling (`art_95feab40`, sha256
`b2f78aa2b1779f2d72289aaba893205b64180b5891bb9ddbeb7c69580651856a`) is the
governing intent. Its core lines, quoted where this document cites them:

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
| [FIT] | `art_95feab40` |
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
literal, `Color.orange`/`.green`/`.red`/`.blue`, or numeric font size that is
not read from the token layer.

**DS-2.** When a token is added for this system, the Swift layer SHALL decode
it and expose it as a typed value.
Serves: [FIT] "Clawline values go into the existing token file and the Swift
token layer."
Accept: `rowSelected` exists in `tokens.json` today but is not decoded
(`Neutral` has no field for it). After the list batch, `Neutral.rowSelected`
exists and the came-back row reads it.

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
| `neutral` | existing, plus `rowSelected` (decoded), `raised` |
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
| `tabOn` | rgba(60,45,30,0.07) | rgba(61,52,41,0.07) | rgba(240,230,215,0.10) | rgba(232,228,224,0.10) | ink at low alpha |

`glass` is a tint for system Liquid Glass and for the Reduce Transparency
fallback, not a hand-built blur (section 9).

#### Accent

| Token | Current light | Target light | Current dark | Target dark |
|---|---|---|---|---|
| `accent` | #526657 | #466B4A | #A5BAA9 | #85AD80 |
| `onAccent` | #F3F0EA | #F7F3EB | #19211B | #1C1917 |
| `seen` | #587C60 | #466B4A | #9CBAA2 | #9CBAA2 |

The accent is Clawline sage, deepened in light and lifted one step in dark so
it passes as text on every neutral, including `rowSelected`. Clawline's own
sage (#8FA68A light, #7BA376 dark) fails there. Terracotta is not the accent;
see D-4.

#### Detail

| Token | Current light | Target light | Current dark | Target dark |
|---|---|---|---|---|
| `selectedChoice` | rgba(255,255,255,0.16) | unchanged | rgba(255,255,255,0.07) | unchanged |
| `replyField` | rgba(0,0,0,0.18) | unchanged | rgba(0,0,0,0.28) | unchanged |

These sit on type colors, which this document does not change.

#### Message types

Values are unchanged from [README] and the current token file. Light: every
type has `text` #F6F1E7 and `secondaryText` #E3DCCF; `listIcon` and
`cameBackBar` equal `background`.

| Type | Light background | Dark background | Dark text | Dark secondary | Dark listIcon |
|---|---|---|---|---|---|
| Request | #7A5540 | #2C2019 | #E4D3C4 | #B09A88 | #C9A891 |
| Information | #4D6470 | #1D252A | #CFD9DE | #93A3AB | #9FB4BF |
| Completed | #4E6547 | #1E261C | #D3DDCC | #99A891 | #A5BC9C |
| Warning | #73592A | #2B2516 | #E6D9B8 | #AEA283 | #D8BE84 |
| Error | #A63A2A | #3A1A14 | #F2C9BE | #C0948A | #EE8B75 |

Dark `cameBackBar` equals dark `listIcon`.

**DS-4.** The app SHALL use type colors only to identify a message's type: the
detail background, the list icon and the came-back bar.
Serves: [FIT] "No other color carries meaning: not senders, not importance."
Accept: no sender avatar, priority mark, badge or button takes a type color
except as listed. (Current code breaks this; see Q-1.)

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

Measured target pairings (lowest per row):

| Foreground | Light, lowest | Dark, lowest |
|---|---|---|
| `text` on `bg`, `raised`, `rowTop`, `rowSelected` | 9.32 (rowTop) | 9.38 (rowSelected) |
| `text2` on the same | 6.41 (rowTop) | 6.96 (rowSelected) |
| `accent` on the same | 4.63 (rowTop) | 4.68 (rowSelected) |
| `seen` on the same | 4.63 (rowTop) | 5.62 (rowSelected) |
| `onAccent` on `accent` | 5.48 | 6.90 |
| type `text` on type background | 5.53 (Information) | 10.37 (Error) |
| type `secondaryText` on type background | 4.57 (Information) | 5.86 (Error) |
| type `listIcon` on the four neutrals | 4.76 (Information on rowTop) | 4.85 (Error on rowSelected) |

Current `seen` light (#587C60) measures 4.25:1 on the current `bg` and fails.
The target value fixes it.

Clawline's `text-muted` (stone, #A69B8D light) measures 2.47:1 on cream and
terracotta 3.07:1. Neither is used for text (D-5, D-4).

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

Type scale. Size is the reference size at the default content size; the
"Relative to" style sets the scaling curve
(`Font.custom(_:size:relativeTo:)`).

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
| `space.base` | 16 | Row horizontal padding, detail horizontal padding |
| `space.comfortable` | 20 | Choice label padding (current 14) |
| `space.generous` | 24 | Detail section gaps, iPad container margin |
| `space.large` | 40 | Empty-state spacing |

**DS-10.** The restyle SHALL draw paddings, gaps and margins from the spacing
tokens, rounding current values to the nearest step.
Serves: [FIT] "spacing on a 4px base".
Accept: row vertical padding becomes 20 (top tier, current 18) and 12 (other
tiers, current 13); the detail padding 16 by 18 becomes 16 by 20.

Values that are touch-target or layout sizes, not spacing, keep their meaning:
44 pt targets, 80 pt paging and search clearance, 680 pt card width, 620 pt
enrollment width, 360 pt chat panel.

### 5.4 Radii

All shapes are squircles (`.continuous`). [ASK] "28px squircles"; [CL] radii.

| Token | Value | Clawline source | Used for |
|---|---|---|---|
| `radius.card` | 28 | demo bubble 28 | Detail content panels, enrollment cards, choice cards, reply card |
| `radius.field` | 24 | input 24 | Composer field, reply field |
| `radius.button` | 22 | button 22 | Rectangular buttons |
| `radius.panel` | 20 | card 20 | Foreground chat banner, popover content |
| `radius.inset` | 16 | link card 16 | Choice labels, chat turns, inline editor |
| `radius.small` | 12 | code 12 | Badges that are not capsules, small chips |
| `radius.check` | 4 | bubble sharp corner 4 | Multi-select checkbox |

Capsules and circles stay capsules and circles.

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
| `elevation.raised` | y 2 blur 4 rgba(92,74,61,0.06); y 8 blur 24 rgba(92,74,61,0.10); y 16 blur 40 rgba(92,74,61,0.08) | y 2 blur 4 rgba(0,0,0,0.15); y 8 blur 24 rgba(0,0,0,0.25); y 16 blur 40 rgba(0,0,0,0.20) |
| `elevation.hover` | y 4 blur 8 rgba(92,74,61,0.08); y 12 blur 32 rgba(92,74,61,0.12); y 24 blur 56 rgba(92,74,61,0.10) | y 4 blur 8 rgba(0,0,0,0.20); y 12 blur 32 rgba(0,0,0,0.30); y 24 blur 56 rgba(0,0,0,0.25) |
| `elevation.flat` | none | none |

Source: [CL-DEMO] `--shadow-bubble` and `--shadow-bubble-hover`. Clawline's
three sources disagree on shadow values; the demo is used because it is the
rendered reference. CSS blur is roughly twice a SwiftUI shadow radius, so the
SwiftUI layer uses radius = blur / 2.

**DS-12.** Raised surfaces on the neutral background (`raised` cards, the
foreground chat banner, the enrollment card) SHALL use `elevation.raised`.
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
  circle; priority tints both; on a selected row the initials take type
  `text`. Target: `timestamp` at 700 in `text2` on `raised`. It is not tinted
  by sender or priority (DS-4).
- Selected row (iPad sidebar, while its message shows in the detail). Current:
  the row fills with the selected message's type background, text in type
  `text`. Target: pending Q-3.
- Padding per DS-10. Separator `separator`, 0.5 pt.
- Top-tier rows on `rowTop`; came-back row on `rowSelected` (section 6.3).
- Seen check in `seen`. Chat flag per section 6.3.
- Warning icons: see Q-2.

### 6.2 Priority fill and selection bar (HarklightWorkspace.swift 2255 to 2295)

Current: a row background gradient whose hue comes from the Warning or Error
type color by priority level, and an 8 pt bar on the leading edge whose color
is always the neutral level (#B3A389 light, #756B61 dark), since it is called
with no level. Priority capsules in `NewMessageArea` and reply rows use Warning
and Error hex literals.

Target: depends on Q-1. If importance stays size-only, these fills are removed
in the list batch and importance is the tier type size. The selection bar
becomes the came-back bar (section 6.3).

### 6.3 List rules (kept from [README])

**DS-18.** When a row is the one the user came back from, the row SHALL show a
bar on its right edge in that message's `cameBackBar` color, with its left
corners rounded, on a `rowSelected` background.
Serves: [FIT] "The list rules in Design/README stay: the came-back bar, the
top-tier and selected row shades."
Accept: open a Warning message, go back; its row has a right-edge bar in the
Warning color and a sage-tinted background. (Current code does not do this;
see Q-3.)

**DS-19.** While a row is top tier, it SHALL use the `rowTop` background.
Serves: [FIT] top-tier shade.
Accept: a top-tier fixture row is on `rowTop`; middle and low are on `bg`.

**DS-20.** While a message has an unread chat, its row SHALL show the chat flag
filled in `accent`; otherwise a message with chat shows it outlined in `text2`.
Serves: [FIT] "the chat flag"; [README] chat flag rule.
Accept: an unread chat row shows a filled sage flag; after reading, an outline.

Row shade colors are re-derived from Clawline neutrals (the target `rowTop`
and `rowSelected` above). [FIT] "Their colors may be re-derived."

### 6.4 Badges (MessageMetadataPresentation.swift, InboxBadge.swift)

- **Type badge**: `caption` text in `text2` on a capsule of `text2` at 0.10.
  Target: same anatomy; `label` style at `caption` size, `radius` capsule.
- **Kind badge**: Blocker uses system `.orange`, Success uses `.green`, with a
  sparkles bounce gated on Reduce Motion. Target: see Q-2. The bounce keeps
  its Reduce Motion gate.
- **Retracted pill**: capsule, `caption2` semibold. Target: `timestamp` style at
  600, `text2` on `tabOn`.
- **Refreshing badge** (toolbar): `accent` text on a capsule of `accent` at
  0.14. Target: unchanged recipe with target `accent`.
- **App icon badge** (InboxBadge.swift): a count, not drawn by the app.
  Unchanged.

### 6.5 New area and replied rows (NewMessageArea.swift, ReplyItemArea.swift, HarklightWorkspace.swift)

Anatomy: section header "New · x of y" on `rowTop`; up to 5 rows; More… /
Less. Replied rows show an AI summary, a 3 pt reply capsule in `accent` at
0.55, and priority capsules.

Current: `quietTitle` and separator colors are hex literals; priority capsules
use Warning and Error hex.

Target: header `sender` style on `rowTop`; rows follow section 6.1; reply
capsule `accent` at 0.55; literals replaced by `text2` and `separator` (DS-1);
priority capsules per Q-1.

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
- **Swipe actions**: Clear (`text2` tint), Seen (`seen` tint), No comment.
  Target: same tints with target values. System swipe buttons draw their own
  shape.

### 6.7 Detail card (`MessageCardSurface`, InboxMessageSurface.swift)

Anatomy: scroll view, content at most 680 pt wide, flat type-color background
to the safe-area edges, "N of M" glass capsule in the navigation bar,
72 pt bottom control clearance.

States: each message type; reply editor open; with and without position.

Target: unchanged structure. The type background stays (D-1). "N of M" uses
`label` with monospaced digits on system glass. No grain, no shadow.

### 6.8 Detail content (`LiveRequestDetail`, `MessageHeading`, LiveContentView.swift)

Anatomy: VStack spacing 12, padding 16 by 18. Heading: 28 pt initials, type
symbol fixed 21 pt, title fixed 26 pt bold. Then body, choices, response
controls, replaced-by section, historical version access.

Current tokens: type `text` and `secondaryText`.

Target: spacing `space.compact`, padding `space.base` by `space.comfortable`.
Title `messageTitle`; symbol scales with it. Initials 28 pt circle on
`selectedChoice` with type `text`. Body `body`. Section labels
(`ReplacedByMessagesSection`) `sender` in type `secondaryText`.

### 6.9 Choices (`MessageChoiceLabel`, `NoCommentChoiceRow`, `ReplyChoiceCard`, `AnswerConfirmationCard`)

Anatomy: checkbox (multi, 20 pt, radius 4) or radio, title, detail, optional
"suggested" and "own answer" marks. Padding 14, radius 16, fill
`selectedChoice` when selected. `ReplyChoiceCard` opens an inline editor
(minimum height 120, white text) with `.smooth(0.25)`.

Target: padding `space.comfortable`; radius `radius.inset`; checkbox
`radius.check`; title `body` at 600, detail `bodySmall` in `secondaryText`. The
editor text uses type `text`, not literal white (DS-1). The open animation is
`motion.interaction`, gated by DS-16. Confirmation cards use `radius.card`.

### 6.10 Detail sheets and dialogs

- Request details sheet, `FailedResponseDialog` (medium and large detents),
  `HistoricalMessageVersionSheet`: system sheets on `bg`. Target: `bg` with
  `raised` sections, `radius.card`, `elevation.flat`. Detents unchanged.
- `LiveCompatibilityActions`, `LiveProjectedSceneView`,
  `LiveProjectedInputView`, `SceneTextView`: projected message content using
  `.title2` semibold, `.body`, `.caption`. Target: `rowTitleTop`, `body`,
  `caption` in type colors.
- `SenderIllustrationCanvas`: a drawn illustration. Unchanged.

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
  Send uses `accent` through `.glassProminent` tint. On iPad with a pointer,
  send uses `motion.hoverScale`; pressing uses `motion.press` (DS-16 applies).
- Status lines `caption` in `text2`; orange and red: see Q-2.
- Avatars and flow layout from Clawline are not adopted (D-6).

### 6.12 Foreground chat banner (`ForegroundChatNotificationIndicatorView`)

Anatomy: top safe-area inset, HStack spacing 10, `.regularMaterial` in a
16 pt shape, padding 12, outer padding 12/6/4. No Reduce Transparency branch.

Target: system glass, `radius.panel`, `elevation.raised`, padding
`space.compact`, spacing `space.compact`. Under Reduce Transparency, an opaque
`raised` fill (DS-23).

### 6.13 Enrollment (`NativeEnrollmentView`, `UnconfirmedAccountRemovalNotice`)

Anatomy: content at most 620 pt wide; cards stroked in `text2` at 0.25, radius
12; `.borderedProminent` and `.bordered` buttons.

Target: cards on `raised`, `radius.card`, `elevation.raised`, no stroke.
Prominent buttons `accent` with `onAccent`; bordered buttons `text` on `tabOn`;
both `radius.button`, `label` style, at least 44 pt tall.

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
  ([README]). Chat badge `accent`.
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
failed response, historical version. Target: sheets on `bg`, system grabber and
detents unchanged.

## 8. (d) Departures from Clawline

| ID | Departure | Reason |
|---|---|---|
| D-1 | Five message-type colors stay, as detail background, list icon and came-back bar. | [FIT] keeps them; they identify type at a glance. |
| D-2 | Importance is shown by size (tier type styles and line limits), never color. | [FIT] "Importance is shown by size, not color." |
| D-3 | The [README] list rules stay: came-back bar, `rowTop` top tier, `rowSelected` came-back row, chat flag. | [FIT] keeps them; shades re-derived from Clawline neutrals. |
| D-4 | Accent is deepened sage, not terracotta. Terracotta is not used. | Terracotta (3.07:1 on cream) fails text contrast and sits near the Request and Error hues, which would let a neutral color read as a type. |
| D-5 | Clawline's muted text (stone) is not adopted; `text2` is the lowest text tone. | Stone measures 2.47:1 on cream. [FIT] 4.5:1. |
| D-6 | Chat avatars, bubble shapes with a sharp corner, and flow layout are not adopted. | Harklight chat is a reply thread under a message, not a messenger; [FIT] restyle only, no layout change. |
| D-7 | System Liquid Glass replaces Clawline's CSS glass recipe. | iOS 26 owns glass rendering; a hand-built blur would fight it and lose Reduce Transparency handling. |
| D-8 | Clawline's metal, caustic and dust-mote effects are not adopted. | Not part of the requested highlights; motion beyond the restyle is behavior change. |
| D-9 | Sender names at full `text2`, not 70% opacity. | 70% fails 4.5:1 on `rowTop`. |
| D-10 | Detail screens get no grain and no shadow. | Grain on saturated type fields lowers legibility ([FIT]); shadows read as dirt there. |

## 9. (e) Platform constraints

**DS-23.** While Reduce Transparency is on, every glass or material surface the
restyle touches SHALL render as an opaque fill: `raised` on neutral screens,
the type `background` on detail screens.
Serves: [FIT] Reduce Transparency respected.
Accept: with Reduce Transparency on, the foreground chat banner and the
composer field show no blur.

Other constraints the restyle works within:

- **Fonts.** DM Sans ships in the app bundle, is listed under `UIAppFonts`, and
  is used through `Font.custom(_:size:relativeTo:)`. The font license file
  ships with it. Variable or static files are the coder's choice.
- **Dynamic Type.** Every text style is relative to a system style (DS-8).
  Illustrations and the brand mark keep fixed frames. Touch targets stay at
  least 44 by 44 at every size.
- **Liquid Glass.** System-owned on iOS 26 and later; the app targets iOS 27. Tint and shape are the
  app's; blur and refraction are not.
- **Pointer hover.** iPad with a pointer only. Hover uses `motion.hoverLift` or
  `motion.hoverScale` and `elevation.hover`, through `.hoverEffect` or
  `onHover`. iPhone has no hover state; nothing may depend on one.
- **Appearance.** Light is the default appearance in design and screenshots;
  the app follows the system setting at runtime and does not add a picker.
  [ASK] "light mode by default with a full dark palette"; [FIT] restyle only.
- **Squircles.** `RoundedRectangle` with `.continuous` corners (the default).
- **Split view.** See DS-21.
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

## 12. Open questions

**Q-1. Priority color on inbox rows (BLOCKING for the inbox row batch,
NON-BLOCKING for this document).** Current rows show priority with Warning and
Error hues: row gradients and priority capsules (commits `0dc30f3`, `1d52cf7`,
pinned by tests). Since live rows are always tier middle, this color is the
only live importance signal. [FIT] rules importance is size only and no other
color carries meaning. The product owner must say whether this is a declared
departure to keep or is removed when tiers carry importance. Raised to delivery
ownership on 2026-11-11.

**Q-2. System status colors (NON-BLOCKING).** Kind badges (Blocker orange,
Success green), row warning icons (red) and chat send status (orange, red) use
system colors outside the token file. Options: map them to the Warning, Error
and Completed type colors (which makes them type colors carrying meaning beyond
type), or to neutral `text2` with an SF Symbol carrying the meaning. This
document recommends the neutral route under DS-4. Batches that do not touch
these components proceed.

**Q-3. List rules not live in code (BLOCKING for the list-rule batch,
NON-BLOCKING for this document).** [FIT] keeps the [README] list rules, but at
`340c710`: `cameBackBar` is decoded and never drawn; `rowSelected` is in the
token file but not decoded; no live row is top tier, so `rowTop` never shows on
a live row; the selection mark is an 8 pt neutral bar on the leading edge.
Making DS-18 and DS-19 visible needs code that draws the came-back bar and
assigns tiers. Also, the iPad sidebar's selected row is filled with the
open message's type background, which [FIT] does not list as a type-color use.
The product owner must say whether drawing these rules is restyle (in scope
for the batches) or new behavior (separate work), and whether the selected row
keeps its type fill or moves to `rowSelected`.

**Q-4. Floating reply field (NON-BLOCKING).** [README] describes a floating
reply field that grows to 30% and no "Not now" button. The code's reply surface
differs. This document describes the code; the reply field's behavior is not
restyle scope.

**Q-5. Shadow source (NON-BLOCKING).** Clawline's three sources disagree on
shadow values. This document uses `demo.html`. A later Clawline correction
would be adopted by updating `elevation.*` only.
