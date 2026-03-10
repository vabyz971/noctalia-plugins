import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  property var cfg: pluginApi?.pluginSettings || ({})
  property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  property real zoomAmount: cfg.zoomAmount ?? defaults.zoomAmount ?? 1.1
  property string parallaxDirection: cfg.parallaxDirection ?? defaults.parallaxDirection ?? "horizontal"
  property real hParallaxAmount: cfg.hParallaxAmount ?? defaults.hParallaxAmount ?? 50
  property int hParallaxDuration: cfg.hParallaxDuration ?? defaults.hParallaxDuration ?? 400
  property real vParallaxAmount: cfg.vParallaxAmount ?? defaults.vParallaxAmount ?? 50
  property int vParallaxDuration: cfg.vParallaxDuration ?? defaults.vParallaxDuration ?? 400
  property bool invertDirection: cfg.invertDirection ?? defaults.invertDirection ?? false
  property bool autoZoom: cfg.autoZoom ?? defaults.autoZoom ?? false
  property string parallaxEasing: cfg.parallaxEasing ?? defaults.parallaxEasing ?? "OutCubic"

  readonly property bool showHorizontal: parallaxDirection === "horizontal" || parallaxDirection === "both"
  readonly property bool showVertical: parallaxDirection === "vertical" || parallaxDirection === "both"

  spacing: Style.marginL

  // ── Wallpaper Zoom ──

  NValueSlider {
    label: "Wallpaper Zoom"
    description: "Scale of the wallpaper to provide room for parallax movement"
    text: root.zoomAmount.toFixed(2) + "x"
    from: 1.01
    to: 1.5
    stepSize: 0.01
    value: root.zoomAmount
    onMoved: val => {
      root.zoomAmount = val;
      root.saveSettings();
    }
  }

  NDivider { Layout.fillWidth: true }

  // ── Parallax Direction ──

  NComboBox {
    Layout.fillWidth: true
    label: "Parallax Direction"
    description: "Which direction the wallpaper shifts when changing workspaces"
    model: [
      { "key": "none", "name": "None" },
      { "key": "horizontal", "name": "Horizontal" },
      { "key": "vertical", "name": "Vertical" },
      { "key": "both", "name": "Horizontal + Vertical" }
    ]
    currentKey: root.parallaxDirection
    onSelected: function(key) {
      root.parallaxDirection = key;
      root.saveSettings();
    }
  }

  // ── Horizontal Parallax Settings ──

  NDivider { Layout.fillWidth: true; visible: root.showHorizontal }

  NLabel {
    visible: root.showHorizontal
    label: "Horizontal Parallax"
  }

  NValueSlider {
    visible: root.showHorizontal
    label: "Parallax Amount"
    text: Math.round(root.hParallaxAmount) + "px"
    from: 1
    to: 200
    stepSize: 1
    value: root.hParallaxAmount
    onMoved: val => {
      root.hParallaxAmount = val;
      root.saveSettings();
    }
  }

  NValueSlider {
    visible: root.showHorizontal
    label: "Animation Duration"
    text: Math.round(root.hParallaxDuration) + "ms"
    from: 50
    to: 2000
    stepSize: 50
    value: root.hParallaxDuration
    onMoved: val => {
      root.hParallaxDuration = val;
      root.saveSettings();
    }
  }

  // ── Vertical Parallax Settings ──

  NDivider { Layout.fillWidth: true; visible: root.showVertical }

  NLabel {
    visible: root.showVertical
    label: "Vertical Parallax"
  }

  NValueSlider {
    visible: root.showVertical
    label: "Parallax Amount"
    text: Math.round(root.vParallaxAmount) + "px"
    from: 1
    to: 200
    stepSize: 1
    value: root.vParallaxAmount
    onMoved: val => {
      root.vParallaxAmount = val;
      root.saveSettings();
    }
  }

  NValueSlider {
    visible: root.showVertical
    label: "Animation Duration"
    text: Math.round(root.vParallaxDuration) + "ms"
    from: 50
    to: 2000
    stepSize: 50
    value: root.vParallaxDuration
    onMoved: val => {
      root.vParallaxDuration = val;
      root.saveSettings();
    }
  }

  // ── Invert Direction ──

  NDivider { Layout.fillWidth: true }

  NToggle {
    label: "Invert Direction"
    description: "Move the wallpaper in the same direction as workspace changes"
    checked: root.invertDirection
    onToggled: checked => {
      root.invertDirection = checked;
      root.saveSettings();
    }
  }

  // ── Auto Zoom ──

  NDivider { Layout.fillWidth: true }

  NToggle {
    label: "Auto Zoom"
    description: "Automatically increase zoom to prevent wallpaper edges from showing"
    checked: root.autoZoom
    onToggled: checked => {
      root.autoZoom = checked;
      root.saveSettings();
    }
  }

  // ── Easing Curve ──

  NDivider { Layout.fillWidth: true }

  NComboBox {
    Layout.fillWidth: true
    label: "Easing Curve"
    description: "The mathematical curve used for parallax animations"
    model: [
      { "key": "Linear", "name": "Linear" },
      { "key": "InQuad", "name": "Ease In Quad" },
      { "key": "OutQuad", "name": "Ease Out Quad" },
      { "key": "InOutQuad", "name": "Ease In Out Quad" },
      { "key": "InCubic", "name": "Ease In Cubic" },
      { "key": "OutCubic", "name": "Ease Out Cubic (Recommended)" },
      { "key": "InOutCubic", "name": "Ease In Out Cubic" },
      { "key": "InQuart", "name": "Ease In Quart" },
      { "key": "OutQuart", "name": "Ease Out Quart" },
      { "key": "InOutQuart", "name": "Ease In Out Quart" },
      { "key": "InExpo", "name": "Ease In Exponential" },
      { "key": "OutExpo", "name": "Ease Out Exponential" },
      { "key": "InOutExpo", "name": "Ease In Out Exponential" }
    ]
    currentKey: root.parallaxEasing
    onSelected: function(key) {
      root.parallaxEasing = key;
      root.saveSettings();
    }
  }

  function saveSettings() {
    if (!pluginApi) {
      Logger.e("ParallaxWallpaper", "Cannot save settings: pluginApi is null");
      return;
    }

    pluginApi.pluginSettings.zoomAmount = root.zoomAmount;
    pluginApi.pluginSettings.parallaxDirection = root.parallaxDirection;
    pluginApi.pluginSettings.hParallaxAmount = root.hParallaxAmount;
    pluginApi.pluginSettings.hParallaxDuration = root.hParallaxDuration;
    pluginApi.pluginSettings.vParallaxAmount = root.vParallaxAmount;
    pluginApi.pluginSettings.vParallaxDuration = root.vParallaxDuration;
    pluginApi.pluginSettings.invertDirection = root.invertDirection;
    pluginApi.pluginSettings.autoZoom = root.autoZoom;
    pluginApi.pluginSettings.parallaxEasing = root.parallaxEasing;

    pluginApi.saveSettings();
  }
}
