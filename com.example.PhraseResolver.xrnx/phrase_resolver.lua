---------------------------------------------------------------------------
--- phrase_resolver.lua
---
--- Resolves Renoise phrase triggers (Zxx commands) into concrete note
--- sequences, returned as iterators for memory efficiency.
---
--- Uses Renoise API property names directly:
---   renoise.NoteColumn → { note_value, instrument_value, volume_value,
---                          panning_value, delay_value,
---                          effect_number_value, effect_number_string,
---                          effect_amount_value }
---   renoise.EffectColumn → { number_value, number_string,
---                            amount_value, amount_string }
---   renoise.PatternLine → { note_columns = {...}, effect_columns = {...} }
---------------------------------------------------------------------------

local M = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

M.NOTE_OFF = 120
M.NOTE_EMPTY = 121
M.EMPTY_INSTRUMENT = 255
M.EMPTY_VOLUME = 255
M.EMPTY_PANNING = 255
M.EMPTY_DELAY = 0
M.EMPTY_EFFECT_NUMBER = 0
M.EMPTY_EFFECT_AMOUNT = 0
M.DEFAULT_BASE_NOTE = 48   -- C-4

M.KEY_TRACKING_NONE = 1
M.KEY_TRACKING_TRANSPOSE = 2
M.KEY_TRACKING_OFFSET = 3

M.ZXX_EFFECT_STRING = "0Z"

---------------------------------------------------------------------------
-- Zxx detection
---------------------------------------------------------------------------

--- Check whether an effect number (string or value) represents the Zxx command.
---
--- @param  number_string  string|nil  e.g. "0Z"
--- @param  number_value   number|nil  e.g. the numeric encoding of "0Z"
--- @return boolean

function M._is_zxx(number_string, number_value)
    if number_string then
        return number_string:upper() == M.ZXX_EFFECT_STRING
    end
    if number_value and number_value ~= M.EMPTY_EFFECT_NUMBER then
        return number_value == M._zxx_number_value
    end
    return false
end

--- Encode a 2-character effect string into the numeric value Renoise
--- uses for effect_number_value / number_value.
---
--- @param  s  string  e.g. "0Z"
--- @return number

function M.encode_effect_string(s)
    s = s:upper()
    local function char_val(c)
        if c >= '0' and c <= '9' then
            return c:byte() - 0x30
        else
            return c:byte() - 0x41 + 10
        end
    end
    return char_val(s:sub(1, 1)) * 256 + char_val(s:sub(2, 2))
end

M._zxx_number_value = M.encode_effect_string(M.ZXX_EFFECT_STRING)

---------------------------------------------------------------------------
-- Empty-column helpers
---------------------------------------------------------------------------

--- Check if a note column table contains any actual data.
function M.is_note_column_empty(col)
    if not col then
        return true
    end
    local nv = col.note_value
    if nv ~= nil and nv ~= M.NOTE_EMPTY then
        return false
    end
    if col.instrument_value and col.instrument_value ~= M.EMPTY_INSTRUMENT then
        return false
    end
    if col.volume_value and col.volume_value ~= M.EMPTY_VOLUME then
        return false
    end
    if col.panning_value and col.panning_value ~= M.EMPTY_PANNING then
        return false
    end
    if col.delay_value and col.delay_value ~= M.EMPTY_DELAY then
        return false
    end
    if col.effect_number_value and col.effect_number_value ~= M.EMPTY_EFFECT_NUMBER then
        return false
    end
    if col.effect_amount_value and col.effect_amount_value ~= M.EMPTY_EFFECT_AMOUNT then
        return false
    end
    return true
end

--- Check if an effect column table contains any actual data.
function M.is_effect_column_empty(col)
    if not col then
        return true
    end
    if col.number_value and col.number_value ~= M.EMPTY_EFFECT_NUMBER then
        return false
    end
    if col.amount_value and col.amount_value ~= M.EMPTY_EFFECT_AMOUNT then
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Internal: transpose a single note value
---------------------------------------------------------------------------

