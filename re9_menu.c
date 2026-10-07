// re9_menu.c  -  Resident Evil 9 (re9.exe) overlay menu  ("Zeno Menu")
// Build: gcc re9_menu.c -o re9_menu.exe -lgdi32 -luser32 -mwindows
//
// Run the exe any time. It idles until re9.exe is running, then HOME toggles
// the menu as an overlay on top of the game window. END (menu open) exits.
//
// Every toggle / slider / color here drives the Lua (zeno_menu.lua) through
// <game>\reframework\data\zeno_bridge.json. The exe also writes a heartbeat
// (zeno_host.json); without it the Lua forces every feature off, so the Lua
// only works while THIS exe is running.
//
// Put zeno_menu.lua next to this exe. On attach the exe installs it to
// <game>\reframework\zeno\ and drops the tiny loader into reframework\autorun\.

#include <windows.h>
#include <math.h>
#include <windowsx.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>

// --- Target game --------------------------------------------------------------
#define GAME_EXE     "re9.exe"
#define TOGGLE_VK    VK_HOME
#define EXIT_VK      VK_END
#define HOST_ID      "zeno_exe_v1"      // must match zeno_loader.lua

// --- Layout -------------------------------------------------------------------
#define WIN_W        540
#define WIN_H        600
#define TITLE_BAR_H   32
#define TAB_H         30
#define TAB_COUNT      8
#define ITEM_H         36
#define ITEM_PAD       12
#define TOGGLE_W       38
#define TOGGLE_H       18
#define SLIDER_H        6

// --- Colors -------------------------------------------------------------------
#define C_KEY         RGB(255,   0, 255)   // transparent key color for the overlay
#define C_BG          RGB(12,  12,  18)
#define C_PANEL       RGB(18,  18,  28)
#define C_TITLEBAR    RGB(20,  14,  44)
#define C_ACCENT      RGB(90,  60, 200)
#define C_ACCENT_HOT  RGB(130, 90, 255)
#define C_TEXT        RGB(220, 220, 235)
#define C_MUTED       RGB(100, 100, 130)
#define C_GREEN       RGB(60,  200, 100)
#define C_RED         RGB(220,  60,  60)
#define C_ON          RGB(80,  200, 120)
#define C_OFF         RGB(50,   50,  80)
#define C_ROW_HOT     RGB(28,   28,  52)
#define C_ROW_NORM    RGB(18,   18,  30)
#define C_BORDER      RGB(40,   40,  65)
#define C_SEP         RGB(28,   28,  45)
#define C_KNOB        RGB(240, 240, 255)
#define C_SLIDER_BG   RGB(30,   30,  50)
#define C_SLIDER_FG   RGB(90,   60, 200)
#define C_TAB_ACT     RGB(90,   60, 200)
#define C_TAB_INACT   RGB(22,   22,  36)
#define C_ACCENT_LINE RGB(110,  70, 230)

#define FEAT_TOGGLE  0
#define FEAT_SLIDER  1
#define FEAT_COLOR   2

// One row in the menu. `key` is the Lua setting it drives ("module.setting");
// NULL means the row is exe-only (Settings tab).
typedef struct {
    bool        enabled;     // toggle state
    float       value;       // slider position 0..1
    char        label[64];
    char        sub[64];
    char        keybind[8];
    int         type;
    const char *key;
    float       lo, hi;      // slider range sent to the Lua
    int         is_int;      // slider sends an integer
    int         palette;     // color row: selected swatch
} Feature;

#define TOG(label, sub, key, init) \
    { (init), 0.0f, label, sub, "", FEAT_TOGGLE, key, 0.0f, 0.0f, 0, 0 }
#define SLD(label, key, lo, hi, isint, init) \
    { false, ((init) - (lo)) / ((hi) - (lo)), label, "", "", FEAT_SLIDER, key, lo, hi, isint, 0 }
#define COL(label, key, idx) \
    { false, 0.0f, label, "", "", FEAT_COLOR, key, 0.0f, 0.0f, 0, idx }

static const char *tab_names[TAB_COUNT] = {
    "PLAYER", "WEAPONS", "AIMBOT", "ESP", "SKELETON", "WORLD", "SETTINGS", "INFO"
};
#define TAB_PLAYER   0
#define TAB_WEAPONS  1
#define TAB_AIMBOT   2
#define TAB_ESP      3
#define TAB_SKELETON 4
#define TAB_WORLD    5
#define TAB_SETTINGS 6
#define TAB_INFO     7

// Swatches for color rows (COLORREF 0x00BBGGRR == the Lua's 0xAABBGGRR minus alpha)
#define PAL_N 8
#define PAL_SLOTS (PAL_N + 1)   // slot PAL_N = animated rainbow (sends "<key>_rb": true)
static const COLORREF palette[PAL_N] = {
    RGB(255,255,255), RGB(255, 60, 60), RGB( 60,255, 60), RGB( 70,130,255),
    RGB(255,230, 60), RGB( 60,240,255), RGB(255, 80,220), RGB(255,150, 40)
};

// --- PLAYER: panel.* in the Lua -----------------------------------------------
enum { P_GOD, P_HEALTH, P_PARRY, P_OHK, P_HS, P_HSMULT, P_AUTOHS, P_MAXDMG, P_DMGMULT };
static Feature player[] = {
    TOG("God Mode",           "Invincible, no damage taken",     "panel.god_mode",        false),
    TOG("Infinite Health",    "Health locked at max",            "panel.infinite_health", false),
    TOG("Auto Parry",         "Every incoming hit is parried",   "panel.auto_parry",      false),
    TOG("One Hit Kill",       "Any hit kills (all enemies)",     "panel.one_hit_kill",    false),
    TOG("Headshot Boost",     "Multiplies headshot damage",      "panel.enable_headshot", false),
    SLD("Headshot Multiplier", "panel.headshot_mult", 1.0f, 20.0f, 1, 2.0f),
    TOG("Auto Headshot",      "Every hit counts as a head hit",  "panel.auto_headshot",   false),
    TOG("Max Weapon Damage",  "Multiplies every hit",            "panel.max_damage",      false),
    SLD("Weapon Damage Multiplier", "panel.damage_mult", 1.0f, 50.0f, 1, 5.0f),
};
#define PLAYER_N (int)(sizeof(player)/sizeof(player[0]))

