"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");

class Element {
  constructor(tag) {
    this.tag = tag; this.children = []; this.attributes = {}; this.events = {};
    this.classes = new Set();
    this.classList = {add: name => this.classes.add(name)};
    this.style = {setProperty: () => { throw Error("CSP forbids inline style"); }};
    this.textContent = ""; this.value = "";
  }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener(name, fn) { this.events[name] = fn; }
  get firstChild() { return this.children[0]; }
  getBoundingClientRect() { return this.bounds || {left: 0, top: 0, width: 200, height: 100}; }
}
global.document = {createElement: tag => new Element(tag), createElementNS: (_, tag) => new Element(tag)};
const {renderSenderScene} = require("../Sources/AttentionHostBoundary/Assets/sender.js");
const all = node => [node, ...node.children.flatMap(all)];
const resource = {id: "plan", label: "Floor plan", width: 200, height: 100, primitives: [
  {kind: "rect", x: 0, y: 0, width: 200, height: 100, fill: "#EEEEEE"},
  {kind: "text", x: 20, y: 30, text: "<script>inert</script>", fill: "#000000", fontSize: 14, align: "start"}
]};
const documentValue = {illustrations: [resource], inputs: [
  {kind: "point", id: "where", label: "Location", illustration: "plan"}
]};

test("sender text and graphic labels remain inert DOM text", () => {
  const mount = new Element("main");
  const tree = {kind: "stack", axis: "vertical", children: [
    {kind: "text", text: "<img src=x onerror=alert(1)>", style: "body"},
    {kind: "illustration", id: "plan"}
  ]};
  renderSenderScene(mount, documentValue, tree);
  assert.equal(all(mount).filter(node => node.tag === "script" || node.tag === "img").length, 0);
  assert.ok(all(mount).some(node => node.textContent === "<img src=x onerror=alert(1)>"));
  assert.ok(all(mount).some(node => node.textContent === "<script>inert</script>"));
  assert.equal(all(mount).find(node => node.tag === "svg").attributes["aria-label"], "Floor plan");
});

test("known result point requires native-authorized point and draws read-only marker", () => {
  const mount = new Element("main");
  const scene = {kind: "result-point", id: "plan", label: "Your submitted location"};
  assert.throws(() => renderSenderScene(mount, documentValue, scene), /Missing authorized/);
  renderSenderScene(mount, documentValue, {...scene, point: {x: 240, y: 610}});
  const marker = all(mount).filter(node => node.tag === "circle").at(-1);
  assert.equal(marker.attributes.cx, "48");
  assert.equal(marker.attributes.cy, "61");
  assert.ok(all(mount).some(node => node.textContent === "Your submitted location: 240, 610"));
  assert.equal(all(mount).filter(node => node.tag === "button").length, 0);
});

test("point input maps content bounds and ignores initial letterbox click", () => {
  const mount = new Element("main");
  const edits = [];
  renderSenderScene(mount, documentValue, {kind: "input", id: "where", layout: "diagram"},
    {editable: true, draft: {}, onDraft: (id, value) => edits.push([id, value])});
  const map = all(mount).find(node => node.className === "sender-graphic");
  map.firstChild.bounds = {left: 20, top: 40, width: 200, height: 100};
  map.events.pointerdown({clientX: 10, clientY: 50, pointerId: 3});
  assert.equal(edits.length, 0);
  map.events.pointerdown({clientX: 68, clientY: 101, pointerId: 3});
  assert.deepEqual(edits[0], ["where", {point: {x: 240, y: 610}}]);
  map.events.pointermove({clientX: 400, clientY: -20, pointerId: 3});
  assert.deepEqual(edits[1], ["where", {point: {x: 1000, y: 0}}]);
  map.events.pointerup({clientX: 400, clientY: -20, pointerId: 3});
  assert.deepEqual(edits[2], ["where", {point: {x: 1000, y: 0}}]);
  const setPoint = all(mount).find(node => node.tag === "button");
  setPoint.events.click();
  assert.deepEqual(edits[3], ["where", {point: {x: 500, y: 500}}]);
});
