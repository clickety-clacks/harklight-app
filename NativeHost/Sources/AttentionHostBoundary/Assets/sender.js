"use strict";

// This module draws a document already admitted and scene-selected by the
// shared native semantic port. It never constructs an answer or chooses a
// terminal branch from sender text.
const SVG = "http://www.w3.org/2000/svg";
const svgElement = name => document.createElementNS(SVG, name);
const byId = (items, id) => items.find(item => item.id === id);
const validPoint = point => point && Number.isInteger(point.x) && Number.isInteger(point.y) &&
  point.x >= 0 && point.x <= 1000 && point.y >= 0 && point.y <= 1000;

function addText(parent, tag, value) {
  const node = document.createElement(tag);
  node.textContent = value;
  parent.appendChild(node);
  return node;
}

function graphic(resource, point = null, pointLabel = "") {
  const frame = document.createElement("div");
  frame.className = "sender-graphic";
  const svg = svgElement("svg");
  svg.setAttribute("viewBox", `0 0 ${resource.width} ${resource.height}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", point ? `${resource.label}; ${pointLabel} (${point.x}, ${point.y})` : resource.label);
  for (const primitive of resource.primitives) {
    const kind = primitive.kind;
    if (!["rect", "circle", "line", "text"].includes(kind)) continue;
    const node = svgElement(kind);
    const attributes = kind === "rect" ? ["x", "y", "width", "height", "fill"]
      : kind === "circle" ? ["cx", "cy", "r", "fill"]
      : kind === "line" ? ["x1", "y1", "x2", "y2", "stroke", "strokeWidth"]
      : ["x", "y", "fill", "fontSize", "align"];
    for (const field of attributes) {
      const name = {strokeWidth: "stroke-width", fontSize: "font-size", align: "text-anchor"}[field] || field;
      if (field in primitive) node.setAttribute(name, String(primitive[field]));
    }
    if (kind === "text") {
      node.textContent = primitive.text;
      node.setAttribute("font-family", "system-ui");
    }
    svg.appendChild(node);
  }
  if (point) {
    const marker = svgElement("circle");
    marker.setAttribute("cx", String(resource.width * point.x / 1000));
    marker.setAttribute("cy", String(resource.height * point.y / 1000));
    marker.setAttribute("r", String(Math.max(4, Math.min(resource.width, resource.height) / 40)));
    marker.setAttribute("fill", "#C9362B");
    marker.setAttribute("stroke", "#FFFFFF");
    marker.setAttribute("stroke-width", "2");
    svg.appendChild(marker);
  }
  frame.appendChild(svg);
  if (point) addText(frame, "p", `${pointLabel}: ${point.x}, ${point.y}`);
  return frame;
}

function renderSenderScene(mount, senderDocument, scene, options = {}) {
  const draft = options.draft || {};
  const changed = options.onDraft || (() => {});
  mount.replaceChildren();

  function render(node) {
    if (node.kind === "stack" || node.kind === "grid") {
      const group = document.createElement("div");
      group.className = node.kind === "grid" ? "sender-grid" : `sender-stack sender-${node.axis}`;
      if (node.kind === "grid") group.classList.add(`sender-columns-${node.columns}`);
      for (const child of node.children) group.appendChild(render(child));
      return group;
    }
    if (node.kind === "text") {
      const tag = {title: "h2", body: "p", caption: "small"}[node.style];
      return addText(document.createElement("div"), tag, node.text);
    }
    if (node.kind === "illustration") return graphic(byId(senderDocument.illustrations, node.id));
    if (node.kind === "result-point") {
      // The admitted node already contains C's authoritative resolved point.
      if (!validPoint(node.point)) throw Error("Missing authorized known result point");
      return graphic(byId(senderDocument.illustrations, node.id), node.point, node.label);
    }
    if (node.kind !== "input" || !options.editable) throw Error("Unrenderable sender node");
    const declaration = byId(senderDocument.inputs, node.id);
    const field = document.createElement("fieldset");
    addText(field, "legend", declaration.label);
    if (declaration.kind === "response") {
      const choices = document.createElement("div");
      choices.className = node.layout === "cards" ? "sender-cards" : "sender-list";
      for (const action of declaration.actions) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = action.label;
        button.setAttribute("aria-pressed", String(draft[node.id]?.action === action.id));
        if (action.illustration) button.appendChild(graphic(byId(senderDocument.illustrations, action.illustration)));
        button.addEventListener("click", () => changed(node.id, {action: action.id}));
        choices.appendChild(button);
      }
      field.appendChild(choices);
      const selected = declaration.actions.find(action => action.id === draft[node.id]?.action);
      if (selected?.kind === "text") {
        const editor = document.createElement("textarea");
        editor.value = draft[node.id]?.text ?? "";
        editor.setAttribute("aria-label", `${declaration.label}: ${selected.label}`);
        editor.addEventListener("input", () => changed(node.id, {action: selected.id, text: editor.value}));
        field.appendChild(editor);
      }
    } else if (declaration.kind === "text") {
      const editor = document.createElement("textarea");
      editor.value = draft[node.id]?.text ?? "";
      editor.setAttribute("aria-label", declaration.label);
      editor.addEventListener("input", () => changed(node.id, {text: editor.value}));
      field.appendChild(editor);
    } else if (declaration.kind === "point") {
      const point = draft[node.id]?.point;
      const resource = byId(senderDocument.illustrations, declaration.illustration);
      const map = graphic(resource, validPoint(point) ? point : null, declaration.label);
      map.classList.add("sender-point-map");
      let capturedPointer = null, contentBounds = null;
      const normalizedBounds = () => {
        const bounds = map.firstChild.getBoundingClientRect();
        const scale = Math.min(bounds.width / resource.width, bounds.height / resource.height);
        const width = resource.width * scale, height = resource.height * scale;
        return {left: bounds.left + (bounds.width - width) / 2,
          top: bounds.top + (bounds.height - height) / 2, width, height};
      };
      const move = event => {
        const {left, top, width, height} = contentBounds;
        const quantize = value => Math.max(0, Math.min(1000, Math.floor(1000 * value + 0.5)));
        changed(node.id, {point: {x: quantize((event.clientX - left) / width),
          y: quantize((event.clientY - top) / height)}});
      };
      map.addEventListener("pointerdown", event => {
        const {left, top, width, height} = normalizedBounds();
        const x = event.clientX - left, y = event.clientY - top;
        if (width <= 0 || height <= 0 || x < 0 || y < 0 || x > width || y > height) return;
        capturedPointer = event.pointerId;
        contentBounds = {left, top, width, height};
        map.setPointerCapture?.(event.pointerId);
        move(event);
      });
      map.addEventListener("pointermove", event => {
        if (capturedPointer === event.pointerId) move(event);
      });
      map.addEventListener("pointerup", event => {
        if (capturedPointer !== event.pointerId) return;
        move(event);
        map.releasePointerCapture?.(event.pointerId);
        capturedPointer = null;
        contentBounds = null;
      });
      map.addEventListener("pointercancel", event => {
        if (capturedPointer !== event.pointerId) return;
        capturedPointer = null;
        contentBounds = null;
      });
      field.appendChild(map);
      const setPoint = document.createElement("button");
      setPoint.type = "button";
      setPoint.textContent = "Set point";
      setPoint.disabled = !!point;
      setPoint.addEventListener("click", () => changed(node.id, {point: {x: 500, y: 500}}));
      field.appendChild(setPoint);
      if (point) for (const [axis, label] of [["x", "Horizontal position"], ["y", "Vertical position"]]) {
        const input = document.createElement("input");
        input.type = "number";
        input.min = "0"; input.max = "1000"; input.step = "1";
        input.value = String(point[axis]);
        input.setAttribute("aria-label", label);
        input.addEventListener("input", () => {
          const value = input.value.trim();
          changed(node.id, {point: {...point, [axis]: /^(0|[1-9][0-9]*)$/.test(value) && Number(value) <= 1000 ? Number(value) : value}});
        });
        field.appendChild(input);
      }
    }
    return field;
  }

  mount.appendChild(render(scene));
}

if (typeof module !== "undefined") module.exports = {renderSenderScene, graphic};
if (typeof window !== "undefined") window.AttentionSender = {renderSenderScene};
