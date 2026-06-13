-- SmartThings Edge Driver: Fellow Stagg EKG Pro  ·  MARK-VIII
-- Protocolo verificado EN VIVO contra el firmware real de la tetera:
--   * Encender → cmd=2 (botón dial): único comando que enciende el calentador
--                de verdad (la temp sube). Es toggle: solo enviar si está apagada.
--   * Apagar   → ss S_Off (set state): directo e idempotente, sin ambigüedad.
--   * ss S_Heat → DESCARTADO: pone la etiqueta de modo pero NO calienta (ho=0).
--   * Set temp → setsetting settempr <°F entero> (directo) + verificación,
--                con ajuste fino por dial (q/w, pasos de 0.5°C) como respaldo.
--   * tempr lee ~3°C sobre el agua real → se resta el offset.
-- Robustez: tolera fallos transitorios (la tetera enmudece varios segundos
--   durante las transiciones) antes de marcar offline.

local capabilities = require "st.capabilities"
local Driver       = require "st.driver"
local cosock       = require "cosock"
local log          = require "log"
local http         = cosock.asyncify "socket.http"
local ltn12        = require "ltn12"

-- ─── Constants ────────────────────────────────────────────────────────────────

local VERSION       = "MARK-VIII"
local DEFAULT_IP    = "192.168.1.100"   -- example; set the real IP in device preferences
local HTTP_TIMEOUT  = 5
local POLL_DEFAULT  = 10
local TEMP_OFFSET   = 3.0
local TEMP_MIN_C    = 40.0
local TEMP_MAX_C    = 100.0
local OFFLINE_AFTER = 3       -- fallos de poll consecutivos antes de marcar offline

http.TIMEOUT = HTTP_TIMEOUT

-- Modos que significan "apagado". Cualquier otro modo = encendido (lista negra
-- para ser robusto ante nombres de modo desconocidos de otros firmwares).
local OFF_MODES = { S_Off = true, S_Stby = true, S_Standby = true }

-- ─── HTTP helper ──────────────────────────────────────────────────────────────

local function kettle_get(ip, cmd)
    local url    = string.format("http://%s/cli?cmd=%s", ip, (cmd or "state"):gsub(" ", "+"))
    local body_t = {}
    local ok, code = http.request({
        url    = url,
        method = "GET",
        sink   = ltn12.sink.table(body_t),
        create = function()
            local sock = cosock.socket.tcp()
            sock:settimeout(HTTP_TIMEOUT)
            return sock
        end,
    })
    if ok and code == 200 then
        return table.concat(body_t), nil
    else
        return nil, tostring(code or "no response")
    end
end

-- ─── Preferences ──────────────────────────────────────────────────────────────

local function get_ip(device)
    return (device.preferences and device.preferences.ipAddress ~= "" and device.preferences.ipAddress)
        or DEFAULT_IP
end

local function get_poll_interval(device)
    local v = device.preferences and device.preferences.pollInterval
    if type(v) == "number" and v >= 10 then return v end
    return POLL_DEFAULT
end

local function alert_enabled(device)
    if device.preferences and device.preferences.alertOnReach ~= nil then
        return device.preferences.alertOnReach
    end
    return true
end

-- ─── Protocol parsing ─────────────────────────────────────────────────────────

local function parse_state(body)
    if not body or #body == 0 then return nil end
    local raw_temp = tonumber(body:match("tempr=([%d%.]+)"))
    local tgt      = tonumber(body:match("temprT=([%d%.]+)"))
    local mode     = body:match("mode=(%S+)")
    if not mode then return nil end
    local current  = raw_temp and (raw_temp - TEMP_OFFSET) or nil
    log.debug(string.format("[parse] mode=%s raw=%s tgt=%s",
        mode, tostring(raw_temp), tostring(tgt)))
    return {
        current_temp = current,           -- nil si la tetera está fuera de la base
        target_temp  = tgt,
        mode         = mode,
        is_heating   = not OFF_MODES[mode],
        docked       = current ~= nil,
    }
end

local function read_state(ip)
    local body, err = kettle_get(ip, "state")
    if err or not body then return nil, err end
    local s = parse_state(body)
    if not s then return nil, "parse failed" end
    return s, nil
