---
--- phrase_resolver_spec.lua
--- Unit tests for phrase_resolver — run with: busted phrase_resolver_spec.lua
---

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Test helpers
---------------------------------------------------------------------------

--- Build a minimal phrase table for testing.
--- @param notes       table   2-D array: notes[line][column] = note_value
--- @param overrides   table?  Extra fields merged onto the phrase
local function make_phrase(notes, overrides)
    local lines = {}
    for i, line_notes in ipairs(notes) do
        local cols = {}
        for j, nv in ipairs(line_notes) do
            cols[j] = { note_value = nv, volume = 128 }
        end
        lines[i] = { note_columns = cols }
    end

    local phrase = {
        lines           = lines,
        number_of_lines = #lines,
        base_note       = PR.DEFAULT_BASE_NOTE,  -- C-4
        key_tracking    = PR.KEY_TRACKING_TRANSPOSE,
        lpb             = 4,
        loop_mode       = PR.LOOP_OFF,
        loop_start      = 1,
        loop_end        = #lines,
    }

    if overrides then
        for k, v in pairs(overrides) do phrase[k] = v end
    end
    return phrase
end

--- Shorthand to build a pattern line with a Zxx command.
local function make_pattern_line(note_value, inst_index, z_amount)
    return {
        note_value       = note_value,
        instrument_index = inst_index,
        effect_columns   = z_amount and {
            { number = PR.EFFECT_Z, amount = z_amount },
        } or {},
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
    it("converts C-0 correctly", function()
        assert.are.equal("C-0", PR.note_to_string(0))
    end)

    it("converts C-4 correctly", function()
        assert.are.equal("C-4", PR.note_to_string(48))
    end)

    it("converts A#9 correctly", function()
        assert.are.equal("A#9", PR.note_to_string(118))
    end)

    it("converts B-9 (max) correctly", function()
        assert.are.equal("B-9", PR.note_to_string(119))
    end)

    it("returns OFF for note-off", function()
        assert.are.equal("OFF", PR.note_to_string(PR.NOTE_OFF))
    end)

    it("returns --- for empty", function()
        assert.are.equal("---", PR.note_to_string(PR.NOTE_EMPTY))
    end)

    it("returns ??? for out of range", function()
        assert.are.equal("???", PR.note_to_string(200))
        assert.are.equal("???", PR.note_to_string(-1))
    end)
end)

describe("string_to_note", function()
    it("round-trips with note_to_string for all valid notes", function()
        for n = 0, 119 do
            assert.are.equal(n, PR.string_to_note(PR.note_to_string(n)))
        end
    end)

    it("handles OFF", function()
        assert.are.equal(PR.NOTE_OFF, PR.string_to_note("OFF"))
    end)

    it("handles ---", function()
        assert.are.equal(PR.NOTE_EMPTY, PR.string_to_note("---"))
    end)

    it("returns nil for garbage input", function()
        assert.is_nil(PR.string_to_note("XYZ"))
    end)
end)

---------------------------------------------------------------------------
-- _transpose_note
---------------------------------------------------------------------------

describe("_transpose_note", function()
    it("transposes up", function()
        assert.are.equal(60, PR._transpose_note(48, 12))
    end)

    it("transposes down", function()
        assert.are.equal(36, PR._transpose_note(48, -12))
    end)

    it("clamps at 0", function()
        assert.are.equal(0, PR._transpose_note(5, -20))
    end)

    it("clamps at 119", function()
        assert.are.equal(119, PR._transpose_note(110, 20))
    end)

    it("leaves NOTE_OFF unchanged", function()
        assert.are.equal(PR.NOTE_OFF, PR._transpose_note(PR.NOTE_OFF, 12))
    end)

    it("leaves NOTE_EMPTY unchanged", function()
        assert.are.equal(PR.NOTE_EMPTY, PR._transpose_note(PR.NOTE_EMPTY, -5))
    end)
end)

