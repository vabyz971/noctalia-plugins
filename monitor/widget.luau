-- widget.luau

-- 1. Lecture des configurations
local defaultGlyph = barWidget.getConfig("glyph") or "device-heart-monitor"
local showLabel = barWidget.getConfig("show_widget_text")
local useEmojiTooltip = barWidget.getConfig("use_emoji_tooltip")
local showStatsInBar = barWidget.getConfig("show_stats_in_bar")

-- Sécurité pour la traduction
local function tr(key)
    local text = noctalia.tr(key)
    return text or key
end

-- 2. Initialisation
barWidget.setVisible(true)
barWidget.setGlyph(defaultGlyph)
barWidget.setTooltip({ { key = tr("loading"), value = "" } })

if showStatsInBar then
    barWidget.setText(tr("loading"))
elseif showLabel then
    barWidget.setText(tr("title"))
else
    barWidget.setText("") -- On vide le texte si on veut juste l'icône
end

-- 3. Mise à jour dynamique
noctalia.state.watch("system_metrics", function(stats)
    if not stats then return end

    -- Mise à jour du texte de la barre selon l'option choisie
    if showStatsInBar then
        -- Affichage des stats avec les icônes texte (Nerd Fonts)
        barWidget.setText(string.format("󰍛 %s | 󰘚 %s", stats.cpu, stats.ramPct))
    elseif showLabel then
        barWidget.setText(tr("title"))
    else
        barWidget.setText("")
    end

    -- Mise à jour du Tooltip
    local tooltipData = {}
    if useEmojiTooltip then
        tooltipData = {
            { key = "󰍛 " .. tr("tooltip_cpu"), value = stats.cpu },
            { key = " " .. tr("tooltip_temp"), value = stats.tempCPU },
            { key = "󰘚 " .. tr("tooltip_ram"), value = string.format("%s (%s)", stats.ram, stats.ramPct) },
            { key = "󰋊 " .. tr("tooltip_disk"), value = string.format("%s (%s)", stats.disk, stats.diskPct) },
        }
    else
        tooltipData = {
            { key = tr("tooltip_cpu"), value = stats.cpu },
            { key = tr("tooltip_temp"), value = stats.tempCPU },
            { key = tr("tooltip_ram"), value = string.format("%s (%s)", stats.ram, stats.ramPct) },
            { key = tr("tooltip_disk"), value = string.format("%s (%s)", stats.disk, stats.diskPct) },
        }
    end

    barWidget.setTooltip(tooltipData)
end)

-- 4. Action au clic
function onClick()
    noctalia.togglePanel("vabyz971/monitor:monitor")
end
