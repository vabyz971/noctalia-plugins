
local tooltipData ={}

local glyph = barWidget.getConfig("glyph")
local showLabel = barWidget.getConfig("show_widget_text")
local interval = barWidget.getConfig("update_interval")



local function render()
    barWidget.setGlyph(glyph)
    if showLabel then
        barWidget.setText("Monitor")
    end
    barWidget.setTooltip(tooltipData)
end

function update()
  noctalia.setUpdateInterval(interval)
  render()
end

noctalia.state.watch("system_metrics", function(stats)
    if not stats then return end

    -- Mise à jour du tooltip avec les données fraîches
    tooltipData = {
        { key = "CPU", value = stats.cpu },
        { key = "Temp CPU", value = stats.tempCPU },
        { key = "RAM", value = stats.ram },
        { key = "DISK", value = stats.disk },
    }
    render()

end)

function onClick()
  render()
end