---------------------------------------------------------------------------
-- _generate_line_sequence
---------------------------------------------------------------------------

describe("_generate_line_sequence", function()
    it("generates a simple non-looped sequence", function()
        local phrase = { number_of_lines = 4, loop_mode = PR.LOOP_OFF }
        assert.are.same({1,2,3,4}, PR._generate_line_sequence(phrase, 4))
    end)

    it("truncates when num_lines < phrase length (no loop)", function()
        local phrase = { number_of_lines = 8, loop_mode = PR.LOOP_OFF }
        assert.are.same({1,2,3}, PR._generate_line_sequence(phrase, 3))
    end)

    it("does not exceed phrase length when no loop and num_lines > length", function()
        local phrase = { number_of_lines = 3, loop_mode = PR.LOOP_OFF }
        assert.are.same({1,2,3}, PR._generate_line_sequence(phrase, 10))
    end)

    it("generates forward loop", function()
        local phrase = {
            number_of_lines = 4,
            loop_mode  = PR.LOOP_FORWARD,
            loop_start = 2,
            loop_end   = 4,
        }
        -- 1,2,3,4, then loops 2,3,4, 2,3,...
        local seq = PR._generate_line_sequence(phrase, 10)
        assert.are.same({1,2,3,4,2,3,4,2,3,4}, seq)
    end)

    it("generates forward loop with loop covering full phrase", function()
        local phrase = {
            number_of_lines = 3,
            loop_mode  = PR.LOOP_FORWARD,
            loop_start = 1,
            loop_end   = 3,
        }
        local seq = PR._generate_line_sequence(phrase, 7)
        assert.are.same({1,2,3,1,2,3,1}, seq)
    end)

    it("generates ping-pong loop", function()
        local phrase = {
            number_of_lines = 5,
            loop_mode  = PR.LOOP_PING_PONG,
            loop_start = 2,
            loop_end   = 4,
        }
        -- Play 1,2,3,4 then bounce: 3,2,3,4,3,2,...
        local seq = PR._generate_line_sequence(phrase, 12)
        assert.are.same({1,2,3,4,3,2,3,4,3,2,3,4}, seq)
    end)

    it("generates reverse loop", function()
        local phrase = {
            number_of_lines = 4,
            loop_mode  = PR.LOOP_REVERSE,
            loop_start = 2,
            loop_end   = 4,
        }
        -- Play 1,2,3,4, then backwards: 3,2, then wraps to 4,3,2, ...
        local seq = PR._generate_line_sequence(phrase, 10)
        assert.are.same({1,2,3,4,3,2,4,3,2,4}, seq)
    end)

    it("handles single-line loop", function()
        local phrase = {
            number_of_lines = 4,
            loop_mode  = PR.LOOP_FORWARD,
            loop_start = 3,
            loop_end   = 3,
        }
        local seq = PR._generate_line_sequence(phrase, 6)
        assert.are.same({1,2,3,3,3,3}, seq)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — transposition
---------------------------------------------------------------------------

describe("resolve_phrase transposition", function()
    it("transposes notes up when trigger > base note", function()
        -- Phrase with C-4 (48) on every line, base_note = C-4
        -- Trigger at C-5 (60) → +12 semitones
        local phrase = make_phrase({{48},{48},{48}})
        local result = PR.resolve_phrase(60, phrase)
        assert.are.same({60, 60, 60}, collect_notes(result))
    end)

    it("transposes notes down when trigger < base note", function()
        local phrase = make_phrase({{48},{52},{55}})
        -- Trigger at C-3 (36) → -12 semitones
        local result = PR.resolve_phrase(36, phrase)
        assert.are.same({36, 40, 43}, collect_notes(result))
    end)

    it("applies no transposition when trigger == base note", function()
        local phrase = make_phrase({{48},{50},{52}})
        local result = PR.resolve_phrase(48, phrase)
        assert.are.same({48, 50, 52}, collect_notes(result))
    end)

    it("skips transposition when key_tracking is NONE", function()
        local phrase = make_phrase({{48},{50},{52}}, {
            key_tracking = PR.KEY_TRACKING_NONE,
        })
        -- Even though trigger is far from base, no transpose happens
        local result = PR.resolve_phrase(96, phrase)
        assert.are.same({48, 50, 52}, collect_notes(result))
    end)

    it("clamps transposed notes at lower bound (0)", function()
        local phrase = make_phrase({{5}})  -- E-0
        -- base=48, trigger=0 → transpose = -48
        local result = PR.resolve_phrase(0, phrase)
        assert.are.same({0}, collect_notes(result))
    end)

    it("clamps transposed notes at upper bound (119)", function()
        local phrase = make_phrase({{115}})  -- G#9
        -- base=48, trigger=60 → transpose = +12 → 127 clamped to 119
        local result = PR.resolve_phrase(60, phrase)
        assert.are.same({119}, collect_notes(result))
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — special note values
---------------------------------------------------------------------------

describe("resolve_phrase special notes", function()
    it("preserves NOTE_OFF", function()
        local phrase = make_phrase({{48},{PR.NOTE_OFF},{52}})
        local result = PR.resolve_phrase(60, phrase)
        local notes  = collect_notes(result)
        assert.are.equal(PR.NOTE_OFF, notes[2])
    end)

    it("preserves NOTE_EMPTY", function()
        local phrase = make_phrase({{48},{PR.NOTE_EMPTY},{52}})
        local result = PR.resolve_phrase(60, phrase)
        local notes  = collect_notes(result)
        assert.are.equal(PR.NOTE_EMPTY, notes[2])
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — multi-column phrases
---------------------------------------------------------------------------

describe("resolve_phrase multi-column", function()
    it("resolves all columns independently", function()
        local phrase = make_phrase({{48, 52}, {50, 55}})
        local result = PR.resolve_phrase(60, phrase)  -- +12

        assert.are.equal(60, result[1].note_columns[1].note_value)
        assert.are.equal(64, result[1].note_columns[2].note_value)
        assert.are.equal(62, result[2].note_columns[1].note_value)
        assert.are.equal(67, result[2].note_columns[2].note_value)
    end)

    it("handles mixed notes and empties across columns", function()
        local phrase = make_phrase({{48, PR.NOTE_EMPTY}, {PR.NOTE_OFF, 55}})
        local result = PR.resolve_phrase(48, phrase)  -- no transpose

        assert.are.equal(48,            result[1].note_columns[1].note_value)
        assert.are.equal(PR.NOTE_EMPTY, result[1].note_columns[2].note_value)
        assert.are.equal(PR.NOTE_OFF,   result[2].note_columns[1].note_value)
        assert.are.equal(55,            result[2].note_columns[2].note_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — timing
---------------------------------------------------------------------------

describe("resolve_phrase timing", function()
    it("calculates time_in_beats using phrase LPB", function()
        local phrase = make_phrase({{48},{48},{48},{48}}, { lpb = 8 })
        local result = PR.resolve_phrase(48, phrase)

        assert.are.equal(0.0,   result[1].time_in_beats)
        assert.are.equal(0.125, result[2].time_in_beats)
        assert.are.equal(0.25,  result[3].time_in_beats)
        assert.are.equal(0.375, result[4].time_in_beats)
    end)

    it("defaults phrase LPB to song LPB when not set", function()
        local phrase = make_phrase({{48},{48}}, { lpb = nil })
        local result = PR.resolve_phrase(48, phrase, { song_lpb = 8 })

        assert.are.equal(0.0,   result[1].time_in_beats)
        assert.are.equal(0.125, result[2].time_in_beats)
    end)

    it("stores correct phrase_line_index and output_line_index", function()
        local phrase = make_phrase({{48},{50},{52}})
        local result = PR.resolve_phrase(48, phrase)

        for i = 1, 3 do
            assert.are.equal(i, result[i].phrase_line_index)
            assert.are.equal(i, result[i].output_line_index)
        end
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — num_lines override + looping
---------------------------------------------------------------------------

describe("resolve_phrase with num_lines and looping", function()
    it("generates extra lines via forward loop", function()
        local phrase = make_phrase({{48},{50},{52}}, {
            loop_mode  = PR.LOOP_FORWARD,
            loop_start = 1,
            loop_end   = 3,
        })
        local result = PR.resolve_phrase(48, phrase, { num_lines = 6 })
        assert.are.same({48,50,52,48,50,52}, collect_notes(result))
    end)

    it("generates fewer lines than phrase length", function()
        local phrase = make_phrase({{48},{50},{52},{55}})
        local result = PR.resolve_phrase(48, phrase, { num_lines = 2 })
        assert.are.equal(2, #result)
        assert.are.same({48,50}, collect_notes(result))
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — volume / metadata passthrough
---------------------------------------------------------------------------

describe("resolve_phrase metadata passthrough", function()
    it("preserves volume from phrase columns", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].note_columns[1].volume = 64
        local result = PR.resolve_phrase(48, phrase)
        assert.are.equal(64, result[1].note_columns[1].volume)
    end)

    it("preserves panning", function()
        local phrase = make_phrase({{48}})
        phrase.lines[1].note_columns[1].panning = 0x40
        local result = PR.resolve_phrase(48, phrase)
        assert.are.equal(0x40, result[1].note_columns[1].panning)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase — edge cases
---------------------------------------------------------------------------

describe("resolve_phrase edge cases", function()
    it("handles empty phrase (no lines)", function()
        local phrase = { lines = {}, number_of_lines = 0, lpb = 4 }
        local result = PR.resolve_phrase(48, phrase)
        assert.are.same({}, result)
    end)

    it("handles lines with no note_columns key", function()
        local phrase = {
            lines = { [1] = {} },   -- missing note_columns
            number_of_lines = 1,
            lpb = 4,
        }
        local result = PR.resolve_phrase(48, phrase)
        assert.are.equal(1, #result)
        assert.are.same({}, result[1].note_columns)
    end)

    it("handles nil note_value in a column", function()
        local phrase = make_phrase({{nil}})
        local result = PR.resolve_phrase(48, phrase)
        -- nil note_value should be treated as EMPTY
        assert.are.equal(PR.NOTE_EMPTY, result[1].note_columns[1].note_value)
    end)
end)

---------------------------------------------------------------------------
-- parse_pattern_line
---------------------------------------------------------------------------

describe("parse_pattern_line", function()
    it("extracts Zxx via numeric effect number", function()
        local line = make_pattern_line(48, 1, 0x05)
        local p = PR.parse_pattern_line(line)
        assert.are.equal(48, p.note_value)
        assert.are.equal(1,  p.instrument_index)
        assert.are.equal(6,  p.phrase_index)  -- 0x05 + 1
    end)

    it("extracts Zxx via string '0Z'", function()
        local line = {
            note_value       = 60,
            instrument_index = 2,
            effect_columns   = {{ number_string = "0Z", amount = 0 }},
        }
        local p = PR.parse_pattern_line(line)
        assert.are.equal(1, p.phrase_index)  -- Z00 → 1
    end)

    it("returns nil phrase_index when no Zxx present", function()
        local line = make_pattern_line(48, 1, nil)
        local p = PR.parse_pattern_line(line)
        assert.is_nil(p.phrase_index)
    end)

    it("returns nil phrase_index when effect columns are empty", function()
        local line = { note_value = 48, instrument_index = 1, effect_columns = {} }
        local p = PR.parse_pattern_line(line)
        assert.is_nil(p.phrase_index)
    end)

    it("ignores non-Z effects", function()
        local line = {
            note_value       = 48,
            instrument_index = 1,
            effect_columns   = {
                { number = 0x01, amount = 5 },  -- not Z
                { number = 0x09, amount = 3 },  -- not Z
            },
        }
        local p = PR.parse_pattern_line(line)
        assert.is_nil(p.phrase_index)
    end)
end)

---------------------------------------------------------------------------
-- resolve_pattern_phrase (high-level integration)
---------------------------------------------------------------------------

describe("resolve_pattern_phrase", function()
    local instrument

    before_each(function()
        instrument = {
            phrases = {
                [1] = make_phrase({{48},{52},{55}}),                          -- Z00
                [2] = make_phrase({{60},{64},{67}}, { base_note = 60 }),     -- Z01
            },
        }
    end)

    it("resolves phrase Z00 correctly", function()
        local line   = make_pattern_line(48, 1, 0)  -- Z00 → phrase 1
        local result = PR.resolve_pattern_phrase(line, instrument)
        assert.are.same({48, 52, 55}, collect_notes(result))
    end)

    it("resolves phrase Z01 with transposition", function()
        local line   = make_pattern_line(72, 1, 1)  -- Z01 → phrase 2, base=60, +12
        local result = PR.resolve_pattern_phrase(line, instrument)
        assert.are.same({72, 76, 79}, collect_notes(result))
    end)

    it("returns error for NOTE_OFF trigger", function()
        local line = make_pattern_line(PR.NOTE_OFF, 1, 0)
        local res, err = PR.resolve_pattern_phrase(line, instrument)
        assert.is_nil(res)
        assert.is_truthy(err:find("No valid trigger"))
    end)

    it("returns error for NOTE_EMPTY trigger", function()
        local line = make_pattern_line(PR.NOTE_EMPTY, 1, 0)
        local res, err = PR.resolve_pattern_phrase(line, instrument)
        assert.is_nil(res)
        assert.is_truthy(err:find("No valid trigger"))
    end)

    it("returns error when no Zxx is present", function()
        local line = make_pattern_line(48, 1, nil)
        local res, err = PR.resolve_pattern_phrase(line, instrument)
        assert.is_nil(res)
        assert.is_truthy(err:find("No Zxx"))
    end)

    it("returns error for out-of-range phrase index", function()
        local line = make_pattern_line(48, 1, 99)  -- Z99 → phrase 100
        local res, err = PR.resolve_pattern_phrase(line, instrument)
        assert.is_nil(res)
        assert.is_truthy(err:find("out of range"))
    end)

    it("returns error when instrument has no phrases", function()
        local line = make_pattern_line(48, 1, 0)
        local res, err = PR.resolve_pattern_phrase(line, {}, {})
        assert.is_nil(res)
        assert.is_truthy(err:find("no phrases"))
    end)

    it("passes options through to resolve_phrase", function()
        local line   = make_pattern_line(48, 1, 0)
        local result = PR.resolve_pattern_phrase(line, instrument, { num_lines = 2 })
        assert.are.equal(2, #result)
    end)
end)

---------------------------------------------------------------------------
-- Full integration scenario
---------------------------------------------------------------------------

describe("integration: realistic arpeggio phrase", function()
    it("resolves a C-major arpeggio triggered at different keys", function()
        -- Phrase contains C-E-G arpeggio relative to C-4
        local arp = make_phrase(
                {{48},{52},{55},{52}},  -- C4, E4, G4, E4
                {
                    base_note   = 48,
                    lpb         = 8,
                    loop_mode   = PR.LOOP_FORWARD,
                    loop_start  = 1,
                    loop_end    = 4,
                }
        )

        -- Trigger at E-4 (52) → +4 semitones → E4, G#4, B4, G#4
        local result = PR.resolve_phrase(52, arp, { num_lines = 8 })
        local notes  = collect_notes(result)
        assert.are.same({52,56,59,56, 52,56,59,56}, notes)

        -- Verify timing at LPB=8
        assert.are.equal(0.0,    result[1].time_in_beats)
        assert.are.equal(0.125,  result[2].time_in_beats)
        assert.are.equal(7/8,    result[8].time_in_beats)
    end)
end)