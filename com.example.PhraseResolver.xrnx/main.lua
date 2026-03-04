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

--- Write a single PatternLine table into a real Renoise pattern line.
--- Expands visible columns on the track if needed.
local function write_pattern_line(rns_track, target_line, pline)
    -- Expand visible columns if this line needs more
    local nc_count = #pline.note_columns
    local fx_count = #pline.effect_columns
    if nc_count > rns_track.visible_note_columns then
        rns_track.visible_note_columns = nc_count
    end
    if fx_count > rns_track.visible_effect_columns then
        rns_track.visible_effect_columns = fx_count
    end

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

--------------------------------------------------------------------------------
-- Backwards Zxx search
--------------------------------------------------------------------------------

--- Scan backwards from a given position to find the most recent Zxx command
--- for the given track/column. Searches through the current pattern and then
--- backwards through the sequencer into previous patterns.
---
--- @param  pattern_idx  number  Current pattern index
--- @param  track_idx    number  Track to scan
--- @param  start_line   number  Line to start scanning from (inclusive)
--- @param  col_index    number? Note column to inspect (default 1)
--- @return number|nil           phrase_index (1-based), or nil if not found

local function find_active_phrase_index(pattern_idx, track_idx, start_line, col_index)
    col_index = col_index or 1
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence

    -- Find the sequence position(s) for this pattern_idx.
    -- Start from the last occurrence in the sequence so we search backwards
    -- through the correct ordering.
    local seq_pos = nil
    for i = #seq, 1, -1 do
        if seq[i] == pattern_idx then
            seq_pos = i
            break
        end
    end
    if not seq_pos then
        return nil
    end

    -- Scan: current pattern from start_line backwards, then previous patterns.
    local current_seq_pos = seq_pos
    local current_line = start_line

    while current_seq_pos >= 1 do
        local pat_idx = seq[current_seq_pos]
        local pattern = song:pattern(pat_idx)

        if track_idx > #pattern.tracks then
            -- Track doesn't exist in this pattern, skip.
            current_seq_pos = current_seq_pos - 1
            if current_seq_pos >= 1 then
                local prev_pat = song:pattern(seq[current_seq_pos])
                current_line = prev_pat.number_of_lines
            end
        else
            local track = pattern:track(track_idx)

            -- Clamp start line to pattern length.
            if current_line > pattern.number_of_lines then
                current_line = pattern.number_of_lines
            end

            for ln = current_line, 1, -1 do
                local line = track:line(ln)
                local parsed = phrase_resolver.parse_pattern_line(line, col_index)
                if parsed.phrase_index then
                    return parsed.phrase_index
                end
            end

            -- Not found in this pattern — move to the previous one.
            current_seq_pos = current_seq_pos - 1
            if current_seq_pos >= 1 then
                local prev_pat = song:pattern(seq[current_seq_pos])
                current_line = prev_pat.number_of_lines
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Line interpretation
--------------------------------------------------------------------------------

--- Clone a Renoise PatternLine into a plain table.
local function clone_line(line)
    local note_cols = {}
    for i = 1, #line.note_columns do
        local nc = line:note_column(i)
        note_cols[i] = {
            note_value = nc.note_value,
            instrument_value = nc.instrument_value,
            volume_value = nc.volume_value,
            panning_value = nc.panning_value,
            delay_value = nc.delay_value,
            effect_number_value = nc.effect_number_value,
            effect_number_string = nc.effect_number_string,
            effect_amount_value = nc.effect_amount_value,
        }
    end

    local fx_cols = {}
    for i = 1, #line.effect_columns do
        local ec = line:effect_column(i)
        fx_cols[i] = {
            number_value = ec.number_value,
            number_string = ec.number_string,
            amount_value = ec.amount_value,
            amount_string = ec.amount_string,
        }
    end

    return { note_columns = note_cols, effect_columns = fx_cols }
end

--- Prepare a pattern line for phrase resolution.
--- If the line already has a Zxx, returns it as-is (the Renoise object).
--- If not, searches backwards for a Zxx and returns a cloned copy
--- with the found Zxx injected into effect column 1.
--- Returns the (possibly modified) line, or nil if no Zxx found anywhere.
local function prepare_line(pos)
    local song = renoise.song()
    local pattern = song:pattern(pos.pattern)
    local line = pattern:track(pos.track):line(pos.line)

    -- Check if the current line already has a Zxx.
    local parsed = phrase_resolver.parse_pattern_line(line)
    if parsed.phrase_index then
        return line
    end

    -- Search backwards for a Zxx.
    local found_idx = find_active_phrase_index(
            pos.pattern, pos.track, pos.line - 1
    )
    if not found_idx then
        return nil
    end

    -- Clone and inject the found Zxx.
    local cloned = clone_line(line)
    cloned.effect_columns[1] = {
        number_value = phrase_resolver.encode_effect_string(
                phrase_resolver.ZXX_EFFECT_STRING
        ),
        number_string = phrase_resolver.ZXX_EFFECT_STRING,
        amount_value = found_idx,
        amount_string = string.format("%02X", found_idx),
    }

    return cloned
end

--- Find the next line in the source track (after start_line) that has
--- a note in the given column.  Searches only within the current pattern.
--- Returns the line number, or nil if no note is found before the pattern ends.
local function find_next_note_line(pattern, track_idx, start_line, col_index)
    col_index = col_index or 1
    local track = pattern:track(track_idx)
    for ln = start_line + 1, pattern.number_of_lines do
        local nc = track:line(ln):note_column(col_index)
        if nc.note_value ~= phrase_resolver.NOTE_EMPTY then
            return ln
        end
    end
    return nil
end

--- Resolve a pattern line and write the result to the _res track.
--- Pulls from the iterator until the next note in the source column
--- or the end of the pattern. Clears remaining lines if the phrase
--- ends early (one-shot).
local function interpret_line(pos)
    local song = renoise.song()

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

    local line = prepare_line(pos)
    if not line then
        return
    end

    local song_lpb = song.transport.lpb
    local iter = phrase_resolver.resolve_pattern_phrase(
            line, song.instruments, { song_lpb = song_lpb }
    )

    -- Determine how far to write: until the next note or end of pattern.
    local next_note = find_next_note_line(pattern, pos.track, pos.line)
    local last_line = next_note and (next_note - 1) or pattern.number_of_lines

    local res_track = pattern:track(res_idx)
    local rns_res_track = song:track(res_idx)

    for ln = pos.line, last_line do
        local target_line = res_track:line(ln)
        target_line:clear()

        local pline = iter()
        if pline then
            write_pattern_line(rns_res_track, target_line, pline)
        end
        -- If iter() returned nil (one-shot ended), the line stays cleared.
    end
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