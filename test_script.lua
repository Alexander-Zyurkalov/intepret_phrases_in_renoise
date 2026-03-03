---
--- test_phrase_in_renoise.lua
--- Run in the Renoise Scripting Terminal via dofile().
---
--- Reads phrase 1 from instrument 1, converts it to the plain-table
--- format (minimal adapter since property names match the API), resolves
--- it, and prints the notes.
---

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Adapter: Renoise API objects → plain tables
--
-- We need this because Renoise API objects are userdata, not plain Lua
-- tables. But the property names are now identical, so the adapter just
-- reads each property and puts it into a table field of the same name.
---------------------------------------------------------------------------

local function note_column_to_table(nc)
    return {
        note_value          = nc.note_value,
        instrument_value    = nc.instrument_value,
        volume_value        = nc.volume_value,
        panning_value       = nc.panning_value,
        delay_value         = nc.delay_value,
        effect_number_value = nc.effect_number_value,
        effect_number_string = nc.effect_number_string,
        effect_amount_value = nc.effect_amount_value,
    }
end

local function effect_column_to_table(fc)
    return {
        number_value  = fc.number_value,
        number_string = fc.number_string,
        amount_value  = fc.amount_value,
        amount_string = fc.amount_string,
    }
end

local function renoise_phrase_to_table(rns_phrase)
    local lines = {}

    for line_idx = 1, rns_phrase.number_of_lines do
        local rns_line = rns_phrase:line(line_idx)

        local note_cols = {}
        for col_idx = 1, rns_phrase.visible_note_columns do
            note_cols[col_idx] = note_column_to_table(rns_line:note_column(col_idx))
        end

        local fx_cols = {}
        for col_idx = 1, rns_phrase.visible_effect_columns do
            fx_cols[col_idx] = effect_column_to_table(rns_line:effect_column(col_idx))
        end

        lines[line_idx] = {
            note_columns   = note_cols,
            effect_columns = fx_cols,
        }
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
print(string.format("FX cols    : %d", rns_phrase.visible_effect_columns))
print("================================================================")

local phrase_tbl = renoise_phrase_to_table(rns_phrase)

-- Resolve at base note (no transposition)
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
            line.phrase_line_index, line.time_in_beats)

    for _, col in ipairs(line.note_columns) do
        local note_str = PR.note_to_string(col.note_value)
        local vol_str  = col.volume_value and col.volume_value ~= 255
                and string.format("%3d", col.volume_value) or " .."
        row = row .. string.format("  %-5s %s", note_str, vol_str)
    end
    print(row)
end

-- Transposed +12
local transposed_note = math.min(119, trigger_note + 12)
print(string.format(
        "\n--- Same phrase triggered at %s (+12 semitones) ---\n",
        PR.note_to_string(transposed_note)))

local resolved_t = PR.resolve_phrase(transposed_note, phrase_tbl)

for _, line in ipairs(resolved_t) do
    local row = string.format("%3d    %-6.3f",
            line.phrase_line_index, line.time_in_beats)
    for _, col in ipairs(line.note_columns) do
        local note_str = PR.note_to_string(col.note_value)
        local vol_str  = col.volume_value and col.volume_value ~= 255
                and string.format("%3d", col.volume_value) or " .."
        row = row .. string.format("  %-5s %s", note_str, vol_str)
    end
    print(row)
end

print("\n================================================================")
print("Done.")