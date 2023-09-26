--[[
Edita (sincroniza) el archivo de subtitulo SRT desde MPV

Basado en el scripts "fix_sub_timing":
https://github.com/wiiaboo/mpv-scripts/blob/master/fix-sub-timing.lua

Adaptación por Alfredo Hantsch, Marzo 2019

El ajuste se realiza mediante múltiples "marcas de referencia" (interpolación lineal).

Modo de uso (todo se realiza dentro de MPV):

a) Ir al inicio de la película, por ejemplo al punto donde debe aparecer el primer subtitulo
   Poner la pausa y ajustar el delay del subtitulo con las herramientas de MPV:
   z (add delay), x (add delay negativo), ctrl+z (sub-step -1), ctrl+x (sub-step 1).
   
b) Presionar el shortcut (ctrl+m) para agregar una nueva marca de referencia 

c) Repetir los pasos a) y b) en varios puntos de la pelicula (cuantos más mejor)

d) Presionar el shortcut para procesar el archivo (ctrl+s)

El script edita el archivo SRT, ajusta el delay de MPV a cero y recarga el archivo SRT (corregido)

]]

local utils = require 'mp.utils'

-- log file para debbuging
local logfile = "/home/alfredo/.config/mpv/fix-sub-timing.log"

-- convierte formato SubRip (hora, minuto, segundo, milisegundo) a segundos
function conv_srtTime2sec(h, m, s, ms)
    local vh = tonumber(h)
    local vm = tonumber(m)
    local vs = tonumber(s)
    local vms = tonumber(ms)
    return vms / 1000 + vs + vm * 60 + vh * 3600
end

-- convierte segundos a formato SubRip (hora, minuto, segundo, milisegundo)
function conv_sec2srtTime(sec)
    local ms = math.floor(sec * 1000 + 0.5)  -- milisegundos (enteros)
    local st_ms = math.fmod(ms, 1000)
    local segundos = (ms - st_ms) / 1000
    local st_s = math.fmod(segundos, 60)
    segundos = segundos - st_s
    local st_m = math.fmod((segundos / 60), 60)
    local st_h = (segundos - st_m * 60) / 3600
    return string.format("%02d:%02d:%02d,%03d", st_h, st_m, st_s, st_ms)
end

-- funcion auxiliar para comprobar si un archivo existe
function file_exists(filename)
    local file = io.open(filename, "r")
    if file then
        file:close()
        return true
    else
        return false
    end
end

-- escribe una linea de texto en archivo (append). Especial para logging
function write_txt_to_file(txt, filename)
    local file = io.open(filename, "a")

    if not file then
        msg.error("Unable to open file for appending: " .. filename)
        return
    end

    file:write(txt .. "\n")
    file:close()
end

-- retorna el nombre del archivo de subtitulo cargado
-- esta función es necesaria porque no hay una propiedad ad-hoc para esto
-- TODO: probar con "path" y "sub-file-paths" relativos
function get_srt_filename()
    local srt_filename = mp.get_property_native("filename/no-ext") .. ".srt"
    
    --primero busca en la misma carpeta que el video
    local path = mp.get_property_native("path")
    local dir, filename = utils.split_path(path)
    local srt_fullname = utils.join_path(dir, srt_filename)
    
    if file_exists(srt_fullname) then
        return srt_fullname
    end

    --si no lo encuentra busca en las carpetas de subtitulos configuradas en mpv.conf
    for key,dir in pairs(mp.get_property_native("sub-file-paths")) do
        srt_fullname = utils.join_path(dir, srt_filename)
        
        if file_exists(srt_fullname) then
            return srt_fullname
        end
    end

    -- no se encontró
    return false
end

-- auxiliar para ordenar elementos de una tabla
function sort_x(a, b)
    return a.x < b.x
end