// --- WEAPONS: panel.* in the Lua ----------------------------------------------
static Feature weapons[] = {
    TOG("Infinite Ammo",      "Guns and rocket launcher",        "panel.infinite_ammo",       false),
    TOG("No Reload",          "Magazine is never consumed",      "panel.no_reload",           false),
    TOG("No Recoil",          "Steady aim",                      "panel.no_recoil",           false),
    TOG("No Spread",          "Bullets go where you aim",        "panel.no_spread",           false),
    TOG("Infinite Axe",       "Axe and handle never break",      "panel.infinite_axe",        false),
    TOG("Infinite Grenades",  "Grenades, molotovs, flashes",     "panel.infinite_grenades",   false),
    TOG("Infinite Flashbangs","Flashbangs are not consumed",     "panel.infinite_flashbangs", false),
    TOG("Infinite Mines",     "Mines are not consumed",          "panel.infinite_mines",      false),
    TOG("Infinite Throwables","All throwables",                  "panel.infinite_throwables", false),
    TOG("Infinite Injector",  "Hemolytic injector",              "panel.infinite_injector",   false),
    TOG("Infinite Healing",   "Healing items are not consumed",  "panel.infinite_healing",    false),
};
#define WEAPONS_N (int)(sizeof(weapons)/sizeof(weapons[0]))

// --- AIMBOT: aim.* in the Lua -------------------------------------------------
static Feature aimbot[] = {
    TOG("Aimbot",             "Master switch",                   "aim.enabled",         false),
    TOG("Hold To Aim",        "Only while aiming (RMB / LT)",    "aim.require_hold",    true),
    TOG("Gamepad Aim",        "Aim with the pad trigger",        "aim.gamepad_enabled", true),
    TOG("Only Inside Circle", "Targets must be in the FOV circle","aim.fov_enabled",    true),
    TOG("Draw FOV Circle",    "Show the circle on screen",       "aim.fov_show",        true),
    SLD("Circle Size (px)",   "aim.fov_radius",    20.0f, 1000.0f, 0, 220.0f),
    SLD("Circle Thickness",   "aim.fov_thickness",  1.0f,    6.0f, 1, 2.0f),
    COL("Circle Color",       "aim.fov_color",      0),
    SLD("Aim Strength",       "aim.strength",       0.01f,   1.0f, 0, 1.0f),
    SLD("Max Distance (m)",   "aim.max_distance",   5.0f,  100.0f, 0, 25.0f),
    TOG("Prefer Head",        "Head over body / weak points",    "aim.prefer_upper",    true),
    TOG("Skip Dead",          "Ignore dead enemies",             "aim.skip_dead",       true),
};
#define AIMBOT_N (int)(sizeof(aimbot)/sizeof(aimbot[0]))

// --- ESP: esp.* in the Lua (boxes only; skeleton is its own tab) -------------
static Feature esp[] = {
    TOG("ESP",                "Master switch",                   "esp.enabled",         false),
    TOG("Enemy Box",          "Box around enemies",              "esp.show_enemy",      true),
    TOG("NPC Box",            "Box around NPCs",                 "esp.show_npc",        false),
    TOG("Self Marker",        "[SELF] tag on you",               "esp.show_self",       false),
    TOG("Enemy Counter",      "Enemy / NPC count on screen",     "esp.show_counter",    false),
    SLD("ESP Distance (m)",   "esp.max_dist",       5.0f,  500.0f, 0, 100.0f),
    COL("Enemy Box Color",    "esp.box_color",      2),
    COL("NPC Box Color",      "esp.npc_color",      5),
    TOG("Enemy Lines",        "Line to zombie heads",            "esp.show_lines",      false),
    COL("Enemy Line Color",   "esp.line_color",     5),
    TOG("NPC Lines",          "Line to NPC heads",               "esp.show_npc_lines",  false),
    COL("NPC Line Color",     "esp.npc_line_color", 2),
    TOG("Bullet Tracers",     "Line from gun to where you aim",  "tracer.enabled",      false),
    COL("Tracer Color",       "tracer.color",       5),
};
#define ESP_N (int)(sizeof(esp)/sizeof(esp[0]))

// --- SKELETON: skel.* in the Lua (real bones, independent of the ESP) --------
static Feature skeleton[] = {
    TOG("Skeleton ESP",       "Real bones, follows movement",    "skel.enabled",        false),
    TOG("Enemies",            "Draw enemy skeletons",            "skel.enemies",        true),
    TOG("NPCs",               "Draw NPC skeletons",              "skel.npcs",           false),
    TOG("Main Bones Only",    "Off = every bone in the rig",     "skel.main_only",      true),
    SLD("Skeleton Distance (m)", "skel.max_dist",   5.0f,  300.0f, 0, 60.0f),
    COL("Skeleton Color",     "skel.color",         0),
    SLD("Rainbow Speed",      "rainbow.speed",      0.05f,   2.0f, 0, 0.35f),
};
#define SKELETON_N (int)(sizeof(skeleton)/sizeof(skeleton[0]))

// --- WORLD: world.* in the Lua ------------------------------------------------
enum { W_SLOW, W_SLOWV, W_FAST, W_FASTV, W_FREEZE };
static Feature world[] = {
    TOG("Slow Motion",        "Slows the whole world",           "world.slow_motion",    false),
    SLD("Slow Speed",         "world.slow_speed",   0.05f,   1.0f, 0, 0.3f),
    TOG("Super Speed",        "Speeds the whole world up",       "world.super_speed",    false),
    SLD("Fast Speed",         "world.fast_speed",   1.0f,    5.0f, 0, 2.0f),
    TOG("Freeze Enemies",     "Enemies stop updating",           "world.freeze_enemies", false),
};
#define WORLD_N (int)(sizeof(world)/sizeof(world[0]))

// settings[] drive real behavior in this file (see update_overlay / timer)
static Feature settings[] = {
    TOG("Lock Position",       "Disable title-bar dragging", NULL, false),
    TOG("Hide When Unfocused", "Hide if game loses focus",   NULL, true),
    { false, 0.8f, "Menu Opacity", "Overlay alpha", "", FEAT_SLIDER, NULL, 0.0f, 1.0f, 0, 0 },
};
#define SETTINGS_N (int)(sizeof(settings)/sizeof(settings[0]))
#define SET_LOCK     0
#define SET_FOCUS    1
#define SET_OPACITY  2

// --- State --------------------------------------------------------------------
static int   active_tab  = 0;
static bool  dragging    = false;
static POINT drag_cursor0 = {0, 0};
static int   drag_menu_x0 = 0, drag_menu_y0 = 0;
static int   drag_slider = -1;
static int   drag_tab    = -1;
static HWND  g_hwnd      = NULL;