end

-- ─── State cache ──────────────────────────────────────────────────────────────

local dev_cache = {}

local function get_cache(device_id)
    if not dev_cache[device_id] then
        dev_cache[device_id] = { initialized = false, fail_count = 0 }
    end
    return dev_cache[device_id]
end

-- ─── Emit helpers ─────────────────────────────────────────────────────────────

local function emit_power(device, heating)
    if heating then
        device:emit_event(capabilities.switch.switch.on())
        device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.heating())
    else
        device:emit_event(capabilities.switch.switch.off())
        device:emit_event(capabilities.thermostatOperatingState.thermostatOperatingState.idle())
    end
end

-- ─── Device update (poll) ─────────────────────────────────────────────────────

local function update_device(driver, device)
    local cache = get_cache(device.id)
    if cache.cmd_in_progress then return false end

    local ip     = get_ip(device)
    local s, err = read_state(ip)

    if not s then
        -- Tolerar fallos transitorios: la tetera enmudece durante transiciones.
        cache.fail_count = (cache.fail_count or 0) + 1
        log.warn(string.format("[%s] poll fail %d/%d: %s",
            device.label or device.id, cache.fail_count, OFFLINE_AFTER, tostring(err)))
        if cache.fail_count >= OFFLINE_AFTER and not device:get_field("is_offline") then
            device:offline()
            device:set_field("is_offline", true)
        end
        return false
    end

    cache.fail_count = 0
    if device:get_field("is_offline") then
        device:online()
        device:set_field("is_offline", false)
    end

    local prev  = cache
    local first = not prev.initialized

    if first then
        device:emit_event(capabilities.thermostatOperatingState.supportedThermostatOperatingStates(
            { "heating", "idle" }, { visibility = { displayed = false } }))
        device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpointRange(
            { value = { minimum = TEMP_MIN_C, maximum = TEMP_MAX_C }, unit = "C" },
            { visibility = { displayed = false } }))
    end

    -- Temperatura actual (si está en la base). Si no, conservamos la última.
    if s.current_temp then
        local rounded = math.floor(s.current_temp * 10 + 0.5) / 10
        if first or rounded ~= prev.current_temp then
            device:emit_event(capabilities.temperatureMeasurement.temperature({
                value = rounded, unit = "C"
            }))
        end
        s.current_temp = rounded
    else
        s.current_temp = prev.current_temp   -- fuera de la base: mantener último valor
    end

    if s.target_temp then
        local tgt = math.floor(s.target_temp * 10 + 0.5) / 10
        if first or tgt ~= prev.target_temp then
            device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({
                value = tgt, unit = "C"
            }))
        end
        s.target_temp = tgt
    end

    if first or (s.is_heating ~= prev.is_heating) then
        emit_power(device, s.is_heating)
    end

    -- Alarma: transición a S_Hold (llegó a temperatura y mantiene)
    local new_temp_reached = prev.temp_reached or (first and s.mode == "S_Hold")
    if alert_enabled(device) then
        if not first and s.mode == "S_Hold" and prev.mode ~= "S_Hold" and not prev.temp_reached then
            log.info(string.format("[%s] Temperatura alcanzada (%.1f°C)",
                device.label or device.id, s.current_temp or 0))
            device:emit_event(capabilities.temperatureAlarm.temperatureAlarm.heat())
            new_temp_reached = true
        elseif prev.temp_reached and s.mode ~= "S_Hold" then
            device:emit_event(capabilities.temperatureAlarm.temperatureAlarm.cleared())
            new_temp_reached = false
        end
    end

    dev_cache[device.id] = {
        initialized     = true,
        fail_count      = 0,
        current_temp    = s.current_temp,
        target_temp     = s.target_temp,
        is_heating      = s.is_heating,
        mode            = s.mode,
        docked          = s.docked,
        temp_reached    = new_temp_reached,
        cmd_in_progress = false,
    }

    return true
end

-- ─── Polling ──────────────────────────────────────────────────────────────────

