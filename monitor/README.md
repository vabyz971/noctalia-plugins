# Monitor Dashboard

Monitor Dashboard provides a comprehensive suite of tools to monitor system and application activity through a dedicated panel, launcher integration, and customizable widgets.

## Plugin

| Field | Value |
| --- | --- |
| ID | `vabyz971/monitor` |
| Launcher | `/monitor` |
| Panel | `monitor` |
| Service | `system-monitor` |
| Widget | `widget` |

## Usage

### Launcher
You can find the monitor tools via the launcher by typing:
`noctalia search /monitor`

### Widget
Add the **widget** from the Add-widget picker. It features several configurable options including a custom icon, visibility toggles for text and stats, and an emoji tooltip.

### Panel
Open the main monitoring dashboard using the following command or by interacting with the launcher:
```sh
noctalia msg panel-toggle vabyz971/monitor:monitor
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `update_interval` | `double` | `1.0` | Interval for data updates (1 to 5). |
| `glyph` | `glyph` | `device-heart-monitor` | The icon used for the widget. |
| `show_widget_text` | `bool` | `true` | Toggle the visibility of the widget text. |
| `use_emoji_tooltip` | `bool` | `true` | Enable emoji icons in the tooltips. |
| `show_stats_in_bar` | `bool` | `false` | Show statistics directly in the status bar. |