static int   menu_x = 40;
static int   menu_y = 40;

static HFONT g_font = NULL, g_font_sm = NULL, g_font_bold = NULL;
static POINT g_mouse   = {0, 0};     // menu-local coordinates
static bool  g_clicked = false;

// game tracking
static DWORD g_pid       = 0;
static HWND  g_game      = NULL;
static bool  menu_open   = false;
static bool  overlay_shown = false;
static int   ov_x = 0, ov_y = 0, ov_w = 0, ov_h = 0;
static BYTE  last_alpha  = 0;
static int   win_px = -99999, win_py = -99999;   // where the window currently is
static DWORD unfocus_since = 0;
static HDC     g_mem = NULL;
static HBITMAP g_mem_bmp = NULL, g_mem_old = NULL;

// Lua link
static char  g_data_dir[MAX_PATH]   = "";   // <game>\reframework\data\  (empty = unknown)
static char  g_game_dir[MAX_PATH]   = "";
static char  g_install_msg[96]      = "";
static bool  g_lua_linked           = false;
static DWORD g_last_pid             = 0;
static char  g_bridge_last[8192]    = "";

// --- Embedded loader (identical to zeno_loader.lua) -----------------------------
static const char LOADER_LUA[] =
    "-- zeno_loader.lua  (installed into reframework/autorun/ by the Zeno exe)\n"
    "-- Inert on its own: sets ZENO_HOST and loads the real menu from\n"
    "-- reframework/zeno/zeno_menu.lua. ZENO_HOST.alive follows the exe heartbeat\n"
    "-- (zeno_host.json); without it the menu forces every feature off.\n"
    "\n"
    "local HOST_FILE = \"zeno_host.json\"\n"
    "local MENU_PATH = \"reframework/zeno/zeno_menu.lua\"\n"
    "\n"
    "ZENO_HOST = { id = \"zeno_exe_v1\", alive = false }\n"
    "\n"
    "local function fresh()\n"
    "    local ok, d = pcall(json.load_file, HOST_FILE)\n"
    "    if not ok or type(d) ~= \"table\" then return false end\n"
    "    if d.id ~= \"zeno_exe_v1\" or type(d.t) ~= \"number\" then return false end\n"
    "    return math.abs(os.time() - d.t) <= 3\n"
    "end\n"
    "\n"
    "local f = io.open(MENU_PATH, \"r\")\n"
    "if f then\n"
    "    local src = f:read(\"*a\")\n"
    "    f:close()\n"
    "    local fn, err = load(src, \"@zeno_menu.lua\")\n"
    "    if fn then\n"
    "        local ok, e = pcall(fn)\n"
    "        if not ok then log.error(\"[Zeno] menu error: \" .. tostring(e)) end\n"
    "    else\n"
    "        log.error(\"[Zeno] menu parse error: \" .. tostring(err))\n"
    "    end\n"
    "else\n"
    "    log.warn(\"[Zeno] \" .. MENU_PATH .. \" not found\")\n"
    "end\n"
    "\n"
    "local tick = 0\n"
    "re.on_frame(function()\n"
    "    tick = tick + 1\n"
    "    if tick % 20 == 0 then ZENO_HOST.alive = fresh() end\n"
    "end)\n";

// --- GDI helpers --------------------------------------------------------------
// hue cycles ~0.35x per second, same default speed as the Lua side
static COLORREF rainbow_now(double offset) {
    double h = fmod(GetTickCount() / 1000.0 * 0.35 + offset, 1.0) * 6.0;
    int i = (int)h;
    double f = h - i, q = 1.0 - f;
    double r, g, b;
    switch (i) {
        case 0:  r = 1; g = f; b = 0; break;
        case 1:  r = q; g = 1; b = 0; break;
        case 2:  r = 0; g = 1; b = f; break;
        case 3:  r = 0; g = q; b = 1; break;
        case 4:  r = f; g = 0; b = 1; break;
        default: r = 1; g = 0; b = q; break;
    }
    return RGB((int)(r * 255), (int)(g * 255), (int)(b * 255));
}

static HBRUSH br(COLORREF c)        { return CreateSolidBrush(c); }
static HPEN   pn(COLORREF c, int w) { return CreatePen(PS_SOLID, w, c); }

static void fill_rect_col(HDC hdc, int x, int y, int w, int h, COLORREF c) {
    HBRUSH b = br(c);
    RECT rc  = {x, y, x+w, y+h};
    FillRect(hdc, &rc, b);
    DeleteObject(b);
}

static void draw_rounded(HDC hdc, int x, int y, int w, int h,
                         int rx, COLORREF fill, COLORREF border) {
    HBRUSH b = br(fill);
    HPEN   p = pn(border, 1);
    HBRUSH ob = (HBRUSH)SelectObject(hdc, b);
    HPEN   op = (HPEN)SelectObject(hdc, p);
    RoundRect(hdc, x, y, x+w, y+h, rx, rx);
    SelectObject(hdc, ob);
    SelectObject(hdc, op);
    DeleteObject(b);
    DeleteObject(p);
}

static void draw_text_col(HDC hdc, const char *txt, int x, int y,
                          COLORREF c, HFONT font) {
    HFONT of = (HFONT)SelectObject(hdc, font);
    SetTextColor(hdc, c);
    SetBkMode(hdc, TRANSPARENT);
    TextOutA(hdc, x, y, txt, (int)strlen(txt));
    SelectObject(hdc, of);
}

static int text_w(HDC hdc, const char *txt, HFONT font) {
    HFONT of = (HFONT)SelectObject(hdc, font);
    SIZE sz;
    GetTextExtentPoint32A(hdc, txt, (int)strlen(txt), &sz);
    SelectObject(hdc, of);
    return sz.cx;
}

static void draw_text_right(HDC hdc, const char *txt, int rx, int y,
                            COLORREF c, HFONT font) {
    draw_text_col(hdc, txt, rx - text_w(hdc, txt, font), y, c, font);
}

static void draw_toggle(HDC hdc, int x, int y, bool on) {
    COLORREF bg = on ? C_ON : C_OFF;
    draw_rounded(hdc, x, y, TOGGLE_W, TOGGLE_H, TOGGLE_H, bg, bg);
    int kx = on ? x + TOGGLE_W - TOGGLE_H + 2 : x + 2;
    draw_rounded(hdc, kx, y + 2, TOGGLE_H - 4, TOGGLE_H - 4,
                 TOGGLE_H, C_KNOB, C_KNOB);
}

