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
-- Backwards scanning
--------------------------------------------------------------------------------

--- Generic backwards scan across the sequencer.
--- Calls predicate(track, line_index) for each line going backwards from
--- (start_seq_pos, start_line).  When the predicate returns a non-nil
--- value, scanning stops and (seq_pos, line_number, value) is returned.
--- Returns (nil, nil, nil) if nothing matches.
local function scan_backwards(track_idx, start_seq_pos, start_line, predicate)
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence
    local current_line = start_line

    for sp = start_seq_pos, 1, -1 do
        local pat = song:pattern(seq[sp])
        if track_idx <= #pat.tracks then
            local track = pat:track(track_idx)
            if current_line > pat.number_of_lines then
                current_line = pat.number_of_lines
            end
            for ln = current_line, 1, -1 do
                local result = predicate(track, ln)
                if result ~= nil then
                    return sp, ln, result
                end
            end
        end
        -- Move to end of previous pattern.
        if sp > 1 then
            current_line = song:pattern(seq[sp - 1]).number_of_lines
        end
    end

    return nil, nil, nil
end

--- Find the most recent Zxx command at or before (start_seq_pos, start_line).
--- Returns the phrase_index (1-based), or nil.
local function find_active_phrase_index(track_idx, start_seq_pos, start_line, col_index)
    col_index = col_index or 1
    local _, _, phrase_index = scan_backwards(
            track_idx, start_seq_pos, start_line,
            function(track, ln)
                local parsed = phrase_resolver.parse_pattern_line(track:line(ln), col_index)
                return parsed.phrase_index  -- non-nil when Zxx found
            end
    )
    return phrase_index
end

--- Find the most recent note at or before (start_seq_pos, start_line).
--- Returns (seq_pos, line_number) or (nil, nil).
local function find_note_at_or_before(track_idx, start_seq_pos, start_line, col_index)
    col_index = col_index or 1
    local sp, ln, _ = scan_backwards(
            track_idx, start_seq_pos, start_line,
            function(track, line_num)
                local nc = track:line(line_num):note_column(col_index)
                if nc.note_value ~= phrase_resolver.NOTE_EMPTY then
                    return true
                end
                return nil  -- keep scanning
            end
    )
    return sp, ln
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
local function prepare_line(seq_pos, pos)
    local song = renoise.song()
    local pattern = song:pattern(pos.pattern)
    local line = pattern:track(pos.track):line(pos.line)

    -- Check if the current line already has a Zxx.
    local parsed = phrase_resolver.parse_pattern_line(line)
    if parsed.phrase_index then
        return line
    end

    -- Search backwards for a Zxx (across patterns).
    local found_idx = find_active_phrase_index(
            pos.track, seq_pos, pos.line - 1
    )
    if not found_idx then
        -- No Zxx anywhere — return the line as-is for passthrough.
        return line
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

--- Find the next note after start_line, searching forward across the
--- sequencer.  Returns (seq_pos, line_number) or (nil, nil).
local function find_next_note_forward(track_idx, start_seq_pos, start_line, col_index)
    col_index = col_index or 1
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence

    for sp = start_seq_pos, #seq do
        local pat = song:pattern(seq[sp])
        if track_idx <= #pat.tracks then
            local track = pat:track(track_idx)
            local first = (sp == start_seq_pos) and (start_line + 1) or 1
            for ln = first, pat.number_of_lines do
                local nc = track:line(ln):note_column(col_index)
                if nc.note_value ~= phrase_resolver.NOTE_EMPTY then
                    return sp, ln
                end
            end
        end
    end

    return nil, nil
end

--- Fill the _res track from an iterator, starting at a given sequence
--- position and line, up to (but not including) a stop position.
--- stop_seq_pos/stop_line can be nil to mean end of song.
--- Clears lines where the iterator is exhausted (one-shot ended).
local function fill_res_track(iter, track_idx, res_idx, start_seq_pos, start_line,
                              stop_seq_pos, stop_line)
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence
    local rns_res_track = song:track(res_idx)

    for sp = start_seq_pos, #seq do
        local pat = song:pattern(seq[sp])
        if res_idx > #pat.tracks then
            break
        end

        local res_track = pat:track(res_idx)
        local first = (sp == start_seq_pos) and start_line or 1
        local last = pat.number_of_lines

        -- Clip to stop position
        if stop_seq_pos and sp == stop_seq_pos then
            last = stop_line - 1
        elseif stop_seq_pos and sp > stop_seq_pos then
            break
        end

        for ln = first, last do
            local target_line = res_track:line(ln)
            target_line:clear()

            local pline = iter()
            if pline then
                write_pattern_line(rns_res_track, target_line, pline)
            end
        end
    end
end

