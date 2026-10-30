# Harklight design system

This is the start of Harklight's design system. It currently covers color, plus the list and detail rules that depend on color.

- `index.html` renders the master list and a detail screen for every message type, in light and dark mode, with the color swatches. Open it in a browser.
- `tokens.json` holds the values. It is the source the app's colors should come from.
- `palettes.js` holds the data the page renders.

## Direction

Natural, humanistic, modern Nordic: light woods, linen, plants. Colors are desaturated, except brick red, which keeps its strength so errors stand out.

No pure white and no pure black. Light mode uses off-white backgrounds and off-black text. Dark mode uses off-black backgrounds and dimmer off-white text that is comfortable in the dark.

## Color carries the message type

Each message type has one color. That color is the background of its detail screen.

| Type | Color | Light background | Dark background |
|---|---|---|---|
| Request | Teak | `#7A5540` | `#2C2019` |
| Information | Fjord | `#4D6470` | `#1D252A` |
| Completed | Moss | `#4E6547` | `#1E261C` |
| Warning | Ochre | `#73592A` | `#2B2516` |
| Error | Brick | `#A63A2A` | `#3A1A14` |

Don't assign color meaning to anything else. In particular, don't give senders or importance their own colors: importance is shown by the tier's title size and body length.

## Master list

- Every row uses the shared neutral background by default. Rows are not tinted by message type.
- Top-tier rows use the `rowTop` neutral shade: `#E6E2DA` in light mode and `#201F1D` in dark mode.
- The row for the message you last viewed (the one you came back from) uses the `rowSelected` neutral shade: `#E7EBE4` in light mode and `#29302B` in dark mode.
- Each row's type icon uses its type color. In dark mode the icon uses the lighter shade of the same hue (`listIcon` in `tokens.json`), because the dark backgrounds are too dark to read at icon size.
- The message you came back from has a bar on the right edge of its row, in that message's detail background color. The bar's left corners are rounded and its right edge is square. On wide screens, where the list and detail sit side by side, the bar meets the detail pane and reads as one piece with it.
- Chat flag: a small chat bubble next to the time once a chat has started. It is an outline in secondary text color, and a filled bubble in the accent color when a new chat message is waiting.

## Detail screen

- The background is the type color, with light text. Every text pairing passes 4.5:1 contrast.
- Glass buttons are tinted from the screen's text color. The Done and Send buttons invert: they are filled with the text color and their icon or label uses the background color.
- The chat button floats in the bottom-right corner. It is a glass outline normally, and filled with a small dot when a new chat message is waiting.
- Reply choices: a selected choice highlights like any other choice and contains no text box. Typing happens in a field that floats above the keyboard, with a round up-arrow send button to its right. The field grows up to 30% of the screen height, then scrolls internally. After sending, the reply text appears inside the selected choice's border, under its label. Tapping it reopens the field above the keyboard.
- There is no Not now button.
