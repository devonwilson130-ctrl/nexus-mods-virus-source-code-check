--=====================================================================
-- ZENO MENU  (Resident Evil Requiem)
--
-- Merged from: Requiem Aimbot v2 (Guz), Requiem Mod Panel 1.3.0
-- (SmartSpeaker) and esp.lua (Enemy ESP). New: FOV circle on the aimbot.
--
-- HOST GATE: this file only runs when zeno_loader.lua (installed by the
-- exe) has defined ZENO_HOST = { id = "zeno_exe_v1", alive = ... }, and
-- every feature is forced off whenever the exe heartbeat is missing.
-- Keep THIS file out of reframework/autorun/ (the exe puts it in
-- reframework/zeno/).
--
-- The exe controls everything through reframework/data/zeno_bridge.json.
-- Same thing is available as ZENO.set("aim.fov_radius", 300),
-- ZENO.toggle("panel.infinite_health"), ZENO.get(..), ZENO.keys().
--=====================================================================

local host = rawget(_G, "ZENO_HOST")
if type(host) ~= "table" or host.id ~= "zeno_exe_v1" then
    return
end

ZENO = { cfg = {} }

local sm_td = sdk.find_type_definition("via.SceneManager")
local sm    = sdk.get_native_singleton("via.SceneManager")

function ZENO.screen_size()
    local w, h
    pcall(function()
        local mv = sdk.call_native_func(sm, sm_td, "get_MainView")
        local sz = mv:get_WindowSize()
        w, h = sz.w, sz.h
    end)
    if not w and imgui.get_display_size then
        pcall(function()
            local d = imgui.get_display_size()
            w, h = d.x, d.y
        end)
    end
    return w, h
end

-- color picker that works across REFramework builds (value is the same
-- 32-bit integer the draw.* calls take)
local function zeno_color(label, v)
    local fn = imgui.color_edit4 or imgui.color_edit
    if fn then
        local ok, c, nv = pcall(fn, label, v)
        if ok and nv ~= nil then return c, nv end
    end
    return false, v
end

-- ===================== RAINBOW =====================
-- ZENO.cfg.rainbow.speed = full hue cycles per second (exe: "Rainbow Speed").
-- Every color has a companion "<name>_rb" flag; when it is on, the color is
-- replaced by a cycling hue (alpha of the base color is kept). The exe sends
-- the flag when you click the rainbow swatch in a color row.
ZENO.cfg.rainbow = { speed = 0.35 }

local function hsv_abgr(h, alpha)
    h = (h % 1.0) * 6.0
    local i = math.floor(h)
    local f = h - i
    local q, t = 1.0 - f, f
    local r, g, b
    if     i == 0 then r, g, b = 1, t, 0
    elseif i == 1 then r, g, b = q, 1, 0
    elseif i == 2 then r, g, b = 0, 1, t
    elseif i == 3 then r, g, b = 0, q, 1
    elseif i == 4 then r, g, b = t, 0, 1
    else               r, g, b = 1, 0, q end
    return (alpha << 24) | (math.floor(b * 255 + 0.5) << 16)
         | (math.floor(g * 255 + 0.5) << 8) | math.floor(r * 255 + 0.5)
end

function ZENO.rainbow(base, offset)
    local a = base and ((base >> 24) & 0xFF) or 0xFF
    if a == 0 then a = 0xFF end
    return hsv_abgr(os.clock() * ZENO.cfg.rainbow.speed + (offset or 0), a)
end

-- resolved color: rainbow when `on`, otherwise the picked color
function ZENO.col(color, on, offset)
    if on then return ZENO.rainbow(color, offset) end
    return color
end

-- color picker + "Rainbow" checkbox bound to tbl[rbkey]
local function zeno_color_rb(label, v, tbl, rbkey)
    local c, nv = zeno_color(label, v)
    imgui.same_line()
    local rc, rv = imgui.checkbox("Rainbow##" .. rbkey, tbl[rbkey] and true or false)
    if rc then tbl[rbkey] = rv end
    return c, nv
end

