import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OpenRouter credits and spend in one bar panel. Single provider, cost
// first: the charts are dollars, and token counts ride in the tooltips.
Panel {
  id: root
  moduleName: "titaniumcoder.openrouter-usage"
  ipcTarget: "titaniumcoder.openrouter-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var record: usage.record
  readonly property var balance: record ? (record.balance || null) : null
  // Account-wide daily bars from the Analytics API, colored by the week's
  // top three keys. The collector emits them only with a management key.
  readonly property var days: record && Array.isArray(record.dailyDays) ? record.dailyDays : []
  // Top three keys by cost across the whole week, ranked by the collector.
  readonly property var dailyKeys: record && Array.isArray(record.dailyKeys) ? record.dailyKeys : []
  // Bars only break into colored segments when two or more keys were active
  // during the week; a single-key account keeps the plain bar and no legend.
  readonly property bool keyedBars: dailyKeys.length > 1
  readonly property var keyIndexMap: {
    var map = {}
    for (var i = 0; i < dailyKeys.length; i++)
      map[String((dailyKeys[i] || {}).name || "")] = i
    return map
  }
  readonly property var activity: record ? (record.activity || null) : null
  readonly property var topModels: activityModelRows()
  readonly property var topApps: activity && Array.isArray(activity.topApps) ? activity.topApps.slice(0, 3) : []
  readonly property var topKeys: activity && Array.isArray(activity.topKeys) ? activity.topKeys.slice(0, 3) : []
  // Per-key spend budgets from /keys: limit is the cap, used the current
  // period's draw, reset the cadence. Sorted most-drained first.
  readonly property var keyBudgets: record && Array.isArray(record.keyBudgets) ? record.keyBudgets : []

  readonly property bool detailsExpanded: root.setting("detailsExpanded", false) === true

  // A budget gauge only exists when the collector was told the top-up size
  // (fundedAmount in ~/.config/omarchy/agents/openrouter.json); without it
  // funded is 0 and the balance is a plain number that never alarms.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1

  property bool cursorActive: false
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function refreshNow() { usage.refreshAll(true) }

  readonly property string barBalanceLabel: balance
    ? formatMoney(balance.remaining, balance.currency)
    : ""

  function openLink(url) {
    var href = String(url || "")
    if (href === "") return
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("xdg-open " + Util.shellQuote(href))
    else
      Qt.openUrlExternally(href)
  }

  // ---------------------------------------------------------------- money

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) return ""
    var prefix = String(currency || "USD").toUpperCase() === "USD" ? "$" : String(currency).toUpperCase() + " "
    return prefix + amount.toFixed(2)
  }

  function formatCost(value) {
    var n = Number(value || 0)
    if (!(n >= 0)) n = 0
    if (n >= 1000) return "$" + (n / 1000).toFixed(1) + "k"
    // Always two decimals so a column of amounts never mixes widths.
    return "$" + n.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  function budgetTooltip(b) {
    if (!b) return ""
    var text = formatMoney(b.used) + " of " + formatMoney(b.limit) + " · " + formatMoney(b.remaining) + " left"
    var reset = String(b.reset || "")
    if (reset !== "") text += " · resets " + reset
    return text
  }

  // Gauge ramp: calm foreground below half the cap, then a steady blend
  // toward the urgent red as a key approaches its budget.
  function drainColor(drain) {
    var t = clamp((Number(drain || 0) - 0.5) / 0.5, 0, 1)
    return Qt.rgba(
      foreground.r + (urgent.r - foreground.r) * t,
      foreground.g + (urgent.g - foreground.g) * t,
      foreground.b + (urgent.b - foreground.b) * t,
      1)
  }

  // Reset cadence as one trailing letter: M(onthly), W(eekly), D(aily),
  // N(ever). Empty for keys without a cadence.
  function resetLetter(reset) {
    var r = String(reset || "").toLowerCase()
    if (r === "monthly") return "M"
    if (r === "weekly") return "W"
    if (r === "daily") return "D"
    if (r === "never" || r === "none") return "N"
    return ""
  }

  // ---------------------------------------------------------------- content

  function heroMeta() {
    if (!record) return ""
    if (String(record.usageStatusText || "") !== "") return record.usageStatusText
    var tier = String(record.tierLabel || "")
    if (tier === "") return "Pay per token"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    return today ? "Today" : dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + formatCost(day.cost)
      + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    if (root.keyedBars && day.keys && day.keys.length > 0) {
      var other = 0
      for (var i = 0; i < day.keys.length; i++) {
        var k = day.keys[i] || {}
        if (root.keyIndexMap[String(k.name || "")] === undefined) {
          other += Number(k.cost || 0)
          continue
        }
        text += "\n" + String(k.name || "") + " · " + formatCost(k.cost)
      }
      if (other > 0) text += "\nOther · " + formatCost(other)
    }
    return text
  }

  // Three hues chosen to stay distinguishable from each other and from the
  // theme: lightness follows the foreground so the segments read on both
  // dark and light popups.
  function keyColor(index) {
    var hues = [212, 25, 160]
    var lum = 0.2126 * foreground.r + 0.7152 * foreground.g + 0.0722 * foreground.b
    return Qt.hsla(hues[index % hues.length] / 360, 0.62, lum > 0.5 ? 0.42 : 0.62, 1)
  }

  // One day's bar as a list of {index, start, fraction} segments, in rank
  // order, followed by Other. Empty when the chart renders plain.
  function daySegments(day) {
    // day.keys arrives as a Qt list wrapper inside Repeater delegates, so a
    // length check is the only portable guard — Array.isArray lies there.
    if (!root.keyedBars || !day || !day.keys || !(day.keys.length > 0)) return []
    var total = Number(day.cost || 0)
    if (!(total > 0)) return []
    var top = [], other = 0
    for (var i = 0; i < day.keys.length; i++) {
      var k = day.keys[i] || {}
      var idx = root.keyIndexMap[String(k.name || "")]
      if (idx !== undefined) top.push({ index: idx, cost: Number(k.cost || 0) })
      else other += Number(k.cost || 0)
    }
    top.sort(function(a, b) { return a.index - b.index })
    var segs = [], pos = 0
    for (var j = 0; j < top.length; j++) {
      segs.push({ index: top[j].index, start: pos / total, fraction: Math.min(1 - pos / total, top[j].cost / total) })
      pos += top[j].cost
    }
    if (other > 0 && pos < total)
      segs.push({ index: -1, start: pos / total, fraction: (total - pos) / total })
    return segs
  }

  function weekPeak() {
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].cost || 0))
    return Math.max(1e-9, peak)
  }

  function activityModelRows() {
    var list = activity && activity.topModels ? activity.topModels : []
    var rows = []
    for (var i = 0; i < list.length; i++) {
      var row = list[i] || {}
      rows.push({
        name: usage.friendlyModelName(row.name || ""),
        tokens: Number(row.tokens || 0),
        cost: Number(row.cost || 0)
      })
    }
    return rows
  }

  // OpenRouter's brand palette pairs chartreuse with dark surfaces and
  // purple with light ones; pick the twin that reads on this theme's popup.
  function logoSource() {
    var lum = 0.2126 * surface.r + 0.7152 * surface.g + 0.0722 * surface.b
    return Qt.resolvedUrl(lum > 0.5 ? "assets/openrouter-light.svg" : "assets/openrouter.svg")
  }

  function footerText() {
    if (!record || !record.updatedAt) return ""
    var updated = new Date(String(record.updatedAt))
    if (isNaN(updated.getTime())) return ""
    var minutes = Math.max(0, Math.round((root.nowMs - updated.getTime()) / 60000))
    return minutes === 0 ? "Updated just now" : "Updated " + minutes + " min ago"
  }

  function periodLabel(period) {
    if (period === "7d") return "7D"
    if (period === "3mo") return "3MO"
    return "1MO"
  }

  function activityHint() {
    if (!activity) return ""
    if (activity.needsManagementKey)
      return "Add managementKey to ~/.config/omarchy/agents/openrouter.json for spend cards and ranked lists."
    return ""
  }

  function formatActivityTokens(n) {
    return usage.formatTokenCount(n)
  }

  function formatRequests(n) {
    var count = Number(n || 0)
    if (!(count >= 0)) count = 0
    if (count >= 1000) return usage.formatTokenCount(count)
    return String(Math.round(count))
  }

  function formatCacheHit(n) {
    var rate = Number(n || 0)
    if (!(rate >= 0)) rate = 0
    if (rate > 1) rate = rate / 100
    return (rate * 100).toFixed(1) + "%"
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleDetails() {
    persistSettings({ detailsExpanded: !root.detailsExpanded })
  }

  // ------------------------------------------------------------------ shell

  // Invisible until the collector has produced something worth reading, so
  // the icon stays away entirely on a machine that has never used OpenRouter.
  visible: !!record && (record.ready === true || String(record.usageStatusText || "") !== "")
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "updated 3 min ago" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱂇"
    labelVisible: false
    hasVisualContent: true
    active: root.balanceAlarming
    fixedWidth: button.vertical ? Style.bar.iconSlot : (barRow.implicitWidth + Style.space(16))
    fixedHeight: button.vertical ? Style.bar.iconSlot : -1
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else root.toggle()
    }

    Row {
      id: barRow
      visible: !button.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        Image {
          id: barMark
          anchors.fill: parent
          source: root.logoSource()
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: barMark
          source: barMark
          visible: barMark.status === Image.Ready
          colorization: 1.0
          colorizationColor: root.balanceAlarming ? root.urgent : root.barForeground
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: barMark.status !== Image.Ready
          text: button.text
          color: root.balanceAlarming ? root.urgent : root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        text: root.barBalanceLabel
        color: root.balanceAlarming ? root.urgent : root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      visible: button.vertical
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      Image {
        id: barMarkVertical
        anchors.fill: parent
        source: root.logoSource()
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        fillMode: Image.PreserveAspectFit
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: barMarkVertical
        source: barMarkVertical
        visible: barMarkVertical.status === Image.Ready
        colorization: 1.0
        colorizationColor: root.balanceAlarming ? root.urgent : root.barForeground
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Collapsed must be taller than the original 560 dashboard so the
    // Details header stays on screen instead of sitting under the fold.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(root.detailsExpanded ? 900 : 640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        if (t === "d" || t === "D") root.toggleDetails()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: mark · name · tier · remaining ----------
          Item {
            id: header
            visible: !!root.record
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property string amountText: root.balance
              ? root.formatMoney(root.balance.remaining, root.balance.currency)
              : ""
            readonly property color amountColor: root.balanceAlarming ? root.urgent : root.foreground
            readonly property color dimColor: root.dim
            readonly property string family: root.fontFamily

            PanelHero {
              id: hero
              width: parent.width
              title: "OpenRouter"
              meta: root.heroMeta()
              foreground: root.foreground
              fontFamily: root.fontFamily
              trailingControl: Component {
                Column {
                  visible: header.amountText !== ""
                  spacing: Style.space(2)
                  width: Math.max(heroAmount.implicitWidth, heroRemaining.implicitWidth)

                  Text {
                    textFormat: Text.PlainText
                    id: heroAmount
                    width: parent.width
                    text: header.amountText
                    color: header.amountColor
                    font.family: header.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: heroRemaining
                    width: parent.width
                    text: "REMAINING"
                    color: header.dimColor
                    font.family: header.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }

              iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: root.logoSource()
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
            }
          }

          // ---------- Status (errors only) ----------
          BorderSurface {
            visible: !!root.record && String(root.record.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              textFormat: Text.PlainText
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.record ? String(root.record.authHelpText || root.record.usageStatusText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Account links ----------
          PanelSeparator {
            visible: linksSection.visible
            foreground: root.foreground
          }

          Column {
            id: linksSection
            visible: !!root.record
            width: parent.width
            spacing: Style.space(10)

            Row {
              id: linksRow
              width: parent.width
              spacing: Style.space(6)

              readonly property real cellWidth: (width - spacing * 3) / 4

              LinkTile {
                width: linksRow.cellWidth
                icon: "󰐕"
                label: "Add Credits"
                url: "https://openrouter.ai/credits"
              }
              LinkTile {
                width: linksRow.cellWidth
                icon: "󰄪"
                label: "Full Activity"
                url: "https://openrouter.ai/activity"
              }
              LinkTile {
                width: linksRow.cellWidth
                icon: "󰌋"
                label: "Manage Keys"
                url: "https://openrouter.ai/workspaces/default/keys"
              }
              LinkTile {
                width: linksRow.cellWidth
                icon: "󰚩"
                label: "Browse Models"
                url: "https://openrouter.ai/models"
              }
            }
          }

          // ---------- Spend by day ----------
          PanelSeparator {
            visible: spendSection.visible
            foreground: root.foreground
          }

          Item {
            // Breathing room between the account links and the first section.
            visible: spendSection.visible
            width: parent.width
            height: Style.space(6)
          }

          Column {
            id: spendSection
            visible: root.days.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property real peak: root.weekPeak()

            PanelSectionHeader {
              width: parent.width
              text: "USAGE BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.days

              DayRow {
                required property var modelData

                width: spendSection.width
                day: modelData
                segs: root.daySegments(modelData)
                ratio: Number(modelData.cost || 0) / spendSection.peak
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Details (cards, key budgets, top models, apps, keys) ----------
          PanelSeparator {
            visible: detailsSection.visible
            foreground: root.foreground
          }

          Column {
            id: detailsSection
            visible: !!root.record
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(detailsHdr.implicitHeight, detailsToggle.height)

              PanelSectionHeader {
                id: detailsHdr
                anchors.left: parent.left
                anchors.right: detailsPeriodBtn.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "DETAILS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Rectangle {
                id: detailsPeriodBtn
                anchors.right: detailsToggle.left
                anchors.rightMargin: root.detailsExpanded ? Style.space(8) : 0
                anchors.verticalCenter: parent.verticalCenter
                width: root.detailsExpanded ? detailsPeriodLabel.implicitWidth + Style.space(16) : 0
                height: Style.space(28)
                visible: root.detailsExpanded
                radius: Math.max(3, Style.cornerRadius - 3)
                color: root.alpha(root.foreground, detailsPeriodMa.containsMouse ? 0.12 : 0.06)
                border.width: 1
                border.color: root.alpha(root.foreground, detailsPeriodMa.containsMouse ? 0.5 : 0.35)

                Text {
                  textFormat: Text.PlainText
                  id: detailsPeriodLabel
                  anchors.centerIn: parent
                  text: root.periodLabel(usage.detailsPeriod) + " ▾"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: detailsPeriodMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: usage.cyclePeriod()
                }
              }

              Rectangle {
                id: detailsToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(88)
                height: Style.space(28)
                radius: Math.max(3, Style.cornerRadius - 3)
                color: root.alpha(root.foreground, detailsToggleMa.containsMouse ? 0.12 : 0.06)
                border.width: 1
                border.color: root.alpha(root.foreground, detailsToggleMa.containsMouse ? 0.5 : 0.35)

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.detailsExpanded ? "COLLAPSE" : "EXPAND"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: detailsToggleMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleDetails()
                }
              }
            }

            Column {
              visible: root.detailsExpanded
              width: parent.width
              spacing: Style.space(10)

              Grid {
                id: detailsGrid
                width: parent.width
                columns: 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)

                StatCard {
                  width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                  label: "Spend"
                  value: root.activity ? root.formatCost(root.activity.spend) : "—"
                }
                StatCard {
                  width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                  label: "Requests"
                  value: root.activity ? root.formatRequests(root.activity.requests) : "—"
                }
                StatCard {
                  width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                  label: "Tokens"
                  value: root.activity ? root.formatActivityTokens(root.activity.tokens) : "—"
                }
                StatCard {
                  width: (detailsGrid.width - detailsGrid.columnSpacing) / 2
                  label: "Cache hit"
                  value: root.activity ? root.formatCacheHit(root.activity.cacheHitRate) : "—"
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                width: parent.width
                text: root.activityHint()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Column {
                id: budgetsSection
                visible: root.keyBudgets.length > 0
                width: parent.width
                spacing: Style.spacing.md

                PanelSectionHeader {
                  width: parent.width
                  text: "KEY BUDGETS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.keyBudgets

                  BudgetRow {
                    required property var modelData

                    width: budgetsSection.width
                    budget: modelData
                  }
                }
              }

              Column {
                id: modelsList
                visible: root.topModels.length > 0
                width: parent.width
                spacing: Style.spacing.md

                PanelSectionHeader {
                  width: parent.width
                  text: "TOP MODELS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.topModels

                  RankedRow {
                    required property var modelData
                    width: modelsList.width
                    row: modelData
                  }
                }
              }

              Column {
                id: appsList
                visible: root.topApps.length > 0
                width: parent.width
                spacing: Style.spacing.md

                PanelSectionHeader {
                  width: parent.width
                  text: "TOP APPS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.topApps

                  RankedRow {
                    required property var modelData
                    width: appsList.width
                    row: modelData
                  }
                }
              }

              Column {
                id: keysList
                visible: root.topKeys.length > 0
                width: parent.width
                spacing: Style.spacing.md

                PanelSectionHeader {
                  width: parent.width
                  text: "TOP KEYS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.topKeys

                  RankedRow {
                    required property var modelData
                    width: keysList.width
                    row: modelData
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component LinkTile: Item {
    id: linkTile
    property string icon: ""
    property string label: ""
    property string url: ""

    implicitHeight: linkIcon.implicitHeight + linkCaption.implicitHeight + Style.space(10)

    MouseArea {
      id: linkMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openLink(linkTile.url)
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        id: linkIcon
        anchors.horizontalCenter: parent.horizontalCenter
        text: linkTile.icon
        color: linkMa.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
      }

      Text {
        textFormat: Text.PlainText
        id: linkCaption
        width: parent.width
        text: linkTile.label
        color: linkMa.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    // Optional fill override; alarming still wins so a critical gauge
    // cannot be painted back to calm by a stale override.
    property color fillColor: root.foreground
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : meter.fillColor

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, dollars. Today is picked out in full
  // foreground; the rest of the week sits dimmed behind it.
  // One budget row: key name, drain meter, used/limit. The meter turns
  // urgent past 90% of the cap, mirroring the balance gauge.
  component BudgetRow: Item {
    id: budgetRow
    property var budget: null

    readonly property real drain: budget && budget.limit > 0
      ? root.clamp(Number(budget.used || 0) / Number(budget.limit), 0, 1)
      : 0
    readonly property bool alarming: drain >= 0.9

    implicitHeight: Math.max(budgetName.implicitHeight, budgetValue.implicitHeight) + Style.spacing.sm

    Text {
      textFormat: Text.PlainText
      id: budgetName
      text: budgetRow.budget ? String(budgetRow.budget.name || "") : ""
      color: budgetRow.alarming ? root.urgent : root.drainColor(budgetRow.drain)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: budgetRow.alarming
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
    }

    Meter {
      anchors.left: budgetName.right
      anchors.right: budgetValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      value: budgetRow.drain
      alarming: budgetRow.alarming
      fillColor: root.drainColor(budgetRow.drain)
    }

    Text {
      textFormat: Text.PlainText
      id: budgetValue
      text: budgetRow.budget
        ? root.formatMoney(budgetRow.budget.used) + " / " + root.formatMoney(budgetRow.budget.limit)
        : ""
      color: budgetRow.alarming ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
    }

    MouseArea {
      id: budgetHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: budgetHover.containsMouse
      text: root.budgetTooltip(budgetRow.budget)
      fontFamily: root.fontFamily
    }
  }

  component DayRow: Item {
    id: dayRow
    property var day: null
    // Precomputed by the parent delegate: [{index, start, fraction}, ...]
    // in bar order, followed by Other (index -1) when present. Empty for
    // plain bars.
    property var segs: []
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabelText.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      textFormat: Text.PlainText
      id: dayLabelText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabelText.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Item {
        id: dayFill
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        // Keyed mode: static slots instead of a Repeater — one per top-three
        // rank plus Other. Overlapping by a hair prevents seams.
        Rectangle {
          id: seg0
          readonly property var seg: dayRow.segs.length > 0 ? dayRow.segs[0] : null
          x: seg ? dayFill.width * seg.start : 0
          width: seg ? dayFill.width * seg.fraction + 1 : 0
          height: parent.height
          topLeftRadius: dayTrack.radius
          bottomLeftRadius: dayTrack.radius
          topRightRadius: !seg1.visible && !seg2.visible && !seg3.visible ? dayTrack.radius : 0
          bottomRightRadius: !seg1.visible && !seg2.visible && !seg3.visible ? dayTrack.radius : 0
          visible: seg !== null
          color: seg ? (seg.index >= 0 ? root.keyColor(seg.index) : root.alpha(root.foreground, 0.55)) : "transparent"
        }

        Rectangle {
          id: seg1
          readonly property var seg: dayRow.segs.length > 1 ? dayRow.segs[1] : null
          x: seg ? dayFill.width * seg.start : 0
          width: seg ? dayFill.width * seg.fraction + 1 : 0
          height: parent.height
          topLeftRadius: !seg0.visible ? dayTrack.radius : 0
          bottomLeftRadius: !seg0.visible ? dayTrack.radius : 0
          topRightRadius: !seg2.visible && !seg3.visible ? dayTrack.radius : 0
          bottomRightRadius: !seg2.visible && !seg3.visible ? dayTrack.radius : 0
          visible: seg !== null
          color: seg ? (seg.index >= 0 ? root.keyColor(seg.index) : root.alpha(root.foreground, 0.55)) : "transparent"
        }

        Rectangle {
          id: seg2
          readonly property var seg: dayRow.segs.length > 2 ? dayRow.segs[2] : null
          x: seg ? dayFill.width * seg.start : 0
          width: seg ? dayFill.width * seg.fraction + 1 : 0
          height: parent.height
          topLeftRadius: !seg0.visible && !seg1.visible ? dayTrack.radius : 0
          bottomLeftRadius: !seg0.visible && !seg1.visible ? dayTrack.radius : 0
          topRightRadius: !seg3.visible ? dayTrack.radius : 0
          bottomRightRadius: !seg3.visible ? dayTrack.radius : 0
          visible: seg !== null
          color: seg ? (seg.index >= 0 ? root.keyColor(seg.index) : root.alpha(root.foreground, 0.55)) : "transparent"
        }

        Rectangle {
          id: seg3
          readonly property var seg: dayRow.segs.length > 3 ? dayRow.segs[3] : null
          x: seg ? dayFill.width * seg.start : 0
          width: seg ? dayFill.width * seg.fraction + 1 : 0
          height: parent.height
          topLeftRadius: !seg0.visible && !seg1.visible && !seg2.visible ? dayTrack.radius : 0
          bottomLeftRadius: !seg0.visible && !seg1.visible && !seg2.visible ? dayTrack.radius : 0
          topRightRadius: dayTrack.radius
          bottomRightRadius: dayTrack.radius
          visible: seg !== null
          color: seg ? (seg.index >= 0 ? root.keyColor(seg.index) : root.alpha(root.foreground, 0.55)) : "transparent"
        }

        // Plain mode: the original monochrome fill.
        Rectangle {
          anchors.fill: parent
          radius: dayTrack.radius
          visible: dayRow.segs.length === 0
          color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      id: dayValue
      text: root.formatCost(dayRow.day ? dayRow.day.cost : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  component StatCard: Rectangle {
    id: statCard
    property string label: ""
    property string value: ""

    implicitHeight: statLabel.implicitHeight + statValue.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: root.alpha(root.foreground, 0.05)

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        id: statLabel
        width: parent.width
        text: statCard.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        id: statValue
        width: parent.width
        text: statCard.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
    }
  }

  component RankedRow: Item {
    id: rankedRow
    property var row: null

    implicitHeight: Math.max(rankedName.implicitHeight, rankedValue.implicitHeight) + Style.spacing.sm

    Text {
      textFormat: Text.PlainText
      id: rankedName
      text: rankedRow.row ? String(rankedRow.row.name || "") : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: rankedValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      id: rankedValue
      text: rankedRow.row ? root.formatActivityTokens(rankedRow.row.tokens) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
