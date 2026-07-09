--!nonstrict
-- Monitor panel: lists the current user's processes with category filters,
-- free-text search, sorting and a per-row Kill action.
--
-- A Noctalia entry is a single file (no `require`), so "modularity" here
-- means splitting the file into clearly separated local namespaces instead
-- of separate files:
--   Categories -> what a category filters on + which field it sorts by
--   Sort       -> pure list -> list sorting helpers
--   Filter     -> pure list -> list filtering helpers (search / category)
--   Format     -> value -> string presentation helpers
--   State      -> the panel's mutable UI state
--   UI         -> view builders (pure functions returning ui.* nodes)
-- Event handlers and lifecycle callbacks stay at the bottom and only
-- orchestrate the modules above.
--
-- Kill button note: a Noctalia button's onClick calls a plain named global
-- function with no arguments — there is no way to pass the row's pid
-- directly. Rather than shelling out to `pkill`/name-matching, we reuse the
-- same fixed-size "slot" pattern the official Wallhaven plugin uses for its
-- result grid (onPick0..onPick23): a bounded pool of onKill0..onKillN
-- handlers mapped to the row's position in the currently rendered list.

local function tr(key)
    return noctalia.tr(key)
end

local row = ui.row
local column = ui.column
local label = ui.label
local button = ui.button

-- ── Categories ───────────────────────────────────────────────────────────
-- Name-based heuristics: Linux does not expose a "this process talks to the
-- network" / "this process uses the GPU" flag without extra tooling, so we
-- match against known process names. The lists are easy to extend.

local NETWORK_HINTS = {
    "firefox", "chrome", "chromium", "brave", "curl", "wget", "ssh", "sshd",
    "rsync", "syncthing", "discord", "telegram", "signal", "thunderbird",
    "transmission", "qbittorrent", "steam", "spotify", "zoom", "slack",
    "networkmanager", "wpa_supplicant", "dhclient", "nc", "ping",
}

local GRAPHICS_HINTS = {
    "xorg", "xwayland", "kwin", "mutter", "gnome-shell", "sway", "hyprland",
    "weston", "compton", "picom", "gimp", "blender", "obs", "vlc", "mpv",
    "kodi", "gpu-screen-recorder",
}

local function nameMatchesAny(name, hints)
    local lower = string.lower(name)
    for _, hint in ipairs(hints) do
        if string.find(lower, hint, 1, true) then
            return true
        end
    end
    return false
end

local Categories = {
    {
        key = "processes",
        labelKey = "category_processes",
        sortField = "cpu",
        matches = function(_proc) return true end,
    },
    {
        key = "memory",
        labelKey = "category_memory",
        sortField = "memPercent",
        matches = function(proc) return proc.memPercent > 0 end,
    },
    {
        key = "storage",
        labelKey = "category_storage",
        sortField = "diskTotal",
        matches = function(proc) return (proc.diskTotal or 0) > 0 end,
    },
    {
        key = "network",
        labelKey = "category_network",
        sortField = "name",
        matches = function(proc) return nameMatchesAny(proc.name, NETWORK_HINTS) end,
    },
    {
        key = "graphics",
        labelKey = "category_graphics",
        sortField = "name",
        matches = function(proc) return nameMatchesAny(proc.name, GRAPHICS_HINTS) end,
    },
}

local function categoryByKey(key)
    for _, category in ipairs(Categories) do
        if category.key == key then
            return category
        end
    end
    return Categories[1]
end

-- ── Sort ─────────────────────────────────────────────────────────────────

local sortOptions = { "croissant", "descending", "alphabetical" }

local function sortLabelList()
    return {
        tr("sort_options.croissant"),
        tr("sort_options.descending"),
        tr("sort_options.alphabetical"),
    }
end

local function sortProcesses(list, sortMode, sortField)
    local sorted = {}
    for i, proc in ipairs(list) do
        sorted[i] = proc
    end

    if sortMode == "alphabetical" then
        table.sort(sorted, function(a, b)
            return string.lower(a.name) < string.lower(b.name)
        end)
    elseif sortMode == "croissant" then
        table.sort(sorted, function(a, b)
            return (a[sortField] or 0) < (b[sortField] or 0)
        end)
    else -- "descending"
        table.sort(sorted, function(a, b)
            return (a[sortField] or 0) > (b[sortField] or 0)
        end)
    end

    return sorted