local UI = {}
local function zui(name, fn) UI[#UI + 1] = { name = name, fn = fn } end

-- ===================== AIMBOT (Guz) =====================
do
--=====================================================================
-- Aimbot.lua  v2  -  RE Requiem / REFramework
--
-- v2: the rotation apply layer is now selectable and instrumented.
--     The goal of this version is to FIND OUT which of the injection
--     points actually moves the camera.
--
-- Actual rotation chain found in the TDB:
--   PlayerXXXCameraController.updateRotation()
--     -> PlayerCameraRotationInterpolation.update(dt, vec2 input, ...)
--        -> .setRotation(Quaternion)   <-- last link
--
-- UI: REFramework -> Script Generated UI -> "Aimbot"
--=====================================================================

local MOD_NAME = "Aimbot"
local CFG_FILE = "zeno_aimbot.json"

--=====================================================================
-- Config
--=====================================================================

local DEFAULTS = {
    enabled        = true,
    require_hold   = true,
    hold_key       = 0x02,      -- VK_RBUTTON

    -- Gamepad. VK only covers keyboard and mouse, so without this the
    -- aimbot does not respond to a pad. 0 = use the left trigger detected
    -- automatically from the via.hid.GamePadButton enum.
    gamepad_enabled = true,
    gamepad_mask    = 512,
    -- On/off toggle on the gamepad. 0 = unassigned; the user sets it
    -- because there is no "natural" button that does not clash with the game.
    gamepad_toggle_mask = 0,
    inspect_key    = 0,
    toggle_key     = 0,

    max_distance   = 25.0,
    max_cone_deg   = 45.0,

    -- Zeno: screen-space FOV circle. Targets are only accepted when their
    -- aim point projects inside a circle centred on the screen.
    fov_enabled    = true,
    fov_show       = true,
    fov_radius     = 220.0,     -- pixels
    fov_thickness  = 2,
    fov_color      = 0xFFFFFFFF,
    fov_color_rb   = false,     -- rainbow circle
    los_mode       = 0,         -- 0 off, 1 isOcclusionToPlayer, 2 isOcclusion
    permissive     = false,     -- ignores cone/distance/LOS (diagnostics)
    -- The game flags with TargetAttribute.AimAssist (bit 0) the anchors
    -- it considers valid to aim at. On enemies with weak points
    -- (e.g. Cp_B052: vfx_core1..6) those are EXACTLY the weak points,
    -- while Spine_2 or root carry other attributes. Trusting that flag
    -- solves weak points without configuring anything per enemy.
    prefer_aimassist = true,

    -- On Cp_D110-style bosses each bulb is a separate GameObject
    -- ("WeakPoint_M_08"), not a body part. Without this, the boss body
    -- can beat a bulb just by being closer.
    prefer_weakpoints  = true,
    weakpoint_keywords = "weakpoint",

    -- The final boss registers its 22 bulbs permanently and does NOT set
    -- DisabledFrame on the hidden ones, so other signals (visibility,
    -- components, _Targetable) are needed to know which one is actually
    -- exposed.
    skip_hidden_wp = true,

    prefer_upper   = true,      -- prefer the head within the same enemy
    -- The head is identified by bone NAME, not by height: with the enemy
    -- on the ground the chest can end up higher than the head.
    -- Weak point bones. They are checked BEFORE the head ones, so a
    -- "Tumor" or a "vfx_core" always beats the head.
    -- Observed convention: Cp_B052 -> vfx_core1..6, cp_B700 -> Tumor,
    -- final boss -> Spit03.
    weak_keywords  = "tumor,vfx_core,core,weak,blister,spit",

    head_keywords  = "head,neck,kubi,atama",

    -- Per-enemy rules. The first one whose `match` appears in the
    -- GameObject name wins, and its bone list replaces head_keywords.
    -- The order inside `joints` is the priority order.
    -- E.g.: { match = "cp_D110", joints = "kobu,weak,head" }
    aim_rules      = {},
    -- If the enemy exposes no head anchor, look for the bone directly
    -- in its skeleton (via.Transform.get_Joints).
    head_from_skeleton = true,
    skip_dead      = true,      -- skip dead / dying enemies

    -- Explosive barrels are registered as lock-on targets with an
    -- "AimAssist" anchor (attr=1), just like an enemy: Capcom wants aim
    -- assist to help you shoot them. Filtering them by category is
    -- fragile, so we require the target to be a character, i.e. that it
    -- resolves an app.CharacterContext.
    require_character = true,
    sticky         = true,      -- do not switch enemy until it stops being valid

    -- View direction relative to the transform's Z axis.
    -- RE Engine looks down -Z. Auto-calibrated with world_to_screen.
    forward_sign   = -1,
    auto_forward   = true,
    priority_mode  = 2,         -- 0 angle, 1 camera dist., 2 player dist.
    aim_height_bias= 0.0,

    strength       = 1.0,       -- 1.0 = hard lock, lower = smoother
    snap           = true,

    cat_enemy      = true,
    cat_npc        = false,
    cat_gimmick    = false,

    -- === apply layer ===
    apply_mode     = 1,         -- ver APPLY_MODES
    scr_arg1       = true,
    scr_arg2       = false,
    entry_index    = 1,         -- for apply_mode 4
    only_active_interp = true,  -- filter the active interpolation instance

    -- === isolated test ===
    -- yaw RELATIVE to where the camera was looking when the key was pressed
    test_force     = false,
    test_yaw_deg   = 30.0,

    debug_draw     = true,

    -- UI only: shows or hides the developer tools
    -- (isolated test, apply mode, axes, dumps, diagnostics).
    -- It does not change the aimbot's behaviour.
    show_dev       = false,

    -- Performance: with this false nothing is scanned while you are not
    -- aiming. Set it to true only if you want to see the target marker
    -- without holding the aim button.
    scan_when_idle = false,
}

local CFG_VERSION = 3

local cfg = {}
do
    local loaded = json.load_file(CFG_FILE) or {}
    for k, v in pairs(DEFAULTS) do
        if loaded[k] ~= nil then
            cfg[k] = loaded[k]
        elseif type(v) == "table" then
            -- copy: if the DEFAULTS table were assigned by reference,
            -- editing the rules would mutate the defaults themselves
            local t = {}
            for kk, vv in pairs(v) do t[kk] = vv end
            cfg[k] = t
        else
            cfg[k] = v
        end
    end
    if type(cfg.aim_rules) ~= "table" then cfg.aim_rules = {} end

    -- Migration v1 -> v2.
    -- The saved config overrides DEFAULTS, so changing the default is not
    -- enough for those who already had an Aimbot.json. v1 configs carry
    -- priority_mode = angle: when the target dies, the camera keeps
    -- looking at the corpse and locks onto whatever enemy is lined up
    -- with it, however far. We force "distance to player" ONCE.
    if (loaded.cfg_version or 0) < 2 then
        cfg.priority_mode = 2
        log.info("[" .. MOD_NAME .. "] config migrated to v2: priority = closest to player")
    end
    -- Migration v2 -> v3.
    -- The Super Tyrant (cp_C510) only publishes two anchors, Head_0 and
    -- Spine_2, both AimAssist. Its weak point is the heart in its chest,
    -- which the game does NOT register as a target: Spine_2 is closest.
    -- We seed the rule so it works without touching the UI.
    if (loaded.cfg_version or 0) < 3 then
        local exists = false
        for _, r in ipairs(cfg.aim_rules) do
            if tostring(r.match or ""):lower():find("cp_c510", 1, true) then exists = true end
        end
        if not exists then
            table.insert(cfg.aim_rules,
                { match = "cp_C510", joints = "Spine", offset_y = 0.0 })
            log.info("[" .. MOD_NAME .. "] seeded rule: cp_C510 -> Spine")
        end
    end

    cfg.cfg_version = CFG_VERSION
end
re.on_config_save(function() json.dump_file(CFG_FILE, cfg) end)
ZENO.cfg.aim = cfg

--=====================================================================
-- Utilities
--=====================================================================

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function v3(x, y, z) return Vector3f.new(x, y, z) end
local function v3_sub(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
local function v3_dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function v3_cross(a, b)
    return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end
local function v3_norm(a)
    local l = math.sqrt(v3_dot(a, a))
    if l < 1e-6 then return v3(0, 0, 1) end
    return v3(a.x / l, a.y / l, a.z / l)
end

local function q_dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w end

-- angular difference between two quaternions, in degrees
local function q_angle_deg(a, b)
    if not (a and b) then return -1 end
    local d = math.abs(q_dot(a, b))
    d = math.max(-1, math.min(1, d))
    return math.deg(2 * math.acos(d))
end

local function elements_of(obj)
    if not obj then return {} end
    local els = safe(function() return obj:get_elements() end)
    if els and #els > 0 then return els end
    local items = safe(function() return obj:get_field("_items") end)
    if items then
        local arr = safe(function() return items:get_elements() end) or {}
        local n = safe(function() return obj:call("get_Count") end) or #arr
        local out = {}
        for i = 1, math.min(n, #arr) do out[i] = arr[i] end
        return out
    end
    return {}
end

--=====================================================================
-- "Look at" rotation
--=====================================================================

-- Builds a quaternion whose +Z COLUMN is `zcol`.
-- Careful: this is not the view direction; see look_rotation_view.
local function look_rotation(zcol, up)
    local f = v3_norm(zcol)
    local u = up or v3(0, 1, 0)
    if math.abs(v3_dot(f, u)) > 0.9995 then u = v3(0, 0, 1) end
    local r  = v3_norm(v3_cross(u, f))
    local nu = v3_cross(f, r)

    local q = safe(function()
        return Matrix4x4f.new(
            Vector4f.new(r.x,  r.y,  r.z,  0),
            Vector4f.new(nu.x, nu.y, nu.z, 0),
            Vector4f.new(f.x,  f.y,  f.z,  0),
            Vector4f.new(0,    0,    0,    1)):to_quat()
    end)
    if q then return q end

    -- fallback: manual matrix->quaternion conversion
    local m00, m01, m02 = r.x,  nu.x, f.x
    local m10, m11, m12 = r.y,  nu.y, f.y
    local m20, m21, m22 = r.z,  nu.z, f.z
    local tr = m00 + m11 + m22
    local x, y, z, w
    if tr > 0 then
        local s = math.sqrt(tr + 1.0) * 2
        w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s
    elseif m11 > m22 then
        local s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s
    else
        local s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s
    end
    return Quaternion.new(x, y, z, w)
end

-- Rotation that makes the camera LOOK towards `view_dir`.
-- The transform's Z axis points to sign*view_dir (sign = -1 in RE Engine).
local function look_rotation_view(view_dir, up)
    local s = cfg.forward_sign
    return look_rotation(v3(view_dir.x * s, view_dir.y * s, view_dir.z * s), up)
end

local function quat_slerp(a, b, t)
    local r = safe(function() return a:slerp(b, t) end)
    if r then return r end
    local d = q_dot(a, b)
    local s = (d < 0) and -1 or 1
    local x = a.x + (b.x * s - a.x) * t
    local y = a.y + (b.y * s - a.y) * t
    local z = a.z + (b.z * s - a.z) * t
    local w = a.w + (b.w * s - a.w) * t
    local l = math.sqrt(x * x + y * y + z * z + w * w)
    if l < 1e-6 then return a end
    return Quaternion.new(x / l, y / l, z / l, w / l)
end

--=====================================================================
-- Keyboard input (with fallback)
--=====================================================================

--- Gamepad -----------------------------------------------------------
-- via.hid.GamePad shows no methods in the IDA dump, so we try the known
-- ways of getting the device and keep the one that responds.

-- Bitwise AND without operators: REFramework may run on Lua 5.4
-- (has &) or LuaJIT (does not). This works on both.
local function band(a, b)
    a, b = math.floor(tonumber(a) or 0), math.floor(tonumber(b) or 0)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if (a % 2 == 1) and (b % 2 == 1) then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

local gp_singleton, gp_td
local gp_mode = "?"

-- Known ways of getting the device. They are tried in order and the
-- one that works is remembered.
local GP_DEVICE_CALLS = {
    { "getMergedDevice",     0    },
    { "get_LastInputDevice", nil  },
    { "get_Device",          0    },
    { "getDevice",           0    },
    { "get_ActiveDevice",    nil  },
    { "getMergedDevice",     nil  },
}

-- Known ways of reading the device's buttons.
local GP_BUTTON_CALLS = { "get_Button", "get_Buttons", "get_ButtonHold", "get_ButtonOn" }

local gp_dev_call, gp_btn_call = nil, nil

local function gamepad_device()
    if not gp_singleton then
        gp_singleton = sdk.get_native_singleton("via.hid.GamePad")
        gp_td        = sdk.find_type_definition("via.hid.GamePad")
    end
    if not (gp_singleton and gp_td) then
        gp_mode = "via.hid.GamePad unavailable"
        return nil
    end

    -- if we already know which one works, go straight to it
    if gp_dev_call then
        local n, a = gp_dev_call[1], gp_dev_call[2]
        local d = safe(function()
            if a ~= nil then return sdk.call_native_func(gp_singleton, gp_td, n, a) end
            return sdk.call_native_func(gp_singleton, gp_td, n)
        end)
        if d then return d end
        gp_dev_call = nil   -- stopped working, retry all of them
    end

    for _, c in ipairs(GP_DEVICE_CALLS) do
        local n, a = c[1], c[2]
        local d = safe(function()
            if a ~= nil then return sdk.call_native_func(gp_singleton, gp_td, n, a) end
            return sdk.call_native_func(gp_singleton, gp_td, n)
        end)
        if d then
            gp_dev_call = c
            gp_mode = n .. (a ~= nil and "(0)" or "()")
            return d
        end
    end

    gp_mode = "no accessor responded"
    return nil
end

-- Mask of the buttons held right now, or nil if there is no gamepad.
local function gamepad_buttons()
    local dev = gamepad_device()
    if not dev then return nil end

    if gp_btn_call then
        local b = safe(function() return dev:call(gp_btn_call) end)
        if b ~= nil then return tonumber(b) end
        gp_btn_call = nil
    end

    for _, n in ipairs(GP_BUTTON_CALLS) do
        local b = safe(function() return dev:call(n) end)
        if b ~= nil then
            gp_btn_call = n
            return tonumber(b)
        end
    end
    return nil
end

-- Resolves the left trigger by NAME in the enum, instead of
-- hardcoding a value that cannot be verified from the dump.
local auto_aim_mask, auto_aim_name = nil, "?"
local function default_aim_mask()
    if auto_aim_mask then return auto_aim_mask end
    auto_aim_mask, auto_aim_name = 0, "not found"
    local td = sdk.find_type_definition("via.hid.GamePadButton")
    if td then
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:is_static() end) then
                local n = tostring(safe(function() return f:get_name() end) or ""):lower()
                if n == "ltrigger" or n == "l2" or n == "lefttrigger" or n == "trigger_l" then
                    auto_aim_mask = tonumber(safe(function() return f:get_data(nil) end)) or 0
                    auto_aim_name = n
                    break
                end
            end
        end
    end
    return auto_aim_mask
end

local function gamepad_mask_held(mask)
    if not cfg.gamepad_enabled or not mask or mask == 0 then return false end
    local b = gamepad_buttons()
    if not b then return false end
    return band(b, mask) == mask
end

local function gamepad_aim_held()
    local mask = cfg.gamepad_mask
    if mask == 0 then mask = default_aim_mask() end
    return gamepad_mask_held(mask)
end

local key_mode = "?"
local function is_key_down(vk)
    local r = safe(function() return reframework:is_key_down(vk) end)
    if r ~= nil then key_mode = "reframework"; return r == true end

    local kb = sdk.get_native_singleton("via.hid.Keyboard")
    if kb then
        local td  = sdk.find_type_definition("via.hid.Keyboard")
        local dev = safe(function() return sdk.call_native_func(kb, td, "get_Device") end)
        if dev then
            local d = safe(function() return dev:call("getDown", vk) end)
            if d ~= nil then key_mode = "via.hid.Keyboard"; return d == true end
        end
    end
    key_mode = "UNAVAILABLE"
    return false
end

--=====================================================================
-- Scene / camera / controller
--=====================================================================

local scene_mgr_td = sdk.find_type_definition("via.SceneManager")

local function find_components(tn)
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return {} end
    local scene = safe(function() return sdk.call_native_func(sm, scene_mgr_td, "get_CurrentScene") end)
    if not scene then return {} end
    local t = sdk.typeof(tn)
    if not t then return {} end
    local list = safe(function() return scene:call("findComponents(System.Type)", t) end)
    if not list then return {} end
    return safe(function() return list:get_elements() end) or {}
end

local frame_counter = 0
local ctrl_cache = { obj = nil, name = nil, frame = -999 }

local function get_active_controller()
    if ctrl_cache.obj and (frame_counter - ctrl_cache.frame) < 30 then
        return ctrl_cache.obj, ctrl_cache.name
    end
    local cam = sdk.get_primary_camera()
    local cam_addr = cam and safe(function() return cam:get_address() end)
    local best, best_name
    for _, tn in ipairs({ "app.PlayerFPSCameraController", "app.PlayerTPSCameraController" }) do
        for _, c in ipairs(find_components(tn)) do
            local enabled = safe(function() return c:call("get_Enabled") end)
            local ccam    = safe(function() return c:call("get_Camera") end)
            local addr    = ccam and safe(function() return ccam:get_address() end)
            if cam_addr and addr == cam_addr and enabled ~= false then
                best, best_name = c, tn
                break
            elseif not best then
                best, best_name = c, tn
            end
        end
        if best_name and ctrl_cache.obj == nil and best then break end
    end
    ctrl_cache.obj, ctrl_cache.name, ctrl_cache.frame = best, best_name, frame_counter
    return best, best_name
end

local function get_camera_transform()
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local go = safe(function() return cam:call("get_GameObject") end)
    if not go then return nil end
    return safe(function() return go:call("get_Transform") end)
end

--=====================================================================
-- Targets
--=====================================================================

local CATEGORY = { Player = 0, Enemy = 1, NPC = 2, Gimmick = 3 }

local diag = {
    lom = false, cam = false, ctrl = "-",
    scanned = 0, candidates = 0,
    target_name = "-", target_dist = 0, target_ang = 0,
    basis_error = -1, forward_sign = 0, fwd_probe = "-",
    applied = false, apply_calls = 0, apply_fail = 0,
    residual_deg = -1,
    last_error = "-",
    interp_hits = 0, interp_active_hits = 0, interp_instances = 0,
    updrot_hits = 0, camupd_hits = 0,
    hooks = "-",
    -- breakdown of why each target is rejected
    rej_disabled = 0, rej_nopos = 0, rej_dist = 0, rej_cone = 0, rej_los = 0,
    rej_dead = 0, rej_hidden = 0, rej_notchar = 0, ctx_resolved = 0, player_pos = "-",
    aim_joint = "-", aim_is_head = false, aim_source = "-", aim_rule = "-",
    sample = {},   -- the nearest works, with their numbers
}

local function active_categories()
    local t = {}
    if cfg.cat_enemy   then table.insert(t, CATEGORY.Enemy)   end
    if cfg.cat_npc     then table.insert(t, CATEGORY.NPC)     end
    if cfg.cat_gimmick then table.insert(t, CATEGORY.Gimmick) end
    return t
end

local current_work    = nil
local current_aim_pos = nil
local forward_calibrated = false

-- Per-enemy data that does not change frame to frame (name, whether it
-- is a weak point, which bone list applies). It used to be recomputed
-- per anchor and per frame, with two :lower() and several finds each.
local owner_meta      = {}
local owner_meta_ver  = -1

-- Single-frame memos: several anchors share an enemy, so get_IsDead
-- and _Targetable were being queried redundantly.
local frame_dead      = {}
local frame_targetable = {}
local locked_owner    = nil   -- locked enemy (GameObject address)
local current_owner_obj = nil -- GameObject of the aimed enemy
local current_owner_addr = nil -- its address; NOT cleared when the key is
                               -- released, so the inspector still has
                               -- something to look at (locked_owner is)
local current_enemy_name = nil
local last_valid        = {}  -- candidates accepted last frame

--- Alive state --------------------------------------------------------
-- LockOnTargetWork -> OwnerObject (via.GameObject)
--   -> app.CharacterUpdaterBase (via.Behavior) -> get_Context()
--   -> app.CharacterContext.get_IsDead()
-- The component may hang from a parent, so we walk up the hierarchy.

local ctx_cache = {}   -- [GameObject addr] = context | false

local function resolve_context(owner)
    if not owner then return nil end
    local addr = safe(function() return owner:get_address() end)
    if not addr then return nil end

    local cached = ctx_cache[addr]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local updater_t = sdk.typeof("app.CharacterUpdaterBase")
    local go, ctx = owner, nil
    for _ = 1, 3 do
        if not go then break end
        local comp = safe(function() return go:call("getComponent(System.Type)", updater_t) end)
        if comp then
            ctx = safe(function() return comp:call("get_Context") end)
               or safe(function() return comp:call("get__Context") end)
            if ctx then break end
        end
        -- move up to the parent
        local tf     = safe(function() return go:call("get_Transform") end)
        local parent = tf and safe(function() return tf:call("get_Parent") end)
        go = parent and safe(function() return parent:call("get_GameObject") end) or nil
    end

    ctx_cache[addr] = ctx or false
    return ctx
end

--- Head identification by bone name ---------------------------------

-- app.LockOnTargetWork.TargetAttribute.AimAssist == 1 (bit 0).
-- Modulo is used instead of & so as not to depend on the Lua version.
local function has_aimassist(attr)
    local n = tonumber(attr)
    if not n then return false end
    return (math.floor(n) % 2) == 1
end

local function parse_words(str)
    local out = {}
    for raw in tostring(str or ""):gmatch("[^,]+") do
        local w = raw:match("^%s*(.-)%s*$"):lower()
        if #w > 0 then table.insert(out, w) end
    end
    return out
end

local head_words     = {}
local wp_words       = {}
local default_words  = {}   -- weak points + head, in that order
local rules_compiled = {}
local rules_version  = 0   -- bumped when rules are edited; invalidates caches

local function refresh_head_words()
    head_words     = parse_words(cfg.head_keywords)
    wp_words       = parse_words(cfg.weakpoint_keywords)

    -- Effective list when no enemy has its own rule.
    -- The order IS the priority, and weak points go first.
    default_words = {}
    for _, w in ipairs(parse_words(cfg.weak_keywords)) do
        table.insert(default_words, w)
    end
    for _, w in ipairs(head_words) do
        table.insert(default_words, w)
    end

    rules_compiled = {}
    for _, r in ipairs(cfg.aim_rules or {}) do
        table.insert(rules_compiled, {
            match = tostring(r.match or ""):lower(),
            words = parse_words(r.joints),
            raw   = r,
        })
    end
    rules_version = rules_version + 1
end
refresh_head_words()

-- Priority bone list for a specific enemy.
-- If no rule matches, head_keywords is used.
local function words_for(enemy_name)
    if enemy_name then
        local n = enemy_name:lower()
        for _, r in ipairs(rules_compiled) do
            if #r.match > 0 and n:find(r.match, 1, true) then return r.words, r.raw end
        end
    end
    -- No rule of its own: weak points first, head afterwards.
    return default_words, nil
end

-- Bone PRIORITY (1 = best) or nil if it is not in the list.
-- The list order is the preference order: with "head,neck"
-- a "head" bone always beats a "neck" one.
-- Is the owner GameObject an independent weak point?
local function is_weakpoint_owner(name)
    if not name then return false end
    local n = name:lower()
    for _, w in ipairs(wp_words) do
        if n:find(w, 1, true) then return true end
    end
    return false
end

local function rank_of(name, words)
    if not name then return nil end
    local n = name:lower()
    for i, w in ipairs(words or head_words) do
        if n:find(w, 1, true) then return i end
    end
    return nil
end


--- Head bone search in the skeleton ----------------------------------
-- Some enemies (the "special" ones) publish no lock-on anchor on the
-- head, only on the torso. For those we go to the skeleton.

local head_joint_cache = {}   -- [GameObject addr] = joint | false

-- Bone list of a transform, fault tolerant.
local function joints_of(tf)
    if not tf then return {} end
    local arr = safe(function() return tf:call("get_Joints") end)
    if not arr then return {} end
    return safe(function() return arr:get_elements() end) or {}
end

local head_cache_version = -1

local function find_head_joint(owner, ctx, words)
    if not owner then return nil end
    local addr = safe(function() return owner:get_address() end)
    if not addr then return nil end

    -- if the rules were edited, the cache is no longer valid
    if head_cache_version ~= rules_version then
        head_joint_cache, head_cache_version = {}, rules_version
    end

    local cached = head_joint_cache[addr]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    -- the skeleton usually hangs from the context's transform, not from
    -- the anchor's GameObject; try both
    local candidates = {}
    if ctx then table.insert(candidates, safe(function() return ctx:call("get_Transform") end)) end
    table.insert(candidates, safe(function() return owner:call("get_Transform") end))

    -- Criterion: first the keyword priority (head > neck), and only
    -- within the same keyword the shortest name, so we keep "head" and
    -- not "head_end" or "headTop_tip", which are end bones outside the
    -- skull.
    local found, found_rank, found_len
    for _, tf in ipairs(candidates) do
        for _, jt in ipairs(joints_of(tf)) do
            local n = safe(function() return jt:call("get_Name") end)
            local r = rank_of(n, words)
            if r then
                if not found_rank or r < found_rank
                   or (r == found_rank and #n < found_len) then
                    found, found_rank, found_len = jt, r, #n
                end
            end
        end
        if found then break end
    end

    head_joint_cache[addr] = found or false
    return found
end

--- Is the bulb actually exposed? -------------------------------------
-- The final boss (Cp_D110) keeps its 22 bulbs always registered and does
-- not touch DisabledFrame. We probe several signals and it is enough for
-- ONE to explicitly say no to reject it. Missing ones are ignored, so
-- the filter never rejects for lack of information.

local wp_comp_cache = {}   -- [addr] = { mesh=, lot=, ctrl=, params={} }

local function wp_components(owner)
    local addr = safe(function() return owner:get_address() end)
    if not addr then return nil end
    local c = wp_comp_cache[addr]
    if c then return c end

    c = { params = {} }
    local function comp(tn)
        local t = sdk.typeof(tn)
        if not t then return nil end
        return safe(function() return owner:call("getComponent(System.Type)", t) end)
    end
    c.mesh = comp("via.render.Mesh")
    c.lot  = comp("app.LockOnTarget")
    c.ctrl = comp("app.Cp_D110WeakPointLockOnTargetController")
    if c.ctrl then
        local params = safe(function() return c.ctrl:get_field("_Params") end)
        for _, p in ipairs(elements_of(params)) do table.insert(c.params, p) end
    end

    wp_comp_cache[addr] = c
    return c
end

-- Fast path, the one the filter uses every frame.
-- Measured in the final boss fight: of the five probed signals,
-- draw/update/mesh/lockon/ctrl are true on all 22 bulbs alike
-- (hidden ones keep drawing and updating). The ONLY one that tells
-- exposed from hidden is _Targetable.
-- nil = the object is not a weak point of this system -> no opinion.
local function weakpoint_targetable(owner)
    if not owner then return nil end
    local c = wp_components(owner)
    if not c then return nil end
    local out = nil
    for _, p in ipairs(c.params) do
        local t = safe(function() return p:get_field("_Targetable") end)
        if t ~= nil then out = t end
    end
    return out
end

-- Full probe. Inspector only: if another boss ever uses a different
-- signal, it would show up here.
local function weakpoint_signals(owner)
    local s = {}
    if not owner then return true, s end

    s.draw   = safe(function() return owner:call("get_DrawSelf") end)
    s.update = safe(function() return owner:call("get_UpdateSelf") end)

    local c = wp_components(owner)
    if c then
        if c.mesh then
            s.mesh = safe(function() return c.mesh:call("get_Enabled") end)
            if s.mesh == nil then
                s.mesh = safe(function() return c.mesh:call("get_DrawSelf") end)
            end
        end
        if c.lot  then s.lockon = safe(function() return c.lot:call("get_Enabled") end) end
        if c.ctrl then s.ctrl   = safe(function() return c.ctrl:call("get_Enabled") end) end
        s.targetable = weakpoint_targetable(owner)
    end

    return s.targetable ~= false, s
end

--- Playable character position --------------------------------------
-- app.CharacterManager.get_PlayerContextFast() -> PlayerContext
--   (inherits CharacterContext) -> get_Transform() -> get_Position()

local player_ctx = nil

local function get_player_pos()
    if not player_ctx or (frame_counter % 120 == 0) then
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        if cm then
            player_ctx = safe(function() return cm:call("get_PlayerContextFast") end)
                      or safe(function() return cm:call("getPlayerContextRefFast") end)
        end
    end
    if not player_ctx then return nil end
    local tf = safe(function() return player_ctx:call("get_Transform") end)
    if not tf then player_ctx = nil; return nil end
    return safe(function() return tf:call("get_Position") end)
end

-- true = dead. nil/false = alive or undetermined.
local function is_dead(owner)
    local ctx = resolve_context(owner)
    if not ctx then return nil end
    return safe(function() return ctx:call("get_IsDead") end) == true
end

-- Enemy metadata, resolved once and reused.
local function meta_of(owner, addr)
    if owner_meta_ver ~= rules_version then
        owner_meta, owner_meta_ver = {}, rules_version
    end
    local m = owner_meta[addr]
    if m then return m end

    local name = owner and (safe(function() return owner:call("get_Name") end) or "?") or "?"
    local words, rule = words_for(name)
    m = {
        name  = name,
        words = words,
        rule  = rule and rule.match or nil,
        off_y = rule and tonumber(rule.offset_y) or nil,
        wp    = is_weakpoint_owner(name),
    }
    owner_meta[addr] = m
    return m
end

local fov_cache = nil
local function fov_reject(aim)
    if not cfg.fov_enabled or cfg.permissive then return false end
    if not fov_cache then
        local w, h = ZENO.screen_size()
        if not w then return false end
        fov_cache = { cx = w * 0.5, cy = h * 0.5, r2 = cfg.fov_radius * cfg.fov_radius }
    end
    local s = safe(function() return draw.world_to_screen(aim) end)
    if not s or not s.x then return true end
    local dx, dy = s.x - fov_cache.cx, s.y - fov_cache.cy
    return (dx * dx + dy * dy) > fov_cache.r2
end

local function acquire_target(cam_pos, cam_fwd)
    local lom = sdk.get_managed_singleton("app.LockOnTargetManager")
    diag.lom = lom ~= nil
    if not lom then return nil end
    fov_cache = nil

    -- memos last one frame
    frame_dead, frame_targetable = {}, {}

    local arr = safe(function() return lom:get_field("LockOnTargetList") end)
    if not arr then return nil end
    local lists = safe(function() return arr:get_elements() end) or {}

    local permissive = cfg.permissive
    local max_cos    = math.cos(math.rad(cfg.max_cone_deg))
    if cfg.fov_enabled and not cfg.permissive then max_cos = -1.0 end   -- circle on: the circle is the limit
    local max_dist2  = cfg.max_distance * cfg.max_distance
    local best, best_pos, best_score, best_ang, best_dist, best_owner
    local scanned, candidates = 0, 0
    local rej = { disabled = 0, nopos = 0, dist = 0, cone = 0, los = 0, dead = 0, hidden = 0, notchar = 0 }
    local ctx_resolved = 0
    local player_pos   = get_player_pos()
    diag.player_pos = player_pos
        and string.format("%.1f, %.1f, %.1f", player_pos.x, player_pos.y, player_pos.z)
        or "NOT FOUND"
    local sample = {}
    local valid  = {}   -- accepted candidates

    for _, cat in ipairs(active_categories()) do
        local list = lists[cat + 1]
        if list then
            for _, work in ipairs(elements_of(list)) do
                scanned = scanned + 1

                local disabled = safe(function() return work:call("get_DisabledFrame") end) == true
                local tp       = safe(function() return work:call("get_TargetPosition") end)

                local row = { cat = cat, disabled = disabled }

                if disabled and not permissive then
                    rej.disabled = rej.disabled + 1
                    row.rejected = "disabled"
                elseif not tp then
                    rej.nopos = rej.nopos + 1
                    row.rejected = "no TargetPosition"
                else
                    -- The anchor is identified BEFORE filtering, so the
                    -- inspector also sees the rejected ones: on a boss, a
                    -- weak point rejected by the cone or for being closed is
                    -- exactly what you want to see.
                    local owner = safe(function() return work:call("get_OwnerObject") end)
                    local oaddr = owner and safe(function() return owner:get_address() end)
                    local okey  = oaddr or 0   -- nil is not valid as an index
                    local meta  = meta_of(owner, okey)

                    row.name       = meta.name
                    row.owner_addr = oaddr

                    -- an enemy has several anchors: ask once
                    local dead = frame_dead[okey]
                    if dead == nil then
                        dead = is_dead(owner)
                        frame_dead[okey] = (dead == nil) and "unknown" or dead
                    elseif dead == "unknown" then
                        dead = nil
                    end
                    row.dead = dead
                    if dead ~= nil then ctx_resolved = ctx_resolved + 1 end

                    local joint  = safe(function() return work:call("get_TargetJoint") end)
                    local jname  = joint and safe(function() return joint:call("get_Name") end) or nil
                    local words  = meta.words

                    -- The rule's vertical offset is applied BEFORE measuring
                    -- angles and distances: otherwise the cone and priority
                    -- would be computed on a point we are not aiming at.
                    local ybias = cfg.aim_height_bias + (meta.off_y or 0)

                    local aim  = v3(tp.x, tp.y + ybias, tp.z)
                    local to   = v3_sub(aim, cam_pos)
                    local d2   = v3_dot(to, to)
                    local dist = math.sqrt(math.max(d2, 1e-8))
                    local dir  = v3(to.x / dist, to.y / dist, to.z / dist)
                    local cosa = v3_dot(dir, cam_fwd)
                    local ang  = math.deg(math.acos(math.max(-1, math.min(1, cosa))))

                    row.dist, row.ang = dist, ang

                    local dplayer = dist
                    if player_pos then
                        local pd = v3_sub(aim, player_pos)
                        dplayer = math.sqrt(v3_dot(pd, pd))
                    end
                    row.dplayer = dplayer

                    row.joint   = jname
                    row.hrank   = rank_of(jname, words)
                    row.is_head = row.hrank ~= nil
                    row.rule    = meta.rule
                    row.attr    = safe(function() return work:call("get_Attribute") end)
                    row.aa      = has_aimassist(row.attr)
                    row.wp      = meta.wp

                    if d2 < 1e-4 then
                        rej.nopos = rej.nopos + 1
                        row.rejected = "degenerate pos"
                    elseif not permissive and d2 > max_dist2 then
                        rej.dist = rej.dist + 1
                        row.rejected = "distance"
                    elseif not permissive and cosa < max_cos then
                        rej.cone = rej.cone + 1
                        row.rejected = "outside cone"
                    elseif fov_reject(aim) then
                        rej.cone = rej.cone + 1
                        row.rejected = "outside FOV circle"
                    elseif cfg.require_character and resolve_context(owner) == nil then
                        -- barrels, crates and props: they have no CharacterContext
                        rej.notchar = rej.notchar + 1
                        row.rejected = "not a character"
                    elseif cfg.skip_dead and row.dead == true then
                        rej.dead = rej.dead + 1
                        row.rejected = "dead"
                    elseif cfg.skip_hidden_wp and row.wp
                           and (function()
                                   local t = frame_targetable[okey]
                                   if t == nil then
                                       t = weakpoint_targetable(owner)
                                       frame_targetable[okey] = (t == nil) and "unknown" or t
                                   end
                                   return t == false
                               end)() then
                        rej.hidden = rej.hidden + 1
                        row.rejected = "hidden bulb"
                    else
                        local occ = false
                        if not permissive and cfg.los_mode > 0 then
                            local fn = (cfg.los_mode == 1) and "isOcclusionToPlayer" or "isOcclusion"
                            local r = safe(function() return work:call(fn, cam_pos) end)
                            row.los_raw = r
                            occ = (r == true)
                        end
                        if occ then
                            rej.los = rej.los + 1
                            row.rejected = "occluded"
                        else
                            candidates = candidates + 1
                            row.rejected = false
                            table.insert(valid, {
                                work = work, aim = aim, owner = oaddr,
                                owner_obj = owner,
                                dist = dist, ang = ang, dplayer = dplayer,
                                joint = jname, is_head = row.is_head, hrank = row.hrank,
                                ename = row.name, rule = row.rule,
                                attr = row.attr, aa = row.aa, wp = row.wp,
                            })
                        end
                    end
                end
                if cfg.show_dev then table.insert(sample, row) end
            end
        end
    end

    ------------------------------------------------------------------
    -- Selection
    ------------------------------------------------------------------
    local function score_of(c)
        if cfg.priority_mode == 1 then return c.dist      -- to the camera
        elseif cfg.priority_mode == 2 then return c.dplayer -- to the player
        else return c.ang end                              -- to the center
    end

    -- 1) Lock: if the previous target is still valid, keep it.
    --    That way it does not jump between enemies on tiny angle changes.
    if cfg.sticky and locked_owner then
        local still = false
        for _, c in ipairs(valid) do
            if c.owner == locked_owner then still = true break end
        end
        if not still then locked_owner = nil end
    end

    -- 2) With no active lock, pick a new enemy.
    --    Distance does NOT decide alone: first we filter by target
    --    quality, or a boss body would beat its own bulbs just by being
    --    closer.
    if not (cfg.sticky and locked_owner) then
        local pick
        for _, c in ipairs(valid) do
            local better
            if not pick then
                better = true
            elseif cfg.prefer_weakpoints and c.wp ~= pick.wp then
                better = c.wp                      -- a bulb beats the body
            elseif cfg.prefer_aimassist and c.aa ~= pick.aa then
                better = c.aa                      -- aimable beats non-aimable
            else
                better = score_of(c) < score_of(pick)
            end
            if better then pick = c end
        end
        locked_owner = pick and pick.owner or nil
    end

    -- 3) Best anchor within the chosen enemy.
    --    A head bone ALWAYS beats height: with the enemy lying down the
    --    chest can be higher than the head.
    local best_entry = nil
    for _, c in ipairs(valid) do
        if c.owner == locked_owner then
            local better
            if not best_entry then
                better = true
            elseif cfg.prefer_upper then
                local rc, rb = c.hrank, best_entry.hrank
                if cfg.prefer_aimassist and c.aa ~= best_entry.aa then
                    -- 1) the game says which one is aimable: trust it
                    better = c.aa
                elseif rc ~= rb then
                    -- 2) keyword priority (head beats neck)
                    if rc and rb then better = rc < rb
                    else better = rc ~= nil end
                elseif c.aa or rc then
                    -- 3) same group and a legitimate point (e.g. several
                    --    blisters): keep the most centered one
                    better = c.ang < best_entry.ang
                else
                    -- 4) no signal at all: the highest, which is usually
                    --    the useful part of the body
                    better = c.aim.y > best_entry.aim.y
                end
            else
                better = score_of(c) < score_of(best_entry)
            end
            if better then best_entry = c end
        end
    end

    if best_entry then
        best, best_pos      = best_entry.work, best_entry.aim
        best_score          = score_of(best_entry)
        best_ang, best_dist = math.rad(best_entry.ang), best_entry.dist
        best_owner          = best_entry.owner
        diag.aim_joint      = best_entry.joint or "(no bone)"
        diag.aim_is_head    = best_entry.is_head
        diag.aim_source     = "anchor"
        current_owner_obj   = best_entry.owner_obj
        current_owner_addr  = best_entry.owner
        current_enemy_name  = best_entry.ename
        diag.aim_rule       = best_entry.rule or "(default)"

        -- 4) The enemy publishes no head anchor: go to the skeleton.
        -- Skeleton fallback ONLY if the game did not give us a valid
        -- anchor. Cp_B052 has Head_0 in its skeleton but its head is not
        -- a weak point: going there would be worse than staying on the core.
        local trust_anchor = cfg.prefer_aimassist and best_entry.aa
        if cfg.prefer_upper and cfg.head_from_skeleton
           and not best_entry.is_head and not trust_anchor then
            local words, wrule = words_for(best_entry.ename)
            local ctx   = resolve_context(best_entry.owner_obj)
            local hj    = find_head_joint(best_entry.owner_obj, ctx, words)
            if hj then
                local hp = safe(function() return hj:call("get_Position") end)
                if hp then
                    local yb = cfg.aim_height_bias
                        + ((wrule and tonumber(wrule.offset_y)) or 0)
                    best_pos = v3(hp.x, hp.y + yb, hp.z)
                    diag.aim_joint   = (safe(function() return hj:call("get_Name") end) or "?")
                    diag.aim_is_head = true
                    diag.aim_source  = "skeleton"
                end
            end
        end
    else
        diag.aim_joint, diag.aim_is_head = "-", false
        diag.aim_source   = "-"
        current_owner_obj = nil
    end

    -- keep the 8 nearest for inspection
    if cfg.show_dev then
        table.sort(sample, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
    end
    while #sample > 8 do table.remove(sample) end

    diag.scanned, diag.candidates = scanned, candidates
    diag.rej_disabled, diag.rej_nopos = rej.disabled, rej.nopos
    diag.rej_dist, diag.rej_cone, diag.rej_los = rej.dist, rej.cone, rej.los
    diag.rej_dead, diag.ctx_resolved = rej.dead, ctx_resolved
    diag.rej_hidden, diag.rej_notchar = rej.hidden, rej.notchar
    diag.sample = sample
    last_valid  = valid
    if best then
        local owner = safe(function() return best:call("get_OwnerObject") end)
        diag.target_name = owner and (safe(function() return owner:call("get_Name") end) or "?") or "?"
        diag.target_dist, diag.target_ang = best_dist, math.deg(best_ang)
    else
        diag.target_name, diag.target_dist, diag.target_ang = "-", 0, 0
    end
    return best, best_pos
end

--=====================================================================
-- Desired rotation computation
--=====================================================================

local desired_q       = nil     -- what we want this frame
local last_requested  = nil     -- to measure the residual
local last_target_screen = nil
local test_base_fwd   = nil     -- forward when the key was pressed (relative test)

-- fire button: mouse LMB or the pad's right trigger (found by name)
local auto_fire_mask
local function fire_mask()
    if auto_fire_mask then return auto_fire_mask end
    auto_fire_mask = 0
    local td = sdk.find_type_definition("via.hid.GamePadButton")
    if td then
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:is_static() end) then
                local n = tostring(safe(function() return f:get_name() end) or ""):lower()
                if n == "rtrigger" or n == "r2" or n == "righttrigger" or n == "trigger_r" then
                    auto_fire_mask = tonumber(safe(function() return f:get_data(nil) end)) or 0
                    break
                end
            end
        end
    end
    return auto_fire_mask
