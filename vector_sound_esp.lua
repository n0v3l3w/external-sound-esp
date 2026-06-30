-- Localize frequently used globals for faster lookup
local math_sin = math.sin
local math_cos = math.cos
local math_abs = math.abs
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local string_format = string.format
local ipairs = ipairs
local pairs = pairs

menu.add_tab("Visualiser", "V")
menu.add_group("Visualiser", "Settings")
menu.add_checkbox("Visualiser", "Settings", "vis_enabled", "Enable Visualiser", true)
menu.add_combo("Visualiser", "Settings", "vis_style", "Style", {"HUD Bars", "3D ESP Rings"}, 1, { parent = "vis_enabled" })
menu.add_colorpicker("Visualiser", "Settings", "vis_color", "Color", {0, 1, 0.5, 1}, { parent = "vis_enabled" })

local active_sounds = {}
local recent_sounds = {}

local BAR_COUNT     = 30
local BAR_WIDTH     = 10
local BAR_GAP       = 4
local BAR_TOTAL_W   = (BAR_COUNT * BAR_WIDTH) + ((BAR_COUNT - 1) * BAR_GAP)
local BAR_Y_OFFSET  = 100
local BAR_MIN_H     = 5
local BAR_MAX_SCALE = 80
local MAX_VOL_CLAMP = 3

local FADE_TIME        = 15.0
local RING_BASE_R      = 15
local RING_PULSE_SCALE = 25
local RING_SEGMENTS    = 32
local RING_THICKNESS   = 2

local draw_color = {0, 0, 0, 0}

local last_cleanup = 0
local CLEANUP_INTERVAL = 2.0

local function get_distance(p1, p2)
    local dx, dy, dz = p1.x - p2.x, p1.y - p2.y, p1.z - p2.z
    return math_sqrt(dx * dx + dy * dy + dz * dz)
end

local function scan_for_sounds()
    if not menu.get("vis_enabled") then return end

    local found = {}
    local count = 0

    for _, player in ipairs(entity.get_players()) do
        local char = player.character
        if utility.is_valid(char) then
            for _, inst in ipairs(char:get_descendants()) do
                if inst:is_a("Sound") then
                    count = count + 1
                    found[count] = inst
                end
            end
        end
    end

    active_sounds = found
end

thread.create(scan_for_sounds, 2000)

function on_frame()
    if not menu.get("vis_enabled") then return end

    local style = menu.get("vis_style")
    local color = menu.get_color("vis_color")
    local current_time = utility.get_time()

    local playing_count = 0
    local total_vol = 0
    local n = #active_sounds
    local i = 1

    while i <= n do
        local snd = active_sounds[i]

        if not utility.is_valid(snd) then
            active_sounds[i] = active_sounds[n]
            active_sounds[n] = nil
            n = n - 1
        else
            local volume = snd.Volume or 1

            if memory.read(snd.Address + 344, "byte") == 1 and volume > 0.000001 then
                playing_count = playing_count + 1
                total_vol = total_vol + volume

                local parent = snd.Parent
                if utility.is_valid(parent) and parent:is_a("BasePart") then
                    local key = parent.Address
                    local entry = recent_sounds[key]
                    if entry then
                        entry.parent = parent
                        entry.last_played = current_time
                        entry.vol = volume
                        entry.name = snd.Name
                        entry.last_pos = parent.Position
                    else
                        recent_sounds[key] = {
                            parent = parent,
                            last_played = current_time,
                            vol = volume,
                            name = snd.Name,
                            max_dist = snd.RollOffMaxDistance or 10000,
                            last_pos = parent.Position
                        }
                    end
                end
            end
            i = i + 1
        end
    end

    if current_time - last_cleanup > CLEANUP_INTERVAL then
        last_cleanup = current_time
        for key, data in pairs(recent_sounds) do
            if not utility.is_valid(data.parent) or (current_time - data.last_played) > FADE_TIME then
                recent_sounds[key] = nil
            end
        end
    end

    if style == 0 and playing_count > 0 then
        local scr_w, scr_h = draw.get_screen_size()
        local start_x = (scr_w - BAR_TOTAL_W) * 0.5
        local base_y  = scr_h - BAR_Y_OFFSET
        local vol_scale = math_min(total_vol, MAX_VOL_CLAMP)

        for j = 1, BAR_COUNT do
            local t = current_time * (2 + j * 0.3) + j
            local noise  = math_abs(math_sin(t)) * math_abs(math_cos(current_time * 4 - j))
            local height = BAR_MIN_H + noise * BAR_MAX_SCALE * vol_scale

            local bx = start_x + (j - 1) * (BAR_WIDTH + BAR_GAP)
            draw.rect_filled(bx, base_y - height, BAR_WIDTH, height, color, 3)
        end

        local text = "Playing Sounds: " .. playing_count
        local tw = draw.get_text_size(text, 14)
        draw.text(scr_w * 0.5 - tw * 0.5, base_y + 20, text, color)
    end

    if style == 1 then
        local local_player = entity.get_local_player()
        local local_pos = nil
        if local_player and utility.is_valid(local_player.character) then
            local_pos = local_player.position
        end

        local c1, c2, c3, c4 = color[1], color[2], color[3], color[4]

        for addr, data in pairs(recent_sounds) do
            local time_quiet = current_time - data.last_played

            if time_quiet > FADE_TIME then goto continue_loop end

            local target_pos = data.last_pos
            if not target_pos then goto continue_loop end

            if local_pos and get_distance(target_pos, local_pos) > data.max_dist then
                goto continue_loop
            end

            local sx, sy, on_screen = draw.world_to_screen(target_pos.x, target_pos.y, target_pos.z)

            if on_screen then
                local alpha = 1.0 - (math_max(0, time_quiet) / FADE_TIME)

                draw_color[1] = c1
                draw_color[2] = c2
                draw_color[3] = c3
                draw_color[4] = c4 * alpha

                local radius = RING_BASE_R + math_abs(math_sin(current_time * 8 + addr)) * RING_PULSE_SCALE * data.vol

                draw.circle(sx, sy, radius, draw_color, RING_SEGMENTS, RING_THICKNESS)

                local text = string_format("%s (Vol: %.1f)", data.name, data.vol)
                local tw = draw.get_text_size(text, 12)
                draw.text(sx - tw * 0.5, sy - radius - 15, text, draw_color)
            end

            ::continue_loop::
        end
    end
end