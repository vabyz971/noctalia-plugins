--!nonstrict
-- Headless data provider for the Monitor Dashboard.
--
-- Split into two small "modules" (Lua tables used as namespaces, since a
-- Noctalia entry is a single file and cannot `require` other files):
--   SystemStats     -> global CPU / RAM / temperature / disk metrics
--   ProcessMonitor  -> per-process list, scoped to the current user
--
-- Both publish their results through noctalia.state so the panel
-- (monitor.luau) and the bar widget (widget.luau) can react to updates
-- without duplicating any system-reading logic.
--
-- Performance note: an earlier version of this file scanned /proc entirely
-- on its own (no `ps` at all) by listing every pid and reading several
-- files per process. On a real desktop session (300-500+ total processes
-- system-wide) that meant thousands of individual noctalia.readFile calls
-- per tick, which made the update() callback time out. `ps` itself reads
-- /proc too, but natively in a single optimized process — one subprocess
-- spawn is dramatically cheaper than hundreds of cross-boundary file reads.
-- So the process TABLE (pid/cpu/mem/name) comes from one `ps` call, already
-- scoped to the current user, and /proc is only used for the extra detail
-- (disk I/O, full process name) on a bounded number of rows.

-- ── SystemStats ──────────────────────────────────────────────────────────

local SystemStats = {}

local prevCpuTotal = 0
local prevCpuIdle = 0
local sysStats = { cpu = "0%", ram = "0%", temp = "0°C", disk = "0%" }

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

        return string.format("%.1f / %.1f GiB", usedGo, totalGo)
    end
    return sysStats.ram
end

function SystemStats.getCPUTemp()
    -- CPU Ryzen / AMD
    for i = 0, 8 do
        local basePath = "/sys/class/hwmon/hwmon" .. i
        local nameStr = noctalia.readFile(basePath .. "/name")

        if nameStr then
            nameStr = string.gsub(nameStr, "%s+", "")

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

    -- Universel (Intel / autres architectures)
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

function SystemStats.updateDiskAsync(onDone)
    -- No /proc or /sys file exposes filesystem free space (that needs the
    -- statvfs syscall), so `df` stays as a deliberate, single, one-shot
    -- external command (not run per-process).
    -- On force la langue en 'C' (anglais) pour que les colonnes soient toujours les mêmes
    local cmd = "sh -c 'LANG=C df -h / | awk \"NR==2 {print \\$4 \\\" / \\\" \\$2}\"'"

    noctalia.runAsync(cmd, function(res)
        if res.exitCode == 0 then
            local val = noctalia.string.trim(res.stdout)
            onDone((val ~= "") and val or "Erreur lecture")
        else
            onDone("N/A")
        end
    end)
end

-- ── ProcessMonitor ───────────────────────────────────────────────────────
-- Lists the processes owned by the current user.
--
-- Per-process network usage is intentionally NOT reported here: Linux does
-- not expose it through /proc without extra tooling (nethogs, iftop...), so
-- rather than faking a value the panel treats it as "not available" and
-- relies on a name-based heuristic for the "Network" category filter.

local ProcessMonitor = {}

ProcessMonitor.MAX_PROCESSES = 150   -- hard cap so the UI stays responsive
ProcessMonitor.MAX_DETAILED = 40     -- bounds the extra /proc reads (disk I/O, full name)

local function currentUser()
    return noctalia.getenv("USER") or noctalia.getenv("LOGNAME") or ""
end

local function readProcessDiskIO(pid)
    local content = noctalia.readFile("/proc/" .. pid .. "/io")
    if not content then
        return 0, 0
    end

    local readBytes = tonumber(string.match(content, "read_bytes:%s*(%d+)")) or 0
    local writeBytes = tonumber(string.match(content, "write_bytes:%s*(%d+)")) or 0
    return readBytes, writeBytes
end

-- /proc/<pid>/cmdline holds the untruncated argv, unlike `ps comm` which the
-- kernel still caps; this is a single bounded extra read, not a full scan.
local function readFullProcessName(pid, fallback)
    local cmdline = noctalia.readFile("/proc/" .. pid .. "/cmdline")
    if cmdline and cmdline ~= "" then
        local firstArg = string.match(cmdline, "^[^%z]*")
        if firstArg and firstArg ~= "" then
            return string.match(firstArg, "([^/]+)$") or firstArg
        end
    end
    return fallback
end

local function parseProcessLine(line)
    -- Fields: pid, %cpu, %mem, comm (widened to 32 chars via `comm:32=`)
    local pid, cpu, mem, name = string.match(line, "^%s*(%d+)%s+([%d%.]+)%s+([%d%.]+)%s+(.-)%s*$")
    if not pid or not name or name == "" then
        return nil
    end

    -- Kernel threads show up as "[name]"; skip them defensively even though
    -- `-u <user>` should already exclude root-owned ones in the common case.
    if string.match(name, "^%[.*%]$") then
        return nil
    end

    return {
        pid = tonumber(pid),
        cpu = tonumber(cpu) or 0,
        memPercent = tonumber(mem) or 0,
        name = name,
    }
end

-- Fetches the current user's process list. `onDone(list)` receives entries
-- shaped as { pid, name, cpu, memPercent, diskRead, diskWrite, diskTotal }.
function ProcessMonitor.collect(onDone)
    local user = currentUser()
    local userFlag = (user ~= "") and ("-u " .. user .. " ") or ""
    local cmd = "ps " .. userFlag .. "-eo pid=,pcpu=,pmem=,comm:32= --sort=-pcpu"

    noctalia.runAsync(cmd, function(res)
        local list = {}

        if res.exitCode == 0 then
            for line in string.gmatch(res.stdout, "[^\r\n]+") do
                local proc = parseProcessLine(line)
                if proc then
                    table.insert(list, proc)
                    if #list >= ProcessMonitor.MAX_PROCESSES then
                        break
                    end
                end
            end

            for i, proc in ipairs(list) do
                if i <= ProcessMonitor.MAX_DETAILED then
                    local readBytes, writeBytes = readProcessDiskIO(proc.pid)
                    proc.diskRead = readBytes
                    proc.diskWrite = writeBytes
                    proc.diskTotal = readBytes + writeBytes
                    proc.name = readFullProcessName(proc.pid, proc.name)
                else
                    proc.diskRead = 0
                    proc.diskWrite = 0
                    proc.diskTotal = 0
                end
            end
        end

        onDone(list)
    end)
end

-- ── Orchestration ────────────────────────────────────────────────────────

noctalia.state.set("user_processes_loading", true)

local function tickIntervalMs()
    local interval = tonumber(noctalia.getConfig("update_interval")) or 1
    return interval * 1000
end

function update()
    noctalia.setUpdateInterval(tickIntervalMs())

    sysStats.cpu = SystemStats.getCPUUsage()
    sysStats.ram = SystemStats.getRamUsage()
    sysStats.tempCPU = SystemStats.getCPUTemp()

    SystemStats.updateDiskAsync(function(disk)
        sysStats.disk = disk
        noctalia.state.set("system_metrics", sysStats)
    end)

    ProcessMonitor.collect(function(list)
        noctalia.state.set("user_processes", list)
        noctalia.state.set("user_processes_loading", false)
    end)
end
