-- zeno_loader.lua  (installed into reframework/autorun/ by the Zeno exe)
-- Inert on its own: sets ZENO_HOST and loads the real menu from
-- reframework/zeno/zeno_menu.lua. ZENO_HOST.alive follows the exe heartbeat
-- (zeno_host.json); without it the menu forces every feature off.

local HOST_FILE = "zeno_host.json"
local MENU_PATH = "reframework/zeno/zeno_menu.lua"

ZENO_HOST = { id = "zeno_exe_v1", alive = false }

local function fresh()
    local ok, d = pcall(json.load_file, HOST_FILE)
    if not ok or type(d) ~= "table" then return false end
    if d.id ~= "zeno_exe_v1" or type(d.t) ~= "number" then return false end
    return math.abs(os.time() - d.t) <= 3
end

local f = io.open(MENU_PATH, "r")
if f then
    local src = f:read("*a")
    f:close()
    local fn, err = load(src, "@zeno_menu.lua")
    if fn then
        local ok, e = pcall(fn)
        if not ok then log.error("[Zeno] menu error: " .. tostring(e)) end
    else
        log.error("[Zeno] menu parse error: " .. tostring(err))
    end
else
    log.warn("[Zeno] " .. MENU_PATH .. " not found")
end

local tick = 0
re.on_frame(function()
    tick = tick + 1
    if tick % 20 == 0 then ZENO_HOST.alive = fresh() end
end)