static void draw_slider(HDC hdc, HFONT font_sm, int x, int y, int w,
                        float val, const char *txt) {
    draw_rounded(hdc, x, y, w, SLIDER_H, SLIDER_H, C_SLIDER_BG, C_SLIDER_BG);
    int filled = (int)(val * (float)w);
    if (filled > 4)
        draw_rounded(hdc, x, y, filled, SLIDER_H, SLIDER_H, C_SLIDER_FG, C_SLIDER_FG);
    draw_rounded(hdc, x + filled - 5, y - 4, 10, SLIDER_H + 8, 4,
                 C_ACCENT_HOT, C_ACCENT_HOT);
    draw_text_right(hdc, txt, x + w, y - 14, C_MUTED, font_sm);
}

static HFONT make_font(int size, bool bold) {
    return CreateFontA(size, 0, 0, 0, bold ? FW_BOLD : FW_NORMAL,
                       FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH | FF_SWISS, "Segoe UI");
}

// slider position -> value the Lua receives
static float slider_real(const Feature *f) {
    float v = f->lo + f->value * (f->hi - f->lo);
    if (f->is_int) v = (float)(int)(v + 0.5f);
    return v;
}

// --- Feature list -------------------------------------------------------------
static void draw_features(HDC hdc, HFONT font, HFONT font_sm,
                          Feature *feats, int count,
                          int px, int py, int pw,
                          int mouse_x, int mouse_y,
                          bool clicked, int tab_id) {
    int y = py + 8;
    for (int i = 0; i < count; i++) {
        Feature *f = &feats[i];
        bool hot = (mouse_x >= px && mouse_x < px + pw &&
                    mouse_y >= y  && mouse_y < y + ITEM_H);

        fill_rect_col(hdc, px, y, pw, ITEM_H, hot ? C_ROW_HOT : C_ROW_NORM);

        if (f->type == FEAT_TOGGLE && f->enabled)
            fill_rect_col(hdc, px, y, 3, ITEM_H, C_ACCENT);

        if (f->type == FEAT_TOGGLE) {
            COLORREF lc = f->enabled ? C_TEXT : C_MUTED;
            draw_text_col(hdc, f->label, px + ITEM_PAD + 4, y + 4, lc, font);
            if (f->sub[0])
                draw_text_col(hdc, f->sub, px + ITEM_PAD + 4, y + ITEM_H - 15,
                              RGB(70,70,105), font_sm);
            if (f->keybind[0]) {
                char kb[16];
                snprintf(kb, sizeof(kb), "[%s]", f->keybind);
                draw_text_right(hdc, kb, px + pw - TOGGLE_W - ITEM_PAD - 6,
                                y + (ITEM_H - 12)/2, RGB(70,70,100), font_sm);
            }
            draw_toggle(hdc, px + pw - TOGGLE_W - ITEM_PAD,
                        y + (ITEM_H - TOGGLE_H) / 2, f->enabled);
            if (clicked && hot)
                f->enabled = !f->enabled;

        } else if (f->type == FEAT_SLIDER) {
            int sx = px + ITEM_PAD + 4;
            int sw = pw - ITEM_PAD * 2 - 8;
            int slab_y = y + ITEM_H - 14;
            char txt[24];

            if (f->key) {
                float r = slider_real(f);
                if (f->is_int || r >= 100.0f) snprintf(txt, sizeof(txt), "%d", (int)(r + 0.5f));
                else                           snprintf(txt, sizeof(txt), "%.2f", r);
            } else {
                snprintf(txt, sizeof(txt), "%d", (int)(f->value * 100.0f));
            }

            draw_text_col(hdc, f->label, sx, y + 6, RGB(160,160,200), font_sm);
            draw_slider(hdc, font_sm, sx, slab_y, sw, f->value, txt);

            if (clicked &&
                mouse_x >= sx && mouse_x <= sx + sw &&
                mouse_y >= slab_y - 6 && mouse_y <= slab_y + SLIDER_H + 6) {
                drag_slider = i;
                drag_tab    = tab_id;
            }
            if (drag_slider == i && drag_tab == tab_id) {
                float nv = (float)(mouse_x - sx) / (float)sw;
                if (nv < 0.0f) nv = 0.0f;
                if (nv > 1.0f) nv = 1.0f;
                f->value = nv;
            }

        } else if (f->type == FEAT_COLOR) {
            const int sz = 18, gap = 6;
            int total = PAL_SLOTS * sz + (PAL_SLOTS - 1) * gap;
            int sx = px + pw - ITEM_PAD - total;
            int sy = y + (ITEM_H - sz) / 2;

            draw_text_col(hdc, f->label, px + ITEM_PAD + 4, y + (ITEM_H - 15) / 2,
                          C_TEXT, font);
            for (int c = 0; c < PAL_SLOTS; c++) {
                int cx = sx + c * (sz + gap);
                bool sel = (c == f->palette);
                COLORREF swatch = palette[c < PAL_N ? c : 0];
                if (c == PAL_N) swatch = rainbow_now(0.0);      // cycling RGB
                draw_rounded(hdc, cx, sy, sz, sz, 4, swatch,
                             sel ? RGB(255,255,255) : C_BORDER);
                if (c == PAL_N) {
                    // second hue band so it reads as "rainbow", not as one color
                    fill_rect_col(hdc, cx + sz / 2, sy + 2, sz / 2 - 2, sz - 4, rainbow_now(0.5));
                }
                if (sel)
                    draw_rounded(hdc, cx - 2, sy - 2, sz + 4, sz + 4, 6,
                                 swatch, RGB(255,255,255));
                if (clicked && mouse_x >= cx && mouse_x < cx + sz &&
                    mouse_y >= sy && mouse_y < sy + sz)
                    f->palette = c;
            }
        }

        fill_rect_col(hdc, px + 4, y + ITEM_H - 1, pw - 8, 1, C_SEP);
        y += ITEM_H;
    }
}

