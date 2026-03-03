---
--- phrase_resolver.lua
--- Resolves Renoise phrase triggers (Zxx) into concrete note sequences.
--- Independent from the Renoise API — works with plain Lua tables.
---

local M = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

M.NOTE_OFF   = 120
M.NOTE_EMPTY = 121

-- Key tracking modes (matches Renoise behaviour)
M.KEY_TRACKING_NONE      = 0   -- phrase plays at fixed pitch
M.KEY_TRACKING_TRANSPOSE = 1   -- phrase transposes relative to base note

-- Loop modes
M.LOOP_OFF       = 0
M.LOOP_FORWARD   = 1
M.LOOP_REVERSE   = 2
M.LOOP_PING_PONG = 3

-- Default base note (C-4 in Renoise's 0-119 range)
M.DEFAULT_BASE_NOTE = 48

-- Renoise Zxx effect number (0x18 = 24 decimal in the API)
M.EFFECT_Z = 0x18

---------------------------------------------------------------------------
-- Internal: build a sequence of phrase-line indices honouring loop mode
---------------------------------------------------------------------------

function M._generate_line_sequence(phrase, num_lines)
    local total      = phrase.number_of_lines
    local loop_mode  = phrase.loop_mode  or M.LOOP_OFF
    local loop_start = phrase.loop_start or 1
    local loop_end   = phrase.loop_end   or total

    -- Clamp loop bounds
    loop_start = math.max(1, math.min(loop_start, total))
    loop_end   = math.max(loop_start, math.min(loop_end, total))

    local indices = {}

    if loop_mode == M.LOOP_OFF then
        for i = 1, math.min(num_lines, total) do
            indices[#indices + 1] = i
        end

    elseif loop_mode == M.LOOP_FORWARD then
        local idx = 1
        for _ = 1, num_lines do
            indices[#indices + 1] = idx
            if idx >= loop_end then
                idx = loop_start
            else
                idx = idx + 1
            end
        end

    elseif loop_mode == M.LOOP_REVERSE then
        -- Play forwards to loop_end, then loop backwards loop_end→loop_start
        local idx = 1
        local in_loop = false
        for _ = 1, num_lines do
            indices[#indices + 1] = idx
            if not in_loop then
                if idx >= loop_end then
                    in_loop = true
                    idx = idx - 1
                else
                    idx = idx + 1
                end
            else
                idx = idx - 1
                if idx < loop_start then
                    idx = loop_end
                end
            end
        end

    elseif loop_mode == M.LOOP_PING_PONG then
        local idx = 1
        local direction = 1
        local in_loop = false
        for _ = 1, num_lines do
            indices[#indices + 1] = idx
            if not in_loop then
                if idx >= loop_end then
                    in_loop = true
                    direction = -1
                    idx = idx - 1
                else
                    idx = idx + 1
                end
            else
                local next_idx = idx + direction
                if next_idx > loop_end then
                    direction = -1
                    next_idx = idx - 1
                elseif next_idx < loop_start then
                    direction = 1
                    next_idx = idx + 1
                end
                idx = next_idx
            end
        end
    end

    return indices
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
-- Core: resolve a phrase into a flat sequence of note lines
---------------------------------------------------------------------------

--- Resolve a phrase given a trigger note.
---
--- @param trigger_note  number   MIDI-style note 0-119 that triggered the phrase
--- @param phrase        table    Phrase data (see below)
--- @param options       table?   Optional overrides
--- @return              table    Array of resolved line tables
---
--- phrase = {
---   lines            = { [1]={note_columns={{note_value=,volume=,...},...}}, ... },
---   number_of_lines  = 16,
---   base_note        = 48,          -- optional, default C-4
---   key_tracking     = 1,           -- optional, default TRANSPOSE
---   lpb              = 4,           -- phrase LPB
---   loop_mode        = 0,           -- optional, default OFF
---   loop_start       = 1,           -- optional, 1-based
---   loop_end         = 16,          -- optional, 1-based
--- }
---
--- options = {
---   song_lpb   = 4,                 -- song LPB for timing
---   num_lines  = nil,               -- lines to generate (default = phrase length)
--- }
---
--- Each returned line:
--- {
---   note_columns       = { {note_value=, volume=, panning=, delay=, ...}, ... },
---   phrase_line_index   = <original line in phrase>,
---   output_line_index   = <1-based position in output>,
---   time_in_beats       = <beat offset from trigger>,
--- }

function M.resolve_phrase(trigger_note, phrase, options)
    options = options or {}

    local song_lpb      = options.song_lpb  or 4
    local num_out       = options.num_lines or phrase.number_of_lines
    local base_note     = phrase.base_note     or M.DEFAULT_BASE_NOTE
    local key_tracking  = phrase.key_tracking  or M.KEY_TRACKING_TRANSPOSE
    local phrase_lpb    = phrase.lpb           or song_lpb

    -- Compute transposition
    local transpose = 0
    if key_tracking == M.KEY_TRACKING_TRANSPOSE then
        transpose = trigger_note - base_note
    end

    -- Beat duration per phrase line
    local beat_per_phrase_line = 1.0 / phrase_lpb

    -- Walk phrase lines
    local line_indices = M._generate_line_sequence(phrase, num_out)
    local result = {}

    for out_idx, ph_idx in ipairs(line_indices) do
        local ph_line  = phrase.lines[ph_idx] or {}
        local columns  = ph_line.note_columns or {}
        local res_cols = {}

        for col_i, col in ipairs(columns) do
            local nv = col.note_value
            if nv == nil then nv = M.NOTE_EMPTY end

            res_cols[col_i] = {
                note_value     = M._transpose_note(nv, transpose),
                volume         = col.volume,
                panning        = col.panning,
                delay          = col.delay,
                effect_number  = col.effect_number,
                effect_amount  = col.effect_amount,
            }
        end

        result[out_idx] = {
            note_columns     = res_cols,
            phrase_line_index = ph_idx,
            output_line_index = out_idx,
            time_in_beats     = (out_idx - 1) * beat_per_phrase_line,
        }
    end

    return result
end

---------------------------------------------------------------------------
-- Helper: extract a Zxx phrase trigger from a pattern line
---------------------------------------------------------------------------

--- Parse a pattern-editor line and return trigger info.
---
--- @param  line  table  { note_value, instrument_index, effect_columns={{number, amount},...} }
--- @return table        { note_value, instrument_index, phrase_index (1-based) or nil }

function M.parse_pattern_line(line)
    local result = {
        note_value       = line.note_value,
        instrument_index = line.instrument_index,
        phrase_index     = nil,
    }

    if line.effect_columns then
        for _, fx in ipairs(line.effect_columns) do
            local is_z = false

            -- Support numeric id (0x18) or string ("0Z" / "Z")
            if fx.number == M.EFFECT_Z then
                is_z = true
            elseif fx.number_string then
                local s = fx.number_string:upper()
                if s == "0Z" or s == "Z" then
                    is_z = true
                end
            end

            if is_z then
                result.phrase_index = fx.amount + 1   -- Renoise Z00 → phrase 1
                break
            end
        end
    end

    return result
end

---------------------------------------------------------------------------
-- High-level: resolve a pattern line + instrument → note sequence
---------------------------------------------------------------------------

--- Given a pattern line and the full instrument table, resolve the phrase.
---
--- @param  pattern_line  table   (see parse_pattern_line)
--- @param  instrument    table   { phrases = { [1]=phrase, ... } }
--- @param  options       table?  (see resolve_phrase)
--- @return table|nil, string?    resolved lines, or nil + error message

function M.resolve_pattern_phrase(pattern_line, instrument, options)
    local parsed = M.parse_pattern_line(pattern_line)

    if not parsed.note_value or
            parsed.note_value == M.NOTE_OFF or
            parsed.note_value == M.NOTE_EMPTY then
        return nil, "No valid trigger note"
    end

    if not parsed.phrase_index then
        return nil, "No Zxx phrase trigger found"
    end

    if not instrument or not instrument.phrases then
        return nil, "Instrument has no phrases"
    end

    local phrase = instrument.phrases[parsed.phrase_index]
    if not phrase then
        return nil, "Phrase index " .. parsed.phrase_index .. " out of range"
    end

    return M.resolve_phrase(parsed.note_value, phrase, options)
end

---------------------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------------------

--- Convert a note value (0-119) to a human-readable string like "C-4".
function M.note_to_string(note_value)
    if note_value == M.NOTE_OFF   then return "OFF" end
    if note_value == M.NOTE_EMPTY then return "---" end
    if note_value < 0 or note_value > 119 then return "???" end

    local names = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}
    local name   = names[(note_value % 12) + 1]
    local octave = math.floor(note_value / 12)
    return name .. octave
end

--- Convert a human-readable note string ("C-4") back to a value.
function M.string_to_note(s)
    if s == "OFF" then return M.NOTE_OFF   end
    if s == "---" then return M.NOTE_EMPTY end

    local map = {
        ["C-"]=0,["C#"]=1,["D-"]=2,["D#"]=3,["E-"]=4,["F-"]=5,
        ["F#"]=6,["G-"]=7,["G#"]=8,["A-"]=9,["A#"]=10,["B-"]=11,
    }

    local name   = s:sub(1, 2)
    local octave = tonumber(s:sub(3, 3))
    if not map[name] or not octave then return nil end
    return octave * 12 + map[name]
end

return M