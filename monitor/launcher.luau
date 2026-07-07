-- launcher.luau

local function tr(key)
    local text = noctalia.tr(key)
    return text or key
end

function onQuery(query)
    local results = {
        {
            id = "open_monitor_panel",
            title = tr("title"),
            subtitle = tr("launcher_provider.description"),
            glyph = "device-heart-monitor"
        }
    }

    -- On renvoie les résultats attachés à la requête actuelle
    launcher.setResults(query, results)
end

-- Appelée quand l'utilisateur appuie sur Entrée sur/ notre résultat
function onActivate(id)
    if id == "open_monitor_panel" then
        noctalia.togglePanel("vabyz971/monitor:monitor")

        -- Optionnel : Vide la barre de recherche du finder
        launcher.setQuery("")
    end
end