local function start_polling(driver, device)
    local existing = device:get_field("poll_timer")
    if existing then driver:cancel_timer(existing) end

    local interval = get_poll_interval(device)
    local timer = driver:call_on_schedule(interval, function()
        update_device(driver, device)
    end, "poll_" .. device.id)
    device:set_field("poll_timer", timer)

    log.info(string.format("[%s] polling every %ds @ %s",
        device.label or device.id, interval, get_ip(device)))

    cosock.spawn(function()
        update_device(driver, device)
    end, "init_poll_" .. device.id)
end

-- ─── Power control ────────────────────────────────────────────────────────────

-- ENCENDER: cmd=2 solo si está apagada (es toggle). Verifica que arrancó.
local function power_on(driver, device)
    local ip    = get_ip(device)
    local cache = get_cache(device.id)
    cache.cmd_in_progress = true

    local function finish()
        cache.cmd_in_progress = false
        update_device(driver, device)
    end

    local s = read_state(ip)
    if s and s.is_heating then
        log.info(string.format("[%s] ya está encendida", device.label or device.id))
        finish(); return
    end

    for attempt = 1, 3 do
        log.info(string.format("[%s] ON → cmd=2 (intento %d)",
            device.label or device.id, attempt))
        local _, err = kettle_get(ip, "2")
        if err then log.error("[on] " .. err); finish(); return end
        for _ = 1, 6 do
            cosock.socket.sleep(0.5)
            s = read_state(ip)
            if s and s.is_heating then
                log.info(string.format("[%s] encendida confirmada (mode=%s)",
                    device.label or device.id, s.mode))
                cache.temp_reached = false
                finish(); return
            end
        end
    end
    log.warn(string.format("[%s] no se confirmó el encendido", device.label or device.id))
    finish()
end

-- APAGAR: ss S_Off (directo, idempotente). Verifica con reintentos.
local function power_off(driver, device)
    local ip    = get_ip(device)
    local cache = get_cache(device.id)
    cache.cmd_in_progress = true

    local function finish()
        cache.cmd_in_progress = false
        update_device(driver, device)
    end

    for attempt = 1, 3 do
        log.info(string.format("[%s] OFF → ss S_Off (intento %d)",
            device.label or device.id, attempt))
        local _, err = kettle_get(ip, "ss S_Off")
        if err then log.error("[off] " .. err); finish(); return end
        cosock.socket.sleep(0.6)
        local s = read_state(ip)
        if s and not s.is_heating then
            log.info(string.format("[%s] apagada confirmada (mode=%s)",
                device.label or device.id, s.mode))
            cache.temp_reached = false
            finish(); return
        end
    end
    log.warn(string.format("[%s] no se confirmó el apagado", device.label or device.id))
    finish()
end

local function handle_on(driver, device, cmd)
    emit_power(device, true)
    device:emit_event(capabilities.temperatureAlarm.temperatureAlarm.cleared())
    cosock.spawn(function() power_on(driver, device) end, "on_" .. device.id)
end

local function handle_off(driver, device, cmd)
    emit_power(device, false)
    device:emit_event(capabilities.temperatureAlarm.temperatureAlarm.cleared())
    cosock.spawn(function() power_off(driver, device) end, "off_" .. device.id)
end

-- ─── Setpoint control ─────────────────────────────────────────────────────────