end
ZENO.fire_held = function()
    if is_key_down(0x01) then return true end
    return gamepad_mask_held(fire_mask())
end

local function is_active()
    if not cfg.enabled then return false end
    if not cfg.require_hold then return true end
    -- keyboard/mouse OR gamepad: pad players generate no VK codes
    if cfg.hold_key ~= 0 and is_key_down(cfg.hold_key) then return true end
    return gamepad_aim_held()
end

-- Recomputes desired_q. Returns true if there is something to apply.
local function compute()
    frame_counter = frame_counter + 1
    desired_q = nil
    last_target_screen = nil

    -- EARLY EXIT. This is the most noticeable optimisation: without it
    -- the target scan always ran, even with the mod off. Now, while you
    -- are not aiming, this callback does practically nothing.
    local active = is_active()
    if not active and not cfg.scan_when_idle and not cfg.show_dev then
        current_work, current_aim_pos = nil, nil
        locked_owner = nil
        return false
    end

    -- drop stale references (scene changes, despawned enemies)
    if frame_counter % 600 == 0 then
        ctx_cache     = {}
        wp_comp_cache = {}
        owner_meta    = {}
    end

    local tf = get_camera_transform()
    diag.cam = tf ~= nil
    if not tf then return false end

    local cam_pos = safe(function() return tf:call("get_Position") end)
    local cam_rot = safe(function() return tf:call("get_Rotation") end)
    local axis_z  = safe(function() return tf:call("get_AxisZ") end)
    local axis_y  = safe(function() return tf:call("get_AxisY") end)
    if not (cam_pos and cam_rot and axis_z) then return false end

    -- residual from the previous frame: how much of our request survived
    if last_requested then
        diag.residual_deg = q_angle_deg(last_requested, cam_rot)
        last_requested = nil
    end

    local axis_z_v = v3_norm(v3(axis_z.x, axis_z.y, axis_z.z))

    -- View direction calibration.
    -- Project a point 5m ahead and another 5m behind along the Z axis.
    -- Only the one actually in front of the camera projects to the screen.
    -- The camera orientation convention does not change mid-game:
    -- calibrate once and stop. This used to fire two world_to_screen
    -- calls per frame forever.
    if cfg.auto_forward and not forward_calibrated then
        local pf = v3(cam_pos.x + axis_z_v.x * 5, cam_pos.y + axis_z_v.y * 5, cam_pos.z + axis_z_v.z * 5)
        local pb = v3(cam_pos.x - axis_z_v.x * 5, cam_pos.y - axis_z_v.y * 5, cam_pos.z - axis_z_v.z * 5)
        local sf = safe(function() return draw.world_to_screen(pf) end)
        local sb = safe(function() return draw.world_to_screen(pb) end)
        diag.fwd_probe = string.format("+Z:%s  -Z:%s", sf and "visible" or "nil", sb and "visible" or "nil")
        if sf and not sb then
            cfg.forward_sign, forward_calibrated = 1, true
        elseif sb and not sf then
            cfg.forward_sign, forward_calibrated = -1, true
        end
    end
    diag.forward_sign = cfg.forward_sign

    local cam_fwd = v3(axis_z_v.x * cfg.forward_sign,
                       axis_z_v.y * cfg.forward_sign,
                       axis_z_v.z * cfg.forward_sign)

    -- Consistency check: only useful when debugging.
    if cfg.show_dev and axis_y then
        local q = look_rotation_view(cam_fwd, v3(axis_y.x, axis_y.y, axis_y.z))
        diag.basis_error = 1.0 - math.min(1.0, math.abs(q_dot(q, cam_rot)))
    end

    local _, ctrl_name = get_active_controller()
    diag.ctrl = ctrl_name or "-"

    -- test mode: ignores targets. Yaw RELATIVE to the moment of pressing,
    -- so the turn can be checked by eye.
    if cfg.test_force then
        if not is_active() then
            test_base_fwd = nil
            return false
        end
        if not test_base_fwd then test_base_fwd = cam_fwd end
        local a = math.rad(cfg.test_yaw_deg)
        local ca, sa = math.cos(a), math.sin(a)
        -- rotate the base forward around the Y axis
        local f = v3(test_base_fwd.x * ca + test_base_fwd.z * sa,
                     test_base_fwd.y,
                     -test_base_fwd.x * sa + test_base_fwd.z * ca)
        desired_q = look_rotation_view(f, v3(0, 1, 0))
        return true
    end

    local work, aim = acquire_target(cam_pos, cam_fwd)
    current_work, current_aim_pos = work, aim
    -- project to screen only if we will actually draw the marker
    if work and aim and cfg.debug_draw then
        last_target_screen = safe(function() return draw.world_to_screen(aim) end)
    end

    -- Releasing the key frees the lock: the next time you aim, the
    -- target is picked from scratch.
    if not is_active() then
        locked_owner = nil
        return false
    end
    if not (work and aim) then return false end

    local target_q = look_rotation_view(v3_norm(v3_sub(aim, cam_pos)), v3(0, 1, 0))
    local k = math.max(0.01, math.min(1.0, cfg.strength))
    if k >= 0.99 then
        desired_q = target_q
    else
        desired_q = quat_slerp(cam_rot, target_q, k)
    end
    return true
end

--=====================================================================
-- Apply  -  several selectable injection points
--=====================================================================

local APPLY_MODES = {
    "1: Interp.setRotation (post update)",
    "2: ctrl.setCameraRotation (post updateRotation)",
    "3: transform.set_Rotation (post onCameraUpdate)",
    "4: transform.set_Rotation (application entry)",
}

local function mark_applied(ok)
    diag.apply_calls = diag.apply_calls + 1
    if ok then
        diag.applied = true
        last_requested = desired_q
    else
        diag.apply_fail = diag.apply_fail + 1
    end
end

local function apply_via_controller(ctrl)
    if not (ctrl and desired_q) then return end
    local ok = pcall(function()
        ctrl:call("setCameraRotation(via.Quaternion, System.Boolean, System.Boolean)",
                  desired_q, cfg.scr_arg1, cfg.scr_arg2)
    end)
    if not ok then
        ok = pcall(function()
            ctrl:call("setCameraRotation", desired_q, cfg.scr_arg1, cfg.scr_arg2)
        end)
    end
    if not ok then diag.last_error = "setCameraRotation failed" end
    mark_applied(ok)
end

local function apply_via_transform()
    if not desired_q then return end
    local tf = get_camera_transform()
    if not tf then return end
    local ok = pcall(function() tf:call("set_Rotation", desired_q) end)
    if not ok then diag.last_error = "set_Rotation failed" end
    mark_applied(ok)
end

--=====================================================================
-- Hooks
--=====================================================================

local hook_report = {}

local function install_hook(type_name, method_name, pre, post)
    local td = sdk.find_type_definition(type_name)
    if not td then
        table.insert(hook_report, "NO TYPE " .. type_name)
        return false
    end
    local m = td:get_method(method_name)
    if not m then
        table.insert(hook_report, "NO METHOD " .. type_name .. "." .. method_name)
        return false
    end
    local ok = pcall(function() sdk.hook(m, pre, post) end)
    table.insert(hook_report, (ok and "OK " or "FAIL ") .. type_name .. "." .. method_name)
    return ok
end

-- --- mode 1: PlayerCameraRotationInterpolation.update -> setRotation
local interp_this = nil
local interp_seen = {}

install_hook("app.PlayerCameraRotationInterpolation", "update",
    function(args)
        interp_this = sdk.to_managed_object(args[2])
        return sdk.PreHookResult.CALL_ORIGINAL
    end,
    function(retval)
        diag.interp_hits = diag.interp_hits + 1
        local this = interp_this
        interp_this = nil
        if not this then return retval end

        local addr = safe(function() return this:get_address() end)
        if addr and not interp_seen[addr] then
            interp_seen[addr] = true
            diag.interp_instances = diag.interp_instances + 1
        end

        if cfg.apply_mode ~= 1 or not desired_q then return retval end

        -- filter: only the instance whose rotation matches the real camera
        if cfg.only_active_interp then
            local tf = get_camera_transform()
            local cam_rot = tf and safe(function() return tf:call("get_Rotation") end)
            local irot    = safe(function() return this:call("get_CameraRotation") end)
            if cam_rot and irot and q_angle_deg(cam_rot, irot) > 25.0 then
                return retval
            end
        end

        diag.interp_active_hits = diag.interp_active_hits + 1
        local ok = pcall(function() this:call("setRotation", desired_q) end)
        if not ok then diag.last_error = "Interp.setRotation failed" end
        mark_applied(ok)
        return retval
    end)

-- --- mode 2: <Ctrl>.updateRotation -> setCameraRotation
local updrot_this = nil
local function make_updrot_hooks(tn)
    install_hook(tn, "updateRotation",
        function(args)
            updrot_this = sdk.to_managed_object(args[2])
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval)
            diag.updrot_hits = diag.updrot_hits + 1
            local this = updrot_this
            updrot_this = nil
            if cfg.apply_mode == 2 and this and desired_q then
                apply_via_controller(this)
            end
            return retval
        end)
end

-- --- mode 3: <Ctrl>.onCameraUpdate -> direct transform
local function make_camupd_hooks(tn)
    install_hook(tn, "onCameraUpdate",
        nil,
        function(retval)
            diag.camupd_hits = diag.camupd_hits + 1
            if cfg.apply_mode == 3 and desired_q then
                apply_via_transform()
            end
            return retval
        end)
end
-- Modes 2 and 3 are for debugging. Their hooks ran every frame just to
-- bump a counter, so now they are installed when selected. sdk.hook
-- cannot be uninstalled, but if they are never installed the cost is
-- zero for 99% of users.
local extra_hooks_installed = false

local function install_debug_apply_hooks()
    if extra_hooks_installed then return end
    extra_hooks_installed = true
    make_updrot_hooks("app.PlayerFPSCameraController")
    make_updrot_hooks("app.PlayerTPSCameraController")
    make_camupd_hooks("app.PlayerFPSCameraController")
    make_camupd_hooks("app.PlayerTPSCameraController")
    diag.hooks = table.concat(hook_report, " | ")
end

diag.hooks = table.concat(hook_report, " | ")

--=====================================================================
-- Application entries: probe + mode 4
--=====================================================================

local ENTRY_NAMES = {
    "UpdateHID", "UpdateBehavior", "LateUpdateBehavior",
    "UpdateMotion", "LateUpdateMotion", "UpdateJoint", "LateUpdateJoint",
    "UpdateSpring", "UpdatePhysics", "UpdateConstraints",
    "UpdateCamera", "LateUpdateCamera",
    "UpdateGui", "BeginRendering", "PrepareRendering", "UpdateDisplay",
}

local entry_hits    = {}
local entry_ok      = {}
local entry_labels  = {}

for _, name in ipairs(ENTRY_NAMES) do
    entry_hits[name] = 0
    entry_ok[name]   = false
    table.insert(entry_labels, name)
end

-- Registering the 16 entries cost six Lua callbacks per frame just to
-- keep debug counters. Now they are registered when the developer
-- options are opened, which is when they are useful.
local entries_registered = false

local function register_entry_probes()
    if entries_registered then return end
    entries_registered = true
    for i, name in ipairs(ENTRY_NAMES) do
        entry_ok[name] = pcall(function()
            re.on_application_entry(name, function()
                entry_hits[name] = entry_hits[name] + 1
                if cfg.apply_mode == 4 and cfg.entry_index == i and desired_q then
                    apply_via_transform()
                end
            end)
        end)
    end
end

-- The computation runs once per frame, before any apply.
re.on_pre_application_entry("UpdateBehavior", function()
    diag.applied = false
    local ok, err = pcall(compute)
    if not ok then diag.last_error = tostring(err) end
end)

--=====================================================================
-- Target inspector
--=====================================================================

local inspect_msg    = nil
local inspect_msg_at = 0

