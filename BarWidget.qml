import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the monitor-settings panel. Clicking runs the exact same IPC
// route a keybinding would use (omarchy-shell shell toggle …), mirroring how
// the first-party omarchy.menu bar widget summons its panel. Static icon only —
// nothing runs while the panel is closed.
BarWidget {
  id: root
  moduleName: "nosignal.monitor-settings"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    tooltipText: "Monitor settings"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.monitor-settings")
    }
  }
}
