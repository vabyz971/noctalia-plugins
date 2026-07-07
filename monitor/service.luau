--!nonstrict
-- service.luau
local SystemStats = {}

local prevCpuTotal = 0
local prevCpuIdle = 0
local sysStats = {
    cpu = "0%",
    ram = "0%", ramPct = "0%",
    tempCPU = "0°C",
    disk = "0%", diskPct = "0%"
}

-- [Identique]
function SystemStats.getCPUUsage()
    local stat = noctalia.readFile("/proc/stat")
    if not stat then return sysStats.cpu end

    local user, nice, sys, idle, iowait, irq, softirq, steal = string.match(
        stat, "cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)"
    )

    if user then
        local total = (tonumber(user) or 0) + (tonumber(nice) or 0) + (tonumber(sys) or 0) + (tonumber(idle) or 0) + (tonumber(iowait) or 0) + (tonumber(irq) or 0) + (tonumber(softirq) or 0) + (tonumber(steal) or 0)
        local idleTotal = (tonumber(idle) or 0) + (tonumber(iowait) or 0)
        local diffTotal = total - prevCpuTotal
        local diffIdle = idleTotal - prevCpuIdle
        prevCpuTotal = total
        prevCpuIdle = idleTotal

        if diffTotal > 0 then
            return string.format("%.1f%%", ((diffTotal - diffIdle) / diffTotal) * 100)
        end
    end
    return sysStats.cpu
end

-- [Modifié pour inclure le pourcentage de RAM]
function SystemStats.getRamUsage()
    local meminfo = noctalia.readFile("/proc/meminfo")
    if not meminfo then return sysStats.ram end

    local memTotalStr = string.match(meminfo, "MemTotal:%s+(%d+) kB")
    local memAvailStr = string.match(meminfo, "MemAvailable:%s+(%d+) kB")

    if memTotalStr and memAvailStr then
        local memTotal = tonumber(memTotalStr)
        local memAvailable = tonumber(memAvailStr)
        local memUsed = memTotal - memAvailable

        local totalGo = memTotal / 1048576
        local usedGo = memUsed / 1048576

        -- Calcul du pourcentage
        sysStats.ramPct = string.format("%.1f%%", (memUsed / memTotal) * 100)
        return string.format("%.1f / %.1f GiB", usedGo, totalGo)
    end
    return sysStats.ram
end

-- [OPTIMISÉ : Mise en cache du chemin de la sonde]
local cachedTempPath = nil

function SystemStats.getCPUTemp()
    -- Si on connaît déjà le bon fichier, on le lit directement (0 boucle !)
    if cachedTempPath then
        local tempStr = noctalia.readFile(cachedTempPath)
        if tempStr then
            local tempValue = tonumber(tempStr)
            if tempValue then return string.format("%.0f°C", tempValue / 1000) end
        end
        cachedTempPath = nil -- Si la lecture échoue, on casse le cache pour chercher à nouveau
    end

    -- CPU Ryzen / AMD
    for i = 0, 8 do
        local basePath = "/sys/class/hwmon/hwmon" .. i
        local nameStr = noctalia.readFile(basePath .. "/name")
        if nameStr then
            nameStr = string.gsub(nameStr, "%s+", "")
            if nameStr == "k10temp" then
                cachedTempPath = basePath .. "/temp1_input"
                return SystemStats.getCPUTemp() -- On rappelle la fonction qui va utiliser le cache
            end
        end
    end

    -- Universel
    for i = 0, 6 do
        local typeStr = noctalia.readFile("/sys/class/thermal/thermal_zone" .. i .. "/type")
        if typeStr then
            typeStr = string.gsub(typeStr, "%s+", "")
            if typeStr == "x86_pkg_temp" or typeStr == "acpitz" then
                cachedTempPath = "/sys/class/thermal/thermal_zone" .. i .. "/temp"
                return SystemStats.getCPUTemp()
            end
        end
    end

    return "N/A"
end

-- [OPTIMISÉ : Throttle & Extraction via AWK]
local diskTickCounter = 10 -- Initialisé à 10 pour forcer le premier rafraîchissement

function SystemStats.updateDiskAsync(onDone)
    diskTickCounter = diskTickCounter + 1

    -- On ne lance 'df' que toutes les 10 secondes d'intervalle, sinon on retourne les anciennes valeurs
    if diskTickCounter < 10 then
        onDone(sysStats.disk, sysStats.diskPct)
        return
    end
    diskTickCounter = 0

    -- On modifie AWK pour qu'il nous donne: Utilisé ($3), Total ($2), et Pourcentage ($5)
    local cmd = "sh -c 'LANG=C df -h / | awk \"NR==2 {print \\$3 \\\" \\\" \\$2 \\\" \\\" \\$5}\"'"

    noctalia.runAsync(cmd, function(res)
        if res.exitCode == 0 then
            -- On extrait les 3 valeurs avec un pattern Luau
            local used, total, pct = string.match(res.stdout, "(%S+)%s+(%S+)%s+(%S+)")
            if used and total and pct then
                onDone(used .. " / " .. total, pct)
            else
                onDone("Erreur lecture", "N/A")
            end
        else
            onDone("N/A", "N/A")
        end
    end)
end

-- ── Orchestration ────────────────────────────────────────────────────────

local function tickIntervalMs()
    local interval = tonumber(noctalia.getConfig("update_interval")) or 1
    return interval * 1000
end

function update()
    noctalia.setUpdateInterval(tickIntervalMs())

    sysStats.cpu = SystemStats.getCPUUsage()
    sysStats.ram = SystemStats.getRamUsage()
    sysStats.tempCPU = SystemStats.getCPUTemp()

    SystemStats.updateDiskAsync(function(diskStr, diskPct)
        sysStats.disk = diskStr
        sysStats.diskPct = diskPct
        noctalia.state.set("system_metrics", sysStats)
    end)
end
