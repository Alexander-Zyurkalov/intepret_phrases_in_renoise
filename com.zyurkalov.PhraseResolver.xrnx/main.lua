---
--- Phrase Resolver Tool – main.lua
---

local phrase_resolver = require("phrase_resolver")

local RES_SUFFIX = "_res"

--------------------------------------------------------------------------------
-- Notifier management
--------------------------------------------------------------------------------

--- @type number?
local watched_pattern_index = nil

--- When true, local line notifiers are suppressed (global rebuild in progress).
--- @type boolean
local rebuilding_globally = false

--- Stored phrase notifier entries for cleanup.
--- Each entry: { inst_idx, phrase_idx, callback }
--- @type table[]
local phrase_notifier_entries = {}

--------------------------------------------------------------------------------
-- Track helpers
--------------------------------------------------------------------------------

--- Check if a track name ends with the _res suffix.
--- @param track_name string
--- @return boolean
local function is_resolved_track(track_name)
    return track_name:sub(-#RES_SUFFIX) == RES_SUFFIX
end

--- Find the source track for a given _res track (by name).
--- Returns the track index, or nil if not found.
--- @param res_track_idx number
--- @return number?
local function find_resource_track(res_track_idx)
    local song = renoise.song()
    local res_track = song.tracks[res_track_idx]
    if not res_track then
        return nil
    end
    local res_name = res_track.name

    -- Remove the _res suffix to get the source track name
    if not is_resolved_track(res_name) then
        return nil
    end

    local source_name = res_name:sub(1, -#RES_SUFFIX - 1)

    for i = 1, #song.tracks do
        if song.tracks[i].name == source_name then
            return i
        end
    end

    return nil
end

--- Find the _res track for a given source track (by name).
--- Returns the track index, or nil if not found.
--- @param source_track_idx number
--- @return number?
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
--- @return nil
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
--- @param rns_track renoise.Track
--- @param target_line renoise.PatternLine
--- @param pline ClonedLine
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
--- @param track_idx number
--- @param start_seq_pos number
--- @param start_line number
--- @param predicate fun(track: renoise.PatternTrack, ln: number): any?
--- @return number? seq_pos
--- @return number? line_number
--- @return any? value
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
--- @param track_idx number
--- @param start_seq_pos number
--- @param start_line number
--- @param col_index? number
--- @return number? phrase_index
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
--- @param track_idx number
--- @param start_seq_pos number
--- @param start_line number
--- @param col_index? number
--- @return number? seq_pos
--- @return number? line_number
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
--- @param line renoise.PatternLine
--- @return ClonedLine
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
--- @param seq_pos number
--- @param pos PatternLinePosition
--- @return renoise.PatternLine|nil
local function prepare_pattern_line(seq_pos, pos)
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
--- @param track_idx number
--- @param start_seq_pos number
--- @param start_line number
--- @param col_index? number
--- @return number? seq_pos
--- @return number? line_number
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
--- @param iter PatternLineIterator
--- @param track_idx number
--- @param res_idx number
--- @param start_seq_pos number
--- @param start_line number
--- @param stop_seq_pos number?
--- @param stop_line number?
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
--- @param line renoise.PatternLine
--- @param col_index? number
--- @return renoise.PatternLine
local function extract_overrides(line, col_index)
    col_index = col_index or 1
    local note_cols = line.note_columns or {}
    local nc = note_cols[col_index] or {}

    local overrides = {
        instrument_value = nil,
        volume_value = nil,
        panning_value = nil,
        effects = {}, -- array of { number_value, amount_value, ... }
    }

    -- Instrument from the note column (always copy if present)
    if nc.instrument_value and nc.instrument_value ~= phrase_resolver.EMPTY_INSTRUMENT then
        overrides.instrument_value = nc.instrument_value
    end

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

--- Build a Z00 effect column table.
--- @return renoise.EffectColumn
local function make_z00_effect()
    return {
        number_value = phrase_resolver.encode_effect_string(
                phrase_resolver.ZXX_EFFECT_STRING
        ),
        number_string = phrase_resolver.ZXX_EFFECT_STRING,
        amount_value = 0,
        amount_string = "00",
    }
end

--- Wrap a pattern_line iterator to apply pattern-level overrides.
--- - Instrument from the pattern is set on every note column.
--- - Volume and panning from the pattern replace phrase values.
--- - Pattern effect columns replace phrase effects with the same number,
---   or are appended.
--- - A Z00 effect is added to every line so the _res track plays raw
---   notes without triggering phrases.
--- @param iter PatternLineIterator
--- @param overrides renoise.PatternLine
--- @return PatternLineIterator
local function apply_overrides(iter, overrides)
    return function()
        local pline = iter()
        if not pline then
            return nil
        end

        local isThereANote = false
        -- Override instrument/volume/panning on every note column
        for _, nc in ipairs(pline.note_columns) do
            local note_off = 120
            if nc.note_value == note_off then
                goto
                continue
            end
            if nc.instrument_value then
                isThereANote = true
            end
            if overrides.instrument_value then
                nc.instrument_value = overrides.instrument_value
            end
            if overrides.volume_value then
                nc.volume_value = overrides.volume_value
            end
            if overrides.panning_value then
                nc.panning_value = overrides.panning_value
            end
            :: continue ::
        end

        -- Merge effects: pattern effects replace phrase effects with same
        -- number, otherwise are appended.
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

        -- Always add Z00 to disable phrase playback on the _res track.

        if isThereANote then
            fx[#fx + 1] = make_z00_effect()
        end

        pline.effect_columns = fx

        return pline
    end
end

--- @param pos PatternLinePosition
--- @return number? seq_pos
local function find_sequence_position(pos)
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence
    local seq_pos = nil
    for i = #seq, 1, -1 do
        if seq[i] == pos.pattern then
            seq_pos = i
            break
        end
    end
    return seq_pos
end

local function copy_line_to_phrase(phrase_line, phrase, phrase_line_number)
    for col_i, col in ipairs(phrase_line.note_columns) do
        local nc = phrase.lines[phrase_line_number]:note_column(col_i)
        if col.note_value then
            nc.note_value = col.note_value
        end
        if col.instrument_value then
            nc.instrument_value = col.instrument_value
        end
        if col.volume_value then
            nc.volume_value = col.volume_value
        end
        if col.panning_value then
            nc.panning_value = col.panning_value
        end
        if col.delay_value then
            nc.delay_value = col.delay_value
        end
        if col.effect_number_value then
            nc.effect_number_value = col.effect_number_value
        end
        if col.effect_amount_value then
            nc.effect_amount_value = col.effect_amount_value
        end
    end

    for fx_i, fc in ipairs(phrase_line.effect_columns) do
        local ec = phrase.lines[phrase_line_number]:effect_column(fx_i)
        if fc.number_value then
            ec.number_value = fc.number_value
        end
        if fc.amount_value then
            ec.amount_value = fc.amount_value
        end
    end
end

--- Handle a change on a _res track.
--- (Stub — not yet implemented.)
--- @param pos PatternLinePosition
local function interpret_line_from_resolved(pos)
    local song = renoise.song()
    local pattern = song:pattern(pos.pattern)
    local line = pattern:track(pos.track):line(pos.line)

    local seq_pos = find_sequence_position(pos)
    if not seq_pos then
        return
    end

    local resource_track = find_resource_track(pos.track)
    if not resource_track then
        return
    end
    local owning_seq, owning_line = find_note_at_or_before(
            resource_track, seq_pos, pos.line
    )
    local total_lines = 0
    for seq_num = owning_seq, seq_pos - 1, 1 do
        local pattern_num = song.sequencer.pattern_sequence[seq_num]
        total_lines = total_lines + song.patterns[pattern_num].number_of_lines
    end
    total_lines = total_lines + pos.line

    -- TODO: fix tests, check whether start loop is not 1
    -- TODO: update velocity and effects
    local phrase_index = find_active_phrase_index(
            resource_track, seq_pos, pos.line
    )
    if not phrase_index then
        print("No phrase")
        return
    end

    --- @type renoise.InstrumentPhrase
    local phrase = song.instruments[1].phrases[phrase_index]
    local song_lpb = song.transport.lpb

    local phrase_line_number = phrase_resolver.phrase_line_from_pattern_offset(total_lines, phrase, song_lpb)
    if not phrase_line_number then
        print("No phrase line")
        return
    end

    local owning_pattern_num = song.sequencer.pattern_sequence[owning_seq]
    local owning_pattern_line = song:pattern(owning_pattern_num):track(resource_track):line(owning_line)
    local trigger_note = owning_pattern_line:note_column(1).note_value

    local base_note = phrase.base_note or phrase_resolver.DEFAULT_BASE_NOTE

    local phrase_line = phrase_resolver.build_phrase_line(
            line, trigger_note, base_note
    )
    copy_line_to_phrase(phrase_line, phrase, phrase_line_number)
end

--- Handle a change on an original (source) track.
---
--- Finds the "owning" note (at or before pos.line), resolves its phrase,
--- and fills forward across patterns until the next note or the end of
--- the song.  When a note is deleted, this re-extends the previous note's
--- phrase to cover the gap.
--- @param pos PatternLinePosition
local function interpret_line_from_source_track(pos)
    local song = renoise.song()

    local res_idx = find_res_track(pos.track)
    if not res_idx then
        return
    end

    -- Find this pattern's position in the sequencer.
    local seq_pos = find_sequence_position(pos)
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
    local seq = song.sequencer.pattern_sequence
    local owning_pat_idx = seq[owning_seq]
    local owning_pos = { pattern = owning_pat_idx, track = pos.track, line = owning_line }
    local line = prepare_pattern_line(owning_seq, owning_pos)
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

--- Dispatch a line change to the appropriate handler.
--- @param pos PatternLinePosition
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

    local track_obj = song:track(pos.track)
    if track_obj.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        return
    end

    if is_resolved_track(track_obj.name) and song.selected_track_index == pos.track then
        interpret_line_from_resolved(pos)
    else
        interpret_line_from_source_track(pos)
    end
end

--------------------------------------------------------------------------------
-- Notifier callbacks
--------------------------------------------------------------------------------

--- react on line changed
--- @param pos PatternLinePosition
local function on_line_changed(pos)
    if rebuilding_globally then
        return
    end
    interpret_line(pos)
end

--- Attach a line notifier to the given pattern (by index).
--- @param pat_idx number
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
--- @return nil
local function on_selected_pattern_changed()
    local song = renoise.song()
    local pos = {
        pattern = song.selected_pattern_index,
        track = song.selected_track_index,
        line = 1
    }
    interpret_line(pos)
    local idx = renoise.song().selected_pattern_index
    attach_to_pattern(idx)
end

--------------------------------------------------------------------------------
-- Rebuild phrase
--------------------------------------------------------------------------------

--- Rebuild _res tracks for all notes that use a specific phrase.
--- Sets the global flag to suppress local notifiers while writing.
--- @param inst_idx number  1-based instrument index
--- @param phrase_idx number  1-based phrase index
--- @return nil
local function rebuild_phrase(inst_idx, phrase_idx)
    local song = renoise.song()
    local seq = song.sequencer.pattern_sequence

    rebuilding_globally = true

    for t = 1, #song.tracks do
        local track_obj = song:track(t)
        if track_obj.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
            goto next_track
        end
        if is_resolved_track(track_obj.name) then
            goto next_track
        end
        if not find_res_track(t) then
            goto next_track
        end

        do
            local active_zxx = nil

            for sp = 1, #seq do
                local pat_idx = seq[sp]
                local pat = song:pattern(pat_idx)
                if t > #pat.tracks then
                    goto next_seq
                end

                local pat_track = pat:track(t)
                for ln = 1, pat.number_of_lines do
                    local line = pat_track:line(ln)

                    local parsed = phrase_resolver.parse_pattern_line(line)
                    if parsed.phrase_index then
                        active_zxx = parsed.phrase_index
                    end

                    local nc = line:note_column(1)
                    if nc.note_value ~= phrase_resolver.NOTE_EMPTY
                            and nc.note_value ~= 120
                            and active_zxx == phrase_idx then
                        local instr = nc.instrument_value
                        if instr ~= 255 and (instr + 1) == inst_idx then
                            interpret_line_from_source_track({
                                pattern = pat_idx,
                                track = t,
                                line = ln,
                            })
                        end
                    end
                end

                ::next_seq::
            end
        end

        ::next_track::
    end

    rebuilding_globally = false
end

--- Action: rebuild the currently selected phrase.
--- @return nil
local function rebuild_current_phrase()
    local song = renoise.song()
    local inst_idx = song.selected_instrument_index
    local phrase_idx = song.selected_phrase_index

    if not phrase_idx or phrase_idx < 1 then
        renoise.app():show_status("Phrase Resolver: no phrase selected.")
        return
    end

    rebuild_phrase(inst_idx, phrase_idx)

    renoise.app():show_status(string.format(
            "Phrase Resolver: rebuilt phrase %d of instrument %d.",
            phrase_idx, inst_idx
    ))
end

--------------------------------------------------------------------------------
-- Phrase notifiers
--------------------------------------------------------------------------------

--- Remove all currently installed phrase line notifiers.
local function detach_phrase_notifiers()
    local song_ok, song = pcall(renoise.song)
    if not song_ok then
        phrase_notifier_entries = {}
        return
    end

    for _, entry in ipairs(phrase_notifier_entries) do
        local ok, inst = pcall(function()
            return song.instruments[entry.inst_idx]
        end)
        if ok and inst and entry.phrase_idx <= #inst.phrases then
            local phrase = inst.phrases[entry.phrase_idx]
            if phrase:has_line_notifier(entry.callback) then
                phrase:remove_line_notifier(entry.callback)
            end
        end
    end
    phrase_notifier_entries = {}
end

--------------------------------------------------------------------------------
-- Song lifecycle
--------------------------------------------------------------------------------

--- @return nil
local function setup_song_notifiers()
    local song = renoise.song()
    if song.selected_pattern_observable:has_notifier(on_selected_pattern_changed) then
        song.selected_pattern_observable:remove_notifier(on_selected_pattern_changed)
    end
    song.selected_pattern_observable:add_notifier(on_selected_pattern_changed)
    attach_to_pattern(song.selected_pattern_index)
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

renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:Phrase Resolver:Rebuild Current Phrase",
    invoke = rebuild_current_phrase,
}

renoise.tool():add_menu_entry {
    name = "Pattern Editor:Phrase Resolver:Rebuild Current Phrase",
    invoke = rebuild_current_phrase,
}

renoise.tool():add_keybinding {
    name = "Global:Tools:Rebuild Current Phrase [Phrase Resolver]",
    invoke = rebuild_current_phrase,
}

renoise.tool().app_new_document_observable:add_notifier(function()
    setup_song_notifiers()
end)
print(">> Phrase Resolver tool loaded.")