local function inspect_target()
    local go = current_owner_obj
    if not go then
        inspect_msg, inspect_msg_at = "Aimbot: aim at an enemy first", os.clock()
        diag.last_error = inspect_msg
        return
    end

    local out = {
        enemy    = current_enemy_name,
        keywords = cfg.head_keywords,
        rule     = diag.aim_rule,
        anchors        = {},   -- lock-on points of THIS enemy
        joints_owner   = {},
        joints_context = {},
        components     = {},
    }

    -- 1) anchors of THIS enemy.
    -- The manager is scanned right here instead of storing a list every
    -- frame just in case F8 is pressed some day. This way ALL of them are
    -- visible too, without going through the cone, distance or category
    -- filters.
    out.anchors_aimassist = 0
    do
        local lom   = sdk.get_managed_singleton("app.LockOnTargetManager")
        local arr   = lom and safe(function() return lom:get_field("LockOnTargetList") end)
        local lists = arr and safe(function() return arr:get_elements() end) or {}
        for cat = 0, 3 do
            for _, w in ipairs(elements_of(lists[cat + 1])) do
                local ow = safe(function() return w:call("get_OwnerObject") end)
                local oa = ow and safe(function() return ow:get_address() end)
                if oa and oa == current_owner_addr then
                    local attr = safe(function() return w:call("get_Attribute") end)
                    local j    = safe(function() return w:call("get_TargetJoint") end)
                    local jn   = j and safe(function() return j:call("get_Name") end) or nil
                    local aa   = has_aimassist(attr)
                    if aa then out.anchors_aimassist = out.anchors_aimassist + 1 end
                    table.insert(out.anchors, {
                        joint     = jn,
                        aimassist = aa,
                        disabled  = safe(function() return w:call("get_DisabledFrame") end),
                        category  = cat,
                        attribute = attr,
                        type      = safe(function() return w:call("get_Type") end),
                        pos       = (function()
                            local p = safe(function() return w:call("get_TargetPosition") end)
                            return p and string.format("%.2f, %.2f, %.2f", p.x, p.y, p.z) or nil
                        end)(),
                        offset    = (function()
                            local o = safe(function() return w:call("get_TargetOffset") end)
                            return o and string.format("%.2f, %.2f, %.2f", o.x, o.y, o.z) or nil
                        end)(),
                    })
                end
            end
        end
    end

    -- 2) full skeleton
    for _, jt in ipairs(joints_of(safe(function() return go:call("get_Transform") end))) do
        table.insert(out.joints_owner, safe(function() return jt:call("get_Name") end))
    end
    local ctx = resolve_context(go)
    if ctx then
        for _, jt in ipairs(joints_of(safe(function() return ctx:call("get_Transform") end))) do
            table.insert(out.joints_context, safe(function() return jt:call("get_Name") end))
        end
    end

    -- 2b) FULL sweep of the manager, ignoring the config's category,
    --     distance and cone filters. If a boss weak point is registered as
    --     a Gimmick, or is outside the cone, it still shows up here.
    do
        local CATNAME = { "Player", "Enemy", "NPC", "Gimmick" }
        local lom   = sdk.get_managed_singleton("app.LockOnTargetManager")
        local arr   = lom and safe(function() return lom:get_field("LockOnTargetList") end)
        local lists = arr and safe(function() return arr:get_elements() end) or {}

        out.scene_owners = {}
        local by = {}
        for cat = 0, 3 do
            for _, w in ipairs(elements_of(lists[cat + 1])) do
                local owner = safe(function() return w:call("get_OwnerObject") end)
                local nm    = owner and safe(function() return owner:call("get_Name") end) or "?"
                local key   = CATNAME[cat + 1] .. "/" .. tostring(nm)
                local e     = by[key]
                if not e then
                    e = { owner = nm, category = CATNAME[cat + 1],
                          anchors = 0, aimassist = 0, joints = {} }
                    by[key] = e
                    table.insert(out.scene_owners, e)
                end
                e.anchors = e.anchors + 1

                -- "exposed" signals for each weak point: with one bulb
                -- burst and others hidden, the column that differs
                -- between them is the right one.
                if owner and e.signals == nil then
                    local act, s = weakpoint_signals(owner)
                    e.active  = act
                    e.signals = string.format(
                        "draw=%s update=%s mesh=%s lockon=%s ctrl=%s targetable=%s",
                        tostring(s.draw), tostring(s.update), tostring(s.mesh),
                        tostring(s.lockon), tostring(s.ctrl), tostring(s.targetable))
                end

                local attr = safe(function() return w:call("get_Attribute") end)
                if has_aimassist(attr) then e.aimassist = e.aimassist + 1 end
                local j  = safe(function() return w:call("get_TargetJoint") end)
                local jn = j and safe(function() return j:call("get_Name") end)
                local dis = safe(function() return w:call("get_DisabledFrame") end)
                if #e.joints < 32 then
                    table.insert(e.joints, string.format("%s(attr=%s%s)",
                        tostring(jn or "-"), tostring(attr), dis and ",OFF" or ""))
                end
            end
        end
    end

    -- 3) components: they reveal per-enemy weak point systems
    local comps = safe(function() return go:call("get_Components") end)
    for _, cp in ipairs(comps and safe(function() return comps:get_elements() end) or {}) do
        table.insert(out.components,
            safe(function() return cp:get_type_definition():get_full_name() end))
    end

    -- One file per enemy: that way you can inspect several bosses in a
    -- row without each F8 overwriting the previous one.
    local slug = tostring(current_enemy_name or "unknown"):gsub("[^%w_%-]", "_")
    local path = "aim_inspect_" .. slug .. ".json"
    json.dump_file(path, out)

    inspect_msg = string.format("Aimbot: %s -> %d anchors (%d AimAssist) | %d objects in scene",
        tostring(current_enemy_name), #out.anchors, out.anchors_aimassist,
        #(out.scene_owners or {}))
    inspect_msg_at  = os.clock()
    diag.last_error = inspect_msg
end

-- Edge detection: fires on press, not while held.
local inspect_was_down = false
local toggle_was_down  = false
local gp_toggle_was_down = false

local function toggle_aimbot()
    cfg.enabled    = not cfg.enabled
    locked_owner   = nil
    inspect_msg    = "Aimbot: " .. (cfg.enabled and "ON" or "OFF")
    inspect_msg_at = os.clock()
end

--=====================================================================
-- Debug draw
--=====================================================================

re.on_frame(function()
    if cfg.enabled and cfg.fov_enabled and cfg.fov_show then
        local w, h = ZENO.screen_size()
        if w then
            local cx, cy, seg = w * 0.5, h * 0.5, 72
            local fov_col = ZENO.col(cfg.fov_color, cfg.fov_color_rb)   -- whole circle is one color; rainbow cycles that color over time
            for t = 0, math.max(1, cfg.fov_thickness) - 1 do
                local r = cfg.fov_radius + t
                local px, py = cx + r, cy
                for i = 1, seg do
                    local a = (i / seg) * 6.2831853
                    local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r
                    draw.line(px, py, nx, ny, fov_col)
                    px, py = nx, ny
                end
            end
        end
    end

    -- toggle: keyboard
    if cfg.toggle_key > 0 then
        local down = is_key_down(cfg.toggle_key)
        if down and not toggle_was_down then toggle_aimbot() end
        toggle_was_down = down
    end

    -- toggle: gamepad
    if cfg.gamepad_enabled and cfg.gamepad_toggle_mask ~= 0 then
        local down = gamepad_mask_held(cfg.gamepad_toggle_mask)
        if down and not gp_toggle_was_down then toggle_aimbot() end
        gp_toggle_was_down = down
    end

    -- inspect key
    if cfg.inspect_key > 0 then
        local down = is_key_down(cfg.inspect_key)
        if down and not inspect_was_down then
            pcall(inspect_target)
        end
        inspect_was_down = down
    end

    -- on-screen confirmation (the REFramework UI may be closed)
    if inspect_msg and (os.clock() - inspect_msg_at) < 4.0 then
        draw.text(inspect_msg, 20, 60, 0xFF00FFFF)
    end

    if not cfg.debug_draw or not last_target_screen then return end
    local s = last_target_screen
    if not s or not s.x then return end
    draw.line(s.x - 10, s.y, s.x + 10, s.y, 0xFF00FF00)
    draw.line(s.x, s.y - 10, s.x, s.y + 10, 0xFF00FF00)
    draw.text(string.format("%s  %.1fm  %.1fdeg",
        diag.target_name, diag.target_dist, diag.target_ang), s.x + 14, s.y - 8, 0xFF00FF00)
end)

--=====================================================================
-- UI
--=====================================================================

local PRIORITY  = { "Closest to screen center", "Closest to camera", "Closest to player" }
local LOS_MODES = { "Off", "On (isOcclusionToPlayer)", "On (isOcclusion)" }

local COL_YELLOW = 0xFF00FFFF
local COL_GREEN  = 0xFF00FF00
local COL_GREY   = 0xFF999999

--- User section ------------------------------------------------------

-- Binding capture. Only one at a time.
local capture_until  = 0
local capture_target = nil   -- "aim_key" | "toggle_key" | "aim_pad" | "toggle_pad"

-- First key pressed. 0x01 (left click) is skipped so the click used to
-- press "Assign" is not captured.
local function first_key_down()
    for vk = 2, 254 do
        if is_key_down(vk) then return vk end
    end
    return nil
end

-- Binding row: shows the current value, the Assign button and resolves
-- the capture while the window is open.
local function assign_row(label, target, current_text, on_capture, live_hint)
    imgui.text(string.format("  %s: %s", label, current_text))
    if live_hint then
        imgui.same_line()
        imgui.text_colored(live_hint, COL_GREY)
    end

    if capture_target == target then
        if os.clock() > capture_until then
            capture_target = nil
        else
            imgui.text_colored("    Press it now...", COL_YELLOW)
            if on_capture() then capture_target = nil end
            return
        end
    end

    imgui.push_id(target)
    if imgui.button("Assign") then
        capture_target = target
        capture_until  = os.clock() + 5
    end
    imgui.pop_id()
end

local function draw_user_ui()
    local ch, tmp

    ---------------------------------------------------------------- on/off
    imgui.text_colored(cfg.enabled and "STATUS: ON" or "STATUS: OFF",
        cfg.enabled and COL_GREEN or COL_GREY)

    ch, cfg.enabled = imgui.checkbox("Enable aimbot", cfg.enabled)

    imgui.separator()
    imgui.text("AIM FOV CIRCLE")
    ch, cfg.fov_enabled = imgui.checkbox("Only aim inside the circle", cfg.fov_enabled)
    ch, cfg.fov_show = imgui.checkbox("Draw circle", cfg.fov_show)
    ch, cfg.fov_radius = imgui.slider_float("Circle size (radius px)", cfg.fov_radius, 20.0, 1000.0, "%.0f")
    ch, cfg.fov_thickness = imgui.slider_int("Circle thickness", cfg.fov_thickness, 1, 6)
    ch, cfg.fov_color = zeno_color_rb("Circle color", cfg.fov_color, cfg, "fov_color_rb")
    imgui.separator()

    if imgui.tree_node("Controls") then
        ch, cfg.require_hold = imgui.checkbox("Only while holding the aim button", cfg.require_hold)
        imgui.text_colored("  Unchecked = always aiming while enabled.", COL_GREY)

        imgui.text("Keyboard / mouse")
        assign_row("Aim key", "aim_key",
            cfg.hold_key == 0 and "none (gamepad only)" or string.format("0x%02X", cfg.hold_key),
            function()
                local vk = first_key_down()
                if vk then cfg.hold_key = vk; return true end
                return false
            end)
        assign_row("Toggle on/off key", "toggle_key",
            cfg.toggle_key == 0 and "none" or string.format("0x%02X", cfg.toggle_key),
            function()
                local vk = first_key_down()
                if vk then cfg.toggle_key = vk; return true end
                return false
            end)
        imgui.text_colored("  Default toggle is E. Right mouse cannot be captured;", COL_GREY)
        imgui.text_colored("  use the sliders below for mouse buttons.", COL_GREY)
        ch, cfg.hold_key   = imgui.slider_int("Aim key (VK code)", cfg.hold_key, 0, 255)
        ch, cfg.toggle_key = imgui.slider_int("Toggle key (VK code)", cfg.toggle_key, 0, 255)
        imgui.text_colored("  0x02 = right mouse, 0x45 = E, 0x2D = Insert, 0x78 = F9.", COL_GREY)

        imgui.tree_pop()
    end

    ----------------------------------------------------------- gamepad
    imgui.separator()
    imgui.text("GAMEPAD")
    ch, cfg.gamepad_enabled = imgui.checkbox("Aim with a gamepad button", cfg.gamepad_enabled)
    if cfg.gamepad_enabled then
        local btn  = gamepad_buttons()
        local auto = (cfg.gamepad_mask == 0)
        local mask = auto and default_aim_mask() or cfg.gamepad_mask

        if btn == nil then
            imgui.text_colored("  No gamepad detected.", COL_YELLOW)
            imgui.text_colored("  Enable developer options and use", COL_GREY)
            imgui.text_colored("  'Dump gamepad API' to report this.", COL_GREY)
        else
            imgui.text(string.format("  Pressed now: 0x%X", btn))
        end
        assign_row("Aim button", "aim_pad",
            string.format("0x%X (%s)", mask,
                auto and ("auto: " .. tostring(auto_aim_name)) or "assigned"),
            function()
                local b = gamepad_buttons()
                if b and b ~= 0 then cfg.gamepad_mask = b; return true end
                return false
            end)
        if not auto then
            imgui.same_line()
            if imgui.button("Reset to auto") then cfg.gamepad_mask = 0 end
        end

        assign_row("Toggle on/off button", "toggle_pad",
            cfg.gamepad_toggle_mask == 0 and "not assigned"
                or string.format("0x%X", cfg.gamepad_toggle_mask),
            function()
                local b = gamepad_buttons()
                if b and b ~= 0 then cfg.gamepad_toggle_mask = b; return true end
                return false
            end)
        if cfg.gamepad_toggle_mask ~= 0 then
            imgui.same_line()
            if imgui.button("Clear") then cfg.gamepad_toggle_mask = 0 end
        end
        imgui.text_colored("  Pick a button the game does not use, or it will", COL_GREY)
        imgui.text_colored("  toggle while you play.", COL_GREY)
    end

    imgui.separator()

    --------------------------------------------------------- how it aims
    imgui.text("AIM BEHAVIOUR")
    ch = false
    imgui.text_colored("  On = locks instantly. Off = smooth pull (recommended).", COL_GREY)
    do
        ch, cfg.strength = imgui.slider_float("Aim strength (1.0 = hard lock)", cfg.strength, 0.01, 1.0, "%.02f")
        imgui.text_colored("  Higher = snappier. 0.2-0.4 feels like strong aim assist.", COL_GREY)
    end
    ch, cfg.aim_height_bias = imgui.slider_float("Vertical aim offset (m)",
        cfg.aim_height_bias, -1, 1, "%.2f")
    ch, cfg.debug_draw = imgui.checkbox("Show target marker", cfg.debug_draw)
    ch, cfg.scan_when_idle = imgui.checkbox("Keep scanning while not aiming", cfg.scan_when_idle)
    imgui.text_colored("  Off = no work at all unless you are aiming.", COL_GREY)
    imgui.text_colored("  Turn on only to see the marker without aiming.", COL_GREY)

    imgui.separator()

    ------------------------------------------------------- what it aims at
    imgui.text("TARGET SELECTION")
    ch, cfg.cat_enemy = imgui.checkbox("Enemies", cfg.cat_enemy)
    imgui.same_line()
    ch, cfg.cat_npc = imgui.checkbox("NPCs", cfg.cat_npc)
    imgui.same_line()
    ch, cfg.cat_gimmick = imgui.checkbox("Objects", cfg.cat_gimmick)

    ch, cfg.max_distance = imgui.slider_float("Max distance (m)", cfg.max_distance, 5, 200, "%.0f")
    ch, cfg.max_cone_deg = imgui.slider_float("Aim cone (deg)", cfg.max_cone_deg, 1, 90, "%.0f")
    imgui.text_colored("  Targets outside this cone are ignored.", COL_GREY)

    ch, tmp = imgui.combo("Priority", cfg.priority_mode + 1, PRIORITY)
    cfg.priority_mode = (tmp or (cfg.priority_mode + 1)) - 1

    ch, tmp = imgui.combo("Line of sight", cfg.los_mode + 1, LOS_MODES)
    cfg.los_mode = (tmp or (cfg.los_mode + 1)) - 1
    imgui.text_colored("  Skips targets behind walls. Off if it feels unreliable.", COL_GREY)

    ch, cfg.sticky = imgui.checkbox("Keep target until it dies or is lost", cfg.sticky)
    imgui.text_colored("  Prevents snapping between enemies mid-fight.", COL_GREY)
    ch, cfg.skip_dead = imgui.checkbox("Ignore dead enemies", cfg.skip_dead)
    ch, cfg.require_character = imgui.checkbox("Only target characters", cfg.require_character)
    imgui.text_colored("  Skips explosive barrels, crates and props. The game", COL_GREY)
    imgui.text_colored("  registers those as valid aim-assist targets too.", COL_GREY)

    imgui.separator()

    ------------------------------------------------------- where it aims
    imgui.text("AIM POINT")
    ch, cfg.prefer_aimassist = imgui.checkbox(
        "Prefer points marked by the game", cfg.prefer_aimassist)
    imgui.text_colored("  Uses the game's own aim-assist flag. On enemies with", COL_GREY)
    imgui.text_colored("  weak spots this targets those instead of the head.", COL_GREY)

    ch, cfg.prefer_weakpoints = imgui.checkbox(
        "Prefer boss weak points", cfg.prefer_weakpoints)
    imgui.text_colored("  Some bosses spawn weak points as separate objects", COL_GREY)
    imgui.text_colored("  (blisters, bulbs). This targets those over the body.", COL_GREY)

    ch, cfg.skip_hidden_wp = imgui.checkbox("Ignore hidden weak points", cfg.skip_hidden_wp)
    imgui.text_colored("  Bosses keep unexposed weak points registered.", COL_GREY)

    ch, cfg.prefer_upper = imgui.checkbox("Prefer head and weak-spot bones", cfg.prefer_upper)
    if not cfg.prefer_upper then
        imgui.text_colored("  WARNING: this also disables the per-enemy rules below.", COL_YELLOW)
    end

    if cfg.prefer_upper and imgui.tree_node("Bone name lists (advanced)") then
        imgui.text_colored("Comma separated. Order = priority.", COL_GREY)
        local cw, tw = imgui.input_text("Weak spot bones (checked first)", cfg.weak_keywords)
        if cw and tw then
            cfg.weak_keywords = tw
            refresh_head_words()
            head_joint_cache = {}
        end
        local c1, t1 = imgui.input_text("Head bones", cfg.head_keywords)
        if c1 and t1 then
            cfg.head_keywords = t1
            refresh_head_words()
            head_joint_cache = {}
        end
        local c2, t2 = imgui.input_text("Weak point object names", cfg.weakpoint_keywords)
        if c2 and t2 then cfg.weakpoint_keywords = t2; refresh_head_words() end
        ch, cfg.head_from_skeleton =
            imgui.checkbox("Find head in skeleton if no anchor exists", cfg.head_from_skeleton)
        imgui.tree_pop()
    end

    if cfg.prefer_upper and imgui.tree_node("Per-enemy rules (advanced)") then
        imgui.text_colored("The first rule whose text appears in the enemy name", COL_GREY)
        imgui.text_colored("replaces the global bone lists for that enemy.", COL_GREY)
        imgui.separator()

        local remove_at = nil
        for i, r in ipairs(cfg.aim_rules) do
            imgui.push_id(i)
            local c1, m = imgui.input_text("Enemy name contains", r.match or "")
            if c1 and m then r.match = m; refresh_head_words() end
            local c2, j = imgui.input_text("Bones (in priority order)", r.joints or "")
            if c2 and j then r.joints = j; refresh_head_words() end
            local c3, o = imgui.slider_float("Vertical offset (m)",
                tonumber(r.offset_y) or 0.0, -1.5, 1.5, "%.03f")
            if c3 then r.offset_y = o end
            if imgui.button("Delete rule") then remove_at = i end
            imgui.separator()
            imgui.pop_id()
        end
        if remove_at then
            table.remove(cfg.aim_rules, remove_at)
            refresh_head_words()
        end

        if current_enemy_name then
            if imgui.button("Add rule for: " .. tostring(current_enemy_name)) then
                table.insert(cfg.aim_rules, {
                    match    = tostring(current_enemy_name),
                    joints   = cfg.head_keywords,
                    offset_y = 0.0,
                })
                refresh_head_words()
            end
        else
            imgui.text_colored("(aim at an enemy to add a rule for it)", COL_GREY)
        end
        imgui.tree_pop()
    end
end

--- Developer section -------------------------------------------------

local function draw_dev_ui()
    local ch, tmp

    imgui.text_colored("Debug tools. Not needed for normal play.", COL_YELLOW)
    imgui.separator()

    if imgui.tree_node("Isolated rotation test") then
        imgui.text_colored("Ignores targets and forces a fixed turn. If the camera", COL_GREY)
        imgui.text_colored("does not move, the problem is rotation APPLY, not targeting.", COL_GREY)
        ch, cfg.test_force   = imgui.checkbox("Force fixed yaw turn", cfg.test_force)
        ch, cfg.test_yaw_deg = imgui.slider_float("Yaw offset (deg)", cfg.test_yaw_deg, -180, 180, "%.0f")
        imgui.tree_pop()
    end

    if imgui.tree_node("Rotation apply mode") then
        ch, tmp = imgui.combo("Mode", cfg.apply_mode, APPLY_MODES)
        cfg.apply_mode = tmp or cfg.apply_mode
        if cfg.apply_mode == 1 then
            ch, cfg.only_active_interp = imgui.checkbox("Active instance only", cfg.only_active_interp)
        elseif cfg.apply_mode == 2 then
            ch, cfg.scr_arg1 = imgui.checkbox("arg1", cfg.scr_arg1)
            imgui.same_line()
            ch, cfg.scr_arg2 = imgui.checkbox("arg2", cfg.scr_arg2)
        elseif cfg.apply_mode == 4 then
            ch, tmp = imgui.combo("Application entry", cfg.entry_index, entry_labels)
            cfg.entry_index = tmp or cfg.entry_index
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Axis calibration") then
        ch, cfg.auto_forward = imgui.checkbox("Auto-detect view direction", cfg.auto_forward)
        if not cfg.auto_forward then
            local neg = (cfg.forward_sign < 0)
            ch, neg = imgui.checkbox("Camera looks down -Z", neg)
            cfg.forward_sign = neg and -1 or 1
        end
        imgui.text(string.format("  forward_sign = %d   probe: %s",
            cfg.forward_sign, tostring(diag.fwd_probe)))
        imgui.tree_pop()
    end

    if imgui.tree_node("Filters (debug)") then
        ch, cfg.permissive = imgui.checkbox(
            "PERMISSIVE MODE (ignore cone / distance / LOS)", cfg.permissive)
        imgui.tree_pop()
    end

    imgui.separator()
    imgui.text("DUMPS")
    if imgui.button("Inspect current target -> data/aim_inspect_<enemy>.json") then
        inspect_target()
    end
    ch, cfg.inspect_key = imgui.slider_int("Inspect key (VK, 0x77 = F8)", cfg.inspect_key, 0, 255)

    if imgui.button("Dump gamepad API -> data/aim_gamepad.json") then
        local out = { types = {}, probes = {}, live = {} }

        -- 1) actual API of the types involved
        for _, tn in ipairs({ "via.hid.GamePad", "via.hid.GamePadDevice",
                              "via.hid.GamePadButton", "via.hid.MouseDevice" }) do
            local td = sdk.find_type_definition(tn)
            local t  = { name = tn, found = td ~= nil, methods = {}, fields = {} }
            if td then
                for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                    local ps = {}
                    for _, pt in ipairs(safe(function() return m:get_param_types() end) or {}) do
                        table.insert(ps, safe(function() return pt:get_full_name() end) or "?")
                    end
                    table.insert(t.methods, string.format("%s %s(%s)",
                        safe(function() return m:get_return_type():get_full_name() end) or "?",
                        safe(function() return m:get_name() end) or "?",
                        table.concat(ps, ", ")))
                end
                for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
                    local st = safe(function() return f:is_static() end)
                    table.insert(t.fields, string.format("%s%s = %s",
                        st and "[static] " or "",
                        safe(function() return f:get_name() end) or "?",
                        st and tostring(safe(function() return f:get_data(nil) end)) or "-"))
                end
            end
            table.insert(out.types, t)
        end

        -- 2) which device accessor responds
        local sing = sdk.get_native_singleton("via.hid.GamePad")
        local std  = sdk.find_type_definition("via.hid.GamePad")
        out.singleton = sing ~= nil
        if sing and std then
            for _, c in ipairs(GP_DEVICE_CALLS) do
                local n, a = c[1], c[2]
                local d = safe(function()
                    if a ~= nil then return sdk.call_native_func(sing, std, n, a) end
                    return sdk.call_native_func(sing, std, n)
                end)
                table.insert(out.probes, string.format("%s(%s) -> %s", n,
                    a ~= nil and tostring(a) or "",
                    d and (safe(function() return d:get_type_definition():get_full_name() end)
                           or "object") or "nil"))
            end
        end

        -- 3) live values (hold a button while dumping)
        local dev = gamepad_device()
        out.device_call = gp_mode
        if dev then
            for _, n in ipairs({ "get_Button", "get_Buttons", "get_ButtonDown",
                                 "get_ButtonUp", "get_ButtonHold", "get_ButtonOn",
                                 "get_AnalogL", "get_AnalogR" }) do
                out.live[n] = tostring(safe(function() return dev:call(n) end))
            end
        end

        json.dump_file("aim_gamepad.json", out)
        diag.last_error = "gamepad API dumped"
    end

    if imgui.button("Dump diagnostics -> data/aim_diag.json") then
        local d = {}
        for k, v in pairs(diag) do d[k] = v end
        d.cfg         = cfg
        d.key_mode    = key_mode
        d.hook_report = hook_report
        d.entry_hits  = entry_hits
        d.entry_ok    = entry_ok
        json.dump_file("aim_diag.json", d)
        diag.last_error = "diagnostics dumped"
    end

    imgui.separator()

    if imgui.tree_node("Diagnostics") then
        imgui.text(string.format("Key input          : %s  (active=%s)", key_mode, tostring(is_active())))
        imgui.text(string.format("Gamepad access     : %s   buttons=%s   auto mask=0x%X (%s)",
            gp_mode, tostring(gamepad_buttons()), default_aim_mask(), tostring(auto_aim_name)))
        imgui.text(string.format("LockOnTargetManager: %s", tostring(diag.lom)))
        imgui.text(string.format("Camera             : %s", tostring(diag.cam)))
        imgui.text(string.format("Controller         : %s", diag.ctrl))
        imgui.text(string.format("Anchors scanned    : %d   candidates: %d", diag.scanned, diag.candidates))
        imgui.text(string.format("Rejected -> disabled:%d nopos:%d dist:%d cone:%d LOS:%d dead:%d hidden:%d notchar:%d",
            diag.rej_disabled, diag.rej_nopos, diag.rej_dist, diag.rej_cone,
            diag.rej_los, diag.rej_dead, diag.rej_hidden, diag.rej_notchar))
        imgui.text(string.format("Contexts resolved  : %d / %d  (0 = dead filter not working)",
            diag.ctx_resolved, diag.scanned))
        imgui.text(string.format("Player position    : %s", tostring(diag.player_pos)))
        imgui.text(string.format("Priority in use    : %s", PRIORITY[cfg.priority_mode + 1] or "?"))
        imgui.text(string.format("Target locked      : %s", locked_owner and "yes" or "no"))
        imgui.text(string.format("Aimed bone         : %s  %s  [via %s]",
            tostring(diag.aim_joint), diag.aim_is_head and "(PRIORITY)" or "",
            tostring(diag.aim_source)))
        imgui.text(string.format("Enemy / rule       : %s  ->  %s",
            tostring(current_enemy_name), tostring(diag.aim_rule)))
        imgui.text(string.format("Target             : %s  %.1fm  %.1fdeg",
            diag.target_name, diag.target_dist, diag.target_ang))
        imgui.text(string.format("Axis basis error   : %.5f  (~0 = ok)", diag.basis_error))
        imgui.separator()
        imgui.text(string.format("Apply calls        : %d   failed: %d", diag.apply_calls, diag.apply_fail))
        imgui.text(string.format("Residual vs request: %.2f deg  (0 = rotation survived)", diag.residual_deg))
        imgui.text(string.format("Interp update hits : %d   active: %d   instances: %d",
            diag.interp_hits, diag.interp_active_hits, diag.interp_instances))
        imgui.text(string.format("updateRotation hits: %d", diag.updrot_hits))
        imgui.text(string.format("onCameraUpdate hits: %d", diag.camupd_hits))
        imgui.text(string.format("Last error         : %s", diag.last_error))
        imgui.tree_pop()
    end

    if imgui.tree_node("Nearest targets") then
        imgui.text_colored("* = priority bone   A = AimAssist   W = weak point object", COL_GREY)
        if #diag.sample == 0 then
            imgui.text("(nothing scanned)")
        end
        for _, r in ipairs(diag.sample) do
            imgui.text(string.format("%-16s [%-13s]%s%s%s attr=%-6s cam=%5.1fm plr=%5.1fm %5.1fdeg dead=%-5s %s%s",
                tostring(r.name or "?"),
                tostring(r.joint or "-"),
                r.is_head and "*" or " ",
                r.aa and "A" or " ",
                r.wp and "W" or " ",
                tostring(r.attr or "-"),
                r.dist or -1, r.dplayer or -1, r.ang or -1,
                tostring(r.dead),
                (r.rejected == false) and "OK" or ("X " .. tostring(r.rejected)),
                (r.los_raw ~= nil) and ("  los=" .. tostring(r.los_raw)) or ""))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Hooks / application entries") then
        for _, r in ipairs(hook_report) do imgui.text(r) end
        imgui.separator()
        for _, name in ipairs(ENTRY_NAMES) do
            imgui.text(string.format("%-20s reg=%s hits=%d",
                name, tostring(entry_ok[name]), entry_hits[name] or 0))
        end
        imgui.tree_pop()
    end