// --- Info tab -----------------------------------------------------------------
static void draw_info(HDC hdc, HFONT font, HFONT font_sm, int px, int py) {
    int y = py + 16;
    char buf[96];

    draw_text_col(hdc, "Resident Evil 9 Menu", px + ITEM_PAD, y,
                  RGB(180,180,220), font);                    y += 28;
    draw_text_col(hdc, "Zeno build 2.1", px + ITEM_PAD, y,
                  C_MUTED, font_sm);                          y += 28;

    fill_rect_col(hdc, px+ITEM_PAD, y, WIN_W-ITEM_PAD*2, 1, C_BORDER); y += 12;

    draw_text_col(hdc, "Game:",   px+ITEM_PAD,    y, C_TEXT, font_sm);
    draw_text_col(hdc, "Resident Evil 9 (" GAME_EXE ")",
                  px+ITEM_PAD+80, y, C_ACCENT_HOT, font_sm);  y += 20;

    snprintf(buf, sizeof(buf), "%s", g_game ? "ATTACHED" : "WAITING");
    draw_text_col(hdc, "Status:", px+ITEM_PAD,    y, C_TEXT, font_sm);
    draw_text_col(hdc, buf,       px+ITEM_PAD+80, y,
                  g_game ? C_GREEN : C_RED, font_sm);         y += 20;

    snprintf(buf, sizeof(buf), "%s", g_lua_linked ? "LINKED" : "WAITING FOR LUA");
    draw_text_col(hdc, "Lua:",    px+ITEM_PAD,    y, C_TEXT, font_sm);
    draw_text_col(hdc, buf,       px+ITEM_PAD+80, y,
                  g_lua_linked ? C_GREEN : C_RED, font_sm);   y += 20;

    snprintf(buf, sizeof(buf), "%lu", (unsigned long)g_pid);
    draw_text_col(hdc, "PID:",    px+ITEM_PAD,    y, C_TEXT, font_sm);
    draw_text_col(hdc, buf,       px+ITEM_PAD+80, y, C_ACCENT_HOT, font_sm); y += 20;

    snprintf(buf, sizeof(buf), "%d x %d", ov_w, ov_h);
    draw_text_col(hdc, "Window:", px+ITEM_PAD,    y, C_TEXT, font_sm);
    draw_text_col(hdc, buf,       px+ITEM_PAD+80, y, C_ACCENT_HOT, font_sm); y += 24;

    if (g_install_msg[0]) {
        draw_text_col(hdc, g_install_msg, px+ITEM_PAD, y, C_MUTED, font_sm);
        y += 20;
    }
    if (g_game && !g_data_dir[0]) {
        draw_text_col(hdc, "REFramework data folder not found.", px+ITEM_PAD, y, C_RED, font_sm);
        y += 20;
    }
    y += 4;

    fill_rect_col(hdc, px+ITEM_PAD, y, WIN_W-ITEM_PAD*2, 1, C_BORDER); y += 12;

    draw_text_col(hdc, "Toggle Menu: [HOME]", px+ITEM_PAD, y, C_MUTED, font_sm); y += 18;
    draw_text_col(hdc, "Exit Overlay: [END]", px+ITEM_PAD, y, C_MUTED, font_sm);
}

// --- Paint --------------------------------------------------------------------
// The window IS the menu (WIN_W x WIN_H), so there is no transparent area and
// nothing to clip. Everything is drawn into a persistent back buffer and
// copied to the window with a single BitBlt, so a half-drawn frame is never
// visible.
static void ensure_backbuffer(HDC ref) {
    if (g_mem) return;
    g_mem     = CreateCompatibleDC(ref);
    g_mem_bmp = CreateCompatibleBitmap(ref, WIN_W, WIN_H);
    g_mem_old = (HBITMAP)SelectObject(g_mem, g_mem_bmp);
}

static void paint(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC real_hdc = BeginPaint(hwnd, &ps);
    ensure_backbuffer(real_hdc);
    HDC hdc = g_mem;

    fill_rect_col(hdc, 0, 0, WIN_W, WIN_H, C_BG);

    // Title bar
    fill_rect_col(hdc, 0, 0, WIN_W, TITLE_BAR_H, C_TITLEBAR);
    fill_rect_col(hdc, 0, TITLE_BAR_H - 2, WIN_W, 2, C_ACCENT_LINE);
    draw_text_col(hdc, "ZENO", 12, 8, RGB(160,100,255), g_font_bold);
    draw_text_col(hdc, "RE9 REQUIEM", 62, 11, RGB(80,60,140), g_font_sm);
    draw_rounded(hdc, WIN_W - 16, 11, 10, 10, 10,
                 g_game ? C_GREEN : C_RED, g_game ? C_GREEN : C_RED);
    draw_text_right(hdc, GAME_EXE, WIN_W - 24, 10, RGB(70,70,110), g_font_sm);

    // Tabs
    int tab_y = TITLE_BAR_H;
    int tw    = WIN_W / TAB_COUNT;
    for (int i = 0; i < TAB_COUNT; i++) {
        int tx = i * tw;
        int w  = (i == TAB_COUNT - 1) ? WIN_W - tx : tw;
        bool act = (i == active_tab);
        fill_rect_col(hdc, tx, tab_y, w, TAB_H, act ? C_TAB_ACT : C_TAB_INACT);
        if (act)
            fill_rect_col(hdc, tx, tab_y + TAB_H - 3, w, 3, C_ACCENT_LINE);
        int lw = text_w(hdc, tab_names[i], g_font_sm);
        draw_text_col(hdc, tab_names[i], tx + (w - lw)/2, tab_y + (TAB_H - 14)/2,
                      act ? RGB(255,255,255) : C_MUTED, g_font_sm);
        if (i < TAB_COUNT - 1)
            fill_rect_col(hdc, tx + w - 1, tab_y, 1, TAB_H, C_BORDER);
    }

    // Content
    int content_y = TITLE_BAR_H + TAB_H;
    fill_rect_col(hdc, 0, content_y, WIN_W, WIN_H - content_y, C_PANEL);

    {
        HPEN p = pn(C_BORDER, 1);
        HPEN op = (HPEN)SelectObject(hdc, p);
        HBRUSH ob = (HBRUSH)SelectObject(hdc, GetStockObject(NULL_BRUSH));
        Rectangle(hdc, 0, 0, WIN_W, WIN_H);
        SelectObject(hdc, op);
        SelectObject(hdc, ob);
        DeleteObject(p);
    }

    int mx = (int)g_mouse.x, my = (int)g_mouse.y;
    bool cl = g_clicked;
    switch (active_tab) {
        case TAB_PLAYER:   draw_features(hdc,g_font,g_font_sm,player,  PLAYER_N,  0,content_y,WIN_W,mx,my,cl,TAB_PLAYER);   break;
        case TAB_WEAPONS:  draw_features(hdc,g_font,g_font_sm,weapons, WEAPONS_N, 0,content_y,WIN_W,mx,my,cl,TAB_WEAPONS);  break;
        case TAB_AIMBOT:   draw_features(hdc,g_font,g_font_sm,aimbot,  AIMBOT_N,  0,content_y,WIN_W,mx,my,cl,TAB_AIMBOT);   break;
        case TAB_ESP:      draw_features(hdc,g_font,g_font_sm,esp,     ESP_N,     0,content_y,WIN_W,mx,my,cl,TAB_ESP);      break;
        case TAB_SKELETON: draw_features(hdc,g_font,g_font_sm,skeleton,SKELETON_N,0,content_y,WIN_W,mx,my,cl,TAB_SKELETON); break;
        case TAB_WORLD:    draw_features(hdc,g_font,g_font_sm,world,   WORLD_N,   0,content_y,WIN_W,mx,my,cl,TAB_WORLD);    break;
        case TAB_SETTINGS: draw_features(hdc,g_font,g_font_sm,settings,SETTINGS_N,0,content_y,WIN_W,mx,my,cl,TAB_SETTINGS); break;
        case TAB_INFO:     draw_info(hdc,g_font,g_font_sm,0,content_y); break;
    }

    BitBlt(real_hdc, 0, 0, WIN_W, WIN_H, hdc, 0, 0, SRCCOPY);
    EndPaint(hwnd, &ps);
    g_clicked = false;

    // a click flips state while drawing; repaint once so the new state shows
    if (cl) InvalidateRect(hwnd, NULL, FALSE);
}