end

-- ── Filter ───────────────────────────────────────────────────────────────

local function filterBySearch(list, query)
    if query == "" then
        return list
    end

    local needle = string.lower(query)
    local out = {}
    for _, proc in ipairs(list) do
        if string.find(string.lower(proc.name), needle, 1, true) or tostring(proc.pid) == needle then
            table.insert(out, proc)
        end
    end
    return out
end

local function filterByCategory(list, category)
    local out = {}
    for _, proc in ipairs(list) do
        if category.matches(proc) then
            table.insert(out, proc)
        end
    end
    return out
end

-- ── Format ───────────────────────────────────────────────────────────────

local function humanizeBytes(bytes)
    if not bytes or bytes <= 0 then
        return "0 B"
    end

    local units = { "B", "KB", "MB", "GB", "TB" }
    local unitIndex = 1
    local value = bytes
    while value >= 1024 and unitIndex < #units do
        value = value / 1024
        unitIndex += 1
    end
    return string.format("%.1f %s", value, units[unitIndex])
end

-- ── ProcessMonitor ───────────────────────────────────────────────────────
-- Lists the processes owned by the current user. This used to live in the
-- headless service (service.luau), but that meant `ps`/`/proc` polling ran
-- non-stop in the background even while the dashboard was closed. It now
-- runs directly from the panel, only while the panel is open (see the
-- onOpen/onClose/update lifecycle at the bottom of this file). service.luau
-- is now dedicated to the bar widget's tooltip (system_metrics) only.
--
-- Per-process network usage is intentionally NOT reported here: Linux does
-- not expose it through /proc without extra tooling (nethogs, iftop...), so
-- rather than faking a value the panel treats it as "not available" and
-- relies on a name-based heuristic for the "Network" category filter.
--
-- Performance note: the process TABLE (pid/cpu/mem/name) comes from one
-- `ps` call, already scoped to the current user, and /proc is only used for
-- the extra detail (disk I/O, full process name) on a bounded number of
-- rows. Scanning /proc entirely by hand would mean thousands of individual
-- noctalia.readFile calls per tick on a real desktop session (300-500+
-- system-wide processes) — `ps` reads /proc too, but natively in a single
-- optimized process, which is dramatically cheaper.

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

-- ── State ────────────────────────────────────────────────────────────────

local state = {
    categoryKey = "processes",
    sortIndex = 1, -- defaults to "descending" (busiest processes first)
    search = "",
    processes = {},
    loading = true,
}

-- The exact list rendered on the last renderUI() call, in on-screen order.
-- Kill buttons reference a row by position in THIS list (see slot pattern
-- note at the top of the file), so it must stay in sync with what's drawn.
local lastRenderedList = {}

-- ── UI ───────────────────────────────────────────────────────────────────
-- All column widths/gaps/padding are shared constants between the header
-- row and the data rows so they can never drift apart. The process name is
-- a FIXED width (not `flex`) and truncated to one line: letting it grow
-- with content pushed every following column out of alignment.

local COLUMN_PROCESS_WIDTH = 100
local ROW_PADDING = 6
local PADDING_LIST = 12

-- Bounded pool of Kill handlers (see the note at the top of the file). Rows
-- beyond this position simply render without a Kill button.
local KILL_SLOT_COUNT = 50

local function rowProcess(pid, name, cpu, ram, disk, net, killHandlerName)
    local killCell
    if killHandlerName then
        killCell = button({
            glyph = "square-rounded-x",
            glyphSize = 13,
            variant = "destructive",
            onClick = killHandlerName,
        })
    else

    end

    return row({ padding = 6 }, {
        label({ text = pid, flexGrow = 1, textAlign = "start" }),
        label({ text = name, maxLines = 1, flexGrow = 1, textAlign = "start", maxWidth = COLUMN_PROCESS_WIDTH }),
        label({ text = cpu, flexGrow = 1, textAlign = "start" }),
        label({ text = ram, flexGrow = 1, textAlign = "start" }),
        label({ text = disk, flexGrow = 1, textAlign = "start" }),
        label({ text = net, flexGrow = 1, textAlign = "start" }),
        killCell,
        ui.spacer({ flexGrow = .65 }),
    })
