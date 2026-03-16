--- debug_build_phrase.lua
---
--- A minimal script to step through resolved_track_iter + build_phrase_from_iter.
--- Set a breakpoint inside either function and run this file.

local M = require("phrase_resolver")

--- Make a simple note column table.
local function ncol(note_value, opts)
    opts = opts or {}
    return {
        note_value = note_value,
        instrument_value = opts.instrument_value or M.EMPTY_INSTRUMENT,
        volume_value = opts.volume_value or M.EMPTY_VOLUME,
        panning_value = opts.panning_value or M.EMPTY_PANNING,
        delay_value = opts.delay_value or M.EMPTY_DELAY,
        effect_number_value = opts.effect_number_value or M.EMPTY_EFFECT_NUMBER,
        effect_number_string = opts.effect_number_string,
        effect_amount_value = opts.effect_amount_value or M.EMPTY_EFFECT_AMOUNT,
    }
end

--- Make a pattern line from a single note column.
local function pline(note_col, fx_cols)
    return {
        note_columns = note_col and { note_col } or {},
        effect_columns = fx_cols or {},
    }
end

--- Make an empty pattern line.
local function empty_line()
    return {
        note_columns = { ncol(M.NOTE_EMPTY) },
        effect_columns = {},
    }
end

--- Turn an array of pattern lines into a stateful iterator.
local function array_iter(lines)
    local i = 0
    return function()
        i = i + 1
        return lines[i]
    end
end
-- Trigger track: the original pattern column the user wrote
local trigger_track = {
    pline(48), -- C-4 (trigger note)
    pline(M.NOTE_EMPTY), -- ...
    pline(M.NOTE_EMPTY), -- ...
    pline(55), -- G-4 (next phrase, not reached)
    pline(M.NOTE_OFF), -- OFF → end of phrase
}

-- Resolved track: what Renoise produces after phrase resolution
local resolved_track = {
    pline(48, 100), -- C-4, vol 100
    pline(49, 80), -- sustain, vol 80
    pline(M.NOTE_EMPTY, 60), -- sustain, vol 60
    pline(M.NOTE_OFF), -- OFF
    pline(55, 100), -- G-4 (next phrase)
}

---------------------------------------------------------------------------
-- Build the iterator, then build the phrase
---------------------------------------------------------------------------

--local iter = M.resolved_track_iter(trigger_track, resolved_track, 1)
--local phrase = M.build_phrase_from_iter(iter, { song_lpb = 4 })

local lines = { empty_line(), empty_line() }
local phrase = M.build_phrase_from_iter(array_iter(lines))

---------------------------------------------------------------------------
-- Print the result
---------------------------------------------------------------------------

print("base_note:       " .. M.note_to_string(phrase.base_note))
print("number_of_lines: " .. phrase.number_of_lines)
print("lpb:             " .. phrase.lpb)
print()

for idx, pline in ipairs(phrase.lines) do
    local col = pline.note_columns[1] or {}
    local note_str = col.note_value and M.note_to_string(col.note_value) or "---"
    local vol_str = (col.volume_value and col.volume_value ~= M.EMPTY_VOLUME)
            and tostring(col.volume_value) or ".."
    local inst_str = (col.instrument_value and col.instrument_value ~= M.EMPTY_INSTRUMENT)
            and string.format("%02X", col.instrument_value) or ".."

    print(string.format("  %02d | %s  %s  %s", idx, note_str, inst_str, vol_str))
end