static void inval_menu(HWND h) {
    InvalidateRect(h, NULL, FALSE);
}

static Feature *tab_feats(int tab, int *count) {
    switch (tab) {
        case TAB_PLAYER:   *count = PLAYER_N;   return player;
        case TAB_WEAPONS:  *count = WEAPONS_N;  return weapons;
        case TAB_AIMBOT:   *count = AIMBOT_N;   return aimbot;
        case TAB_ESP:      *count = ESP_N;      return esp;
        case TAB_SKELETON: *count = SKELETON_N; return skeleton;
        case TAB_WORLD:    *count = WORLD_N;    return world;
        case TAB_SETTINGS: *count = SETTINGS_N; return settings;
    }
    *count = 0;
    return NULL;
}

// --- Lua bridge ---------------------------------------------------------------
// One-hit-kill / headshot boost are mutually exclusive in the Lua, and so are
// slow motion / super speed; mirror that here so the switches never disagree.
// Whichever was just turned on wins.
static void sync_rules(void) {
    static bool p_ohk = false, p_slow = false;
    Feature *ohk = &player[P_OHK], *hs = &player[P_HS];
    if (ohk->enabled && hs->enabled) {
        if (ohk->enabled && !p_ohk) hs->enabled = false;
        else                        ohk->enabled = false;
    }
    p_ohk = ohk->enabled;

    Feature *slow = &world[W_SLOW], *fast = &world[W_FAST];
    if (slow->enabled && fast->enabled) {
        if (slow->enabled && !p_slow) fast->enabled = false;
        else                          slow->enabled = false;
    }
    p_slow = slow->enabled;
}

static int build_bridge(char *out, int cap) {
    static Feature *tabs[6];
    static int      cnt[6];
    tabs[0] = player;   cnt[0] = PLAYER_N;
    tabs[1] = weapons;  cnt[1] = WEAPONS_N;
    tabs[2] = aimbot;   cnt[2] = AIMBOT_N;
    tabs[3] = esp;      cnt[3] = ESP_N;
    tabs[4] = skeleton; cnt[4] = SKELETON_N;
    tabs[5] = world;    cnt[5] = WORLD_N;

    int n = snprintf(out, cap, "{\n");
    bool first = true;
    for (int t = 0; t < 6; t++) {
        for (int i = 0; i < cnt[t]; i++) {
            Feature *f = &tabs[t][i];
            if (!f->key) continue;
            char val[32];
            if (f->type == FEAT_TOGGLE) {
                snprintf(val, sizeof(val), "%s", f->enabled ? "true" : "false");
            } else if (f->type == FEAT_SLIDER) {
                float r = slider_real(f);
                if (f->is_int) snprintf(val, sizeof(val), "%d", (int)r);
                else           snprintf(val, sizeof(val), "%.3f", r);
            } else {
                // ABGR with full alpha, same layout as COLORREF
                int pi = (f->palette >= 0 && f->palette < PAL_N) ? f->palette : 0;
                unsigned c = 0xFF000000u | (unsigned)palette[pi];
                snprintf(val, sizeof(val), "%u", c);
            }
            if (n < cap - 80)
                n += snprintf(out + n, cap - n, "%s  \"%s\": %s",
                              first ? "" : ",\n", f->key, val);
            first = false;
            if (f->type == FEAT_COLOR && n < cap - 80)
                n += snprintf(out + n, cap - n, ",\n  \"%s_rb\": %s",
                              f->key, f->palette == PAL_N ? "true" : "false");
        }
    }
    if (n < cap - 4) n += snprintf(out + n, cap - n, "\n}\n");
    return n;
}

static bool write_atomic(const char *path, const char *data, int len) {
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return false;
    size_t w = fwrite(data, 1, (size_t)len, f);
    fclose(f);
    if (w != (size_t)len) { DeleteFileA(tmp); return false; }
    return MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING) != 0;
}

static void push_bridge(bool force) {
    if (!g_data_dir[0]) return;
    char buf[8192];
    int n = build_bridge(buf, sizeof(buf));
    if (!force && strcmp(buf, g_bridge_last) == 0) return;
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%szeno_bridge.json", g_data_dir);
    if (write_atomic(path, buf, n)) {
        strncpy(g_bridge_last, buf, sizeof(g_bridge_last) - 1);
        g_bridge_last[sizeof(g_bridge_last) - 1] = 0;
    }
}

static void write_heartbeat(void) {
    if (!g_data_dir[0]) return;
    char buf[160], path[MAX_PATH];
    int n = snprintf(buf, sizeof(buf), "{\"id\":\"%s\",\"pid\":%lu,\"t\":%lld}\n",
                     HOST_ID, (unsigned long)g_pid, (long long)time(NULL));
    snprintf(path, sizeof(path), "%szeno_host.json", g_data_dir);
    write_atomic(path, buf, n);
}

static void read_link_status(void) {
    g_lua_linked = false;
    if (!g_data_dir[0]) return;
    char path[MAX_PATH], buf[256];
    snprintf(path, sizeof(path), "%szeno_status.json", g_data_dir);
    FILE *f = fopen(path, "rb");
    if (!f) return;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = strstr(buf, "\"t\"");
    if (!p) return;
    p = strchr(p, ':');
    if (!p) return;
    double t = strtod(p + 1, NULL);
    double now = (double)time(NULL);
    g_lua_linked = (t > 0 && now - t >= -3.0 && now - t <= 6.0);
}

