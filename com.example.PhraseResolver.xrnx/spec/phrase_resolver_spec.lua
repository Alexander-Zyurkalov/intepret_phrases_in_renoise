---
--- phrase_resolver_spec.lua
--- Unit tests for phrase_resolver — run with: busted phrase_resolver_spec.lua
---

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Test helpers
---------------------------------------------------------------------------

--- Build a minimal phrase table using Renoise API property names.
--- @param notes       table   2-D array: notes[line][column] = note_value
--- @param overrides   table?  Extra fields merged onto the phrase
local function make_phrase(notes, overrides)
    local lines = {}
    for i, line_notes in ipairs(notes) do
        local cols = {}
        for j, nv in ipairs(line_notes) do
            cols[j] = {
                note_value          = nv,
                instrument_value    = PR.EMPTY_INSTRUMENT,
                volume_value        = 128,
                panning_value       = PR.EMPTY_PANNING,
                delay_value         = PR.EMPTY_DELAY,
                effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                effect_amount_value = PR.EMPTY_EFFECT_AMOUNT,
            }
        end
        lines[i] = { note_columns = cols, effect_columns = {} }
    end

    local phrase = {
        lines           = lines,
        number_of_lines = #lines,
        base_note       = PR.DEFAULT_BASE_NOTE,
        key_tracking    = PR.KEY_TRACKING_TRANSPOSE,
        lpb             = 4,
        looping         = false,
        loop_start      = 1,
        loop_end        = #lines,
    }

    if overrides then
        for k, v in pairs(overrides) do phrase[k] = v end
    end
    return phrase
end

--- Build a PatternLine-shaped table with a Zxx in the effect columns.
local function make_pattern_line_fx(note_value, inst_value, z_amount)
    return {
        note_columns = {
            {
                note_value          = note_value,
                instrument_value    = inst_value or 0,
                volume_value        = PR.EMPTY_VOLUME,
                panning_value       = PR.EMPTY_PANNING,
                delay_value         = PR.EMPTY_DELAY,
                effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                effect_amount_value = PR.EMPTY_EFFECT_AMOUNT,
            },
        },
        effect_columns = z_amount and {
            { number_string = "0Z", number_value = PR._zxx_number_value,
              amount_value = z_amount },
        } or {},
    }
end

--- Build a PatternLine where Zxx lives in the note column's effect sub-column.
local function make_pattern_line_nc(note_value, inst_value, z_amount)
    return {
        note_columns = {
            {
                note_value          = note_value,
                instrument_value    = inst_value or 0,
                volume_value        = PR.EMPTY_VOLUME,
                panning_value       = PR.EMPTY_PANNING,
                delay_value         = PR.EMPTY_DELAY,
                effect_number_string = "0Z",
                effect_number_value = PR._zxx_number_value,
                effect_amount_value = z_amount,
            },
        },
        effect_columns = {},
    }
end

--- Collect resolved note values from column 1 of each output line.
local function collect_notes(resolved)
    local out = {}
    for i, line in ipairs(resolved) do
        local col = line.note_columns[1]
        out[i] = col and col.note_value or nil
    end
    return out
end

---------------------------------------------------------------------------
-- note_to_string / string_to_note
---------------------------------------------------------------------------

describe("note_to_string", function()
    it("converts C-0", function() assert.are.equal("C-0", PR.note_to_string(0)) end)
    it("converts C-4", function() assert.are.equal("C-4", PR.note_to_string(48)) end)
    it("converts A#9", function() assert.are.equal("A#9", PR.note_to_string(118)) end)
    it("converts B-9", function() assert.are.equal("B-9", PR.note_to_string(119)) end)
    it("returns OFF",  function() assert.are.equal("OFF", PR.note_to_string(PR.NOTE_OFF)) end)
    it("returns ---",  function() assert.are.equal("---", PR.note_to_string(PR.NOTE_EMPTY)) end)
    it("returns ???",  function()
        assert.are.equal("???", PR.note_to_string(200))
        assert.are.equal("???", PR.note_to_string(-1))
    end)
end)