end

zui("Aimbot", function()

    draw_user_ui()

    imgui.separator()
    local ch
    ch, cfg.show_dev = imgui.checkbox("Show developer options", cfg.show_dev)
    if cfg.show_dev then
        -- debug probes are only hooked when requested
        register_entry_probes()
        install_debug_apply_hooks()
        draw_dev_ui()
    end
end)

log.info("[" .. MOD_NAME .. "] loaded")

end

-- ===================== ESP =====================
do
-- ── config ───────────────────────────────────────────────
local CFG_PATH = "reframework/data/zeno_esp_config.json"

local default_cfg = {
    enabled       = true,
    show_enemy    = true,
    show_npc      = true,
    show_self     = true,
    show_counter  = true,
    max_dist      = 100.0,
    box_color     = 0xFF00FF00,
    npc_color     = 0xFF00FFFF,
    self_color    = 0xFFFFFF00,
    counter_color = 0xFF00FF00,
    box_color_rb      = false,
    npc_color_rb      = false,
    self_color_rb     = false,
    counter_color_rb  = false,
    line_color_rb     = false,
    npc_line_color_rb = false,
    strict_alive  = true,
    show_lines     = false,
    show_npc_lines = false,
    line_color     = 0xFF00FFFF,
    npc_line_color = 0xFFFFFF00,
    counter_scale = 3,
    counter_x     = 0.35,
    counter_y     = 0.08,
    wid_scale     = 0.28,
    top_bias      = 0.10,
    bot_bias      = 0.05,
}

local cfg = {}
for k,v in pairs(default_cfg) do cfg[k]=v end