// Copy zeno_menu.lua next to the game's REFramework and drop the loader.
static void install_lua(void) {
    g_install_msg[0] = 0;
    if (!g_game_dir[0]) return;

    char exe[MAX_PATH], src[MAX_PATH], dst[MAX_PATH], dir[MAX_PATH];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    char *slash = strrchr(exe, '\\');
    if (slash) slash[1] = 0;
    snprintf(src, sizeof(src), "%szeno_menu.lua", exe);

    snprintf(dir, sizeof(dir), "%sreframework\\zeno", g_game_dir);
    CreateDirectoryA(dir, NULL);
    snprintf(dst, sizeof(dst), "%s\\zeno_menu.lua", dir);
    if (!CopyFileA(src, dst, FALSE)) {
        snprintf(g_install_msg, sizeof(g_install_msg),
                 "zeno_menu.lua must sit next to this exe.");
        return;
    }

    snprintf(dir, sizeof(dir), "%sreframework\\autorun", g_game_dir);
    CreateDirectoryA(dir, NULL);
    snprintf(dst, sizeof(dst), "%s\\zeno_loader.lua", dir);

    bool same = false;
    FILE *f = fopen(dst, "rb");
    if (f) {
        char cur[sizeof(LOADER_LUA) + 8];
        size_t n = fread(cur, 1, sizeof(cur), f);
        fclose(f);
        same = (n == sizeof(LOADER_LUA) - 1 && memcmp(cur, LOADER_LUA, n) == 0);
    }
    if (!same) {
        if (write_atomic(dst, LOADER_LUA, (int)sizeof(LOADER_LUA) - 1))
            snprintf(g_install_msg, sizeof(g_install_msg),
                     "Loader installed: restart game / Reload Scripts.");
        else
            snprintf(g_install_msg, sizeof(g_install_msg), "Could not write loader.");
    } else {
        snprintf(g_install_msg, sizeof(g_install_msg), "Lua installed.");
    }
}

// --- Game tracking ------------------------------------------------------------
static DWORD find_pid(const char *exe) {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, exe) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

typedef struct { DWORD pid; HWND best; long best_area; } FindCtx;

static BOOL CALLBACK enum_cb(HWND h, LPARAM lp) {
    FindCtx *c = (FindCtx *)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != c->pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER))
        return TRUE;
    RECT rc;
    GetClientRect(h, &rc);
    long area = (long)(rc.right - rc.left) * (long)(rc.bottom - rc.top);
    if (area > c->best_area) { c->best = h; c->best_area = area; }
    return TRUE;
}

// <game folder>\ of the running exe, and its reframework\data\ if present
static void locate_game_dirs(DWORD pid) {
    g_game_dir[0] = g_data_dir[0] = 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return;
    char path[MAX_PATH];
    DWORD len = MAX_PATH;
    if (QueryFullProcessImageNameA(h, 0, path, &len)) {
        char *slash = strrchr(path, '\\');
        if (slash) {
            slash[1] = 0;
            snprintf(g_game_dir, sizeof(g_game_dir), "%s", path);
            char data[MAX_PATH];
            snprintf(data, sizeof(data), "%sreframework\\data", path);
            DWORD attr = GetFileAttributesA(data);
            if (attr == INVALID_FILE_ATTRIBUTES) {
                char rf[MAX_PATH];
                snprintf(rf, sizeof(rf), "%sreframework", path);
                if (GetFileAttributesA(rf) != INVALID_FILE_ATTRIBUTES &&
                    CreateDirectoryA(data, NULL))
                    attr = GetFileAttributesA(data);
            }
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY))
                snprintf(g_data_dir, sizeof(g_data_dir), "%s\\", data);
        }
    }
    CloseHandle(h);
}

static void scan_game(void) {
    DWORD pid = find_pid(GAME_EXE);
    if (!pid) {
        g_pid = 0; g_game = NULL;
        g_data_dir[0] = g_game_dir[0] = 0;
        g_lua_linked = false;
        g_last_pid = 0;
        return;
    }
    FindCtx c = { pid, NULL, 0 };
    EnumWindows(enum_cb, (LPARAM)&c);
    g_pid  = pid;
    g_game = c.best;

    if (pid != g_last_pid) {            // fresh attach
        g_last_pid = pid;
        locate_game_dirs(pid);
        install_lua();
        g_bridge_last[0] = 0;
        push_bridge(true);
    }
}

// Window follows the game client area + the menu offset. Moving the window
// (instead of repainting a full-screen transparent overlay) is what removes the
// clipping / flicker.
static void apply_position(void) {
    int x = ov_x + menu_x, y = ov_y + menu_y;
    if (overlay_shown && x == win_px && y == win_py) return;
    win_px = x; win_py = y;
    SetWindowPos(g_hwnd, HWND_TOPMOST, x, y, WIN_W, WIN_H,
                 SWP_NOACTIVATE | SWP_NOSENDCHANGING |
                 (overlay_shown ? 0 : SWP_SHOWWINDOW));
}

static void update_overlay(void) {
    HWND  fg  = GetForegroundWindow();
    DWORD now = GetTickCount();
    bool game_ok   = g_game && IsWindow(g_game) && !IsIconic(g_game);
    bool focus_now = !settings[SET_FOCUS].enabled || fg == g_game || fg == g_hwnd;

    // a brief focus change (alt-tab flicker, game re-grabbing focus) must not
    // hide and re-show the menu
    if (focus_now)           unfocus_since = 0;
    else if (!unfocus_since) unfocus_since = now ? now : 1;
    bool focus = focus_now || (unfocus_since && (now - unfocus_since) < 600);

    bool want = menu_open && game_ok && focus;

    if (!want) {
        if (overlay_shown) {
            ShowWindow(g_hwnd, SW_HIDE);
            overlay_shown = false;
            win_px = win_py = -99999;
        }
        return;
    }

    RECT rc;
    GetClientRect(g_game, &rc);
    POINT o = {0, 0};
    ClientToScreen(g_game, &o);
    int w = rc.right, h = rc.bottom;

    if (o.x != ov_x || o.y != ov_y || w != ov_w || h != ov_h) {
        ov_x = o.x; ov_y = o.y; ov_w = w; ov_h = h;
        if (menu_x > w - WIN_W) menu_x = w - WIN_W;
        if (menu_y > h - WIN_H) menu_y = h - WIN_H;
        if (menu_x < 0) menu_x = 0;
        if (menu_y < 0) menu_y = 0;
    }

    BYTE alpha = (BYTE)(80 + settings[SET_OPACITY].value * 175.0f);
    if (alpha != last_alpha) {
        last_alpha = alpha;
        SetLayeredWindowAttributes(g_hwnd, 0, alpha, LWA_ALPHA);
    }

    bool was_shown = overlay_shown;
    apply_position();
    if (!was_shown) {
        overlay_shown = true;
        InvalidateRect(g_hwnd, NULL, FALSE);
    }
}

