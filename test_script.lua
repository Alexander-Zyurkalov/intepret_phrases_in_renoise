---
--- test_phrase_in_renoise.lua
--- Run this in the Renoise Scripting Terminal (Edit → Scripting Terminal → paste & execute).
---
--- It reads the first phrase of the first instrument, converts it into
--- the plain-table format that phrase_resolver expects, resolves it for
--- the base note and +12 semitones, and prints the resulting notes.
---

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Adapter: convert a Renoise InstrumentPhrase into a plain table
---------------------------------------------------------------------------

local function renoise_phrase_to_table(rns_phrase)
    local lines = {}

    for line_idx = 1, rns_phrase.number_of_lines do
        local rns_line = rns_phrase:line(line_idx)
        local cols = {}

        for col_idx = 1, rns_phrase.visible_note_columns do
            local nc = rns_line:note_column(col_idx)
            cols[col_idx] = {
                note_value    = nc.note_value,
                volume        = nc.volume_value,
                panning       = nc.panning_value,
                delay         = nc.delay_value,
                effect_number = nc.effect_number_value,
                effect_amount = nc.effect_amount_value,
            }
        end

        lines[line_idx] = { note_columns = cols }
    end

    return {
        lines           = lines,
        number_of_lines = rns_phrase.number_of_lines,
        base_note       = rns_phrase.base_note,
        key_tracking    = rns_phrase.key_tracking,
        lpb             = rns_phrase.lpb,
        looping         = rns_phrase.looping,
        loop_start      = rns_phrase.loop_start,
        loop_end        = rns_phrase.loop_end,
    }
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local song       = renoise.song()
local instrument = song.instruments[1]
local rns_phrase = instrument.phrases[1]

print("================================================================")
print(string.format("Instrument : %s", instrument.name))
print(string.format("Phrase     : %s", rns_phrase.name))
print(string.format("Lines      : %d", rns_phrase.number_of_lines))
print(string.format("LPB        : %d", rns_phrase.lpb))
print(string.format("Looping    : %s", tostring(rns_phrase.looping)))
print(string.format("Loop range : %d - %d", rns_phrase.loop_start, rns_phrase.loop_end))
print(string.format("Base note  : %s (%d)", PR.note_to_string(rns_phrase.base_note), rns_phrase.base_note))
print(string.format("Key track  : %d", rns_phrase.key_tracking))
print(string.format("Note cols  : %d", rns_phrase.visible_note_columns))
print("================================================================")

local phrase_tbl = renoise_phrase_to_table(rns_phrase)

-- Resolve at the phrase's own base note (no transposition)
local trigger_note = phrase_tbl.base_note
print(string.format("\nResolving at trigger note %s (base note, no transposition):\n",
        PR.note_to_string(trigger_note)))

local resolved = PR.resolve_phrase(trigger_note, phrase_tbl)

-- Header
local hdr = string.format("%-5s  %-6s", "LINE", "BEAT")
for c = 1, rns_phrase.visible_note_columns do
    hdr = hdr .. string.format("  %-5s %-4s", "N" .. c, "VOL")
end
print(hdr)
print(string.rep("-", #hdr + 4))

-- Rows
for _, line in ipairs(resolved) do
    local row = string.format("%3d    %-6.3f",
            line.phrase_line_index,
            line.time_in_beats)

    for _, col in ipairs(line.note_columns) do
        local note_str = PR.note_to_string(col.note_value)
        local vol_str  = col.volume and col.volume ~= 255
                and string.format("%3d", col.volume) or " .."
        row = row .. string.format("  %-5s %s", note_str, vol_str)
    end

    print(row)
end

-- Also show what it would sound like transposed up an octave
local transposed_note = math.min(119, trigger_note + 12)
print(string.format(
        "\n--- Same phrase triggered at %s (+12 semitones) ---\n",
        PR.note_to_string(transposed_note)))

local resolved_t = PR.resolve_phrase(transposed_note, phrase_tbl)

for _, line in ipairs(resolved_t) do
    local row = string.format("%3d    %-6.3f", line.phrase_line_index, line.time_in_beats)
    for _, col in ipairs(line.note_columns) do
        local note_str = PR.note_to_string(col.note_value)
        local vol_str  = col.volume and col.volume ~= 255
                and string.format("%3d", col.volume) or " .."
        row = row .. string.format("  %-5s %s", note_str, vol_str)
    end
    print(row)
end

print("\n================================================================")
print("Done.")