function M._transpose_note(note_value, semitones)
    if note_value == M.NOTE_OFF or note_value == M.NOTE_EMPTY then
        return note_value
    end
    local result = note_value + semitones
    return math.max(0, math.min(119, result))
end

---------------------------------------------------------------------------
-- Core: phrase iterator
---------------------------------------------------------------------------

--- Return an iterator that yields one resolved phrase line per call.
---
--- For one-shot phrases the iterator stops at the phrase length.
--- For looping phrases the iterator runs forever — the caller decides
--- when to stop pulling.
---
--- Each yielded table has:
---   { note_columns, effect_columns, phrase_line_index,
---     output_line_index, time_in_beats }
---
--- @param trigger_note  number   MIDI-style note 0-119
--- @param phrase        table    Phrase data
--- @param options       table?   { song_lpb = 4 }
--- @return function              Iterator function

function M.resolve_phrase_iter(trigger_note, phrase, options)
    options = options or {}

    local song_lpb = options.song_lpb or 4
    local base_note = phrase.base_note or M.DEFAULT_BASE_NOTE
    local key_tracking = phrase.key_tracking or M.KEY_TRACKING_TRANSPOSE
    local phrase_lpb = phrase.lpb or song_lpb
    local total = phrase.number_of_lines
    local looping = phrase.looping or false
    local loop_start = phrase.loop_start or 1
    local loop_end = phrase.loop_end or total

    loop_start = math.max(1, math.min(loop_start, total))
    loop_end = math.max(loop_start, math.min(loop_end, total))

    local transpose = 0
    if key_tracking == M.KEY_TRACKING_TRANSPOSE then
        transpose = trigger_note - base_note
    end

    local beat_per_phrase_line = 1.0 / phrase_lpb
    local ph_idx = 1
    local out_idx = 0
    local finished = false

    return function()
        if finished then
            return nil
        end

        -- One-shot: stop at the end of the phrase
        if not looping and ph_idx > total then
            finished = true
            return nil
        end

        out_idx = out_idx + 1
        local current_ph_idx = ph_idx

        -- Build resolved note columns
        local ph_line = phrase.lines[current_ph_idx] or {}
        local columns = ph_line.note_columns or {}
        local res_cols = {}

        for col_i, col in ipairs(columns) do
            local nv = col.note_value
            if nv == nil then
                nv = M.NOTE_EMPTY
            end
            res_cols[col_i] = {
                note_value = M._transpose_note(nv, transpose),
                instrument_value = col.instrument_value,
                volume_value = col.volume_value,
                panning_value = col.panning_value,
                delay_value = col.delay_value,
                effect_number_value = col.effect_number_value,
                effect_amount_value = col.effect_amount_value,
            }
        end

        -- Build resolved effect columns
        local res_fx = {}
        local fx_cols = ph_line.effect_columns or {}
        for fx_i, fx in ipairs(fx_cols) do
            res_fx[fx_i] = {
                number_value = fx.number_value,
                number_string = fx.number_string,
                amount_value = fx.amount_value,
                amount_string = fx.amount_string,
            }
        end

        -- Advance phrase index
        if looping then
            if ph_idx >= loop_end then
                ph_idx = loop_start
            else
                ph_idx = ph_idx + 1
            end
        else
            ph_idx = ph_idx + 1
        end

        return {
            note_columns = res_cols,
            effect_columns = res_fx,
            phrase_line_index = current_ph_idx,
            output_line_index = out_idx,
            time_in_beats = (out_idx - 1) * beat_per_phrase_line,
        }
    end
end

---------------------------------------------------------------------------
-- Pattern-grid iterator
---------------------------------------------------------------------------