-- Directo: setsetting settempr <°F entero>. Verifica leyendo temprT.
-- Respaldo: ajuste fino por dial (q/w) si el directo no clavó el valor.
local function set_target(driver, device, target_c)
    local ip    = get_ip(device)
    local cache = get_cache(device.id)
    cache.cmd_in_progress = true

    local function finish()
        cache.cmd_in_progress = false
        update_device(driver, device)
    end

    -- 1) Intento directo en °F
    local target_f = math.floor(target_c * 9 / 5 + 32 + 0.5)
    log.info(string.format("[%s] SET %.1f°C → setsetting settempr %d°F",
        device.label or device.id, target_c, target_f))
    kettle_get(ip, string.format("setsetting settempr %d", target_f))
    cosock.socket.sleep(0.4)

    local s = read_state(ip)
    if s and s.target_temp and math.abs(target_c - s.target_temp) < 0.6 then
        log.info(string.format("[%s] setpoint directo OK: %.1f°C",
            device.label or device.id, s.target_temp))
        cache.temp_reached = false
        finish(); return
    end

    -- 2) Respaldo: ajuste fino por dial (pasos de 0.5°C)
    log.info(string.format("[%s] afinando con dial (target real=%s)",
        device.label or device.id, s and tostring(s.target_temp) or "?"))
    for _ = 1, 12 do
        s = read_state(ip)
        if not s or not s.target_temp then break end
        local diff = target_c - s.target_temp
        if math.abs(diff) < 0.1 then
            log.info(string.format("[%s] setpoint afinado: %.1f°C",
                device.label or device.id, s.target_temp))
            cache.temp_reached = false
            finish(); return
        end
        local clicks = math.min(math.max(math.floor(math.abs(diff) / 0.5 + 0.5), 1), 10)
        local key = (diff > 0) and "w" or "q"
        for _ = 1, clicks do kettle_get(ip, key) end
        cosock.socket.sleep(0.3)
    end

    log.warn(string.format("[%s] no se pudo clavar el setpoint en %.1f°C",
        device.label or device.id, target_c))
    finish()
end

local function handle_set_setpoint(driver, device, cmd)
    local target = math.floor(cmd.args.setpoint * 2 + 0.5) / 2
    target = math.max(TEMP_MIN_C, math.min(TEMP_MAX_C, target))
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({
        value = target, unit = "C"
    }))
    cosock.spawn(function() set_target(driver, device, target) end, "set_temp_" .. device.id)
end

local function handle_refresh(driver, device, cmd)
    cosock.spawn(function() update_device(driver, device) end, "refresh_" .. device.id)
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

local function device_added(driver, device)
    log.info("ADDED: " .. (device.label or device.id))
    dev_cache[device.id] = { initialized = false, fail_count = 0 }
end

local function device_init(driver, device)
    log.info("INIT: " .. (device.label or device.id))
    if not dev_cache[device.id] then
        dev_cache[device.id] = { initialized = false, fail_count = 0 }
    end
    start_polling(driver, device)
end

local function device_removed(driver, device)
    log.info("REMOVED: " .. (device.label or device.id))
    local timer = device:get_field("poll_timer")
    if timer then driver:cancel_timer(timer) end
    dev_cache[device.id] = nil
end

local function info_changed(driver, device, event, args)
    log.info("PREFERENCES CHANGED: " .. (device.label or device.id))
    start_polling(driver, device)
end

-- ─── Discovery ────────────────────────────────────────────────────────────────

local discovered = false

local function discovery_handler(driver, _, should_continue)
    if not should_continue() then return end
    if discovered then return end
    log.info("[discovery] creating Fellow Stagg EKG Pro")
    local ok, err = driver:try_create_device({
        type                  = "LAN",
        device_network_id     = "fellow-stagg-main",
        label                 = "Tetera Fellow Stagg",
        profile               = "fellow-stagg-ekg-pro",
        manufacturer          = "Fellow",
        model                 = "Stagg EKG Pro",
        vendor_provided_label = "Fellow Stagg EKG Pro",
    })
    if ok then
        discovered = true
        log.info("[discovery] device created OK")
    else
        log.error("[discovery] create failed: " .. tostring(err))
    end
end

-- ─── Driver ───────────────────────────────────────────────────────────────────

local driver = Driver("fellow-stagg-ekg-pro", {
    discovery = discovery_handler,

    lifecycle_handlers = {
        added       = device_added,
        init        = device_init,
        removed     = device_removed,
        infoChanged = info_changed,
    },

    capability_handlers = {
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME]  = handle_on,
            [capabilities.switch.commands.off.NAME] = handle_off,
        },
        [capabilities.thermostatHeatingSetpoint.ID] = {
            [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = handle_set_setpoint,
        },
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
        },
    },

    supported_capabilities = {
        capabilities.switch,
        capabilities.temperatureMeasurement,
        capabilities.thermostatHeatingSetpoint,
        capabilities.thermostatOperatingState,
        capabilities.temperatureAlarm,
        capabilities.refresh,
    },
})

log.info("Fellow Stagg EKG Pro driver " .. VERSION .. " starting")
driver:run()
