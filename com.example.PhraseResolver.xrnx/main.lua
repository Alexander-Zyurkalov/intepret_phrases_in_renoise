---
--- Phrase Resolver Tool – main.lua
---

local phrase_resolver = require("phrase_resolver")

local RES_SUFFIX = "_res"

--------------------------------------------------------------------------------
-- Notifier management
--------------------------------------------------------------------------------

local watched_pattern_index = nil

--------------------------------------------------------------------------------
-- Track helpers
--------------------------------------------------------------------------------

--- Check if a track name ends with the _res suffix.
local function is_resolved_track(track_name)
    return track_name:sub(-#RES_SUFFIX) == RES_SUFFIX
end

--- Find the _res track for a given source track (by name).
--- Returns the track index, or nil if not found.
local function find_res_track(source_track_idx)
    local song = renoise.song()
    local res_name = song:track(source_track_idx).name .. RES_SUFFIX

    for i = 1, #song.tracks do
        if song:track(i).name == res_name then
            return i
        end
    end

    return nil
end

--- Set up a _res track + group for the currently selected track.
--- Called from the menu — safe to insert tracks here because
--- we're not inside a notifier callback.
local function setup_res_track()
    local song = renoise.song()
    local src_idx = song.selected_track_index
    local source_track = song:track(src_idx)

    -- Don't set up on a _res track or a group.
    if is_resolved_track(source_track.name) then
        renoise.app():show_status("Cannot set up on a _res track.")
        return
    end
    if source_track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        renoise.app():show_status("Select a sequencer track first.")
        return
    end

    -- Check if _res track already exists.
    local res_name = source_track.name .. RES_SUFFIX
    for i = 1, #song.tracks do
        if song:track(i).name == res_name then
            renoise.app():show_status("'" .. res_name .. "' already exists.")
            return
        end
    end

    local source_name = source_track.name
    local source_color = source_track.color

    -- Not in a group — create: source, _res, then group them.
    local res_idx = src_idx + 1
    song:insert_track_at(res_idx)
    local res_track = song:track(res_idx)
    res_track.name = res_name
    res_track.color = source_color
    res_track.mute_state = renoise.Track.MUTE_STATE_OFF

    local group_idx = res_idx + 1
    song:insert_group_at(group_idx)
    song:track(group_idx).name = source_name
    song:track(group_idx).color = source_color

    -- Add source first → leftmost. After this, _res shifts to src_idx.
    -- Add _res second → rightmost. Use src_idx again since indices shifted.
    song:add_track_to_group(src_idx, group_idx)
    song:add_track_to_group(src_idx, group_idx)

    renoise.app():show_status("Phrase Resolver: set up '" .. res_name .. "'.")
end

--------------------------------------------------------------------------------
-- Writing resolved data to a track
--------------------------------------------------------------------------------

--- Ensure the target track has enough visible columns for the data.
local function ensure_visible_columns(rns_track, pattern_lines)
    local max_note_cols = 0
    local max_fx_cols = 0
    for _, pline in ipairs(pattern_lines) do
        if #pline.note_columns > max_note_cols then
            max_note_cols = #pline.note_columns
        end
        if #pline.effect_columns > max_fx_cols then
            max_fx_cols = #pline.effect_columns
        end
    end

    if max_note_cols > rns_track.visible_note_columns then
        rns_track.visible_note_columns = max_note_cols
    end
    if max_fx_cols > rns_track.visible_effect_columns then
        rns_track.visible_effect_columns = max_fx_cols
    end
end

--- Write a single PatternLine table into a real Renoise pattern line.
local function write_pattern_line(target_line, pline)
    for col_i, col in ipairs(pline.note_columns) do
        local nc = target_line:note_column(col_i)
        if col.note_value and col.note_value ~= 121 then
            nc.note_value = col.note_value
        end
        if col.instrument_value and col.instrument_value ~= 255 then
            nc.instrument_value = col.instrument_value
        end
        if col.volume_value and col.volume_value ~= 255 then
            nc.volume_value = col.volume_value
        end
        if col.panning_value and col.panning_value ~= 255 then
            nc.panning_value = col.panning_value
        end
        if col.delay_value and col.delay_value ~= 0 then
            nc.delay_value = col.delay_value
        end
        if col.effect_number_value and col.effect_number_value ~= 0 then
            nc.effect_number_value = col.effect_number_value
        end
        if col.effect_amount_value and col.effect_amount_value ~= 0 then
            nc.effect_amount_value = col.effect_amount_value
        end
    end

    for fx_i, fc in ipairs(pline.effect_columns) do
        local ec = target_line:effect_column(fx_i)
        if fc.number_value and fc.number_value ~= 0 then
            ec.number_value = fc.number_value
        end
        if fc.amount_value and fc.amount_value ~= 0 then
            ec.amount_value = fc.amount_value
        end
    end
end

--- Write an array of PatternLine tables into a pattern track,
--- starting at the given line index.
local function write_to_track(pattern, target_track_idx, start_line, pattern_lines)
    local song = renoise.song()
    local track = pattern:track(target_track_idx)
    local rns_track = song:track(target_track_idx)

    ensure_visible_columns(rns_track, pattern_lines)

    for i, pline in ipairs(pattern_lines) do
        local line_idx = start_line + (i - 1)
        if line_idx > pattern.number_of_lines then
            break
        end

        local target_line = track:line(line_idx)
        target_line:clear()
        write_pattern_line(target_line, pline)
    end
end

--------------------------------------------------------------------------------
-- Line interpretation
--------------------------------------------------------------------------------

--- Resolve a pattern line and write the result to the _res track.
local function interpret_line(pos)
    local song = renoise.song()
    local instruments = song.instruments

    -- Bounds check.
    if pos.pattern < 1 or pos.pattern > #song.patterns then
        return
    end
    local pattern = song:pattern(pos.pattern)
    if pos.track < 1 or pos.track > #pattern.tracks then
        return
    end

    -- Skip _res tracks and non-sequencer tracks.
    local track_obj = song:track(pos.track)
    if is_resolved_track(track_obj.name) then
        return
    end
    if track_obj.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        return
    end

    -- Only process if a _res track has been set up for this track.
    local res_idx = find_res_track(pos.track)
    if not res_idx then
        return
    end

    local line = pattern:track(pos.track):line(pos.line)

    local resolved = phrase_resolver.resolve_pattern_phrase(line, instruments)
    local pattern_lines = phrase_resolver.resolved_to_pattern_lines(
            resolved, song.transport.lpb
    )

    write_to_track(pattern, res_idx, pos.line, pattern_lines)
end

--------------------------------------------------------------------------------
-- Notifier callbacks
--------------------------------------------------------------------------------

local function on_line_changed(pos)
    interpret_line(pos)
end

--- Attach a line notifier to the given pattern (by index).
local function attach_to_pattern(pat_idx)
    local song = renoise.song()

    -- Remove the old notifier, if any.
    if watched_pattern_index then
        local ok, old_pat = pcall(function()
            return song:pattern(watched_pattern_index)
        end)
        if ok and old_pat:has_line_notifier(on_line_changed) then
            old_pat:remove_line_notifier(on_line_changed)
        end
        watched_pattern_index = nil
    end

    -- Attach to the new pattern.
    if pat_idx >= 1 and pat_idx <= #song.patterns then
        local pat = song:pattern(pat_idx)
        if not pat:has_line_notifier(on_line_changed) then
            pat:add_line_notifier(on_line_changed)
        end
        watched_pattern_index = pat_idx
        print(string.format(">> Phrase Resolver: watching pattern %d", pat_idx))
    end
end

--- Called whenever selected_pattern_observable fires.
local function on_selected_pattern_changed()
    local idx = renoise.song().selected_pattern_index
    attach_to_pattern(idx)
end

--------------------------------------------------------------------------------
-- Song lifecycle
--------------------------------------------------------------------------------

local function setup_song_notifiers()
    local song = renoise.song()
    if song.selected_pattern_observable:has_notifier(on_selected_pattern_changed) then
        song.selected_pattern_observable:remove_notifier(on_selected_pattern_changed)
    end
    song.selected_pattern_observable:add_notifier(on_selected_pattern_changed)
    attach_to_pattern(song.selected_pattern_index)
end

local function teardown_song_notifiers()
    watched_pattern_index = nil
end

--------------------------------------------------------------------------------
-- Tool entry point
--------------------------------------------------------------------------------

renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:Phrase Resolver:Set Up Resolve Track",
    invoke = setup_res_track,
}

renoise.tool():add_menu_entry {
    name = "Pattern Editor:Phrase Resolver:Set Up Resolve Track",
    invoke = setup_res_track,
}

renoise.tool().app_new_document_observable:add_notifier(function()
    setup_song_notifiers()
end)

if rawget(_G, "renoise") and renoise.song() then
    setup_song_notifiers()
end

print(">> Phrase Resolver tool loaded.")