--- Wrap a phrase iterator and yield one PatternLine-shaped table per song
--- line offset (0, 1, 2, …).
---
--- Phrase lines are placed on the correct song-grid position based on
--- their time_in_beats and the song LPB.  When a phrase line falls
--- between song lines, it is placed on the nearest song line with a
--- delay value.  If multiple phrase lines map to the same song line,
--- only the first is kept (no extra columns are created).
---
--- Returns nil when the phrase is exhausted (one-shot finished).
--- Returns an empty PatternLine for gap lines with no phrase content.
--- For looping phrases the iterator never returns nil.
---
--- @param  phrase_iter  function  Iterator from resolve_phrase_iter
--- @param  song_lpb     number   The song's lines-per-beat
--- @return function               Iterator yielding PatternLine tables

function M.pattern_line_iter(phrase_iter, song_lpb)
    song_lpb = song_lpb or 4

    local current_offset = -1
    local pending = nil    -- buffered phrase line for a future offset
    local exhausted = false

    return function()
        if exhausted and not pending then
            return nil
        end

        current_offset = current_offset + 1
        local note_cols = {}
        local fx_cols = {}
        local placed = false

        while true do
            -- Get the next phrase line if we don't have one buffered
            if not pending then
                if exhausted then
                    break
                end
                pending = phrase_iter()
                if not pending then
                    exhausted = true
                    break
                end
            end

            -- Map phrase time → song line offset + delay
            local exact_line = pending.time_in_beats * song_lpb
            local offset = math.floor(exact_line)
            local frac = exact_line - offset
            local delay = math.floor(frac * 256 + 0.5)
            if delay > 255 then
                delay = 0
                offset = offset + 1
            end

            -- This phrase line belongs to a future song line — stop
            if offset > current_offset then
                break
            end

            if offset == current_offset and not placed then
                -- Take only the first phrase line for this song line
                for _, col in ipairs(pending.note_columns or {}) do
                    if not M.is_note_column_empty(col) then
                        note_cols[#note_cols + 1] = {
                            note_value = col.note_value,
                            instrument_value = col.instrument_value,
                            volume_value = col.volume_value,
                            panning_value = col.panning_value,
                            delay_value = (delay > 0) and delay or (col.delay_value or 0),
                            effect_number_value = col.effect_number_value,
                            effect_amount_value = col.effect_amount_value,
                        }
                    end
                end

                for _, fc in ipairs(pending.effect_columns or {}) do
                    if not M.is_effect_column_empty(fc) then
                        fx_cols[#fx_cols + 1] = {
                            number_value = fc.number_value,
                            number_string = fc.number_string,
                            amount_value = fc.amount_value,
                            amount_string = fc.amount_string,
                        }
                    end
                end

                placed = true
            end
            -- Skip additional phrase lines for the same offset, or past offsets

            pending = nil  -- consumed
        end

        -- Nothing for this offset and phrase is done → signal end
        if not placed and exhausted and not pending then
            return nil
        end

        return { note_columns = note_cols, effect_columns = fx_cols }
    end
end

---------------------------------------------------------------------------
-- Pattern line parsing: extract Zxx phrase trigger
---------------------------------------------------------------------------

--- Parse a pattern-editor line and extract the Zxx phrase trigger.
---
--- Checks for Zxx in two places (matching Renoise behaviour):
---   1. The specified note column's own effect sub-column
---   2. The line's effect columns
---
--- @param  line        table    PatternLine-shaped table
--- @param  col_index   number?  Note column to inspect (default 1)
--- @return table                { note_value, instrument_value, …,
---                                phrase_index (1-based) or nil }

function M.parse_pattern_line(line, col_index)
    col_index = col_index or 1

    local note_cols = line.note_columns or {}
    local nc = note_cols[col_index] or {}

    local result = {
        note_value = nc.note_value,
        instrument_value = nc.instrument_value,
        volume_value = nc.volume_value,
        panning_value = nc.panning_value,
        delay_value = nc.delay_value,
        effect_number_value = nc.effect_number_value,
        effect_amount_value = nc.effect_amount_value,
        phrase_index = nil,
    }

    -- 1. Check the note column's own effect sub-column
    if M._is_zxx(nc.effect_number_string, nc.effect_number_value) then
        local amount = nc.effect_amount_value or 0
        if amount > 0 then
            result.phrase_index = amount
        end
        return result
    end

    -- 2. Check the line's effect columns
    if line.effect_columns then
        for _, fx in ipairs(line.effect_columns) do
            if M._is_zxx(fx.number_string, fx.number_value) then
                local amount = fx.amount_value or 0
                if amount > 0 then
                    result.phrase_index = amount
                end
                return result
            end
        end
    end

    return result