describe("string_to_note", function()
    it("round-trips all valid notes", function()
        for n = 0, 119 do
            assert.are.equal(n, PR.string_to_note(PR.note_to_string(n)))
        end
    end)
    it("handles OFF", function() assert.are.equal(PR.NOTE_OFF, PR.string_to_note("OFF")) end)
    it("handles ---", function() assert.are.equal(PR.NOTE_EMPTY, PR.string_to_note("---")) end)
    it("returns nil for garbage", function() assert.is_nil(PR.string_to_note("XYZ")) end)
end)

---------------------------------------------------------------------------
-- encode_effect_string
---------------------------------------------------------------------------

describe("encode_effect_string", function()
    it("encodes '0Z' correctly", function()
        -- '0' → 0x00, 'Z' → 0x23 → result = 0x0023 = 35
        assert.are.equal(35, PR.encode_effect_string("0Z"))
    end)

    it("encodes '00' to zero", function()
        assert.are.equal(0, PR.encode_effect_string("00"))
    end)

    it("encodes 'ZZ'", function()
        -- 'Z' → 0x23 = 35 → result = 35*256 + 35 = 8995
        assert.are.equal(35 * 256 + 35, PR.encode_effect_string("ZZ"))
    end)

    it("is case-insensitive", function()
        assert.are.equal(PR.encode_effect_string("0Z"), PR.encode_effect_string("0z"))
    end)
end)

---------------------------------------------------------------------------
-- _is_zxx
---------------------------------------------------------------------------

describe("_is_zxx", function()
    it("detects Zxx via string", function()
        assert.is_true(PR._is_zxx("0Z", nil))
    end)

    it("detects Zxx via string case-insensitively", function()
        assert.is_true(PR._is_zxx("0z", nil))
    end)

    it("detects Zxx via numeric value", function()
        assert.is_true(PR._is_zxx(nil, PR._zxx_number_value))
    end)

    it("rejects non-Z strings", function()
        assert.is_false(PR._is_zxx("0G", nil))
    end)

    it("rejects empty effect number", function()
        assert.is_false(PR._is_zxx(nil, PR.EMPTY_EFFECT_NUMBER))
    end)

    it("rejects nil/nil", function()
        assert.is_false(PR._is_zxx(nil, nil))
    end)
end)

---------------------------------------------------------------------------
-- _transpose_note
---------------------------------------------------------------------------

describe("_transpose_note", function()
    it("transposes up",              function() assert.are.equal(60, PR._transpose_note(48, 12)) end)
    it("transposes down",            function() assert.are.equal(36, PR._transpose_note(48, -12)) end)
    it("clamps at 0",               function() assert.are.equal(0, PR._transpose_note(5, -20)) end)
    it("clamps at 119",             function() assert.are.equal(119, PR._transpose_note(110, 20)) end)
    it("leaves NOTE_OFF unchanged", function() assert.are.equal(PR.NOTE_OFF, PR._transpose_note(PR.NOTE_OFF, 12)) end)
    it("leaves NOTE_EMPTY unchanged", function() assert.are.equal(PR.NOTE_EMPTY, PR._transpose_note(PR.NOTE_EMPTY, -5)) end)
end)

---------------------------------------------------------------------------
-- _generate_line_sequence
---------------------------------------------------------------------------

