import QtQuick
import Quickshell
import Quickshell.Io

// The data side of the OpenRouter widget. All extraction lives behind
// bin/collect, which prints one display-ready JSON record; this file only
// schedules that command and parses what it prints. No systemd units, no
// shared state directory: the record travels over stdout and lives here.
Item {
  id: root
  visible: false

  property var settings: ({})

  // manifest.json's directory, resolved at load time. Process wants a plain
  // path, not the file:// URL Qt.resolvedUrl hands back.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    return url.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  property var record: null
  property bool loading: false
  property string collectError: ""
  property string stdoutBuf: ""
  property string stderrBuf: ""
  property bool outputOverflow: false
  readonly property int maxCollectorOutput: 1024 * 1024
  readonly property int maxCollectorError: 8192

  readonly property bool ready: !!record && record.ready === true

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 300)))
  property string pendingKind: ""
  property string detailsPeriod: "1mo"
  readonly property var detailsPeriods: ["7d", "1mo", "3mo"]

  Process {
    id: collectProcess
    running: false

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.outputOverflow) return
        var piece = String(chunk || "")
        if (root.stdoutBuf.length + piece.length > root.maxCollectorOutput) {
          root.outputOverflow = true
          collectProcess.running = false
          return
        }
        root.stdoutBuf += piece
      }
    }

    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.stderrBuf.length >= root.maxCollectorError) return
        root.stderrBuf += String(chunk || "").slice(0, root.maxCollectorError - root.stderrBuf.length)
      }
    }

    onExited: {
      collectDeadline.stop()
      root.loading = false
      if (!root.outputOverflow) root.applyRecord(root.stdoutBuf)
      else root.collectError = "Collector output exceeded its safety limit."
      if (root.stderrBuf.trim() !== "") console.warn("openrouter-usage", root.stderrBuf.trim())
      if (root.pendingKind !== "") {
        var kind = root.pendingKind
        root.pendingKind = ""
        root.collect(kind)
      }
    }
  }

  Timer {
    id: collectDeadline
    interval: 30000
    repeat: false
    onTriggered: {
      if (!collectProcess.running) return
      root.collectError = "Collector timed out."
      root.outputOverflow = true
      collectProcess.running = false
    }
  }

  function collect(kind) {
    if (collectProcess.running) {
      // Collapse queued requests: a forced refresh outranks the cheaper
      // kinds it might have been queued behind.
      if (kind === "force" || pendingKind === "") pendingKind = kind
      return
    }
    var command = [pluginDir + "/bin/collect"]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    command.push("--period")
    command.push(root.detailsPeriod === "7d" || root.detailsPeriod === "3mo" ? root.detailsPeriod : "1mo")
    loading = true
    stdoutBuf = ""
    stderrBuf = ""
    outputOverflow = false
    collectProcess.command = command
    collectProcess.running = true
    collectDeadline.restart()
  }

  function setPeriod(period) {
    var next = period === "7d" || period === "3mo" ? period : "1mo"
    if (next === detailsPeriod) return
    detailsPeriod = next
    collect("normal")
  }

  function cyclePeriod() {
    var list = detailsPeriods
    var index = list.indexOf(detailsPeriod)
    if (index < 0) index = 1
    setPeriod(list[(index + 1) % list.length])
  }

  function applyRecord(output) {
    try {
      if (String(output || "").length > root.maxCollectorOutput) throw new Error("record too large")
      var parsed = JSON.parse(String(output || ""))
      if (parsed && typeof parsed === "object" && parsed.schemaVersion === 1 && parsed.id === "openrouter") {
        record = root.normalizeValue(parsed, 0)
        collectError = ""
        return
      }
    } catch (e) {
      console.warn("openrouter-usage", "Ignoring bad record", e)
    }
    collectError = "Collector produced no usable record."
  }

  function normalizeValue(value, depth) {
    if (depth > 8 || value === undefined || value === null) return null
    if (typeof value === "string") return value.replace(/[\x00-\x1f\x7f]/g, "").slice(0, 512)
    if (typeof value === "number") return isFinite(value) ? value : 0
    if (typeof value === "boolean") return value
    if (Array.isArray(value)) {
      var list = []
      for (var i = 0; i < value.length && i < 128; i++) list.push(root.normalizeValue(value[i], depth + 1))
      return list
    }
    if (typeof value === "object") {
      var result = {}
      var keys = Object.keys(value)
      for (var j = 0; j < keys.length && j < 128; j++) {
        var key = String(keys[j]).slice(0, 160)
        result[key] = root.normalizeValue(value[keys[j]], depth + 1)
      }
      return result
    }
    return null
  }

  function refreshAll(force) { collect(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collector reuses its
  // recent scan in this mode.
  function refreshLimits() { collect("limits") }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.collect("normal")
  }

  // ------------------------------------------------------------ formatting

  function formatTokenCount(n) {
    if (n === undefined || n === null) return "0"
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function friendlyModelName(id) {
    if (!id) return "Unknown"
    // OpenRouter ids are vendor/model; the vendor is noise in a four-row
    // table and the model half already carries the family name.
    var name = String(id).split("/").pop()
    // Snapshot builds append YYYYMMDD (`qwen3.8-max-20260803`). Drop it so
    // the row reads as the product, not the train date.
    name = name.replace(/-\d{8}$/, "")
    var words = name.split("-")
    var out = []
    for (var i = 0; i < words.length; i++) {
      var w = words[i]
      if (w === "" || /^\d{8}$/.test(w)) continue
      if (w === "gpt") w = "GPT"
      else if (w === "deepseek") w = "DeepSeek"
      else if (!/^\d/.test(w)) w = w.charAt(0).toUpperCase() + w.slice(1)
      out.push(w)
    }
    return out.join(" ")
  }
}