--- Extract non-empty overrides from the pattern note column and effect
--- columns.  These are the values that should take priority over whatever
--- the phrase contains.
local function extract_overrides(line, col_index)
    col_index = col_index or 1
    local note_cols = line.note_columns or {}
    local nc = note_cols[col_index] or {}

    local overrides = {
        volume_value = nil,
        panning_value = nil,
        effects = {}, -- array of { number_value, amount_value }
    }

    -- Volume / panning from the note column (only if explicitly set)
    if nc.volume_value and nc.volume_value ~= phrase_resolver.EMPTY_VOLUME then
        overrides.volume_value = nc.volume_value
    end
    if nc.panning_value and nc.panning_value ~= phrase_resolver.EMPTY_PANNING then
        overrides.panning_value = nc.panning_value
    end

    -- Effect sub-column on the note column (skip Zxx — already consumed)
    if nc.effect_number_value and nc.effect_number_value ~= phrase_resolver.EMPTY_EFFECT_NUMBER then
        if not phrase_resolver._is_zxx(nc.effect_number_string, nc.effect_number_value) then
            overrides.effects[#overrides.effects + 1] = {
                number_value = nc.effect_number_value,
                number_string = nc.effect_number_string,
                amount_value = nc.effect_amount_value or 0,
                amount_string = nc.effect_amount_string,
            }
        end
    end

    -- Effect columns on the line (skip Zxx)
    local fx_cols = line.effect_columns or {}
    for _, fx in ipairs(fx_cols) do
        if fx.number_value and fx.number_value ~= phrase_resolver.EMPTY_EFFECT_NUMBER then
            if not phrase_resolver._is_zxx(fx.number_string, fx.number_value) then
                overrides.effects[#overrides.effects + 1] = {
                    number_value = fx.number_value,
                    number_string = fx.number_string,
                    amount_value = fx.amount_value or 0,
                    amount_string = fx.amount_string,
                }
            end
        end
    end

    return overrides
end

--- Wrap a pattern_line iterator to apply pattern-level overrides.
--- Volume and panning from the pattern replace phrase values on every
--- yielded line.  Pattern effect columns are appended (replacing any
--- phrase effect with the same number).
local function apply_overrides(iter, overrides)
    return function()
        local pline = iter()
        if not pline then
            return nil
        end

        -- Override volume/panning on every note column
        for _, nc in ipairs(pline.note_columns) do
            if overrides.volume_value then
                nc.volume_value = overrides.volume_value
            end
            if overrides.panning_value then
                nc.panning_value = overrides.panning_value
            end
        end

        -- Merge effects: pattern effects replace phrase effects with same
        -- number, otherwise are appended.
        if #overrides.effects > 0 then
            local fx = pline.effect_columns or {}

            for _, ov_fx in ipairs(overrides.effects) do
                local replaced = false
                for i, existing in ipairs(fx) do
                    if existing.number_value == ov_fx.number_value then
                        fx[i] = ov_fx
                        replaced = true
                        break
                    end
                end
                if not replaced then
                    fx[#fx + 1] = ov_fx
                end
            end

            pline.effect_columns = fx
        end

        return pline
    end
end

--- Resolve a pattern line and write the result to the _res track.
---
--- Finds the "owning" note (at or before pos.line), resolves its phrase,
--- and fills forward across patterns until the next note or the end of
--- the song.  When a note is deleted, this re-extends the previous note's
--- phrase to cover the gap.
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

    -- Find this pattern's position in the sequencer.
    local seq = song.sequencer.pattern_sequence
    local seq_pos = nil
    for i = #seq, 1, -1 do
        if seq[i] == pos.pattern then
            seq_pos = i
            break
        end
    end
    if not seq_pos then
        return
    end

    -- Find the owning note: the most recent note at or before pos.line,
    -- searching backwards across patterns.
    local owning_seq, owning_line = find_note_at_or_before(
            pos.track, seq_pos, pos.line
    )
    if not owning_seq then
        return
    end

    -- Prepare the owning line (inject Zxx from backwards search if needed).
    local owning_pat_idx = seq[owning_seq]
    local owning_pos = { pattern = owning_pat_idx, track = pos.track, line = owning_line }
    local line = prepare_line(owning_seq, owning_pos)
    if not line then
        return
    end

    -- Extract pattern-level overrides (volume, panning, effects).
    local overrides = extract_overrides(line)

    -- Create the iterator, with overrides applied.
    local song_lpb = song.transport.lpb
    local iter = phrase_resolver.resolve_pattern_phrase(
            line, song.instruments, { song_lpb = song_lpb }
    )
    iter = apply_overrides(iter, overrides)

    -- Find the next note after the owning note (across patterns).
    local stop_seq, stop_ln = find_next_note_forward(
            pos.track, owning_seq, owning_line
    )

    -- Fill from the owning note forward.
    fill_res_track(iter, pos.track, res_idx,
            owning_seq, owning_line, stop_seq, stop_ln)
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