local function save_cfg()
    local f = io.open(CFG_PATH, "w")
    if not f then return end
    f:write("{\n")
    local lines = {}
    for k,v in pairs(cfg) do
        local val
        if type(v)=="boolean" then val = v and "true" or "false"
        elseif type(v)=="number" then
            if math.abs(v)>100 and v==math.floor(v) then
                val = string.format("%d", math.floor(v))
            else val = string.format("%.4f", v) end
        end
        if val then lines[#lines+1]=string.format('  "%s": %s',k,val) end
    end
    f:write(table.concat(lines,",\n"))
    f:write("\n}\n"); f:close()
end

local function load_cfg()
    local f = io.open(CFG_PATH, "r")
    if not f then return end
    local content = f:read("*a"); f:close()
    for k,val_str in content:gmatch('"([%w_]+)"%s*:%s*([%S]+)') do
        val_str = val_str:gsub("[,}%s]","")
        if default_cfg[k]~=nil then
            local t=type(default_cfg[k])
            if t=="boolean" then cfg[k]=(val_str=="true")
            elseif t=="number" then local n=tonumber(val_str); if n then cfg[k]=n end end
        end
    end
end
load_cfg()
ZENO.cfg.esp = cfg

-- ── world to screen ──
local SceneManager_td = sdk.find_type_definition("via.SceneManager")
local sceneManager    = sdk.get_native_singleton("via.SceneManager")
local ENEMY_FIELD = "<EnemyContextList>k__BackingField"
local NPC_FIELD   = "<NPCContextList>k__BackingField"

local function get_screen_size()
    if not sceneManager then return nil end
    local mv = sdk.call_native_func(sceneManager, SceneManager_td, "get_MainView")
    if not mv then return nil end
    return mv:get_WindowSize()
end

local function world_to_screen(pos)
    if not pos then return nil end
    local cam = sdk.get_primary_camera()
    if not cam then return nil end
    local vp = cam:call("get_ViewProjMatrix")
    if not vp then return nil end
    local sz = get_screen_size()
    if not sz then return nil end
    local v0,v1,v2,v3 = vp[0],vp[1],vp[2],vp[3]
    local x,y,z = pos.x, pos.y, pos.z
    local cx = v0.x*x + v1.x*y + v2.x*z + v3.x
    local cy = v0.y*x + v1.y*y + v2.y*z + v3.y
    local cw = v0.w*x + v1.w*y + v2.w*z + v3.w
    if cw <= 0.001 then return nil end
    local sx = (1 + cx/cw) * 0.5 * sz.w
    local sy = (1 - cy/cw) * 0.5 * sz.h
    if sx < -200 or sx > sz.w+200 or sy < -200 or sy > sz.h+200 then return nil end
    return { x=sx, y=sy, w=sz.w, h=sz.h }
end

local function pos_offset_y(pos, dy)
    return Vector3f.new(pos.x, pos.y + dy, pos.z)
end

local function outline_text(text, x, y, color)
    draw.text(text, x+1, y+1, 0xFF000000)
    draw.text(text, x,   y,   color)
end

local function scale_text(text, x, y, color, scale)
    scale = math.max(1, math.floor(scale or 1))
    if scale <= 1 then outline_text(text,x,y,color); return end
    for ox=0,scale-1 do for oy=0,scale-1 do
        draw.text(text, x+ox+2, y+oy+2, 0xFF000000)
    end end
    for ox=0,scale-1 do for oy=0,scale-1 do
        draw.text(text, x+ox, y+oy, color)
    end end
end

-- ── ESP box ──
local function draw_head_line(pos, cap_h, color)
    local w, h = ZENO.screen_size()
    if not w then return end
    local hp = world_to_screen(pos_offset_y(pos, cap_h * 0.93))   -- just under the top of the capsule = head
    if not hp then return end
    draw.line(w * 0.5, h, hp.x, hp.y, color)
end

local function draw_esp_box(pos, label, color, cap_h, line_col, no_box)
    cap_h = cap_h or 1.75

    if line_col then draw_head_line(pos, cap_h, line_col) end
    if no_box then return true end
    local sp_foot = world_to_screen(pos)
    local sp_head = world_to_screen(pos_offset_y(pos, cap_h))
    if not sp_foot or not sp_head then return false end

    local top_y = math.min(sp_foot.y, sp_head.y)
    local bot_y = math.max(sp_foot.y, sp_head.y)
    local h     = bot_y - top_y
    if h < 2 then return false end

    top_y = top_y + h * cfg.top_bias
    bot_y = bot_y - h * cfg.bot_bias
    h     = bot_y - top_y

    local cx = (sp_foot.x + sp_head.x) * 0.5
    local bw = h * cfg.wid_scale
    local x1, x2 = cx - bw, cx + bw

    draw.line(x1,top_y, x2,top_y, color)
    draw.line(x1,bot_y, x2,bot_y, color)
    draw.line(x1,top_y, x1,bot_y, color)
    draw.line(x2,top_y, x2,bot_y, color)
    outline_text(label, cx - 28, top_y - 18, color)
    return true
end

-- liveness: the context lists keep stale entries after a despawn and
-- ctx:get_Position() keeps returning the last cached value. A live enemy still
-- has a GameObject + Transform whose position can be read and that agrees
-- with the context's own position.
local frame_n = 0
local alive_cache = {}

local function check_alive(ctx, cpos)
    local ok_go, go = pcall(function() return ctx:get_GameObject() end)
    if not ok_go or not go then return false end
    local ok_dr, dr = pcall(function() return go:call("get_DrawSelf") end)
    if ok_dr and dr == false then return false end
    local ok_tf, tf = pcall(function() return go:call("get_Transform") end)
    if not ok_tf or not tf then return false end
    local ok_tp, tp = pcall(function() return tf:call("get_Position") end)
    if not ok_tp or not tp then return false end
    if math.abs(tp.x) < 0.01 and math.abs(tp.y) < 0.01 and math.abs(tp.z) < 0.01 then return false end
    if cpos then
        local dx, dy, dz = tp.x - cpos.x, tp.y - cpos.y, tp.z - cpos.z
        if dx*dx + dy*dy + dz*dz > 25.0 then return false end
    end
    return true
end

local function ctx_alive(ctx, cpos)
    if not cfg.strict_alive then return true end
    if sdk.is_managed_object and not sdk.is_managed_object(ctx) then return false end
    local ok_a, addr = pcall(function() return ctx:get_address() end)
    if not ok_a or not addr then return check_alive(ctx, cpos) end
    local e = alive_cache[addr]
    if e and (frame_n - e.at) < 5 then return e.ok end
    local ok = check_alive(ctx, cpos)
    alive_cache[addr] = { ok = ok, at = frame_n }
    return ok
end

local function count_valid(list)
    local total=0
    if not list then return 0 end
    local ok_cnt,cnt = pcall(function() return list:get_Count() end)
    if not ok_cnt or not cnt then return 0 end
    for i=0,cnt-1 do
        local ok_c,ctx = pcall(function() return list:get_Item(i) end)
        if ok_c and ctx then
            local ok_p,pos = pcall(function() return ctx:get_Position() end)
            if ok_p and pos then
                if math.abs(pos.x)>0.01 or math.abs(pos.y)>0.01 or math.abs(pos.z)>0.01 then
                    if ctx_alive(ctx, pos) then total=total+1 end
                end
            end
        end
    end
    return total
end

local g_enemy_total = 0
local g_npc_total   = 0

-- ── main frame ───────────────────────────────────────────
re.on_frame(function()
    if not cfg.enabled then return end
    frame_n = frame_n + 1
    if frame_n % 1800 == 0 then
        for a, e in pairs(alive_cache) do
            if frame_n - e.at > 1800 then alive_cache[a] = nil end
        end
    end
    local charMgr = sdk.get_managed_singleton("app.CharacterManager")
    if not charMgr then return end
    local box_col      = ZENO.col(cfg.box_color,      cfg.box_color_rb)
    local npc_col      = ZENO.col(cfg.npc_color,      cfg.npc_color_rb,      0.33)
    local self_col     = ZENO.col(cfg.self_color,     cfg.self_color_rb,     0.66)
    local cnt_col      = ZENO.col(cfg.counter_color,  cfg.counter_color_rb)
    local line_col     = ZENO.col(cfg.line_color,     cfg.line_color_rb,     0.15)
    local npc_line_col = ZENO.col(cfg.npc_line_color, cfg.npc_line_color_rb, 0.50)

    local player_pos = nil
    local ok_pc,pc = pcall(function() return charMgr:getPlayerContextRef() end)
    if ok_pc and pc then
        local ok_pp,pp = pcall(function() return pc:get_Position() end)
        if ok_pp and pp then player_pos=pp end
    end

    local ok_el,elist = pcall(function() return charMgr:get_field(ENEMY_FIELD) end)
    local ok_nl,nlist = pcall(function() return charMgr:get_field(NPC_FIELD) end)

    g_enemy_total = count_valid(ok_el and elist or nil)
    g_npc_total   = count_valid(ok_nl and nlist or nil)

    -- counter
    if cfg.show_counter then
        local sz = get_screen_size()
        local cx = sz and (sz.w * cfg.counter_x) or 400
        local cy = sz and (sz.h * cfg.counter_y) or 60
        scale_text(
            string.format("Enemies: %d    NPCs: %d", g_enemy_total, g_npc_total),
            cx, cy, cnt_col, cfg.counter_scale)
    end

    -- self
    if cfg.show_self and player_pos then
        local sp = world_to_screen(player_pos)
        if sp then outline_text("[SELF]", sp.x-20, sp.y-20, self_col) end
    end

    -- enemies
    if (cfg.show_enemy or cfg.show_lines) and ok_el and elist then
        for i=0,elist:get_Count()-1 do
            local ok_c,ctx = pcall(function() return elist:get_Item(i) end)
            if ok_c and ctx then
                local ok_ep,epos = pcall(function() return ctx:get_Position() end)
                if ok_ep and epos and (math.abs(epos.x)>0.01 or math.abs(epos.z)>0.01) and ctx_alive(ctx, epos) then
                    local dist=0
                    if player_pos then
                        local dx=player_pos.x-epos.x
                        local dy=player_pos.y-epos.y
                        local dz=player_pos.z-epos.z
                        dist=math.sqrt(dx*dx+dy*dy+dz*dz)
                    end
                    if dist<=cfg.max_dist then
                        -- get cap_h from CC
                        local cap_h=1.75
                        local ok_go,go = pcall(function() return ctx:get_GameObject() end)
                        if ok_go and go then
                            local ok_cc,cc = pcall(function()
                                return go:call("getComponent(System.Type)",
                                    sdk.typeof("via.physics.CharacterController"))
                            end)
                            if ok_cc and cc then
                                local okh,hv=pcall(function() return cc:call("get_Height") end)
                                if okh and hv and hv>0.1 then cap_h=hv end
                            end
                        end
                        draw_esp_box(epos,
                            string.format("Enemy  %.0fm", dist),
                            box_col, cap_h,
                            cfg.show_lines and line_col or nil, not cfg.show_enemy)
                    end
                end
            end
        end
    end

    -- NPCs
    if (cfg.show_npc or cfg.show_npc_lines) and ok_nl and nlist then
        for i=0,nlist:get_Count()-1 do
            local ok_c,ctx = pcall(function() return nlist:get_Item(i) end)
            if ok_c and ctx then
                local ok_np,npos = pcall(function() return ctx:get_Position() end)
                if ok_np and npos and (math.abs(npos.x)>0.01 or math.abs(npos.z)>0.01) and ctx_alive(ctx, npos) then
                    local dist=0
                    if player_pos then
                        local dx=player_pos.x-npos.x
                        local dy=player_pos.y-npos.y
                        local dz=player_pos.z-npos.z
                        dist=math.sqrt(dx*dx+dy*dy+dz*dz)
                    end
                    if dist<=cfg.max_dist then
                        local cap_h=1.75
                        local ok_go,go = pcall(function() return ctx:get_GameObject() end)
                        if ok_go and go then
                            local ok_cc,cc = pcall(function()
                                return go:call("getComponent(System.Type)",
                                    sdk.typeof("via.physics.CharacterController"))
                            end)
                            if ok_cc and cc then
                                local okh,hv=pcall(function() return cc:call("get_Height") end)
                                if okh and hv and hv>0.1 then cap_h=hv end
                            end
                        end
                        draw_esp_box(npos,
                            string.format("NPC  %.0fm", dist),
                            npc_col, cap_h,
                            cfg.show_npc_lines and npc_line_col or nil, not cfg.show_npc)
                    end
                end
            end
        end
    end
end)

-- ── settings ─────────────────────────────────────────────
zui("ESP", function()
    if not imgui.tree_node("Enemy ESP") then return end
    local c,v
    imgui.text("── Display ──")
    c,v=imgui.checkbox("Enable ESP",     cfg.enabled);      if c then cfg.enabled=v end
    c,v=imgui.checkbox("Show Counter",   cfg.show_counter); if c then cfg.show_counter=v end
    c,v=imgui.checkbox("Show Enemy Box", cfg.show_enemy);   if c then cfg.show_enemy=v end
    c,v=imgui.checkbox("Show NPC Box",   cfg.show_npc);     if c then cfg.show_npc=v end
    c,v=imgui.checkbox("Show Self",      cfg.show_self);    if c then cfg.show_self=v end
    imgui.separator()
    imgui.text("── Counter ──")
    c,v=imgui.slider_int("Scale (1~5)", cfg.counter_scale, 1, 5)
    if c then cfg.counter_scale=v end
    c,v=imgui.slider_float("X", cfg.counter_x, 0.0, 1.0, "%.2f")
    if c then cfg.counter_x=v end
    c,v=imgui.slider_float("Y", cfg.counter_y, 0.0, 1.0, "%.2f")
    if c then cfg.counter_y=v end
    imgui.separator()
    imgui.text("── Range ──")
    c,v=imgui.slider_float("Max Dist(m)", cfg.max_dist, 5, 500, "%.0f")
    if c then cfg.max_dist=v end
    imgui.separator()
    imgui.text("── Box Tuning ──")
    c,v=imgui.slider_float("Width scale", cfg.wid_scale, 0.05, 0.8, "%.2f")
    if c then cfg.wid_scale=v end
    c,v=imgui.slider_float("Top bias",    cfg.top_bias,  -0.3, 0.5, "%.2f")
    if c then cfg.top_bias=v end
    c,v=imgui.slider_float("Bot bias",    cfg.bot_bias,  -0.3, 0.5, "%.2f")
    if c then cfg.bot_bias=v end
    imgui.separator()
    imgui.text("── Colors ──")
    c,v=zeno_color_rb("Enemy Box", cfg.box_color,  cfg, "box_color_rb");  if c then cfg.box_color=v end
    c,v=zeno_color_rb("NPC",       cfg.npc_color,  cfg, "npc_color_rb");  if c then cfg.npc_color=v end
    c,v=zeno_color_rb("Self",      cfg.self_color, cfg, "self_color_rb"); if c then cfg.self_color=v end
    c,v=zeno_color_rb("Counter",   cfg.counter_color, cfg, "counter_color_rb"); if c then cfg.counter_color=v end
    c,v=imgui.slider_float("Rainbow speed", ZENO.cfg.rainbow.speed, 0.05, 2.0, "%.2f")
    if c then ZENO.cfg.rainbow.speed=v end
    c,v=imgui.checkbox("Lines to enemy heads", cfg.show_lines); if c then cfg.show_lines=v end
    c,v=zeno_color_rb("Enemy line", cfg.line_color, cfg, "line_color_rb"); if c then cfg.line_color=v end
    c,v=imgui.checkbox("Lines to NPC heads", cfg.show_npc_lines); if c then cfg.show_npc_lines=v end
    c,v=zeno_color_rb("NPC line", cfg.npc_line_color, cfg, "npc_line_color_rb"); if c then cfg.npc_line_color=v end
    imgui.separator()
    if imgui.button("Save Config") then save_cfg() end
    imgui.same_line()
    if imgui.button("Reset Default") then
        for k,dv in pairs(default_cfg) do cfg[k]=dv end
    end
    imgui.tree_pop()
end)
end

-- ===================== PLAYER / WEAPONS (SmartSpeaker) =====================
do
-- ============================================================================
-- REQUIEM MOD PANEL
-- Version: 1.3.0
-- Merge: bundle logic for Ammo, Axe, Grenades, Injector, Credits, Speed,
--        FOV, Film Grain, Map Reveal, Auto Parry, Headshot, No Recoil,
--        No Reload.  Health + One Hit Kill kept from original.
-- ============================================================================

local PANEL    = "Requiem Mod Panel"
local CFG_PATH = "zeno_panel.json"
local VER      = "1.3.0"

-- ============================================================================
-- CONFIG
-- ============================================================================
local cfg = {
    -- Health (original logic kept)
    infinite_health   = false,

    -- Ammo & Weapons
    infinite_ammo     = false,
    infinite_axe      = false,
    infinite_grenades = false,
    infinite_injector = false,
    no_reload         = false,
    no_recoil         = false,

    -- Combat
    auto_parry        = false,
    one_hit_kill      = false,   -- (original logic kept)
    enable_headshot   = false,
    headshot_mult     = 2.0,

    -- Zeno additions
    god_mode            = false,   -- invincible flag + zero incoming damage, HP untouched
    no_spread           = false,
    infinite_flashbangs = false,
    infinite_mines      = false,
    infinite_throwables = false,
    infinite_healing    = false,
    max_damage          = false,   -- multiplies every hit
    damage_mult         = 5.0,
    auto_headshot       = false,   -- every hit counts as a head hit
    log_items           = false,   -- dev: records consumed item names
}

-- ============================================================================
-- CONFIG I/O
-- ============================================================================
local function load_cfg()
    local ok, data = pcall(json.load_file, CFG_PATH)
    if ok and data then
        for k, v in pairs(data) do
            if cfg[k] ~= nil and type(cfg[k]) == type(v) then
                cfg[k] = v
            end
        end
    end
end

local function save_cfg()
    pcall(json.dump_file, CFG_PATH, cfg)
end

load_cfg()
ZENO.cfg.panel = cfg

-- ============================================================================
-- SINGLETON CACHE
-- ============================================================================
local _cache = {}

local function get_singleton(key, type_name)
    local c = _cache[key]
    if c then
        local alive = pcall(c.get_type_definition, c)
        if alive then return c end
        _cache[key] = nil
    end
    local ok, inst = pcall(sdk.get_managed_singleton, type_name)
    if ok and inst then
        _cache[key] = inst
        return inst
    end
    return nil
end

-- ============================================================================
-- HELPERS  (safe_call / safe_get_field / safe_set_field use type_definition
--           for structured access; try_call / try_get_field / try_set_field
--           use the direct obj:call / obj:get_field style from the bundle)
-- ============================================================================
local function safe_call(obj, method_names, ...)
    if not obj then return false, nil end
    local td = obj:get_type_definition()
    if not td then return false, nil end
    local args = {...}
    for _, m in ipairs(method_names) do
        local method = td:get_method(m)
        if method then
            local ok, ret = pcall(function() return method:call(obj, table.unpack(args)) end)
            if ok then return true, ret end
        end
    end
    return false, nil
end

local function safe_get_field(obj, field_names)
    if not obj then return false, nil end
    local td = obj:get_type_definition()
    if not td then return false, nil end
    for _, f in ipairs(field_names) do
        local prop = td:get_method("get_" .. f)
        if prop then
            local ok, ret = pcall(function() return prop:call(obj) end)
            if ok then return true, ret end
        end
        local field = td:get_field(f)
        if field then
            local ok, ret = pcall(function() return field:get_data(obj) end)
            if ok then return true, ret end
        end
    end
    return false, nil
end

local function safe_set_field(obj, field_names, value)
    if not obj then return false end
    local td = obj:get_type_definition()
    if not td then return false end
    for _, f in ipairs(field_names) do
        local setter = td:get_method("set_" .. f)
        if setter then
            local ok = pcall(function() setter:call(obj, value) end)
            if ok then return true end
        end
        local field = td:get_field(f)
        if field then
            local ok = pcall(function() field:set_data(obj, value) end)
            if ok then return true end
        end
    end
    return false
end

-- Bundle-style helpers (direct obj:call / obj:get_field / obj:set_field)
local function try_call(obj, methods, ...)
    if not obj then return false, nil end
    for _, name in ipairs(methods) do
        local ok, ret = pcall(obj.call, obj, name, ...)
        if ok then return true, ret end
    end
    return false, nil
end

local function try_get_field(obj, fields)
    if not obj then return false, nil end
    for _, name in ipairs(fields) do
        local ok, ret = pcall(function() return obj:get_field(name) end)
        if ok and ret ~= nil then return true, ret end
    end
    return false, nil
end

local function try_set_field(obj, fields, value)
    if not obj then return false end
    for _, name in ipairs(fields) do
        local ok = pcall(obj.set_field, obj, name, value)
        if ok then return true end
    end
    return false
end

local function safe_hook(method, pre, post)
    if not method then return false end
    local ok, err = pcall(sdk.hook, method, pre, post)
    if not ok then log.warn("[RMP] Hook failed: " .. tostring(err)) end
    return ok
end

local function get_number(obj, getters, fields)
    local ok, v = safe_call(obj, getters)
    if ok and type(v) == "number" then return v end
    if fields then
        local ok2, f = safe_get_field(obj, fields)
        if ok2 and type(f) == "number" then return f end
    end
    return nil
end

-- ============================================================================
-- PLAYER HELPERS
-- ============================================================================
local function get_player()
    local mgr = get_singleton("char_mgr", "app.CharacterManager")
    if not mgr then return nil end
    local ok, p = try_call(mgr, {"getPlayerContextRef()", "getPlayerContextRef"})
    if ok and p then return p end
    return nil
end

local function get_player_hp(player)
    if not player then return nil end
    local ok, hp = try_call(player, {"get_HitPoint()", "get_HitPoint"})
    if ok and hp then return hp end
    local ok2, hp2 = try_get_field(player, {"HitPoint", "_HitPoint"})
    if ok2 then return hp2 end
    return nil
end

-- ============================================================================
-- SAVED STATE & LIVE DEBUG
-- ============================================================================
local saved = {
    -- HP (original)
    default_hp_current    = nil,
    default_hp_max        = nil,
    health_override_active = false,

    -- Ammo / Axe originals
    orig_ammo_captured    = false,
    orig_infinity_gun     = false,
    orig_infinity_rl      = false,
    orig_axe_captured     = false,
    orig_infinity_axe     = false,
    orig_infinity_axe_hdl = false,

    -- Active override tracking
    ammo_active = false,
    axe_active  = false,
}

local live_hp = { current = 0, max = 0 }
local every_other_frame = false

-- ============================================================================
-- FEATURE: Infinite Health  (original logic — unchanged)
-- ============================================================================
local function set_hp_max_only(hp, value)
    safe_call(hp, {
        "set_CurrentMaximumHitPoint(System.Int32)", "set_MaximumHitPoint(System.Int32)",
        "set_CurrentMaximumHitPoint", "set_MaximumHitPoint"
    }, value)
    safe_set_field(hp, {
        "CurrentMaximumHitPoint", "_CurrentMaximumHitPoint",
        "_MaximumHitPoint", "MaximumHitPoint"
    }, value)
end

local function set_hp_current_only(hp, value)
    safe_call(hp, {
        "set_CurrentHitPoint(System.Int32)", "set_HitPoint(System.Int32)",
        "set_CurrentHitPoint", "set_HitPoint"
    }, value)
    safe_set_field(hp, {"CurrentHitPoint", "_CurrentHitPoint", "HitPoint"}, value)
end

local function set_invincible_on(hp)
    safe_call(hp, {"set_Invincible(System.Boolean)", "set_Invincible"}, true)
end

local function set_invincible_off(hp)
    safe_call(hp, {"set_Invincible(System.Boolean)", "set_Invincible"}, false)
end

local function heal_hp_to(hp, current_hp, target_hp)
    if current_hp >= target_hp then return end
    local delta = target_hp - current_hp
    local ok = safe_call(hp, {
        "recovery(System.Int32, app.HitPoint.RecoveryFactor)", "recovery(System.Int32)", "recovery"
    }, delta, 0)
    if not ok then
        safe_call(hp, {"resetHitPoint(System.Int32)", "resetHitPoint"}, target_hp)
    end
    set_hp_current_only(hp, target_hp)
end

local function apply_health_recovery()
    local player = get_player()
    if not player then return end
    local hp = get_player_hp(player)
    if not hp then return end

    if cfg.god_mode and not cfg.infinite_health then
        set_invincible_on(hp)
        saved.god_active = true
    elseif saved.god_active and not cfg.god_mode and not cfg.infinite_health then
        set_invincible_off(hp)
        saved.god_active = false
    end

    local current_hp = get_number(hp,
        {"get_CurrentHitPoint()", "get_HitPoint()", "get_CurrentHitPoint", "get_HitPoint"},
        {"CurrentHitPoint", "_CurrentHitPoint", "HitPoint"}) or 0

    local max_hp = get_number(hp,
        {"get_CurrentMaximumHitPoint()", "get_MaximumHitPoint()", "get_CurrentMaximumHitPoint", "get_MaximumHitPoint"},
        {"CurrentMaximumHitPoint", "_CurrentMaximumHitPoint", "_MaximumHitPoint", "MaximumHitPoint"}) or 0

    live_hp.current = current_hp
    live_hp.max     = max_hp

    if cfg.infinite_health then
        local target_hp = 99999

        if not saved.health_override_active then
            saved.default_hp_current   = current_hp
            saved.default_hp_max       = max_hp
            saved.health_override_active = true
            set_hp_max_only(hp, target_hp)
            set_invincible_on(hp)
            if current_hp < target_hp then
                heal_hp_to(hp, current_hp, target_hp)
                current_hp = target_hp
            end
            live_hp.current = target_hp
            live_hp.max     = target_hp
            return
        end

        every_other_frame = not every_other_frame
        if every_other_frame then
            set_invincible_on(hp)
            if max_hp < target_hp then set_hp_max_only(hp, target_hp); max_hp = target_hp end
            if current_hp < target_hp then heal_hp_to(hp, current_hp, target_hp); current_hp = target_hp end
        end
        live_hp.current = target_hp
        live_hp.max     = target_hp
    else
        if saved.health_override_active then
            local restore_max     = saved.default_hp_max or 800
            local restore_current = restore_max
            set_invincible_off(hp)
            set_hp_max_only(hp, restore_max)
            set_hp_current_only(hp, restore_current)

            live_hp.current = get_number(hp,
                {"get_CurrentHitPoint()", "get_HitPoint()", "get_CurrentHitPoint", "get_HitPoint"},
                {"CurrentHitPoint", "_CurrentHitPoint", "HitPoint"}) or restore_current
            live_hp.max = get_number(hp,
                {"get_CurrentMaximumHitPoint()", "get_MaximumHitPoint()", "get_CurrentMaximumHitPoint", "get_MaximumHitPoint"},
                {"CurrentMaximumHitPoint", "_CurrentMaximumHitPoint", "_MaximumHitPoint", "MaximumHitPoint"}) or restore_max

            saved.default_hp_current     = nil
            saved.default_hp_max         = nil
            saved.health_override_active = false
            every_other_frame            = false
        else
            live_hp.current = current_hp
            live_hp.max     = max_hp
        end
    end
end

-- ============================================================================
-- FEATURE: Infinite Ammo & Axe  (bundle pattern: obj:get_field / obj:set_field)
-- ============================================================================
local function apply_infinite_ammo_axe()
    local im = get_singleton("item_mgr", "app.ItemManager")
    if not im then return end

    -- Capture originals once
    if not saved.orig_ammo_captured then
        local ok1, v1 = try_get_field(im, {"_InfinityGun"})
        local ok2, v2 = try_get_field(im, {"_InfinityRocketLauncher"})
        saved.orig_infinity_gun = (ok1 and v1) or false
        saved.orig_infinity_rl  = (ok2 and v2) or false
        saved.orig_ammo_captured = true
    end

    if not saved.orig_axe_captured then
        local ok1, v1 = try_get_field(im, {"_InfinityAxe"})
        local ok2, v2 = try_get_field(im, {"_InfinityAxeHandle"})
        saved.orig_infinity_axe     = (ok1 and v1) or false
        saved.orig_infinity_axe_hdl = (ok2 and v2) or false
        saved.orig_axe_captured = true
    end

    -- Infinite Ammo toggle
    if cfg.infinite_ammo then
        try_set_field(im, {"_InfinityGun"}, true)
        try_set_field(im, {"_InfinityRocketLauncher"}, true)
        saved.ammo_active = true
    elseif saved.ammo_active then
        try_set_field(im, {"_InfinityGun"}, saved.orig_infinity_gun)
        try_set_field(im, {"_InfinityRocketLauncher"}, saved.orig_infinity_rl)
        saved.ammo_active = false
    end

    -- Infinite Axe toggle
    if cfg.infinite_axe then
        try_set_field(im, {"_InfinityAxe"}, true)
        try_set_field(im, {"_InfinityAxeHandle"}, true)
        saved.axe_active = true
    elseif saved.axe_active then
        try_set_field(im, {"_InfinityAxe"}, saved.orig_infinity_axe)
        try_set_field(im, {"_InfinityAxeHandle"}, saved.orig_infinity_axe_hdl)
        saved.axe_active = false
    end
end

-- ============================================================================
-- HOOK INSTALLS
-- ============================================================================
local grenades_done  = false
local injector_done  = false
local reload_done    = false
local recoil_done    = false
local parry_done     = false
local headshot_done  = false

local function get_method_safe(tname, sig)
    local td = sdk.find_type_definition(tname)
    if not td then return nil end
    return td:get_method(sig)
end

-- ============================================================================
-- FEATURE: Infinite Grenades + Injector  (single hook, bundle style)
-- ============================================================================
-- item-name rules for the consumeStock hook (name tokens, lower case)
local consume_rules = {
    { flag = "infinite_grenades",   tokens = {"grenade","molotov","incendiary","bomb","flash"} },
    { flag = "infinite_flashbangs", tokens = {"flash"} },
    { flag = "infinite_mines",      tokens = {"mine"} },
    { flag = "infinite_throwables", tokens = {"grenade","molotov","incendiary","bomb","flash","mine"} },
    { flag = "infinite_healing",    tokens = {"herb","spray","heal","medic","first_aid","firstaid","bandage"} },
}

local seen_items, seen_dirty, seen_tick = {}, false, 0
local function log_item(n)
    if not seen_items[n] then seen_items[n] = true; seen_dirty = true end
end
local function flush_items()
    seen_tick = seen_tick + 1
    if not seen_dirty or seen_tick % 120 ~= 0 then return end
    local list = {}
    for n in pairs(seen_items) do list[#list + 1] = n end
    table.sort(list)
    pcall(json.dump_file, "zeno_items.json", { items = list })
    seen_dirty = false
end

local function install_consume_hook()
    if grenades_done and injector_done then return end
    grenades_done = true
    injector_done = true

    local inv_t = sdk.find_type_definition("app.Inventory")
    if not inv_t then return end

    local c1 = inv_t:get_method("consumeStock(app.ItemID, System.Int32, app.ItemStockChangedEventType)")
    local c2 = inv_t:get_method("consumeStock(app.Inventory.PanelKey, System.Int32, app.ItemStockChangedEventType)")

    local function hook_fn(args)
        local item_id = sdk.to_managed_object(args[3])
        local name = nil
        if item_id then
            local ok, n = pcall(function()
                return item_id:call("get_Name()") or item_id:call("ToString()")
            end)
            if ok and n then name = string.lower(tostring(n)) end
        end

        if cfg.infinite_injector and name == "it99_50_001" then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        if name then
            if cfg.log_items then log_item(name) end
            for _, r in ipairs(consume_rules) do
                if cfg[r.flag] then
                    for _, tok in ipairs(r.tokens) do
                        if string.find(name, tok, 1, true) then
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end
            end
        end

        return sdk.PreHookResult.CALL_ORIGINAL
    end

    if c1 then pcall(sdk.hook, c1, hook_fn, nil) end
    if c2 then pcall(sdk.hook, c2, hook_fn, nil) end
end

-- ============================================================================
-- FEATURE: No Reload  (bundle style — only no_reload, NOT infinite_ammo)
-- ============================================================================
local function install_no_reload()
    if reload_done then return end
    reload_done = true

    local equip_t = sdk.find_type_definition("app.PlayerEquipment")
    if not equip_t then return end

    local m = equip_t:get_method("consumeLoading(System.Int32)") or equip_t:get_method("consumeLoading")
    if m then
        pcall(sdk.hook, m, function(args)
            if cfg.no_reload then return sdk.PreHookResult.SKIP_ORIGINAL end
            return sdk.PreHookResult.CALL_ORIGINAL
        end, nil)
    end
end

-- ============================================================================
-- FEATURE: No Recoil  (bundle style)
-- ============================================================================
local function install_no_recoil()
    if recoil_done then return end
    recoil_done = true

    local targets = {
        {class = "app.CameraRecoilController",   methods = {"addRecoil", "update", "lateUpdate"}},
        {class = "app.WeaponRecoil",              methods = {"addRecoil", "calculateRecoil", "update"}},
        {class = "app.SpreadOfFireManager",       methods = {"addSpread", "update", "calcSpread"}, flag = "no_spread"},
        {class = "app.PlayerCameraShakeController", methods = {"addShake", "update"}},
        {class = "app.PlayerGun",                 methods = {"applyRecoil", "addRecoil", "updateRecoil"}},
        {class = "app.Gun",                       methods = {"applyRecoil", "addRecoil", "updateRecoil"}},
    }

    local hooked = {}
    for _, t in ipairs(targets) do
        local flag = t.flag or "no_recoil"
        local td = sdk.find_type_definition(t.class)
        if td then
            local ok_ms, ms = pcall(function() return td:get_methods() end)
            if ok_ms and ms then
                for _, m in ipairs(ms) do
                    local ok_n, mname = pcall(function() return m:get_name() end)
                    if ok_n and mname then
                        local lname = mname:lower()
                        local key   = tostring(m)
                        for _, target in ipairs(t.methods) do
                            if not hooked[key] and string.find(lname, target:lower(), 1, true) then
                                hooked[key] = true
                                pcall(sdk.hook, m,
                                    function(args)
                                        if cfg[flag] then return sdk.PreHookResult.SKIP_ORIGINAL end
                                        return sdk.PreHookResult.CALL_ORIGINAL
                                    end,
                                    function(retval)
                                        if cfg[flag] then return sdk.to_ptr(0) end
                                        return retval
                                    end)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- FEATURE: Auto Parry  (bundle style)
-- ============================================================================
local function install_auto_parry()
    if parry_done then return end
    parry_done = true

    local FLAG_P  = 32
    local FLAG_JP = 8192

    local m1 = get_method_safe("app.PlayerAttackDamageDriver", "checkParry(app.HitController.DamageInfo)")
            or get_method_safe("app.PlayerAttackDamageDriver", "checkParry")
    local m2 = get_method_safe("app.PlayerAttackDamageDriver", "onCheckDamageHit(app.HitController.DamageInfo)")
            or get_method_safe("app.PlayerAttackDamageDriver", "onCheckDamageHit")

    if m1 then
        pcall(sdk.hook, m1,
            function(args) return sdk.PreHookResult.CALL_ORIGINAL end,
            function(retval) if cfg.auto_parry then return true end return retval end)
    end

    if m2 then
        pcall(sdk.hook, m2,
            function(args)
                if not cfg.auto_parry and not cfg.infinite_health and not cfg.god_mode then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end
                local di = sdk.to_managed_object(args[3]) or sdk.to_managed_object(args[4])
                if di then
                    pcall(function()
                        if cfg.infinite_health or cfg.god_mode then
                            local td = di:get_type_definition()
                            if td then
                                local sd = td:get_method("set_Damage")
                                if sd then pcall(function() sd:call(di, 0.0) end) end
                                local fd = td:get_field("_Damage")
                                if fd then pcall(function() fd:set_data(di, 0.0) end) end
                            end
                        end
                        if cfg.auto_parry then
                            di:call("onFlag(app.HitController.DamageInfo.AttackDamageFlagEnum)", FLAG_P)
                            di:call("onFlag(app.HitController.DamageInfo.AttackDamageFlagEnum)", FLAG_JP)
                        end
                    end)
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end
end

-- ============================================================================
-- FEATURE: Headshot + One Hit Kill  (original logic)
-- ============================================================================
local function install_headshot()
    if headshot_done then return end
    headshot_done = true

    local m = get_method_safe("app.EnemyAttackDamageDriver", "calcBodyPartsRate")
    if not m then return end

    local si, sf, sh = nil, nil, nil

    pcall(sdk.hook, m,
        function(args)
            si = nil
            if not (cfg.enable_headshot or cfg.one_hit_kill or cfg.max_damage or cfg.auto_headshot) then return end
            pcall(function()
                local di = sdk.to_managed_object(args[3])
                local c  = sdk.to_managed_object(args[4])
                if not di or not c then return end
                local dmg = di:call("get_Damage")
                if not dmg or dmg <= 0 then return end
                si = di
                sf = di:call("get_DamageFactor")
                sh = c:call("getBodyPartDamageFactor", 1)
            end)
        end,
        function(retval)
            pcall(function()
                if not si or not sf or not sh then return end
                if sh <= 0 or sf == 0 then return end
                local fa = si:call("get_DamageFactor")
                if cfg.one_hit_kill then
                    si:set_field("_DamageFactor", fa * 99999.0)
                else
                    local nf = fa
                    local was_head = math.abs(fa / sf - sh) < 0.01
                    if cfg.auto_headshot and not was_head then
                        nf = sf * sh
                        was_head = true
                    end
                    if cfg.enable_headshot and was_head then
                        nf = nf * math.floor(cfg.headshot_mult)
                    end
                    if cfg.max_damage then
                        nf = nf * cfg.damage_mult
                    end
                    if nf ~= fa then si:set_field("_DamageFactor", nf) end
                end
                si, sf, sh = nil, nil, nil
            end)
            return retval
        end)
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
re.on_frame(function()
    pcall(flush_items)
    pcall(apply_health_recovery)
    pcall(apply_infinite_ammo_axe)

    pcall(install_consume_hook)
    pcall(install_no_reload)
    pcall(install_no_recoil)
    pcall(install_auto_parry)
    pcall(install_headshot)
end)

re.on_config_save(save_cfg)

-- ============================================================================
-- UI HELPERS
-- ============================================================================
local function toggle(label, key)
    local ch, val = imgui.checkbox(label, cfg[key])
    if ch then cfg[key] = val; save_cfg() end
end

local function gap()
    imgui.spacing(); imgui.spacing()
end

local function section(label)
    imgui.spacing()
    imgui.text_colored(0xFFCCAA55, "  " .. label)
    imgui.separator()
    imgui.spacing()
end

-- ============================================================================
-- UI
-- ============================================================================
zui("Player / Weapons", function()
    local opened = imgui.tree_node("Player / Weapons")
    if not opened then return end

    local ok, err = pcall(function()
        imgui.spacing()

        -- ── Health ──────────────────────────────────────────────────────────
        if imgui.collapsing_header("Health") then
            section("Survival")
            imgui.text(string.format("Live Player HP: %d / %d",
                math.floor(live_hp.current), math.floor(live_hp.max)))
            imgui.spacing()
            toggle("Infinite Health", "infinite_health")
            gap()
        end

        -- ── Weapons ─────────────────────────────────────────────────────────
        if imgui.collapsing_header("Weapons") then
            section("Ammo")
            toggle("Infinite Ammo",            "infinite_ammo")
            toggle("No Reload",                "no_reload")
            toggle("No Recoil",                "no_recoil")
            toggle("No Spread",                "no_spread")

            section("Equipment")
            toggle("Infinite Axe Durability",  "infinite_axe")
            toggle("Infinite Grenades/Molotovs","infinite_grenades")
            toggle("Infinite Hemolytic Injector","infinite_injector")
            toggle("Infinite Flashbangs",      "infinite_flashbangs")
            toggle("Infinite Mines",           "infinite_mines")
            toggle("Infinite Throwables (all)","infinite_throwables")
            toggle("Infinite Healing Items",   "infinite_healing")
            gap()
        end

        -- ── Combat ──────────────────────────────────────────────────────────
        if imgui.collapsing_header("Combat") then
            section("Defense")
            toggle("Auto Parry", "auto_parry")
            toggle("God Mode",   "god_mode")

            section("Offense")
            local ch_ohk, v_ohk = imgui.checkbox("One Hit Kill", cfg.one_hit_kill)
            if ch_ohk then
                cfg.one_hit_kill = v_ohk
                if v_ohk then cfg.enable_headshot = false end
                save_cfg()
            end

            local ch_hs, v_hs = imgui.checkbox("Headshot Boost", cfg.enable_headshot)
            if ch_hs then
                cfg.enable_headshot = v_hs
                if v_hs then cfg.one_hit_kill = false end
                save_cfg()
            end

            if cfg.enable_headshot and not cfg.one_hit_kill then
                imgui.indent(16)
                imgui.push_item_width(220)
                local ch, val = imgui.slider_float("Damage Multiplier",
                    cfg.headshot_mult, 1.0, 20.0, "%.1fx")
                if ch then cfg.headshot_mult = val; save_cfg() end
                imgui.pop_item_width()
                imgui.indent(-16)
            end
            toggle("Auto Headshot (any hit = head)", "auto_headshot")
            toggle("Max Weapon Damage",              "max_damage")
            if cfg.max_damage then
                imgui.indent(16)
                imgui.push_item_width(220)
                local ch, val = imgui.slider_float("Weapon Damage Multiplier",
                    cfg.damage_mult, 1.0, 50.0, "%.1fx")
                if ch then cfg.damage_mult = val; save_cfg() end
                imgui.pop_item_width()
                imgui.indent(-16)
            end
            gap()
        end

        -- ── Info ────────────────────────────────────────────────────────────
        if imgui.collapsing_header("Info") then
            imgui.spacing()
            imgui.text("Zeno Menu")
            imgui.text("Panel logic: SmartSpeaker")
            imgui.text("Aimbot logic: Guz")
            imgui.spacing()
        end
    end)

    imgui.tree_pop()

    if not ok then
        log.error("[RMP UI Error] " .. tostring(err))
    end
end)

log.info("[Zeno] player/weapons module loaded")
end

-- ===================== SKELETON ESP =====================
do
-- Skeleton ESP: its own feature, independent of the box ESP.
-- Same drawing as the box: world_to_screen on native Vector3f + draw.line.
-- The lines follow the enemy's REAL bones: every frame the live joint
-- positions are read and each bone is drawn to its parent bone.
local CFG_PATH = "zeno_skeleton.json"

local cfg = {
    enabled   = false,
    enemies   = true,
    npcs      = false,
    max_dist  = 60.0,
    main_only = true,
    color     = 0xFFFFFFFF,
    color_rb  = false,
}

do
    local ok, data = pcall(json.load_file, CFG_PATH)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
        end
    end
end
re.on_config_save(function() pcall(json.dump_file, CFG_PATH, cfg) end)
ZENO.cfg.skel = cfg

local ENEMY_FIELD = "<EnemyContextList>k__BackingField"
local NPC_FIELD   = "<NPCContextList>k__BackingField"

local sm_td = sdk.find_type_definition("via.SceneManager")
local sm    = sdk.get_native_singleton("via.SceneManager")

-- main-body bones (name contains one of KEEP and none of SKIP)
local KEEP = { "hip","pelvis","spine","chest","neck","head","kubi","atama","clavicle","shoulder",
               "arm","elbow","hand","wrist","thigh","upleg","leg","knee","calf","shin","foot","ankle","toe" }
local SKIP = { "twist","roll","helper","_end","end_","tip","finger","thumb","index","middle",
               "ring","pinky","hair","cloth","skirt","_ik","ik_","wep","weapon","dummy","adjust",
               "tail","jaw","eye","tongue","face","cp_","vfx","attach","offset" }

local function wanted(lname)
    if not cfg.main_only then return true end
    for _, t in ipairs(SKIP) do if lname:find(t, 1, true) then return false end end
    for _, t in ipairs(KEEP) do if lname:find(t, 1, true) then return true end end
    return false
end

local function addr_of(o)
    local ok, a = pcall(function() return o:get_address() end)
    if ok then return a end
    return nil
end

local function call(o, m)
    local ok, r = pcall(function() return o:call(m) end)
    if ok then return r end
    return nil
end

local function joints_of(tf)
    if not tf then return nil end
    local arr = call(tf, "get_Joints")
    if not arr then return nil end
    local ok, els = pcall(function() return arr:get_elements() end)
    if ok and els and #els > 0 then return els end
    return nil
end

-- (child joint, parent joint) pairs for the wanted bones
local function build_bones(ctx, all)
    local els = joints_of(call(ctx, "get_Transform"))
    if not els then
        local go = call(ctx, "get_GameObject")
        els = go and joints_of(call(go, "get_Transform"))
    end
    if not els then return {} end

    local info = {}
    for _, j in ipairs(els) do
        local a = addr_of(j)
        if a then
            local n = call(j, "get_Name")
            local p = call(j, "get_Parent") or call(j, "get_ParentJoint")
            info[a] = {
                j = j,
                parent = p and addr_of(p) or nil,
                keep = all or wanted(n and tostring(n):lower() or ""),
            }
        end
    end

    local bones = {}
    for _, i in pairs(info) do
        if i.keep and #bones < 160 then
            local pa, hops = i.parent, 0
            while pa and info[pa] and not info[pa].keep and hops < 12 do
                pa = info[pa].parent
                hops = hops + 1
            end
            if pa and info[pa] and info[pa].keep then
                bones[#bones + 1] = { i.j, info[pa].j }
            end
        end
    end
    return bones
end

local cache, frame = {}, 0
local stat = { enemies = 0, bones = 0 }

local function bones_for(ctx)
    local a = addr_of(ctx)
    if not a then return nil end
    local c = cache[a]
    if not c or c.main ~= cfg.main_only
       or (frame - c.at) > ((#c.bones > 0) and 900 or 90) then
        local b = build_bones(ctx, false)
        if #b == 0 and cfg.main_only then b = build_bones(ctx, true) end   -- unknown naming: show everything
        c = { bones = b, at = frame, main = cfg.main_only }
        cache[a] = c
    end
    c.seen = frame
    return c.bones
end

-- projection: same math as the ESP box, camera/screen read once per frame
local vp0, vp1, vp2, vp3, scr_w, scr_h
local function begin_projection()
    vp0 = nil
    local cam = sdk.get_primary_camera()
    if not cam then return false end
    local vp = call(cam, "get_ViewProjMatrix")
    if not vp then return false end
    local ok, mv = pcall(sdk.call_native_func, sm, sm_td, "get_MainView")
    if not ok or not mv then return false end
    local ok2, sz = pcall(function() return mv:get_WindowSize() end)
    if not ok2 or not sz then return false end
    vp0, vp1, vp2, vp3 = vp[0], vp[1], vp[2], vp[3]
    scr_w, scr_h = sz.w, sz.h
    return true
end

local function w2s(pos)
    local x, y, z = pos.x, pos.y, pos.z
    local cx = vp0.x * x + vp1.x * y + vp2.x * z + vp3.x
    local cy = vp0.y * x + vp1.y * y + vp2.y * z + vp3.y
    local cw = vp0.w * x + vp1.w * y + vp2.w * z + vp3.w
    if cw <= 0.001 then return nil end
    local sx = (1 + cx / cw) * 0.5 * scr_w
    local sy = (1 - cy / cw) * 0.5 * scr_h
    if sx < -200 or sx > scr_w + 200 or sy < -200 or sy > scr_h + 200 then return nil end
    return sx, sy
end

local function draw_skeleton(ctx)
    local bones = bones_for(ctx)
    if not bones then return end
    local pts = {}
    local function pt(j)
        local v = pts[j]
        if v == nil then
            local p = call(j, "get_Position")
            if p then
                local sx, sy = w2s(p)
                v = sx and { sx, sy } or false
            else
                v = false
            end
            pts[j] = v
        end
        return v
    end
    local n = 0
    local col = ZENO.col(cfg.color, cfg.color_rb)
    for _, b in ipairs(bones) do
        local a, c = pt(b[1]), pt(b[2])
        if a and c then
            draw.line(a[1], a[2], c[1], c[2], col)
            n = n + 1
        end
    end
    stat.bones = stat.bones + n
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function draw_list(list, ppos)
    if not list then return end
    local ok_n, count = pcall(function() return list:get_Count() end)
    if not ok_n or not count then return end
    for i = 0, count - 1 do
        local ok_c, ctx = pcall(function() return list:get_Item(i) end)
        if ok_c and ctx then
            local ok_p, pos = pcall(function() return ctx:get_Position() end)
            if ok_p and pos and (math.abs(pos.x) > 0.01 or math.abs(pos.z) > 0.01) then
                if not ppos or dist3(ppos, pos) <= cfg.max_dist then
                    stat.enemies = stat.enemies + 1
                    draw_skeleton(ctx)
                end
            end
        end
    end
end

re.on_frame(function()
    if not cfg.enabled then return end
    frame = frame + 1
    stat.enemies, stat.bones = 0, 0

    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return end
    if not begin_projection() then return end

    local ppos
    local ok_pc, pc = pcall(function() return mgr:getPlayerContextRef() end)
    if ok_pc and pc then
        local ok_pp, pp = pcall(function() return pc:get_Position() end)
        if ok_pp then ppos = pp end
    end

    if cfg.enemies then
        local ok, list = pcall(function() return mgr:get_field(ENEMY_FIELD) end)
        if ok then draw_list(list, ppos) end
    end
    if cfg.npcs then
        local ok, list = pcall(function() return mgr:get_field(NPC_FIELD) end)
        if ok then draw_list(list, ppos) end
    end

    if frame % 1800 == 0 then
        for a, c in pairs(cache) do
            if frame - (c.seen or 0) > 1800 then cache[a] = nil end
        end
    end
end)

zui("Skeleton ESP", function()
    if not imgui.tree_node("Skeleton ESP (real bones)") then return end
    local c, v
    c, v = imgui.checkbox("Enable skeleton ESP", cfg.enabled);   if c then cfg.enabled = v end
    c, v = imgui.checkbox("Enemies",             cfg.enemies);   if c then cfg.enemies = v end
    c, v = imgui.checkbox("NPCs",                cfg.npcs);      if c then cfg.npcs = v end
    c, v = imgui.checkbox("Main bones only",     cfg.main_only); if c then cfg.main_only = v end
    c, v = imgui.slider_float("Max distance (m)", cfg.max_dist, 5, 300, "%.0f")
    if c then cfg.max_dist = v end
    c, v = zeno_color_rb("Color", cfg.color, cfg, "color_rb"); if c then cfg.color = v end
    imgui.text(string.format("Drawing %d enemies, %d bones", stat.enemies, stat.bones))
    imgui.tree_pop()
end)

end

-- ===================== WORLD =====================
do
-- World: game speed (slow motion / super speed) and freeze enemies.
-- Speed uses via.Application.set_GlobalSpeed, so it scales the WHOLE world
-- (enemies included). Freeze uses GameObject.set_UpdateSelf(false).
local CFG_PATH = "zeno_world.json"

local cfg = {
    slow_motion    = false,
    slow_speed     = 0.3,
    super_speed    = false,
    fast_speed     = 2.0,
    freeze_enemies = false,
}

do
    local ok, data = pcall(json.load_file, CFG_PATH)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
        end
    end
end
re.on_config_save(function() pcall(json.dump_file, CFG_PATH, cfg) end)
ZENO.cfg.world = cfg

local app_td = sdk.find_type_definition("via.Application")
local app    = sdk.get_native_singleton("via.Application")

local function get_speed()
    local ok, v = pcall(sdk.call_native_func, app, app_td, "get_GlobalSpeed")
    if ok and type(v) == "number" then return v end
    return nil
end
local function set_speed(v)
    pcall(sdk.call_native_func, app, app_td, "set_GlobalSpeed", v)
end

local speed_active = false
local frozen = {}          -- [address] = GameObject we switched off
local tick = 0

local function each_enemy(fn)
    local mgr = sdk.get_managed_singleton("app.CharacterManager")
    if not mgr then return end
    local ok, list = pcall(function() return mgr:get_field("<EnemyContextList>k__BackingField") end)
    if not ok or not list then return end
    local ok_n, n = pcall(function() return list:get_Count() end)
    if not ok_n or not n then return end
    for i = 0, n - 1 do
        local ok_c, ctx = pcall(function() return list:get_Item(i) end)
        if ok_c and ctx then
            local ok_g, go = pcall(function() return ctx:get_GameObject() end)
            if ok_g and go then fn(go) end
        end
    end
end

re.on_frame(function()
    -- game speed (super speed wins if both are on)
    local want
    if cfg.super_speed then want = cfg.fast_speed
    elseif cfg.slow_motion then want = cfg.slow_speed end

    if want then
        local cur = get_speed()
        if not cur or cur > 0.0001 then   -- leave real pauses alone
            set_speed(want)
        end
        speed_active = true
    elseif speed_active then
        set_speed(1.0)
        speed_active = false
    end

    -- freeze enemies (also catches new spawns)
    tick = tick + 1
    if cfg.freeze_enemies then
        if tick % 10 == 0 then
            each_enemy(function(go)
                local ok, a = pcall(function() return go:get_address() end)
                if ok and a and not frozen[a] then
                    local ok2 = pcall(function() go:call("set_UpdateSelf", false) end)
                    if ok2 then frozen[a] = go end
                end
            end)
        end
    elseif next(frozen) ~= nil then
        for a, go in pairs(frozen) do
            pcall(function() go:call("set_UpdateSelf", true) end)
            frozen[a] = nil
        end
    end
end)

zui("World", function()
    if not imgui.tree_node("World") then return end
    local c, v
    c, v = imgui.checkbox("Slow motion", cfg.slow_motion); if c then cfg.slow_motion = v end
    c, v = imgui.slider_float("Slow speed", cfg.slow_speed, 0.05, 1.0, "%.2f")
    if c then cfg.slow_speed = v end
    c, v = imgui.checkbox("Super speed", cfg.super_speed); if c then cfg.super_speed = v end
    c, v = imgui.slider_float("Fast speed", cfg.fast_speed, 1.0, 5.0, "%.2f")
    if c then cfg.fast_speed = v end
    c, v = imgui.checkbox("Freeze enemies", cfg.freeze_enemies); if c then cfg.freeze_enemies = v end
    imgui.tree_pop()
end)

end

-- ===================== DEV TOOLS =====================
do
-- Dev tools: dump a game type's members and log consumed item names, so new
-- features can be wired against the real RE9 names. Output goes to
-- reframework/data/ (zeno_dump_<type>.json, zeno_items.json).
local type_name = "app.ItemManager"

local function dump(name)
    local td = sdk.find_type_definition(name)
    if not td then return false, "type not found" end
    local out = { type = name, methods = {}, fields = {} }
    local ok_p, parent = pcall(function() return td:get_parent_type() end)
    if ok_p and parent then
        local ok_n, pn = pcall(function() return parent:get_full_name() end)
        if ok_n then out.parent = pn end
    end
    local ok_m, ms = pcall(function() return td:get_methods() end)
    if ok_m and ms then
        for _, m in ipairs(ms) do
            local ok, n = pcall(function() return m:get_name() end)
            if ok and n then out.methods[#out.methods + 1] = n end
        end
    end
    local ok_f, fs = pcall(function() return td:get_fields() end)
    if ok_f and fs then
        for _, f in ipairs(fs) do
            local ok, n = pcall(function() return f:get_name() end)
            local okt, ft = pcall(function() return f:get_type():get_full_name() end)
            if ok and n then out.fields[#out.fields + 1] = n .. " : " .. (okt and tostring(ft) or "?") end
        end
    end
    local fname = "zeno_dump_" .. name:gsub("[^%w_]", "_") .. ".json"
    pcall(json.dump_file, fname, out)
    return true, fname
end

local last_msg = ""
zui("Dev tools", function()
    if not imgui.tree_node("Dev tools") then return end
    local pc = ZENO.cfg.panel
    local c, v = imgui.checkbox("Log consumed item names (zeno_items.json)", pc.log_items)
    if c then pc.log_items = v end
    local ch, nv = imgui.input_text("Type to dump", type_name)
    if ch then type_name = nv end
    if imgui.button("Dump type") then
        local ok, msg = dump(type_name)
        last_msg = ok and ("wrote " .. msg) or ("failed: " .. msg)
    end
    if last_msg ~= "" then imgui.text(last_msg) end
    imgui.tree_pop()
end)

end

-- ===================== BULLET TRACERS =====================
do
-- A line from roughly the gun to where you are aiming, drawn while you hold
-- fire (left mouse / right trigger) and fading out over "life" seconds.
local CFG_PATH = "zeno_tracer.json"

local tracer = {
    enabled   = false,
    color     = 0xFF00FFFF,
    color_rb  = false,
    life      = 0.6,
    thickness = 2,
    interval  = 0.07,
}
do
    local ok, data = pcall(json.load_file, CFG_PATH)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if tracer[k] ~= nil and type(tracer[k]) == type(v) then tracer[k] = v end
        end
    end
end
re.on_config_save(function() pcall(json.dump_file, CFG_PATH, tracer) end)
ZENO.cfg.tracer = tracer

local function pc(o, m, ...)
    local a = { ... }
    local ok, r = pcall(function() return o:call(m, table.unpack(a)) end)
    if ok then return r end
    return nil
end

-- same projection the box ESP uses; matrix and screen size read once per frame
local VP, SW, SH
local function refresh_view()
    VP, SW, SH = nil, nil, nil
    local cam = sdk.get_primary_camera()
    if not cam then return end
    local ok, vp = pcall(function() return cam:call("get_ViewProjMatrix") end)
    if not ok or not vp then return end
    local w, h = ZENO.screen_size()
    if not w then return end
    VP, SW, SH = vp, w, h
end
local function w2s(x, y, z)
    if not VP then return nil end
    local v0, v1, v2, v3 = VP[0], VP[1], VP[2], VP[3]
    local cx = v0.x * x + v1.x * y + v2.x * z + v3.x
    local cy = v0.y * x + v1.y * y + v2.y * z + v3.y
    local cw = v0.w * x + v1.w * y + v2.w * z + v3.w
    if cw <= 0.001 then return nil end
    local sx = (1 + cx / cw) * 0.5 * SW
    local sy = (1 - cy / cw) * 0.5 * SH
    if sx < -3000 or sx > SW + 3000 or sy < -3000 or sy > SH + 3000 then return nil end
    return { x = sx, y = sy }
end

local stat = { shots = 0, fire = false, fail = 0 }
local shots, last_shot = {}, 0

local function spawn_shot(now)
    local cam = sdk.get_primary_camera()
    local cgo = cam and pc(cam, "get_GameObject")
    local ctf = cgo and pc(cgo, "get_Transform")
    local cp  = ctf and pc(ctf, "get_Position")
    local az  = ctf and pc(ctf, "get_AxisZ")
    local ax  = ctf and pc(ctf, "get_AxisX")
    local ay  = ctf and pc(ctf, "get_AxisY")
    local sh = { t = now }
    if cp and az and ax and ay and VP then
        -- which sign of AxisZ points where the camera looks (checked on screen)
        local v0, v1, v2, v3 = VP[0], VP[1], VP[2], VP[3]
        local cw = v0.w * (cp.x + az.x * 5) + v1.w * (cp.y + az.y * 5) + v2.w * (cp.z + az.z * 5) + v3.w
        local fs = (cw > 0) and 1 or -1
        local fx, fy, fz = az.x * fs, az.y * fs, az.z * fs
        sh.b = { x = cp.x + fx * 60, y = cp.y + fy * 60, z = cp.z + fz * 60 }
        sh.a = { x = cp.x + fx * 1.0 + ax.x * 0.25 - ay.x * 0.22,
                 y = cp.y + fy * 1.0 + ax.y * 0.25 - ay.y * 0.22,
                 z = cp.z + fz * 1.0 + ax.z * 0.25 - ay.z * 0.22 }
    else
        stat.fail = stat.fail + 1       -- no camera data: draw a 2D tracer so something shows
        sh.flat = true
    end
    shots[#shots + 1] = sh
    stat.shots = stat.shots + 1
    if #shots > 40 then table.remove(shots, 1) end
end

local last_msg = ""
re.on_frame(function()
    if not tracer.enabled then
        if #shots > 0 then shots = {} end
        return
    end
    local ok, err = pcall(function()
        refresh_view()
        local now = os.clock()
        local fire = ZENO.fire_held and ZENO.fire_held() or false
        stat.fire = fire
        if fire and now - last_shot >= tracer.interval then
            last_shot = now
            spawn_shot(now)
        end
        local th = math.max(1, math.floor(tracer.thickness))
        local base = ZENO.col(tracer.color, tracer.color_rb)
        local keep = {}
        for _, s in ipairs(shots) do
            local age = now - s.t
            if age <= tracer.life then
                keep[#keep + 1] = s
                local fade = 1.0 - age / tracer.life
                local col = (base & 0x00FFFFFF) | (math.floor(255 * fade) << 24)
                local x1, y1, x2, y2
                if s.flat then
                    x1, y1, x2, y2 = SW * 0.62, SH * 0.85, SW * 0.5, SH * 0.5
                else
                    local sa = w2s(s.a.x, s.a.y, s.a.z)
                    local sb = w2s(s.b.x, s.b.y, s.b.z)
                    if sa and sb then x1, y1, x2, y2 = sa.x, sa.y, sb.x, sb.y end
                end
                if x1 then
                    for t = 0, th - 1 do
                        local d = t - (th - 1) * 0.5
                        draw.line(x1 + d, y1, x2 + d, y2, col)
                        draw.line(x1, y1 + d, x2, y2 + d, col)
                    end
                end
            end
        end
        shots = keep
    end)
    if not ok then last_msg = "tracer error: " .. tostring(err) end
end)

zui("Bullet tracers", function()
    if not imgui.tree_node("Bullet tracers") then return end
    local c, v
    c, v = imgui.checkbox("Bullet tracers", tracer.enabled); if c then tracer.enabled = v end
    c, v = zeno_color_rb("Tracer color", tracer.color, tracer, "color_rb"); if c then tracer.color = v end
    c, v = imgui.slider_float("Tracer life (s)", tracer.life, 0.1, 3.0, "%.2f"); if c then tracer.life = v end
    c, v = imgui.slider_int("Tracer thickness", tracer.thickness, 1, 6); if c then tracer.thickness = v end
    imgui.text(string.format("  fire button seen: %s   tracers: %d   no-camera fallbacks: %d",
        stat.fire and "yes" or "no", stat.shots, stat.fail))
    if imgui.button("Test tracer") then refresh_view(); spawn_shot(os.clock()) end
    if last_msg ~= "" then imgui.text(last_msg) end
    imgui.tree_pop()
end)

end

--=====================================================================
-- Unified UI + exe link
--
-- The exe is the menu. It writes zeno_bridge.json (all settings) and a
-- heartbeat (zeno_host.json) into reframework/data/. zeno_loader.lua sets
-- host.alive from that heartbeat. No heartbeat = every feature is off.
--=====================================================================

re.on_draw_ui(function()
    if not imgui.collapsing_header("Zeno Menu") then return end
    if not host.alive then
        imgui.text("Waiting for the Zeno exe...")
        return
    end
    for _, m in ipairs(UI) do
        local ok, err = pcall(m.fn)
        if not ok then log.error("[Zeno] UI error in " .. m.name .. ": " .. tostring(err)) end
    end
end)

local function coerce(old, v)
    local t = type(old)
    if t == "boolean" then
        if type(v) == "number" then return v ~= 0 end
        if type(v) == "string" then return v == "true" or v == "1" end
        return v and true or false
    elseif t == "number" then
        local n = tonumber(v)
        if n and math.type(old) == "integer" then
            return math.tointeger(n) or math.floor(n + 0.5)
        end
        return n
    end
    return nil
end

local function split(path)
    return path:match("^(%w+)%.(.+)$")
end

function ZENO.get(path)
    local m, k = split(path)
    local c = m and ZENO.cfg[m]
    return c and c[k]
end

function ZENO.set(path, v)
    local m, k = split(path)
    local c = m and ZENO.cfg[m]
    if not c or c[k] == nil then return false end
    local nv = coerce(c[k], v)
    if nv == nil then return false end
    c[k] = nv
    return true
end

function ZENO.toggle(path)
    local cur = ZENO.get(path)
    if type(cur) ~= "boolean" then return false end
    return ZENO.set(path, not cur)
end

function ZENO.keys()
    local out = {}
    for m, c in pairs(ZENO.cfg) do
        for k, v in pairs(c) do
            if type(v) == "boolean" or type(v) == "number" then
                out[#out + 1] = m .. "." .. k
            end
        end
    end
    table.sort(out)
    return out
end

-- every switch that actually does something; forced off with no exe
local KILL = {
    "panel.infinite_health", "panel.god_mode", "panel.auto_parry", "panel.one_hit_kill",
    "panel.enable_headshot", "panel.auto_headshot", "panel.max_damage",
    "panel.infinite_ammo", "panel.no_reload", "panel.no_recoil", "panel.no_spread",
    "panel.infinite_axe", "panel.infinite_grenades", "panel.infinite_flashbangs",
    "panel.infinite_mines", "panel.infinite_throwables", "panel.infinite_injector",
    "panel.infinite_healing", "panel.log_items",
    "aim.enabled", "esp.enabled", "skel.enabled",
    "world.slow_motion", "world.super_speed", "world.freeze_enemies",
    "tracer.enabled",
}
local function kill_all()
    for _, k in ipairs(KILL) do ZENO.set(k, false) end
end
kill_all()   -- nothing runs until the exe says so

local was_alive, bridge_last, tick = false, {}, 0
re.on_frame(function()
    if host.alive then
        if not was_alive then
            was_alive, bridge_last = true, {}   -- re-apply the exe's full state
        end
        tick = tick + 1
        if tick % 6 == 0 then
            local ok, data = pcall(json.load_file, "zeno_bridge.json")
            if ok and type(data) == "table" then
                for k, v in pairs(data) do
                    if bridge_last[k] ~= v then
                        ZENO.set(k, v)
                        bridge_last[k] = v
                    end
                end
            end
        end
        if tick % 90 == 0 then
            pcall(json.dump_file, "zeno_status.json", { alive = true, t = os.time() })
        end
    elseif was_alive then
        was_alive = false
        kill_all()
    end
end)

log.info("[Zeno] menu loaded (inert until the exe heartbeat is seen)")