-- edita el archivo srt
function edit_srt_file()
    -- ordena la lista de marcas de referencia
    table.sort(mref, sort_x)

    -- lee el archivo SRT completo y lo pone en tabla "arr_lines"
    local file = io.open(srt_filename, "r")
    local arr_lines = {}
    for line in file:lines() do
        table.insert (arr_lines, line)
    end
    file:close()
    
    -- recorre la tabla buscando rangos de tiempo a editar
    for key, val in pairs(arr_lines) do
        local h1, m1, s1, ms1, h2, m2, s2, ms2 = string.match(val, "(%d%d):(%d%d):(%d%d),(%d%d%d) %-%-> (%d%d):(%d%d):(%d%d),(%d%d%d)")
        if h1 then
            local sec1 = conv_srtTime2sec(h1, m1, s1, ms1)
            local sec2 = conv_srtTime2sec(h2, m2, s2, ms2)
            
            sec1 = get_fixed_time(sec1)
            sec2 = get_fixed_time(sec2)
            
            -- guarda en la tabla el nuevo rango de tiempos (editado)
            arr_lines[key] = string.format("%s --> %s", conv_sec2srtTime(sec1), conv_sec2srtTime(sec2))
        end
    end
    
    --renombra el archivo srt original (para backup)
    local ret = os.rename(srt_filename, srt_filename .. ".bak")
    
    if not ret then
        mp.osd_message("Error al renombrar el archivo SRT (para backup)", 10)
        return false
    end

    -- guarda archivo SRT con el mismo nombre (reemplaza al anterior)
    file = io.open(srt_filename, "w")
    if not file then
        mp.osd_message("Error al escribir archivo: " .. srt_filename, 10)
        return false
    end
    file:write(table.concat(arr_lines, "\n"))
    file:close()

    mp.osd_message(srt_filename .. "\n" .. #arr_lines .. " lineas editadas con éxito.", 10)
    return true  -- todo OK
end

-- retorna el tiempo, corregido
-- la tabla mref (marcas de referencia) tiene que tener al menos dos elementos y deben estar ordenados en x
function get_fixed_time(tsec)
    -- cantidad de marcas de referencia
    local n = #mref

    -- antes que la primera marca de referencia
    if tsec < mref[1].x then
        return mref[1].y - (mref[2].y - mref[1].y) * (mref[1].x - tsec) / (mref[2].x - mref[1].x)
    end

    -- despues de la ultima marca de referencia
    if tsec > mref[n].x then
        return mref[n].y + (mref[n].y - mref[n-1].y) * (tsec - mref[n].x) / (mref[n].x - mref[n-1].x)
    end

    -- entre dos marcas de referencia (i, j)
    for i = 1, n-1 do
        local j = i + 1
        if mref[i].x <= tsec and mref[j].x >= tsec then
             return mref[i].y + (mref[j].y - mref[i].y) * (tsec - mref[i].x) / (mref[j].x - mref[i].x)
        end
    end
end


-- almacena una nueva "marca de referencia". Se ejecuta al presionar "ctrl-m"
-- esta función debe invocarse al menos dos veces antes de hacer la corrección
function sub_marca_referencia()
    -- inicializa variables la primera vez que se invoca
    if #mref == 0 then
        srt_filename = get_srt_filename()
        if not srt_filename then
            mp.osd_message("Error: No se encuentra el archivo de subtitulos", 10)
            return
        end
    end

    -- obtiene los tiempos de subtitulo y video
    local sub_delay = mp.get_property_native("sub-delay")
    local vid_time = mp.get_property_native("playback-time")
    local sub_speed = mp.get_property_native("sub-speed")
    local sub_time = (vid_time - sub_delay) / sub_speed

    -- evita marcas duplicadas (mismo horario)
    for key, val in pairs(mref) do
        if math.abs(vid_time - val.y) < 0.5 then
            mp.osd_message("Error: Marca de referencia duplicada o muy próximas entre sí.\nPor favor seleccionar otro punto.", 10)
            return
        end
    end
    
    --guarda la marca de referencia
    table.insert(mref, { x = sub_time , y = vid_time })
    
    mp.osd_message("Marca de referencia numero " .. tostring(#mref) .. " realizada con éxito", 5)
end

-- se ejecuta al presionar "ctrl-s"
function sub_fix_external_srt()
    if #mref < 2 then
        mp.osd_message("Error: Antes de modificar el archivo SRT debe crear al menos dos marcas de referencia.", 10)
        return
    end
    
    -- ajusta el timing del archivo SRT
    mp.osd_message("Procesando...", 10)    

    -- log to file (debug)
    write_txt_to_file(srt_filename .. "\n" .. utils.to_string(mref) .. "\n", logfile)

    local ret = edit_srt_file()
    if not ret then
        return
    end

    -- recarga el archivo SRT recien editado
    mp.command("sub-reload")

    -- Delay y Speed a los valores nominales
    mp.set_property_native("sub-delay", 0.0)
    mp.set_property_native("sub-speed", 1.0)
    
    -- reinicializa por las dudas haya que volver a ajustar
    mref = {}
end

-- lista de marcas de referencia
mref = {}

mp.add_key_binding("ctrl+m", "sub-marca-referencia", sub_marca_referencia)
mp.add_key_binding("ctrl+s", "sub-fix-external-srt", sub_fix_external_srt)