end

local function filterChip(label, active, onClick, key)
    return ui.button({
        key = key,
        text = label,
        variant = if active then "primary" else "outline",
        onClick = onClick,
    })
end

local function filtersPanel()
    return row({ gap = 6, align = "center" }, {
        row({ gap = 6, align = "center", flexGrow = 1 }, {
            filterChip(tr("category_processes"), state.categoryKey == "processes", "onCategoryProcesses", "filter_cat_processes"),
            filterChip(tr("category_memory"), state.categoryKey == "memory", "onCategoryMemory", "filter_cat_memory"),
            filterChip(tr("category_storage"), state.categoryKey == "storage", "onCategoryStorage", "filter_cat_storage"),
            filterChip(tr("category_network"), state.categoryKey == "network", "onCategoryNetwork", "filter_cat_network"),
            filterChip(tr("category_graphics"), state.categoryKey == "graphics", "onCategoryGraphics", "filter_cat_graphics"),
        }),
        row({ flexGrow = 1 }, {
            ui.select({
                key = "sort",
                options = sortLabelList(),
                selectedIndex = state.sortIndex,
                flexGrow = 1,
                onChange = "onSort",
            }),
        }),
    })
end

local function visibleProcesses()
    local category = categoryByKey(state.categoryKey)
    local filtered = filterByCategory(state.processes, category)
    filtered = filterBySearch(filtered, state.search)
    filtered = sortProcesses(filtered, sortOptions[state.sortIndex + 1] or "descending", category.sortField)
    return filtered
end

local function processRows(list)
    local rows = {}
    for index, proc in ipairs(list) do
        local killHandler = nil
        if index <= KILL_SLOT_COUNT then
            killHandler = "onKill" .. tostring(index - 1)
        end

        table.insert(rows, rowProcess(
            tostring(proc.pid),
            proc.name,
            string.format("%.1f%%", proc.cpu),
            string.format("%.1f%%", proc.memPercent),
            humanizeBytes(proc.diskTotal),
            tr("not_available"),
            killHandler
        ))
    end
    return rows
end

local function emptyState(textKey)
    return column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
        label({ text = tr(textKey), color = "on_surface_variant" }),
    })
end

local function processesList()
    if state.loading then
        lastRenderedList = {}
        return emptyState("loading")
    end

    local filtered = visibleProcesses()
    lastRenderedList = filtered

    if #filtered == 0 then
        return emptyState("no_results")
    end

    return column({ padding = PADDING_LIST, fill = "surface", radius = 6 }, processRows(filtered))
end

