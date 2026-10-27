// Tests for the UI's JavaScript libraries, run with plain Node.
// Each `.pragma library` file is evaluated in its own context.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

function load(rel) {
  const file = path.join(__dirname, "..", "ui", rel)
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "")
  const context = vm.createContext({ String, Number, Math, Date, JSON, Object, Array, isFinite, Infinity })
  vm.runInContext(source, context, { filename: file })
  return context
}

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL " + name + ": " + e.message)
    process.exitCode = 1
  }
}

const Layout = load("lib/Layout.js")
const Format = load("lib/Format.js")
const Keymap = load("keys/Keymap.js")
const Thumbhash = load("lib/Thumbhash.js")
const Wire = load("backend/Wire.js")

test("justified rows fill the width exactly", () => {
  const items = [1.5, 0.75, 1.33, 1.78, 1, 1.5, 0.66, 2.4, 1.33, 1.5].map(r => ({ ratio: r }))
  const width = 1000, gap = 3
  const rows = Layout.rows(items, width, 200, gap)
  let covered = 0
  rows.forEach((row, i) => {
    const w = Layout.widths(items, row, width, gap)
    assert.strictEqual(w.length, row.count)
    if (i < rows.length - 1) {
      const sum = w.reduce((a, b) => a + b, 0) + gap * (row.count - 1)
      assert.strictEqual(sum, width, "row " + i + " sums to " + sum)
      assert.ok(row.height > 120 && row.height < 320, "row height " + row.height)
    }
    covered += row.count
  })
  assert.strictEqual(covered, items.length)
})

test("the last row is not stretched", () => {
  const items = [{ ratio: 1 }]
  const rows = Layout.rows(items, 1000, 200, 3)
  assert.strictEqual(rows.length, 1)
  assert.strictEqual(rows[0].height, 200)
  assert.deepStrictEqual(Array.from(Layout.widths(items, rows[0], 1000, 3)), [200])
})

test("broken ratios are clamped", () => {
  assert.strictEqual(Layout.clampRatio(null), 1)
  assert.strictEqual(Layout.clampRatio(50), 3.2)
  assert.strictEqual(Layout.clampRatio(0.01), 0.4)
})

test("widths survive a row that outruns its items", () => {
  assert.deepStrictEqual(Array.from(Layout.widths([], { start: 0, count: 2, height: 100 }, 500, 3)), [0, 0])
})

test("bucket labels", () => {
  assert.strictEqual(Format.bucketLabel("2026-10-01", 2026), "October")
  assert.strictEqual(Format.bucketLabel("2019-03-01", 2026), "March 2019")
  assert.strictEqual(Format.bucketYear("2019-03-01T00:00:00.000Z"), 2019)
})

test("dates read without time zone shifts", () => {
  assert.strictEqual(Format.dateLabel("2026-10-24T06:12:08"), "Saturday, 24 October 2026")
  assert.strictEqual(Format.timeLabel("2026-10-24T06:12:08"), "06:12")
  assert.strictEqual(Format.dayKey("2026-10-24T23:59:00.000Z"), "2026-10-24")
  assert.strictEqual(Format.dateRange("2026-01-02", "2026-01-05"), "2–5 Jan 2026")
})

test("numbers and sizes", () => {
  assert.strictEqual(Format.thousands(147254), "147,254")
  assert.strictEqual(Format.count(1, "photo"), "1 photo")
  assert.strictEqual(Format.count(3, "person", "people"), "3 people")
  assert.strictEqual(Format.bytes(2008537), "1.9 MB")
  assert.strictEqual(Format.exposure("1/250"), "1/250 s")
  assert.strictEqual(Format.exposure(0.004), "1/250 s")
})

test("media versions keep only safe characters", () => {
  assert.strictEqual(Format.versionOf("EjkS+JI/Z4=="), "EjkSJIZ4")
})

test("sync summaries", () => {
  assert.strictEqual(Format.syncSummary({ phase: "disabled" }), "Folder sync is off")
  assert.strictEqual(Format.syncSummary({ phase: "uploading", queue: 2, active: [{}] }), "Uploading 3 files")
  assert.strictEqual(Format.syncSummary({ phase: "idle", failed: 2 }), "2 files could not upload")
})

test("no key means two things in one context", () => {
  assert.deepStrictEqual(Array.from(Keymap.conflicts()), [])
})

test("typing contexts bind no bare letters", () => {
  for (const context of ["search", "page", "dialog"]) {
    for (const entry of Keymap.sequencesFor(context)) {
      assert.ok(/^(Ctrl|Alt|Meta)\+|^Escape$|^F\d+$/.test(entry.sequence), context + " binds " + entry.sequence)
    }
  }
})

test("holding a key never repeats a change to the library", () => {
  for (const context of ["grid", "viewer"]) {
    for (const entry of Keymap.sequencesFor(context)) {
      const binding = Keymap.BINDINGS.find(b => b.id === entry.id)
      if (["favorite", "archive", "trash", "deleteForever", "addToAlbum", "tag", "share", "download", "rate"].includes(entry.id))
        assert.strictEqual(entry.repeat, false, entry.id + " on " + entry.sequence + " repeats")
      else assert.strictEqual(entry.repeat, binding.changes !== true)
    }
  }
})

test("the viewer and grid have hints", () => {
  assert.ok(Keymap.hintsFor("grid").length >= 4)
  assert.ok(Keymap.hintsFor("viewer").length >= 4)
  assert.strictEqual(Keymap.contextFor({ dialog: true, viewer: true }), "dialog")
  assert.strictEqual(Keymap.contextFor({ viewer: true }), "viewer")
})

test("thumbhash average colour", () => {
  const c = Thumbhash.averageColor("EjkSJIZ4h4ePd3h4iHVHf3f1dw==")
  assert.ok(/^#[0-9a-f]{6}$/.test(c), c)
  assert.strictEqual(Thumbhash.averageColor(""), "")
  assert.strictEqual(Thumbhash.averageColor("!!!"), "")
})

test("wire frames", () => {
  assert.ok(Wire.response({ jsonrpc: "2.0", id: "q1", result: 1 }))
  assert.strictEqual(Wire.response({ jsonrpc: "2.0", id: "q1", result: 1, error: {} }), null)
  assert.ok(Wire.notification({ jsonrpc: "2.0", method: "sync.changed", params: {} }))
  assert.strictEqual(Wire.notification({ jsonrpc: "2.0", method: "evil.thing", params: {} }), null)
  assert.strictEqual(Wire.parse("not json"), null)
})

test("an http:// address is called out only when it crosses the internet", () => {
  for (const home of ["http://192.168.1.10:2283", "http://10.0.0.5", "http://172.20.1.1:2283", "http://127.0.0.1:2283",
    "http://nas:2283", "http://nas.local:2283", "http://jellyfin.home.arpa", "http://100.101.102.103:2283",
    "http://media.tail1234.ts.net", "http://[::1]:2283", "http://[fd00::5]:2283", "https://tv.example.com", "", "192.168.1.10", "nas:2283"])
    assert.strictEqual(Format.plainOverInternet(home), false, home)
  for (const away of ["http://tv.example.com", "HTTP://tv.example.com:2283/jellyfin", "http://203.0.113.7:2283",
    "http://172.32.0.1", "http://[2001:db8::1]:2283", "http://tv.example.com.", "tv.example.com:2283"])
    assert.strictEqual(Format.plainOverInternet(away), true, away)
})

console.log(passed + " UI logic tests passed")