// --- Window proc --------------------------------------------------------------
#define TIMER_FAST  1   // hotkey + overlay tracking + bridge
#define TIMER_SCAN  2   // process / window lookup + heartbeat

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        case WM_PAINT:
            paint(hwnd);
            return 0;

        case WM_ERASEBKGND:
            return 1;

        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;

        case WM_SETCURSOR:
            SetCursor(LoadCursor(NULL, IDC_ARROW));
            return TRUE;

        case WM_MOUSEMOVE: {
            g_mouse.x = GET_X_LPARAM(lp);
            g_mouse.y = GET_Y_LPARAM(lp);

            if (drag_slider >= 0) {
                int count = 0;
                Feature *feats = tab_feats(drag_tab, &count);
                if (feats && drag_slider < count) {
                    int sx = ITEM_PAD + 4;
                    int sw = WIN_W - ITEM_PAD * 2 - 8;
                    float nv = (float)((int)g_mouse.x - sx) / (float)sw;
                    if (nv < 0.0f) nv = 0.0f;
                    if (nv > 1.0f) nv = 1.0f;
                    feats[drag_slider].value = nv;
                }
            }

            if (dragging) {
                POINT cur;
                GetCursorPos(&cur);
                menu_x = drag_menu_x0 + (cur.x - drag_cursor0.x);
                menu_y = drag_menu_y0 + (cur.y - drag_cursor0.y);
                if (menu_x > ov_w - WIN_W) menu_x = ov_w - WIN_W;
                if (menu_y > ov_h - WIN_H) menu_y = ov_h - WIN_H;
                if (menu_x < 0) menu_x = 0;
                if (menu_y < 0) menu_y = 0;
                apply_position();
            }
            inval_menu(hwnd);
            return 0;
        }

        case WM_LBUTTONDOWN: {
            int mx = GET_X_LPARAM(lp);
            int my = GET_Y_LPARAM(lp);

            g_mouse.x = mx;
            g_mouse.y = my;
            g_clicked = true;
            SetCapture(hwnd);           // keep slider / title drags alive outside the window

            if (my >= TITLE_BAR_H && my < TITLE_BAR_H + TAB_H) {
                int t = mx / (WIN_W / TAB_COUNT);
                if (t >= TAB_COUNT) t = TAB_COUNT - 1;
                if (t >= 0) {
                    active_tab = t;
                    g_clicked  = false;
                }
            }

            if (my < TITLE_BAR_H && !settings[SET_LOCK].enabled) {
                dragging = true;
                GetCursorPos(&drag_cursor0);
                drag_menu_x0 = menu_x;
                drag_menu_y0 = menu_y;
            }

            inval_menu(hwnd);
            return 0;
        }

        case WM_LBUTTONUP:
            dragging    = false;
            drag_slider = -1;
            drag_tab    = -1;
            ReleaseCapture();
            inval_menu(hwnd);
            return 0;

        case WM_TIMER:
            if (wp == TIMER_SCAN) {
                scan_game();
                if (!g_game) menu_open = false;
                write_heartbeat();
                read_link_status();
                if (overlay_shown) {
                    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                                 SWP_NOREDRAW | SWP_NOSENDCHANGING);
                    inval_menu(hwnd);       // keeps the INFO tab status current
                }
            } else if (wp == TIMER_FAST) {
                static bool hk_prev = false;
                bool down = (GetAsyncKeyState(TOGGLE_VK) & 0x8000) != 0;
                if (down && !hk_prev && g_game) {
                    HWND fg = GetForegroundWindow();
                    if (fg == g_game || fg == hwnd)
                        menu_open = !menu_open;
                }
                hk_prev = down;

                if (menu_open && overlay_shown &&
                    (GetAsyncKeyState(EXIT_VK) & 0x8000)) {
                    DestroyWindow(hwnd);
                    return 0;
                }
                sync_rules();
                push_bridge(false);
                update_overlay();
                { static int anim = 0;
                  if (overlay_shown && (++anim % 4) == 0) inval_menu(hwnd); }   // animated rainbow swatch
            }
            return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

// --- WinMain ------------------------------------------------------------------
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow) {
    (void)hPrev; (void)lpCmd; (void)nShow;

    SetProcessDPIAware();   // overlay pixels must match game pixels

    HANDLE mutex = CreateMutexA(NULL, TRUE, "Global\\RE9MenuOverlay");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    g_font      = make_font(15, false);
    g_font_sm   = make_font(12, false);
    g_font_bold = make_font(15, true);

    WNDCLASSEXA wc = {0};
    wc.cbSize        = sizeof(wc);
    wc.style         = 0;                   // no CS_HREDRAW/VREDRAW: no full repaints on move
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInst;
    wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = "RE9MenuOverlay";
    RegisterClassExA(&wc);

    g_hwnd = CreateWindowExA(
        WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        "RE9MenuOverlay", "RE9 Menu",
        WS_POPUP,
        0, 0, WIN_W, WIN_H,
        NULL, NULL, hInst, NULL
    );

    last_alpha = (BYTE)(80 + settings[SET_OPACITY].value * 175.0f);
    SetLayeredWindowAttributes(g_hwnd, 0, last_alpha, LWA_ALPHA);

    scan_game();
    SetTimer(g_hwnd, TIMER_FAST, 16,  NULL);
    SetTimer(g_hwnd, TIMER_SCAN, 500, NULL);

    MSG msg = {0};
    while (GetMessageA(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    if (g_mem) {
        SelectObject(g_mem, g_mem_old);
        DeleteObject(g_mem_bmp);
        DeleteDC(g_mem);
    }
    DeleteObject(g_font);
    DeleteObject(g_font_sm);
    DeleteObject(g_font_bold);
    if (mutex) CloseHandle(mutex);
    return (int)msg.wParam;
}
