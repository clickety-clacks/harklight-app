const GLASS_LIGHT = { glass: "rgba(255,255,255,0.72)", glassEdge: "rgba(0,0,0,0.08)", tabOn: "rgba(0,0,0,0.06)" };
const GLASS_DARK = { glass: "rgba(44,44,48,0.72)", glassEdge: "rgba(255,255,255,0.10)", tabOn: "rgba(255,255,255,0.10)" };

const GLASS_LIGHT_WARM = { glass: "rgba(250,246,238,0.74)", glassEdge: "rgba(60,45,30,0.10)", tabOn: "rgba(60,45,30,0.07)" };
const GLASS_DARK_WARM = { glass: "rgba(46,42,37,0.74)", glassEdge: "rgba(240,230,215,0.10)", tabOn: "rgba(240,230,215,0.10)" };

const PALETTES = { harklight: {
  "_name": "Harklight",
  "_typed": true,
  "_note": "Birch neutrals for the list. The detail screen takes the color of the message type: request teak, information fjord, completed moss, warning ochre, error brick. In the list every row shares one off-white background and the type icon takes the detail color. A bar on the right edge marks the message you came back from.",
  "light": {
    "glass": "rgba(250,246,238,0.74)",
    "glassEdge": "rgba(60,45,30,0.10)",
    "tabOn": "rgba(60,45,30,0.07)",
    "bg": "#F1EEE9",
    "rowTop": "#E6E2DA",
    "rowSelected": "#E7EBE4",
    "text": "#31302D",
    "text2": "#5C5854",
    "accent": "#526657",
    "onAccent": "#F3F0EA",
    "separator": "#DEDAD3",
    "infoBody": "#E7EBE4",
    "infoText": "#354438",
    "replySurface": "#F1EFEB",
    "seen": "#587C60",
    "errorTitle": "#A63A2A",
    "warningTitle": "#6A562A",
    "errorBody": "#F7E4DE",
    "errorText": "#6E2417",
    "warningBody": "#EEE9DC",
    "warningText": "#483B1E",
    "doneBody": "#E4E9E1",
    "doneText": "#394834",
    "detailBg": "#526657",
    "detailText": "#F3F0EA",
    "detailText2": "#E2E8E1",
    "detailSelected": "rgba(255,255,255,0.16)",
    "detailField": "rgba(0,0,0,0.18)",
    "types": {
      "request": {
        "edge": "#755441",
        "bg": "#7A5540",
        "text": "#F6F1E7",
        "text2": "#E3DCCF"
      },
      "info": {
        "edge": "#4D6470",
        "bg": "#4D6470",
        "text": "#F6F1E7",
        "text2": "#E3DCCF"
      },
      "done": {
        "edge": "#4E6547",
        "bg": "#4E6547",
        "text": "#F6F1E7",
        "text2": "#E3DCCF"
      },
      "warning": {
        "edge": "#73592A",
        "bg": "#73592A",
        "text": "#F6F1E7",
        "text2": "#E3DCCF"
      },
      "error": {
        "edge": "#A63A2A",
        "bg": "#A63A2A",
        "text": "#F6F1E7",
        "text2": "#E3DCCF"
      }
    }
  },
  "dark": {
    "glass": "rgba(46,42,37,0.74)",
    "glassEdge": "rgba(240,230,215,0.10)",
    "tabOn": "rgba(240,230,215,0.10)",
    "bg": "#161514",
    "rowTop": "#201F1D",
    "rowSelected": "#29302B",
    "text": "#DDD9D1",
    "text2": "#9E9992",
    "accent": "#A5BAA9",
    "onAccent": "#19211B",
    "separator": "#2C2A27",
    "infoBody": "#212823",
    "infoText": "#C4D1C6",
    "replySurface": "#201F1D",
    "seen": "#9CBAA2",
    "errorTitle": "#EE8B75",
    "warningTitle": "#C6AD7E",
    "errorBody": "#34201B",
    "errorText": "#F2B9AA",
    "warningBody": "#29251B",
    "warningText": "#D8C8A8",
    "doneBody": "#20271E",
    "doneText": "#B8C6B1",
    "detailBg": "#202822",
    "detailText": "#D5DAD3",
    "detailText2": "#9CA79C",
    "detailSelected": "rgba(255,255,255,0.07)",
    "detailField": "rgba(0,0,0,0.28)",
    "types": {
      "request": {
        "edge": "#C9A891",
        "icon": "#C9A891",
        "bg": "#2C2019",
        "text": "#E4D3C4",
        "text2": "#B09A88"
      },
      "info": {
        "edge": "#9FB4BF",
        "icon": "#9FB4BF",
        "bg": "#1D252A",
        "text": "#CFD9DE",
        "text2": "#93A3AB"
      },
      "done": {
        "edge": "#A5BC9C",
        "icon": "#A5BC9C",
        "bg": "#1E261C",
        "text": "#D3DDCC",
        "text2": "#99A891"
      },
      "warning": {
        "edge": "#D8BE84",
        "icon": "#D8BE84",
        "bg": "#2B2516",
        "text": "#E6D9B8",
        "text2": "#AEA283"
      },
      "error": {
        "edge": "#EE8B75",
        "icon": "#EE8B75",
        "bg": "#3A1A14",
        "text": "#F2C9BE",
        "text2": "#C0948A"
      }
    }
  }
} };

const CHANGES = [];