end

---------------------------------------------------------------------------
-- High-level: resolve a pattern line → pattern_line_iter
---------------------------------------------------------------------------

--- Build a passthrough iterator: yields one line with just the trigger
--- note, then stops.
function M._passthrough_iter(parsed, song_lpb)
    song_lpb = song_lpb or 4
    local done = false
    return function()
        if done then
            return nil
        end
        done = true
        return {
            note_columns = {
                {
                    note_value = parsed.note_value,
                    instrument_value = parsed.instrument_value,
                    volume_value = parsed.volume_value,
                    panning_value = parsed.panning_value,
                    delay_value = parsed.delay_value,
                    effect_number_value = parsed.effect_number_value,
                    effect_amount_value = parsed.effect_amount_value,
                },
            },
            effect_columns = {},
        }
    end
end

--- Given a pattern line and the song's instruments array, return an
--- iterator that yields PatternLine-shaped tables one per song line.
---
--- The instrument is determined from the note column's instrument_value.
--- When a Zxx command selects a phrase, that phrase is resolved with
--- transposition.  In all other cases the function returns a passthrough
--- iterator yielding one line with the original trigger note.
---
--- @param  pattern_line  table    PatternLine-shaped table
--- @param  instruments   table    Array of instrument tables (1-based)
--- @param  options       table?   { col_index=1, song_lpb=4 }
--- @return function               Iterator yielding PatternLine tables

function M.resolve_pattern_phrase(pattern_line, instruments, options)
    options = options or {}
    local col_index = options.col_index or 1
    local song_lpb = options.song_lpb or 4

    local parsed = M.parse_pattern_line(pattern_line, col_index)

    -- No playable note → passthrough
    if not parsed.note_value or
            parsed.note_value == M.NOTE_OFF or
            parsed.note_value == M.NOTE_EMPTY then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- No Zxx phrase trigger → passthrough
    if not parsed.phrase_index then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- Look up instrument
    local instrument
    if parsed.instrument_value and
            parsed.instrument_value ~= M.EMPTY_INSTRUMENT and
            instruments then
        instrument = instruments[parsed.instrument_value + 1]
    end

    -- No instrument or no phrases → passthrough
    if not instrument or not instrument.phrases or #instrument.phrases == 0 then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- Phrase index out of range → passthrough
    local phrase = instrument.phrases[parsed.phrase_index]
    if not phrase then
        return M._passthrough_iter(parsed, song_lpb)
    end

    local phrase_iter = M.resolve_phrase_iter(parsed.note_value, phrase, options)
    return M.pattern_line_iter(phrase_iter, song_lpb)
end

---------------------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------------------

function M.note_to_string(note_value)
    if note_value == M.NOTE_OFF then
        return "OFF"
    end
    if note_value == M.NOTE_EMPTY then
        return "---"
    end
    if note_value < 0 or note_value > 119 then
        return "???"
    end

    local names = { "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" }
    local name = names[(note_value % 12) + 1]
    local octave = math.floor(note_value / 12)
    return name .. octave
end

function M.string_to_note(s)
    if s == "OFF" then
        return M.NOTE_OFF
    end
    if s == "---" then
        return M.NOTE_EMPTY
    end

    local map = {
        ["C-"] = 0, ["C#"] = 1, ["D-"] = 2, ["D#"] = 3, ["E-"] = 4, ["F-"] = 5,
        ["F#"] = 6, ["G-"] = 7, ["G#"] = 8, ["A-"] = 9, ["A#"] = 10, ["B-"] = 11,
    }

    local name = s:sub(1, 2)
    local octave = tonumber(s:sub(3, 3))
    if not map[name] or not octave then
        return nil
    end
    return octave * 12 + map[name]
end

return M