describe("_generate_line_sequence", function()
    it("one-shot sequence", function()
        local phrase = { number_of_lines = 4, looping = false }
        assert.are.same({1,2,3,4}, PR._generate_line_sequence(phrase, 4))
    end)

    it("truncates one-shot", function()
        local phrase = { number_of_lines = 8, looping = false }
        assert.are.same({1,2,3}, PR._generate_line_sequence(phrase, 3))
    end)

    it("caps one-shot at phrase length", function()
        local phrase = { number_of_lines = 3, looping = false }
        assert.are.same({1,2,3}, PR._generate_line_sequence(phrase, 10))
    end)

    it("forward loop with partial range", function()
        local phrase = { number_of_lines = 4, looping = true, loop_start = 2, loop_end = 4 }
        assert.are.same({1,2,3,4,2,3,4,2,3,4}, PR._generate_line_sequence(phrase, 10))
    end)

    it("forward loop covering full phrase", function()
        local phrase = { number_of_lines = 3, looping = true, loop_start = 1, loop_end = 3 }
        assert.are.same({1,2,3,1,2,3,1}, PR._generate_line_sequence(phrase, 7))
    end)

    it("single-line loop", function()
        local phrase = { number_of_lines = 4, looping = true, loop_start = 3, loop_end = 3 }
        assert.are.same({1,2,3,3,3,3}, PR._generate_line_sequence(phrase, 6))
    end)

    it("defaults to one-shot when looping is nil", function()
        local phrase = { number_of_lines = 3 }
        assert.are.same({1,2,3}, PR._generate_line_sequence(phrase, 5))
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — transposition
---------------------------------------------------------------------------

describe("resolve_phrase transposition", function()
    it("transposes up when trigger > base", function()
        local phrase = make_phrase({{48},{48},{48}})
        assert.are.same({60,60,60}, collect_notes(PR.resolve_phrase(60, phrase)))
    end)

    it("transposes down when trigger < base", function()
        local phrase = make_phrase({{48},{52},{55}})
        assert.are.same({36,40,43}, collect_notes(PR.resolve_phrase(36, phrase)))
    end)

    it("no transposition when trigger == base", function()
        local phrase = make_phrase({{48},{50},{52}})
        assert.are.same({48,50,52}, collect_notes(PR.resolve_phrase(48, phrase)))
    end)

    it("skips transposition when key_tracking is NONE", function()
        local phrase = make_phrase({{48},{50},{52}}, { key_tracking = PR.KEY_TRACKING_NONE })
        assert.are.same({48,50,52}, collect_notes(PR.resolve_phrase(96, phrase)))
    end)

    it("clamps at lower bound", function()
        assert.are.same({0}, collect_notes(PR.resolve_phrase(0, make_phrase({{5}}))))
    end)

    it("clamps at upper bound", function()
        assert.are.same({119}, collect_notes(PR.resolve_phrase(60, make_phrase({{115}}))))
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — special notes & multi-column
---------------------------------------------------------------------------

describe("resolve_phrase special notes", function()
    it("preserves NOTE_OFF",   function()
        local r = PR.resolve_phrase(60, make_phrase({{48},{PR.NOTE_OFF},{52}}))
        assert.are.equal(PR.NOTE_OFF, collect_notes(r)[2])
    end)
    it("preserves NOTE_EMPTY", function()
        local r = PR.resolve_phrase(60, make_phrase({{48},{PR.NOTE_EMPTY},{52}}))
        assert.are.equal(PR.NOTE_EMPTY, collect_notes(r)[2])
    end)
end)

describe("resolve_phrase multi-column", function()
    it("resolves all columns independently", function()
        local r = PR.resolve_phrase(60, make_phrase({{48, 52}, {50, 55}}))
        assert.are.equal(60, r[1].note_columns[1].note_value)
        assert.are.equal(64, r[1].note_columns[2].note_value)
        assert.are.equal(62, r[2].note_columns[1].note_value)
        assert.are.equal(67, r[2].note_columns[2].note_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — timing
---------------------------------------------------------------------------

describe("resolve_phrase timing", function()
    it("uses phrase LPB for beat calculation", function()
        local r = PR.resolve_phrase(48, make_phrase({{48},{48},{48},{48}}, { lpb = 8 }))
        assert.are.equal(0.0,   r[1].time_in_beats)
        assert.are.equal(0.125, r[2].time_in_beats)
        assert.are.equal(0.25,  r[3].time_in_beats)
        assert.are.equal(0.375, r[4].time_in_beats)
    end)

    it("falls back to song LPB when phrase LPB is nil", function()
        local phrase = make_phrase({{48},{48}})
        phrase.lpb = nil
        local r = PR.resolve_phrase(48, phrase, { song_lpb = 8 })
        assert.are.equal(0.125, r[2].time_in_beats)
    end)

    it("stores correct line indices", function()
        local r = PR.resolve_phrase(48, make_phrase({{48},{50},{52}}))
        for i = 1, 3 do
            assert.are.equal(i, r[i].phrase_line_index)
            assert.are.equal(i, r[i].output_line_index)
        end
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — metadata passthrough
---------------------------------------------------------------------------

describe("resolve_phrase metadata passthrough", function()
    it("preserves volume_value", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].note_columns[1].volume_value = 64
        local r = PR.resolve_phrase(48, phrase)
        assert.are.equal(64, r[1].note_columns[1].volume_value)
    end)

    it("preserves panning_value", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].note_columns[1].panning_value = 0x40
        local r = PR.resolve_phrase(48, phrase)
        assert.are.equal(0x40, r[1].note_columns[1].panning_value)
    end)

    it("preserves instrument_value", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].note_columns[1].instrument_value = 5
        local r = PR.resolve_phrase(48, phrase)
        assert.are.equal(5, r[1].note_columns[1].instrument_value)
    end)

    it("passes through effect columns", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].effect_columns = {
            { number_string = "0G", number_value = 10, amount_value = 0x50 },
        }
        local r = PR.resolve_phrase(48, phrase)
        assert.are.equal("0G", r[1].effect_columns[1].number_string)
        assert.are.equal(0x50, r[1].effect_columns[1].amount_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — edge cases
---------------------------------------------------------------------------

describe("resolve_phrase edge cases", function()
    it("handles empty phrase", function()
        local phrase = { lines = {}, number_of_lines = 0, lpb = 4 }
        assert.are.same({}, PR.resolve_phrase(48, phrase))
    end)

    it("handles line with no note_columns", function()
        local phrase = { lines = { [1] = {} }, number_of_lines = 1, lpb = 4 }
        local r = PR.resolve_phrase(48, phrase)
        assert.are.same({}, r[1].note_columns)
    end)

    it("treats nil note_value as EMPTY", function()
        local phrase = {
            lines = { [1] = { note_columns = { [1] = { volume_value = 128 } } } },
            number_of_lines = 1, lpb = 4,
        }
        local r = PR.resolve_phrase(48, phrase)
        assert.are.equal(PR.NOTE_EMPTY, r[1].note_columns[1].note_value)
    end)
end)

---------------------------------------------------------------------------
-- parse_pattern_line — Zxx in effect columns
---------------------------------------------------------------------------

describe("parse_pattern_line with Zxx in effect columns", function()
    it("extracts Zxx via number_string", function()
        local line = make_pattern_line_fx(48, 1, 0x05)  -- Z05 → phrase 5
        local p = PR.parse_pattern_line(line)
        assert.are.equal(48, p.note_value)
        assert.are.equal(1,  p.instrument_value)
        assert.are.equal(5,  p.phrase_index)
    end)

    it("Z00 means no phrase", function()
        local line = make_pattern_line_fx(48, 1, 0x00)  -- Z00 → no phrase
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)

    it("returns nil phrase_index when no Zxx present", function()
        local line = make_pattern_line_fx(48, 1, nil)
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)

    it("returns nil phrase_index for empty effect columns", function()
        local line = { note_columns = {{ note_value = 48, instrument_value = 1 }}, effect_columns = {} }
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)

    it("ignores non-Z effects", function()
        local line = {
            note_columns = {{ note_value = 48, instrument_value = 1 }},
            effect_columns = {
                { number_string = "0G", number_value = 10, amount_value = 5 },
            },
        }
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)
end)

---------------------------------------------------------------------------
-- parse_pattern_line — Zxx in note column effect sub-column
---------------------------------------------------------------------------

describe("parse_pattern_line with Zxx in note column", function()
    it("extracts Zxx from note column effect_number_string", function()
        local line = make_pattern_line_nc(60, 2, 0x03)  -- Z03 → phrase 3
        local p = PR.parse_pattern_line(line)
        assert.are.equal(60, p.note_value)
        assert.are.equal(3,  p.phrase_index)
    end)

    it("note column Zxx takes priority over effect column Zxx", function()
        -- Zxx in note column says phrase 2, effect column says phrase 6
        local line = {
            note_columns = {{
                                note_value = 48, instrument_value = 0,
                                effect_number_string = "0Z", effect_number_value = PR._zxx_number_value,
                                effect_amount_value = 0x02,  -- Z02 → phrase 2
                            }},
            effect_columns = {{
                                  number_string = "0Z", number_value = PR._zxx_number_value,
                                  amount_value = 0x06,  -- Z06 → phrase 6
                              }},
        }
        local p = PR.parse_pattern_line(line)
        assert.are.equal(2, p.phrase_index)  -- note column wins
    end)

    it("falls back to effect column when note column has no Zxx", function()
        local line = {
            note_columns = {{
                                note_value = 48, instrument_value = 0,
                                effect_number_string = "0G",
                                effect_amount_value = 0x50,
                            }},
            effect_columns = {{
                                  number_string = "0Z", number_value = PR._zxx_number_value,
                                  amount_value = 0x04,  -- Z04 → phrase 4
                              }},
        }
        local p = PR.parse_pattern_line(line)
        assert.are.equal(4, p.phrase_index)
    end)
end)

---------------------------------------------------------------------------
-- parse_pattern_line — col_index parameter
---------------------------------------------------------------------------

describe("parse_pattern_line col_index", function()
    it("reads from the specified note column", function()
        local line = {
            note_columns = {
                { note_value = 48, instrument_value = 0 },
                { note_value = 60, instrument_value = 1,
                  effect_number_string = "0Z", effect_amount_value = 0x01 },  -- Z01 → phrase 1
            },
            effect_columns = {},
        }
        local p = PR.parse_pattern_line(line, 2)
        assert.are.equal(60, p.note_value)
        assert.are.equal(1,  p.instrument_value)
        assert.are.equal(1,  p.phrase_index)
    end)

    it("defaults to column 1", function()
        local line = {
            note_columns = {
                { note_value = 48, instrument_value = 0,
                  effect_number_string = "0Z", effect_amount_value = 0x03 },  -- Z03 → phrase 3
                { note_value = 60, instrument_value = 1 },
            },
            effect_columns = {},
        }
        local p = PR.parse_pattern_line(line)
        assert.are.equal(48, p.note_value)
        assert.are.equal(3,  p.phrase_index)
    end)
end)

---------------------------------------------------------------------------
-- resolve_pattern_phrase — integration
---------------------------------------------------------------------------

describe("resolve_pattern_phrase", function()
    local instruments

    before_each(function()
        instruments = {
            -- instruments[1] = instrument_value 0 in pattern
            {
                phrases = {
                    [1] = make_phrase({{48},{52},{55}}),
                    [2] = make_phrase({{60},{64},{67}}, { base_note = 60 }),
                },
            },
            -- instruments[2] = instrument_value 1 in pattern
            {
                phrases = {
                    [1] = make_phrase({{36},{40},{43}}, { base_note = 36 }),
                },
            },
        }
    end)

    it("resolves Zxx from effect column", function()
        local line = make_pattern_line_fx(48, 0, 1)  -- inst 0, Z01 → phrase 1
        assert.are.same({48,52,55}, collect_notes(PR.resolve_pattern_phrase(line, instruments)))
    end)

    it("resolves Zxx from note column", function()
        local line = make_pattern_line_nc(48, 0, 1)  -- inst 0, Z01 → phrase 1
        assert.are.same({48,52,55}, collect_notes(PR.resolve_pattern_phrase(line, instruments)))
    end)

    it("resolves with transposition", function()
        local line = make_pattern_line_fx(72, 0, 2)  -- inst 0, Z02 → phrase 2, +12
        assert.are.same({72,76,79}, collect_notes(PR.resolve_pattern_phrase(line, instruments)))
    end)

    it("looks up the correct instrument by instrument_value", function()
        local line = make_pattern_line_fx(36, 1, 1)  -- inst 1, Z01 → instruments[2].phrases[1]
        assert.are.same({36,40,43}, collect_notes(PR.resolve_pattern_phrase(line, instruments)))
    end)

    -- Passthrough cases: return a single line with the trigger note

    it("passthrough for NOTE_OFF", function()
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(PR.NOTE_OFF, 0, 1), instruments)
        assert.are.equal(1, #r)
        assert.are.equal(PR.NOTE_OFF, r[1].note_columns[1].note_value)
    end)

    it("passthrough for NOTE_EMPTY", function()
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(PR.NOTE_EMPTY, 0, 1), instruments)
        assert.are.equal(1, #r)
        assert.are.equal(PR.NOTE_EMPTY, r[1].note_columns[1].note_value)
    end)

    it("passthrough when no Zxx present", function()
        local line = { note_columns = {{ note_value = 60, instrument_value = 0 }}, effect_columns = {} }
        local r = PR.resolve_pattern_phrase(line, instruments)
        assert.are.equal(1, #r)
        assert.are.equal(60, r[1].note_columns[1].note_value)
        assert.are.equal(0,  r[1].note_columns[1].instrument_value)
    end)

    it("passthrough for Z00 (no phrase)", function()
        local line = make_pattern_line_fx(48, 0, 0)  -- Z00 → no phrase
        local r = PR.resolve_pattern_phrase(line, instruments)
        assert.are.equal(1, #r)
        assert.are.equal(48, r[1].note_columns[1].note_value)
    end)

    it("passthrough for EMPTY instrument", function()
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(48, PR.EMPTY_INSTRUMENT, 1), instruments)
        assert.are.equal(1, #r)
        assert.are.equal(48, r[1].note_columns[1].note_value)
    end)

    it("passthrough when instrument index is out of range", function()
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(48, 99, 1), instruments)
        assert.are.equal(1, #r)
        assert.are.equal(48, r[1].note_columns[1].note_value)
    end)

    it("passthrough when phrase index is out of range", function()
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(48, 0, 99), instruments)
        assert.are.equal(1, #r)
        assert.are.equal(48, r[1].note_columns[1].note_value)
    end)

    it("passthrough when instrument has no phrases", function()
        local empty_instruments = { { phrases = {} } }
        local r = PR.resolve_pattern_phrase(make_pattern_line_fx(48, 0, 1), empty_instruments)
        assert.are.equal(1, #r)
        assert.are.equal(48, r[1].note_columns[1].note_value)
    end)

    it("passthrough preserves volume and panning", function()
        local line = {
            note_columns = {{
                                note_value = 60, instrument_value = 0,
                                volume_value = 80, panning_value = 64,
                                delay_value = 10,
                            }},
            effect_columns = {},
        }
        local r = PR.resolve_pattern_phrase(line, instruments)
        assert.are.equal(80, r[1].note_columns[1].volume_value)
        assert.are.equal(64, r[1].note_columns[1].panning_value)
        assert.are.equal(10, r[1].note_columns[1].delay_value)
    end)

    it("passthrough has time_in_beats = 0", function()
        local line = { note_columns = {{ note_value = 60, instrument_value = 0 }}, effect_columns = {} }
        local r = PR.resolve_pattern_phrase(line, instruments)
        assert.are.equal(0.0, r[1].time_in_beats)
        assert.is_nil(r[1].phrase_line_index)
        assert.are.equal(1, r[1].output_line_index)
    end)

    it("passes options through", function()
        local line = make_pattern_line_fx(48, 0, 1)  -- Z01 → phrase 1
        local r = PR.resolve_pattern_phrase(line, instruments, { num_lines = 2 })
        assert.are.equal(2, #r)
    end)

    it("respects col_index option", function()
        local line = {
            note_columns = {
                { note_value = PR.NOTE_EMPTY, instrument_value = PR.EMPTY_INSTRUMENT },
                { note_value = 48, instrument_value = 0,
                  effect_number_string = "0Z", effect_amount_value = 1 },  -- Z01 → phrase 1
            },
            effect_columns = {},
        }
        local r = PR.resolve_pattern_phrase(line, instruments, { col_index = 2 })
        assert.are.same({48,52,55}, collect_notes(r))
    end)
end)

---------------------------------------------------------------------------
-- resolved_to_pattern_lines
---------------------------------------------------------------------------

describe("resolved_to_pattern_lines", function()
    it("maps 1:1 when phrase LPB == song LPB", function()
        local phrase = make_phrase({{48},{52},{55}}, { lpb = 4 })
        local resolved = PR.resolve_phrase(48, phrase, { song_lpb = 4 })
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        assert.are.equal(3, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(52, lines[2].note_columns[1].note_value)
        assert.are.equal(55, lines[3].note_columns[1].note_value)
        assert.are.equal(0,  lines[1].note_columns[1].delay_value)
        assert.are.equal(0,  lines[2].note_columns[1].delay_value)
    end)

    it("spreads out when phrase LPB < song LPB", function()
        -- phrase LPB=2, song LPB=4: each phrase line spans 2 song lines
        local phrase = make_phrase({{48},{52},{55}}, { lpb = 2 })
        local resolved = PR.resolve_phrase(48, phrase, { song_lpb = 2 })
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        -- time_in_beats: 0.0, 0.5, 1.0 → offsets at LPB 4: 0, 2, 4
        assert.are.equal(5, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(0,  #lines[2].note_columns)  -- empty gap
        assert.are.equal(52, lines[3].note_columns[1].note_value)
        assert.are.equal(0,  #lines[4].note_columns)  -- empty gap
        assert.are.equal(55, lines[5].note_columns[1].note_value)
    end)

    it("compresses when phrase LPB > song LPB, using delay", function()
        -- phrase LPB=8, song LPB=4: two phrase lines per song line
        local phrase = make_phrase({{48},{52},{55},{60}}, { lpb = 8 })
        local resolved = PR.resolve_phrase(48, phrase, { song_lpb = 8 })
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        -- time_in_beats: 0, 0.125, 0.25, 0.375 → at LPB 4: 0.0, 0.5, 1.0, 1.5
        -- offsets: 0, 0, 1, 1 with delays: 0, 128, 0, 128
        assert.are.equal(2, #lines)
        assert.are.equal(2, #lines[1].note_columns)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(0,  lines[1].note_columns[1].delay_value)
        assert.are.equal(52, lines[1].note_columns[2].note_value)
        assert.are.equal(128, lines[1].note_columns[2].delay_value)
        assert.are.equal(2, #lines[2].note_columns)
        assert.are.equal(55, lines[2].note_columns[1].note_value)
        assert.are.equal(60, lines[2].note_columns[2].note_value)
    end)

    it("returns empty array for empty resolved", function()
        assert.are.same({}, PR.resolved_to_pattern_lines({}, 4))
    end)

    it("returns empty array for nil resolved", function()
        assert.are.same({}, PR.resolved_to_pattern_lines(nil, 4))
    end)

    it("handles single-line passthrough", function()
        local resolved = {
            {
                note_columns = {{ note_value = 60, instrument_value = 0, volume_value = 80 }},
                effect_columns = {},
                time_in_beats = 0.0,
            },
        }
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        assert.are.equal(1, #lines)
        assert.are.equal(60, lines[1].note_columns[1].note_value)
        assert.are.equal(80, lines[1].note_columns[1].volume_value)
    end)

    it("preserves effect columns", function()
        local phrase = make_phrase({{48}}, { lpb = 4 })
        phrase.lines[1].effect_columns = {
            { number_value = 10, number_string = "0G", amount_value = 0x50, amount_string = "50" },
        }
        local resolved = PR.resolve_phrase(48, phrase)
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        assert.are.equal("0G", lines[1].effect_columns[1].number_string)
        assert.are.equal(0x50, lines[1].effect_columns[1].amount_value)
    end)

    it("handles multi-column phrases", function()
        local phrase = make_phrase({{48, 60}}, { lpb = 4 })
        local resolved = PR.resolve_phrase(48, phrase)
        local lines = PR.resolved_to_pattern_lines(resolved, 4)
        assert.are.equal(2, #lines[1].note_columns)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(60, lines[1].note_columns[2].note_value)
    end)

    it("defaults song_lpb to 4", function()
        local phrase = make_phrase({{48},{52}}, { lpb = 4 })
        local resolved = PR.resolve_phrase(48, phrase)
        local lines = PR.resolved_to_pattern_lines(resolved)
        assert.are.equal(2, #lines)
    end)
end)

---------------------------------------------------------------------------
-- Integration scenario
---------------------------------------------------------------------------

describe("integration: arpeggio phrase", function()
    it("resolves correctly with looping and timing", function()
        local arp = make_phrase(
                {{48},{52},{55},{52}},
                { base_note = 48, lpb = 8, looping = true, loop_start = 1, loop_end = 4 }
        )
        local r = PR.resolve_phrase(52, arp, { num_lines = 8 })
        assert.are.same({52,56,59,56, 52,56,59,56}, collect_notes(r))
        assert.are.equal(0.0,   r[1].time_in_beats)
        assert.are.equal(0.125, r[2].time_in_beats)
        assert.are.equal(7/8,   r[8].time_in_beats)
    end)
end)