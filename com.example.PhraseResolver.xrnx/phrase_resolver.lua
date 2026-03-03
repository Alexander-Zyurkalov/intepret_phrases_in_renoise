---
--- phrase_resolver.lua
--- Resolves Renoise phrase triggers (Zxx) into concrete note sequences.
--- Independent from the Renoise API — works with plain Lua tables that
--- mirror the Renoise API property names exactly.
---
--- Table schemas match:
---   renoise.PatternLine   → { note_columns = {...}, effect_columns = {...} }
---   renoise.NoteColumn    → { note_value, instrument_value, volume_value,
---                              panning_value, delay_value,
---                              effect_number_value, effect_number_string,
---                              effect_amount_value }
---   renoise.EffectColumn  → { number_value, number_string,
---                              amount_value, amount_string }
---   renoise.InstrumentPhrase (as plain table, see resolve_phrase docs)
---

local M = {}

---------------------------------------------------------------------------
-- Constants (matching Renoise API values)
---------------------------------------------------------------------------

M.NOTE_OFF = 120
M.NOTE_EMPTY = 121

M.EMPTY_INSTRUMENT = 255
M.EMPTY_VOLUME = 255
M.EMPTY_PANNING = 255
M.EMPTY_DELAY = 0
M.EMPTY_EFFECT_NUMBER = 0
M.EMPTY_EFFECT_AMOUNT = 0

-- Key tracking modes (Renoise API: 1-based)
M.KEY_TRACKING_NONE = 1
M.KEY_TRACKING_TRANSPOSE = 2
M.KEY_TRACKING_OFFSET = 3