local function renderUI()
    panel.render(
        column({ flexGrow = 1, gap = 12, justify = "space_between", align = "stretch" }, {

            -- 1. HEADER (Titre)
            row({ align = "center", justify = "space_between", gap = 8 }, {
                label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
                button({ glyph = "close", onClick = "onCloseClicked" }),
            }),

            filtersPanel(),

            row({  }, {
                ui.input({
                    key = "search",
                    placeholder = tr("search_process_placeholder"),
                    flexGrow = 1,
                    onChange = "onSearchChange",
                    onSubmit = "onSearchSubmit",
                }),
            }),

            row({ padding = PADDING_LIST, justify = "space_between", fill = "surface", radius = 6 }, {
                label({ text = tr("column_pid"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_process"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_cpu"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_ram"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_disk"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_net"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
                label({ text = tr("column_action"), fontWeight = "bold", flexGrow = 1, textAlign = "start" }),
            }),
            ui.scroll({ flexGrow = 1 }, {
                processesList(),
            }),
        })
    )
end

-- ── Event handlers ───────────────────────────────────────────────────────

local function selectCategory(key)
    state.categoryKey = key
    renderUI()
end

function onCategoryProcesses() selectCategory("processes") end
function onCategoryMemory() selectCategory("memory") end
function onCategoryStorage() selectCategory("storage") end
function onCategoryNetwork() selectCategory("network") end
function onCategoryGraphics() selectCategory("graphics") end

function onSort(index, _text)
    state.sortIndex = tonumber(index) or 0
    renderUI()
end

function onSearchChange(text)
    state.search = text or ""
    renderUI()
end

function onSearchSubmit(text)
    state.search = text or ""
    renderUI()
end

-- Kills the process rendered at `index` (0-based) in the last drawn list.
-- Fire-and-forget: there is no /proc-based way to terminate a process, so
-- this is the one deliberate exception to "avoid external commands" — it's
-- a single one-shot action triggered by an explicit user click, not a
-- per-tick poll.
local function killProcessAtIndex(index)
    local proc = lastRenderedList[index + 1]
    if not proc then
        return
    end

    noctalia.runAsync("kill -9 " .. tostring(proc.pid))

    -- Optimistic local removal for instant feedback; the next service tick
    -- republishes the authoritative list a moment later anyway.
    for i, cached in ipairs(state.processes) do
        if cached.pid == proc.pid then
            table.remove(state.processes, i)
            break
        end
    end

    renderUI()
end

function onKill0() killProcessAtIndex(0) end
function onKill1() killProcessAtIndex(1) end
function onKill2() killProcessAtIndex(2) end
function onKill3() killProcessAtIndex(3) end
function onKill4() killProcessAtIndex(4) end
function onKill5() killProcessAtIndex(5) end
function onKill6() killProcessAtIndex(6) end
function onKill7() killProcessAtIndex(7) end
function onKill8() killProcessAtIndex(8) end
function onKill9() killProcessAtIndex(9) end
function onKill10() killProcessAtIndex(10) end
function onKill11() killProcessAtIndex(11) end
function onKill12() killProcessAtIndex(12) end
function onKill13() killProcessAtIndex(13) end
function onKill14() killProcessAtIndex(14) end
function onKill15() killProcessAtIndex(15) end
function onKill16() killProcessAtIndex(16) end
function onKill17() killProcessAtIndex(17) end
function onKill18() killProcessAtIndex(18) end
function onKill19() killProcessAtIndex(19) end
function onKill20() killProcessAtIndex(20) end
function onKill21() killProcessAtIndex(21) end
function onKill22() killProcessAtIndex(22) end
function onKill23() killProcessAtIndex(23) end
function onKill24() killProcessAtIndex(24) end
function onKill25() killProcessAtIndex(25) end
function onKill26() killProcessAtIndex(26) end
function onKill27() killProcessAtIndex(27) end
function onKill28() killProcessAtIndex(28) end
function onKill29() killProcessAtIndex(29) end
function onKill30() killProcessAtIndex(30) end
function onKill31() killProcessAtIndex(31) end
function onKill32() killProcessAtIndex(32) end
function onKill33() killProcessAtIndex(33) end
function onKill34() killProcessAtIndex(34) end
function onKill35() killProcessAtIndex(35) end
function onKill36() killProcessAtIndex(36) end
function onKill37() killProcessAtIndex(37) end
function onKill38() killProcessAtIndex(38) end
function onKill39() killProcessAtIndex(39) end
function onKill40() killProcessAtIndex(40) end
function onKill41() killProcessAtIndex(41) end
function onKill42() killProcessAtIndex(42) end
function onKill43() killProcessAtIndex(43) end
function onKill44() killProcessAtIndex(44) end
function onKill45() killProcessAtIndex(45) end
function onKill46() killProcessAtIndex(46) end
function onKill47() killProcessAtIndex(47) end
function onKill48() killProcessAtIndex(48) end
function onKill49() killProcessAtIndex(49) end

-- ── Lifecycle ────────────────────────────────────────────────────────────
-- The panel now owns its own polling loop instead of watching a service:
-- `ps`/`/proc` only get read while the dashboard is actually open.

local function tickIntervalMs()
    local interval = tonumber(panel.getConfig("update_interval")) or 1
    return interval * 1000
end

local function refreshProcesses()
    ProcessMonitor.collect(function(list)
        state.processes = list or {}
        state.loading = false
        renderUI()
    end)
end

function update()
    noctalia.setUpdateInterval(tickIntervalMs())
    refreshProcesses()
end

function onOpen(_context)
    panel.setWantsSecondTicks(true)

    renderUI()
    refreshProcesses()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function onCloseClicked()
    panel.close()
end
