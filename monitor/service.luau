
local prevCpuTotal = 0
local prevCpuIdle = 0
local sysStats = { cpu = "0%", ram = "0%", temp = "0°C", disk = "0%" }

local function getCPUUsage()
    local stat = noctalia.readFile("/proc/stat")
    if not stat then return sysStats.cpu end

    local user, nice, sys, idle, iowait, irq, softirq, steal = string.match(
        stat, "cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)"
    )

    if user then
        local total = tonumber(user) + tonumber(nice) + tonumber(sys) + tonumber(idle) + tonumber(iowait) + tonumber(irq) + tonumber(softirq) + tonumber(steal)
        local idleTotal = tonumber(idle) + tonumber(iowait)
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

-- local function getGPUUsage()
--     -- Boucle standard sur les cartes graphiques du système (card0, card1...)
--     for i = 0, 4 do
--         local baseDrm = "/sys/class/drm/card" .. i .. "/device"

--         -- 1. Cas AMD (Fichier direct et standard)
--         local amdUsage = noctalia.readFile(baseDrm .. "/gpu_busy_percent")
--         if amdUsage then
--             local usageValue = tonumber(string.gsub(amdUsage, "%s+", ""))
--             if usageValue then return string.format("%d%%", usageValue) end
--         end

--         -- 2. Cas NVIDIA (Lecture via les compteurs de performance sysfs du pilote)
--         local nvUsage = noctalia.readFile(baseDrm .. "/utilization/gpu")
--         if nvUsage then
--             local usageValue = tonumber(string.gsub(nvUsage, "%s+", ""))
--             if usageValue then return string.format("%d%%", usageValue) end
--         end
--     end

--     return "N/A"
-- end


local function getRamUsage()
    local meminfo = noctalia.readFile("/proc/meminfo")
    if not meminfo then return sysStats.ram end

    local memTotalStr = string.match(meminfo, "MemTotal:%s+(%d+) kB")
    local memAvailStr = string.match(meminfo, "MemAvailable:%s+(%d+) kB")

    if memTotalStr and memAvailStr then
        local memTotal = tonumber(memTotalStr)
        local memAvailable = tonumber(memAvailStr)

        -- Calcul de la mémoire utilisée en kB
        local memUsed = memTotal - memAvailable

        -- Conversion de kB en Go
        local totalGo = memTotal / 1048576
        local usedGo = memUsed / 1048576

        -- Formatage : "4.2 / 32.0 GiB"
        return string.format("%.1f / %.1f GiB", usedGo, totalGo)
    end
    return sysStats.ram
end

local function getCPUTemp()
    -- CPU Ryzen
    for i = 0, 8 do
        local basePath = "/sys/class/hwmon/hwmon" .. i
        local nameStr = noctalia.readFile(basePath .. "/name")

        if nameStr then
            -- Nettoie les retours à la ligne (\n)
            nameStr = string.gsub(nameStr, "%s+", "")

            -- Pilote officiel AMD Ryzen
            if nameStr == "k10temp" then
                local tempStr = noctalia.readFile(basePath .. "/temp1_input")
                if tempStr then
                    local tempValue = tonumber(tempStr)
                    if tempValue then
                        return string.format("%.0f°C", tempValue / 1000)
                    end
                end
            end
        end
    end

    -- Universel (Intel / Autres architectures)
    for i = 0, 6 do
        local typeStr = noctalia.readFile("/sys/class/thermal/thermal_zone" .. i .. "/type")
        if typeStr then
            typeStr = string.gsub(typeStr, "%s+", "")
            if typeStr == "x86_pkg_temp" or typeStr == "acpitz" then
                local tempStr = noctalia.readFile("/sys/class/thermal/thermal_zone" .. i .. "/temp")
                if tempStr then
                    local tempValue = tonumber(tempStr)
                    if tempValue then
                        return string.format("%.0f°C", tempValue / 1000)
                    end
                end
            end
        end
    end

    return "N/A"
end

-- local function getGPUTemp()
--     -- 1. Tentative AMD (Pilote open-source amdgpu ou amdvlk)
--     for i = 0, 8 do
--         local basePath = "/sys/class/hwmon/hwmon" .. i
--         local nameStr = noctalia.readFile(basePath .. "/name")
--         if nameStr then
--             nameStr = string.gsub(nameStr, "%s+", "")
--             if nameStr == "amdgpu" then
--                 local tempStr = noctalia.readFile(basePath .. "/temp1_input")
--                 if tempStr then
--                     local tempValue = tonumber(tempStr)
--                     if tempValue then
--                         return string.format("%.0f°C", tempValue / 1000)
--                     end
--                 end
--             end
--         end
--     end

--     -- 2. Secours NVIDIA (Pilote propriétaire via nvidia-smi)
--     -- On utilise un appel système léger si noctalia supporte l'exécution
--     local handle = io.popen("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null")
--     if handle then
--         local result = handle:read("*a")
--         handle:close()
--         if result and result ~= "" then
--             local tempValue = tonumber(string.gsub(result, "%s+", ""))
--             if tempValue then
--                 return string.format("%.0f°C", tempValue)
--             end
--         end
--     end

--     return "N/A"
-- end


local function updateDiskAsync()
    -- On force la langue en 'C' (anglais) pour que les colonnes soient toujours les mêmes
    -- $4 est le disponible, $2 est le total
    local cmd = "sh -c 'LANG=C df -h / | awk \"NR==2 {print \\$4 \\\" / \\\" \\$2}\"'"

    noctalia.runAsync(cmd, function(res)
        if res.exitCode == 0 then
            local val = noctalia.string.trim(res.stdout)
            -- Si la valeur est vide, on affiche une erreur pour le débogage
            sysStats.disk = (val ~= "") and val or "Erreur lecture"
            noctalia.state.set("system_metrics", sysStats)
        else
            sysStats.disk = "N/A"
            noctalia.state.set("system_metrics", sysStats)
        end
    end)
end

noctalia.setUpdateInterval(1000)

function update()
    -- On met à jour la table locale
    sysStats.cpu = getCPUUsage()
    -- sysStats.gpu = getGPUUsage()
    sysStats.ram = getRamUsage()
    sysStats.tempCPU = getCPUTemp()
    -- sysStats.tempGPU = getGPUTemp()

    updateDiskAsync()

    noctalia.state.set("system_metrics", sysStats)
end