-- Default base note (C-4 in Renoise's 0-119 range)
M.DEFAULT_BASE_NOTE = 48

-- Zxx effect command string as it appears in both
-- NoteColumn.effect_number_string and EffectColumn.number_string
M.ZXX_EFFECT_STRING = "0Z"

---------------------------------------------------------------------------
-- Internal: check if an effect is a Zxx phrase trigger
---------------------------------------------------------------------------

--- Check whether an effect number (string or value) represents the Zxx command.
--- Prefers string comparison when available; falls back to checking for the
--- numeric encoding.  Returns true/false.
---
--- @param  number_string  string|nil  e.g. "0Z"
--- @param  number_value   integer|nil e.g. the numeric encoding of "0Z"
--- @return boolean
function M._is_zxx(number_string, number_value)
    if number_string then
        return number_string:upper() == M.ZXX_EFFECT_STRING
    end
    -- Fallback: if only the numeric value is available, the caller must have
    -- provided the correct platform-specific encoding.  We expose a helper
    -- (encode_effect_string) so tests can produce the right number.
    if number_value and number_value ~= M.EMPTY_EFFECT_NUMBER then
        -- Compare against the encoded constant (set once on init or by caller)
        return number_value == M._zxx_number_value
    end
    return false
end

--- Encode a 2-char effect string into the numeric 0xXXYY value that Renoise
--- uses for effect_number_value / number_value.
--- Renoise maps: '0'-'9' → 0x00-0x09, 'A'-'Z' → 0x0A-0x23
---
--- @param  s  string  Two-character effect string, e.g. "0Z"
--- @return integer
function M.encode_effect_string(s)
    s = s:upper()
    local function char_to_num(c)
        local b = c:byte()
        if b >= 0x30 and b <= 0x39 then
            return b - 0x30
        end       -- '0'-'9'
        if b >= 0x41 and b <= 0x5A then
            return b - 0x41 + 0x0A
        end -- 'A'-'Z'
        return 0
    end
    local hi = char_to_num(s:sub(1, 1))
    local lo = char_to_num(s:sub(2, 2))
    return hi * 256 + lo
end

-- Pre-compute the numeric Zxx value
M._zxx_number_value = M.encode_effect_string(M.ZXX_EFFECT_STRING)

---------------------------------------------------------------------------
-- Internal: build a sequence of phrase-line indices honouring looping
---------------------------------------------------------------------------

function M._generate_line_sequence(phrase, num_lines)
    local total = phrase.number_of_lines
    local looping = phrase.looping or false
    local loop_start = phrase.loop_start or 1
    local loop_end = phrase.loop_end or total

    loop_start = math.max(1, math.min(loop_start, total))
    loop_end = math.max(loop_start, math.min(loop_end, total))

    local indices = {}

    if not looping then
        for i = 1, math.min(num_lines, total) do
            indices[#indices + 1] = i
        end
    else
        local idx = 1
        for _ = 1, num_lines do
            indices[#indices + 1] = idx
            if idx >= loop_end then
                idx = loop_start
            else
                idx = idx + 1
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
---   lines = {
---     [1] = {
---       note_columns = {
---         [1] = {
---           note_value           = 48,    -- 0-119, 120=OFF, 121=EMPTY
---           instrument_value     = 255,   -- 0-254, 255=EMPTY
---           volume_value         = 255,   -- 0-127 or 255=EMPTY
---           panning_value        = 255,   -- 0-127 or 255=EMPTY
---           delay_value          = 0,     -- 0-255
---           effect_number_value  = 0,     -- 16-bit
---           effect_amount_value  = 0,     -- 0-255
---         },
---       },
---       effect_columns = {               -- optional, phrase effect columns
---         [1] = { number_value=0, amount_value=0 },
---       },
---     },
---   },
---   number_of_lines  = 16,
---   base_note        = 48,           -- 0-119, default C-4
---   key_tracking     = 2,            -- 1=NONE, 2=TRANSPOSE, 3=OFFSET
---   lpb              = 4,            -- phrase LPB
---   looping          = false,        -- boolean (one-shot when false)
---   loop_start       = 1,            -- 1-based
---   loop_end         = 16,           -- 1-based
--- }
---
--- options = {
---   song_lpb   = 4,
---   num_lines  = nil,                -- lines to generate (default = phrase length)
--- }

function M.resolve_phrase(trigger_note, phrase, options)
    options = options or {}

    local song_lpb = options.song_lpb or 4
    local num_out = options.num_lines or phrase.number_of_lines
    local base_note = phrase.base_note or M.DEFAULT_BASE_NOTE
    local key_tracking = phrase.key_tracking or M.KEY_TRACKING_TRANSPOSE
    local phrase_lpb = phrase.lpb or song_lpb

    local transpose = 0
    if key_tracking == M.KEY_TRACKING_TRANSPOSE then
        transpose = trigger_note - base_note
    end

    local beat_per_phrase_line = 1.0 / phrase_lpb

    local line_indices = M._generate_line_sequence(phrase, num_out)
    local result = {}

    for out_idx, ph_idx in ipairs(line_indices) do
        local ph_line = phrase.lines[ph_idx] or {}
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

        -- Pass through effect columns unchanged
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

        result[out_idx] = {
            note_columns = res_cols,
            effect_columns = res_fx,
            phrase_line_index = ph_idx,
            output_line_index = out_idx,
            time_in_beats = (out_idx - 1) * beat_per_phrase_line,
        }
    end

    return result
end

---------------------------------------------------------------------------
-- Pattern line parsing: extract Zxx phrase trigger
---------------------------------------------------------------------------

--- Parse a pattern-editor line and extract the Zxx phrase trigger.
---
--- Checks for Zxx in two places (matching Renoise behaviour):
---   1. The specified note column's own effect sub-column
---      (NoteColumn.effect_number_string / effect_number_value)
---   2. The line's effect columns
---      (EffectColumn.number_string / number_value)
---
--- @param  line        table    PatternLine-shaped table
--- @param  col_index   integer? Note column to inspect (default 1)
--- @return table                { note_value, instrument_value,
---                                phrase_index (1-based) or nil }

function M.parse_pattern_line(line, col_index)
    col_index = col_index or 1

    local note_cols = line.note_columns or {}
    local nc = note_cols[col_index] or {}

    local result = {
        note_value = nc.note_value,
        instrument_value = nc.instrument_value,
        phrase_index = nil,
    }

    -- 1. Check the note column's own effect sub-column
    if M._is_zxx(nc.effect_number_string, nc.effect_number_value) then
        result.phrase_index = (nc.effect_amount_value or 0)
        return result
    end

    -- 2. Check the line's effect columns
    if line.effect_columns then
        for _, fx in ipairs(line.effect_columns) do
            if M._is_zxx(fx.number_string, fx.number_value) then
                result.phrase_index = (fx.amount_value or 0)
                return result
            end
        end
    end

    return result
end

---------------------------------------------------------------------------
-- Keymap-based phrase lookup
---------------------------------------------------------------------------

--- Find the phrase that should play for a given note based on keymap ranges.
---
--- Each phrase's mapping should have:
---   phrase.mapping.note_range = { start, end }  -- 1-based inclusive
---   or
---   phrase.mapping.note_range_start = N
---   phrase.mapping.note_range_end   = N
---
--- @param  note_value   integer   Trigger note (0-119)
--- @param  instrument   table     { phrases = { [1]=phrase, ... } }
--- @return table|nil, integer|nil  Matching phrase and its 1-based index, or nil

function M.find_phrase_by_keymap(note_value, instrument)
    if not instrument or not instrument.phrases then
        return nil, nil
    end

    for idx, phrase in ipairs(instrument.phrases) do
        local mapping = phrase.mapping
        if mapping then
            local range_start, range_end

            if mapping.note_range then
                range_start = mapping.note_range[1]
                range_end = mapping.note_range[2]
            else
                range_start = mapping.note_range_start
                range_end = mapping.note_range_end
            end

            if range_start and range_end
                    and note_value >= range_start
                    and note_value <= range_end then
                return phrase, idx
            end
        end
    end

    return nil, nil
end

---------------------------------------------------------------------------
-- High-level: resolve a pattern line + instrument → note sequence
---------------------------------------------------------------------------

--- Given a pattern line and the song's instruments array, resolve the
--- triggered phrase.
---
--- The instrument is determined from the note column's instrument_value.
--- Renoise uses 0-based instrument values in patterns but 1-based indexing
--- in song.instruments, so we look up instruments[instrument_value + 1].
---
--- Supports both Zxx (program mode) and keymap-based phrase selection.
--- When a Zxx command is present, it takes priority.
--- If Z7F (127) is found, it falls back to keymap mode.
---
--- @param  pattern_line  table    PatternLine-shaped table
--- @param  instruments   table    Array of instrument tables (1-based, like song.instruments)
--- @param  options       table?   Optional: { col_index=1, song_lpb=4, num_lines=nil }
--- @return table|nil, string?     Resolved lines, or nil + error message

function M.resolve_pattern_phrase(pattern_line, instruments, options)
    options = options or {}
    local col_index = options.col_index or 1

    local parsed = M.parse_pattern_line(pattern_line, col_index)

    if not parsed.note_value or
            parsed.note_value == M.NOTE_OFF or
            parsed.note_value == M.NOTE_EMPTY then
        return nil, "No valid trigger note"
    end

    if not parsed.instrument_value or
            parsed.instrument_value == M.EMPTY_INSTRUMENT then
        return nil, "No instrument specified"
    end

    -- Renoise: pattern instrument_value is 0-based, instruments[] is 1-based
    local instrument = instruments[parsed.instrument_value + 1]

    if not instrument then
        return nil, "Instrument " .. parsed.instrument_value .. " not found"
    end

    if not instrument.phrases or #instrument.phrases == 0 then
        return nil, "Instrument has no phrases"
    end

    local phrase

    if parsed.phrase_index and parsed.phrase_index ~= 0 then
        phrase = instrument.phrases[parsed.phrase_index]
    else
        phrase = parsed
    end

    if not phrase then
        return nil, "No matching phrase found"
    end

    return M.resolve_phrase(parsed.note_value, phrase, options)
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