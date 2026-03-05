---------------------------------------------------------------------------
--- phrase_resolver_spec.lua — tests for the iterator-based phrase resolver
---------------------------------------------------------------------------

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Test helpers
---------------------------------------------------------------------------

--- Collect up to `max` results from an iterator into an array.
local function collect(iter, max)
    max = max or 200
    local result = {}
    for _ = 1, max do
        local item = iter()
        if item == nil then
            break
        end
        result[#result + 1] = item
    end
    return result
end

--- Collect note_value from the first note column of each PatternLine.
local function collect_notes(iter, max)
    local lines = collect(iter, max)
    local notes = {}
    for _, line in ipairs(lines) do
        local nc = line.note_columns and line.note_columns[1]
        if nc then
            notes[#notes + 1] = nc.note_value
        end
    end
    return notes
end

--- Build a minimal phrase table from a list of note rows.
--- Each row is { note1, note2, ... } where each value is a MIDI note.
local function make_phrase(rows, opts)
    opts = opts or {}
    local lines = {}
    for i, row in ipairs(rows) do
        local note_cols = {}
        for c, nv in ipairs(row) do
            note_cols[c] = {
                note_value = nv,
                instrument_value = PR.EMPTY_INSTRUMENT,
                volume_value = 128,
                panning_value = PR.EMPTY_PANNING,
                delay_value = PR.EMPTY_DELAY,
                effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                effect_amount_value = PR.EMPTY_EFFECT_AMOUNT,
            }
        end
        lines[i] = { note_columns = note_cols, effect_columns = {} }
    end
    return {
        lines = lines,
        number_of_lines = #lines,
        base_note = opts.base_note or PR.DEFAULT_BASE_NOTE,
        key_tracking = opts.key_tracking or PR.KEY_TRACKING_TRANSPOSE,
        lpb = opts.lpb or 4,
        looping = opts.looping or false,
        loop_start = opts.loop_start,
        loop_end = opts.loop_end,
    }
end

--- Build a pattern line with Zxx in the effect column.
local function make_pattern_line_fx(note_val, inst_val, phrase_idx)
    local fx = {}
    if phrase_idx then
        fx[1] = {
            number_value = PR.encode_effect_string(PR.ZXX_EFFECT_STRING),
            number_string = PR.ZXX_EFFECT_STRING,
            amount_value = phrase_idx,
            amount_string = string.format("%02X", phrase_idx),
        }
    end
    return {
        note_columns = { {
                             note_value = note_val,
                             instrument_value = inst_val,
                             volume_value = PR.EMPTY_VOLUME,
                             panning_value = PR.EMPTY_PANNING,
                             delay_value = PR.EMPTY_DELAY,
                             effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                             effect_amount_value = PR.EMPTY_EFFECT_AMOUNT,
                         } },
        effect_columns = fx,
    }
end

--- Build a pattern line with Zxx in the note column's effect sub-column.
local function make_pattern_line_nc(note_val, inst_val, phrase_idx)
    return {
        note_columns = { {
                             note_value = note_val,
                             instrument_value = inst_val,
                             volume_value = PR.EMPTY_VOLUME,
                             panning_value = PR.EMPTY_PANNING,
                             delay_value = PR.EMPTY_DELAY,
                             effect_number_string = PR.ZXX_EFFECT_STRING,
                             effect_number_value = PR.encode_effect_string(PR.ZXX_EFFECT_STRING),
                             effect_amount_value = phrase_idx,
                         } },
        effect_columns = {},
    }
end

---------------------------------------------------------------------------
-- note_to_string / string_to_note
---------------------------------------------------------------------------

describe("note_to_string", function()
    it("converts C-0", function()
        assert.are.equal("C-0", PR.note_to_string(0))
    end)
    it("converts C-4", function()
        assert.are.equal("C-4", PR.note_to_string(48))
    end)
    it("converts A#9", function()
        assert.are.equal("A#9", PR.note_to_string(118))
    end)
    it("converts B-9", function()
        assert.are.equal("B-9", PR.note_to_string(119))
    end)
    it("returns OFF", function()
        assert.are.equal("OFF", PR.note_to_string(120))
    end)
    it("returns ---", function()
        assert.are.equal("---", PR.note_to_string(121))
    end)
    it("returns ???", function()
        assert.are.equal("???", PR.note_to_string(200))
    end)
end)

describe("string_to_note", function()
    it("round-trips all valid notes", function()
        for n = 0, 119 do
            assert.are.equal(n, PR.string_to_note(PR.note_to_string(n)))
        end
    end)
    it("handles OFF", function()
        assert.are.equal(120, PR.string_to_note("OFF"))
    end)
    it("handles ---", function()
        assert.are.equal(121, PR.string_to_note("---"))
    end)
    it("returns nil for garbage", function()
        assert.is_nil(PR.string_to_note("XYZ"))
    end)
end)

---------------------------------------------------------------------------
-- encode_effect_string
---------------------------------------------------------------------------

describe("encode_effect_string", function()
    it("encodes '0Z' correctly", function()
        assert.are.equal(0 * 256 + 35, PR.encode_effect_string("0Z"))
    end)
    it("encodes '00' to zero", function()
        assert.are.equal(0, PR.encode_effect_string("00"))
    end)
    it("encodes 'ZZ'", function()
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
        assert.is_false(PR._is_zxx("0A", nil))
    end)
    it("rejects empty effect number", function()
        assert.is_false(PR._is_zxx(nil, 0))
    end)
    it("rejects nil/nil", function()
        assert.is_false(PR._is_zxx(nil, nil))
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
        assert.are.equal(0, PR._transpose_note(5, -10))
    end)
    it("clamps at 119", function()
        assert.are.equal(119, PR._transpose_note(115, 10))
    end)
    it("leaves NOTE_OFF unchanged", function()
        assert.are.equal(120, PR._transpose_note(120, 5))
    end)
    it("leaves NOTE_EMPTY unchanged", function()
        assert.are.equal(121, PR._transpose_note(121, 5))
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase_iter — one-shot
---------------------------------------------------------------------------

describe("resolve_phrase_iter one-shot", function()
    it("yields correct number of lines", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter)
        assert.are.equal(3, #lines)
    end)

    it("transposes up when trigger > base", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } })
        local iter = PR.resolve_phrase_iter(60, phrase)
        local lines = collect(iter)
        assert.are.equal(60, lines[1].note_columns[1].note_value)
        assert.are.equal(64, lines[2].note_columns[1].note_value)
        assert.are.equal(67, lines[3].note_columns[1].note_value)
    end)

    it("transposes down when trigger < base", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } })
        local iter = PR.resolve_phrase_iter(36, phrase)
        local lines = collect(iter)
        assert.are.equal(36, lines[1].note_columns[1].note_value)
        assert.are.equal(40, lines[2].note_columns[1].note_value)
        assert.are.equal(43, lines[3].note_columns[1].note_value)
    end)

    it("no transposition when trigger == base", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("skips transposition when key_tracking is NONE", function()
        local phrase = make_phrase({ { 48 } }, { key_tracking = PR.KEY_TRACKING_NONE })
        local iter = PR.resolve_phrase_iter(60, phrase)
        local lines = collect(iter)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("preserves NOTE_OFF", function()
        local phrase = make_phrase({ { 120 } })
        local iter = PR.resolve_phrase_iter(60, phrase)
        local lines = collect(iter)
        assert.are.equal(120, lines[1].note_columns[1].note_value)
    end)

    it("preserves NOTE_EMPTY", function()
        local phrase = make_phrase({ { 121 } })
        local iter = PR.resolve_phrase_iter(60, phrase)
        local lines = collect(iter)
        assert.are.equal(121, lines[1].note_columns[1].note_value)
    end)

    it("returns nil after exhaustion", function()
        local phrase = make_phrase({ { 48 } })
        local iter = PR.resolve_phrase_iter(48, phrase)
        iter()  -- line 1
        assert.is_nil(iter())
        assert.is_nil(iter())  -- stays nil
    end)

    it("sets correct time_in_beats", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } }, { lpb = 8 })
        local iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 8 })
        local lines = collect(iter)
        assert.are.equal(0.0, lines[1].time_in_beats)
        assert.are.equal(0.125, lines[2].time_in_beats)
        assert.are.equal(0.25, lines[3].time_in_beats)
    end)

    it("falls back to song LPB when phrase LPB is nil", function()
        local phrase = make_phrase({ { 48 }, { 52 } })
        phrase.lpb = nil
        local iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 8 })
        local lines = collect(iter)
        assert.are.equal(0.125, lines[2].time_in_beats)
    end)

    it("stores correct phrase_line_index", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter)
        assert.are.equal(1, lines[1].phrase_line_index)
        assert.are.equal(2, lines[2].phrase_line_index)
        assert.are.equal(3, lines[3].phrase_line_index)
    end)

    it("preserves volume_value", function()
        local phrase = make_phrase({ { 48 } })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter)
        assert.are.equal(128, lines[1].note_columns[1].volume_value)
    end)

    it("resolves all columns independently", function()
        local phrase = make_phrase({ { 48, 60 } })
        local iter = PR.resolve_phrase_iter(60, phrase)  -- +12
        local lines = collect(iter)
        assert.are.equal(60, lines[1].note_columns[1].note_value)
        assert.are.equal(72, lines[1].note_columns[2].note_value)
    end)

    it("passes through effect columns", function()
        local phrase = make_phrase({ { 48 } })
        phrase.lines[1].effect_columns = {
            { number_value = 10, number_string = "0G", amount_value = 0x50, amount_string = "50" },
        }
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter)
        assert.are.equal("0G", lines[1].effect_columns[1].number_string)
        assert.are.equal(0x50, lines[1].effect_columns[1].amount_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase_iter — looping
---------------------------------------------------------------------------

describe("resolve_phrase_iter looping", function()
    it("loops forever", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } }, { looping = true })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter, 10)
        assert.are.equal(10, #lines)
    end)

    it("loops within loop_start..loop_end", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 }, { 60 } }, {
            looping = true, loop_start = 2, loop_end = 3
        })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter, 8)
        -- Lines: 1(48), 2(52), 3(55), 2(52), 3(55), 2(52), 3(55), 2(52)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(52, lines[2].note_columns[1].note_value)
        assert.are.equal(55, lines[3].note_columns[1].note_value)
        assert.are.equal(52, lines[4].note_columns[1].note_value)
        assert.are.equal(55, lines[5].note_columns[1].note_value)
    end)

    it("full-phrase loop", function()
        local phrase = make_phrase({ { 48 }, { 52 } }, { looping = true })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter, 6)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(52, lines[2].note_columns[1].note_value)
        assert.are.equal(48, lines[3].note_columns[1].note_value)
        assert.are.equal(52, lines[4].note_columns[1].note_value)
    end)

    it("single-line loop", function()
        local phrase = make_phrase({ { 48 } }, { looping = true })
        local iter = PR.resolve_phrase_iter(48, phrase)
        local lines = collect(iter, 5)
        for _, l in ipairs(lines) do
            assert.are.equal(48, l.note_columns[1].note_value)
        end
    end)
end)

---------------------------------------------------------------------------
-- pattern_line_iter
---------------------------------------------------------------------------

describe("pattern_line_iter", function()
    it("maps 1:1 when phrase LPB == song LPB", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } }, { lpb = 4 })
        local phrase_iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 4 })
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        assert.are.equal(3, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(52, lines[2].note_columns[1].note_value)
        assert.are.equal(55, lines[3].note_columns[1].note_value)
        assert.are.equal(0, lines[1].note_columns[1].delay_value)
    end)

    it("spreads out when phrase LPB < song LPB", function()
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 } }, { lpb = 2 })
        local phrase_iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 2 })
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        -- time_in_beats: 0.0, 0.5, 1.0 → offsets at LPB 4: 0, 2, 4
        assert.are.equal(5, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(0, #lines[2].note_columns)  -- gap
        assert.are.equal(52, lines[3].note_columns[1].note_value)
        assert.are.equal(0, #lines[4].note_columns)  -- gap
        assert.are.equal(55, lines[5].note_columns[1].note_value)
    end)

    it("keeps only first phrase line per song line when compressed", function()
        -- phrase LPB=8, song LPB=4: two phrase lines per song line
        local phrase = make_phrase({ { 48 }, { 52 }, { 55 }, { 60 } }, { lpb = 8 })
        local phrase_iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 8 })
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        -- offsets: 0, 0, 1, 1 — only first per offset kept
        assert.are.equal(2, #lines)
        assert.are.equal(1, #lines[1].note_columns)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(0, lines[1].note_columns[1].delay_value)
        assert.are.equal(1, #lines[2].note_columns)
        assert.are.equal(55, lines[2].note_columns[1].note_value)
        assert.are.equal(0, lines[2].note_columns[1].delay_value)
    end)

    it("uses delay for fractional placement", function()
        -- Single phrase line at time_in_beats = 0.125, song LPB = 4
        -- exact_line = 0.5 → offset 0, delay 128
        local done = false
        local phrase_iter = function()
            if done then
                return nil
            end
            done = true
            return {
                note_columns = { { note_value = 48, instrument_value = 0 } },
                effect_columns = {},
                time_in_beats = 0.125,
            }
        end
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(128, lines[1].note_columns[1].delay_value)
    end)

    it("returns nil for empty phrase iterator", function()
        local iter = PR.pattern_line_iter(function()
            return nil
        end, 4)
        assert.is_nil(iter())
    end)

    it("handles single-line passthrough", function()
        local done = false
        local phrase_iter = function()
            if done then
                return nil
            end
            done = true
            return {
                note_columns = { { note_value = 60, instrument_value = 0, volume_value = 80 } },
                effect_columns = {},
                time_in_beats = 0.0,
            }
        end
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        assert.are.equal(1, #lines)
        assert.are.equal(60, lines[1].note_columns[1].note_value)
        assert.are.equal(80, lines[1].note_columns[1].volume_value)
    end)

    it("excludes empty note columns", function()
        local done = false
        local phrase_iter = function()
            if done then
                return nil
            end
            done = true
            return {
                note_columns = {
                    { note_value = 48, instrument_value = 0 },
                    { note_value = PR.NOTE_EMPTY, instrument_value = PR.EMPTY_INSTRUMENT,
                      volume_value = PR.EMPTY_VOLUME, panning_value = PR.EMPTY_PANNING,
                      delay_value = PR.EMPTY_DELAY,
                      effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                      effect_amount_value = PR.EMPTY_EFFECT_AMOUNT },
                },
                effect_columns = {},
                time_in_beats = 0.0,
            }
        end
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        assert.are.equal(1, #lines[1].note_columns)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("excludes empty effect columns", function()
        local done = false
        local phrase_iter = function()
            if done then
                return nil
            end
            done = true
            return {
                note_columns = { { note_value = 48 } },
                effect_columns = {
                    { number_value = 0, amount_value = 0 },
                    { number_value = 10, amount_value = 0x50 },
                },
                time_in_beats = 0.0,
            }
        end
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter)
        assert.are.equal(1, #lines[1].effect_columns)
        assert.are.equal(10, lines[1].effect_columns[1].number_value)
    end)

    it("looping iterator never returns nil", function()
        local phrase = make_phrase({ { 48 }, { 52 } }, { looping = true, lpb = 4 })
        local phrase_iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 4 })
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter, 20)
        assert.are.equal(20, #lines)
    end)
end)

---------------------------------------------------------------------------
-- parse_pattern_line
---------------------------------------------------------------------------

describe("parse_pattern_line with Zxx in effect columns", function()
    it("extracts Zxx via number_string", function()
        local line = make_pattern_line_fx(48, 0, 1)
        local result = PR.parse_pattern_line(line)
        assert.are.equal(1, result.phrase_index)
        assert.are.equal(48, result.note_value)
    end)

    it("Z00 means no phrase", function()
        local line = make_pattern_line_fx(48, 0, 0)
        local result = PR.parse_pattern_line(line)
        assert.is_nil(result.phrase_index)
    end)

    it("returns nil phrase_index when no Zxx present", function()
        local line = { note_columns = { { note_value = 48, instrument_value = 0 } }, effect_columns = {} }
        local result = PR.parse_pattern_line(line)
        assert.is_nil(result.phrase_index)
    end)

    it("returns nil phrase_index for empty effect columns", function()
        local line = { note_columns = { { note_value = 48 } }, effect_columns = {} }
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)

    it("ignores non-Z effects", function()
        local line = {
            note_columns = { { note_value = 48, instrument_value = 0 } },
            effect_columns = { { number_string = "0A", number_value = PR.encode_effect_string("0A"), amount_value = 5 } },
        }
        assert.is_nil(PR.parse_pattern_line(line).phrase_index)
    end)
end)

describe("parse_pattern_line with Zxx in note column", function()
    it("extracts Zxx from note column effect_number_string", function()
        local line = make_pattern_line_nc(48, 0, 2)
        local result = PR.parse_pattern_line(line)
        assert.are.equal(2, result.phrase_index)
    end)

    it("note column Zxx takes priority over effect column Zxx", function()
        local line = make_pattern_line_nc(48, 0, 3)
        line.effect_columns = { { number_string = "0Z", amount_value = 5 } }
        local result = PR.parse_pattern_line(line)
        assert.are.equal(3, result.phrase_index)
    end)

    it("falls back to effect column when note column has no Zxx", function()
        local line = {
            note_columns = { { note_value = 48, instrument_value = 0 } },
            effect_columns = { { number_string = "0Z", amount_value = 7 } },
        }
        assert.are.equal(7, PR.parse_pattern_line(line).phrase_index)
    end)
end)

describe("parse_pattern_line col_index", function()
    it("reads from the specified note column", function()
        local line = {
            note_columns = {
                { note_value = 48, instrument_value = 0 },
                { note_value = 60, instrument_value = 1 },
            },
            effect_columns = {},
        }
        local result = PR.parse_pattern_line(line, 2)
        assert.are.equal(60, result.note_value)
        assert.are.equal(1, result.instrument_value)
    end)

    it("defaults to column 1", function()
        local line = {
            note_columns = {
                { note_value = 48, instrument_value = 0 },
                { note_value = 60, instrument_value = 1 },
            },
            effect_columns = {},
        }
        assert.are.equal(48, PR.parse_pattern_line(line).note_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_pattern_phrase (returns iterator)
---------------------------------------------------------------------------

describe("resolve_pattern_phrase", function()
    local instruments

    before_each(function()
        instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { 48 }, { 52 }, { 55 } }),
                    [2] = make_phrase({ { 60 }, { 64 }, { 67 } }, { base_note = 60 }),
                },
            },
            {
                phrases = {
                    [1] = make_phrase({ { 36 }, { 40 }, { 43 } }, { base_note = 36 }),
                },
            },
        }
    end)

    it("resolves Zxx from effect column", function()
        local line = make_pattern_line_fx(48, 0, 1)
        local notes = collect_notes(PR.resolve_pattern_phrase(line, instruments))
        assert.are.same({ 48, 52, 55 }, notes)
    end)

    it("resolves Zxx from note column", function()
        local line = make_pattern_line_nc(48, 0, 1)
        local notes = collect_notes(PR.resolve_pattern_phrase(line, instruments))
        assert.are.same({ 48, 52, 55 }, notes)
    end)

    it("resolves with transposition", function()
        local line = make_pattern_line_fx(72, 0, 2)
        local notes = collect_notes(PR.resolve_pattern_phrase(line, instruments))
        assert.are.same({ 72, 76, 79 }, notes)
    end)

    it("looks up the correct instrument by instrument_value", function()
        local line = make_pattern_line_fx(36, 1, 1)
        local notes = collect_notes(PR.resolve_pattern_phrase(line, instruments))
        assert.are.same({ 36, 40, 43 }, notes)
    end)

    -- Passthrough cases

    it("passthrough for NOTE_OFF", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(PR.NOTE_OFF, 0, 1), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(PR.NOTE_OFF, lines[1].note_columns[1].note_value)
    end)

    it("passthrough for NOTE_EMPTY", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(PR.NOTE_EMPTY, 0, 1), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(PR.NOTE_EMPTY, lines[1].note_columns[1].note_value)
    end)

    it("passthrough when no Zxx present", function()
        local line = { note_columns = { { note_value = 60, instrument_value = 0 } }, effect_columns = {} }
        local lines = collect(PR.resolve_pattern_phrase(line, instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(60, lines[1].note_columns[1].note_value)
    end)

    it("passthrough for Z00", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(48, 0, 0), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("passthrough for EMPTY instrument", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(48, PR.EMPTY_INSTRUMENT, 1), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("passthrough when instrument index is out of range", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(48, 99, 1), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("passthrough when phrase index is out of range", function()
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(48, 0, 99), instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("passthrough when instrument has no phrases", function()
        local empty_instruments = { { phrases = {} } }
        local lines = collect(PR.resolve_pattern_phrase(make_pattern_line_fx(48, 0, 1), empty_instruments))
        assert.are.equal(1, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
    end)

    it("passthrough preserves volume and panning", function()
        local line = {
            note_columns = { {
                                 note_value = 60, instrument_value = 0,
                                 volume_value = 80, panning_value = 64,
                                 delay_value = 10,
                             } },
            effect_columns = {},
        }
        local lines = collect(PR.resolve_pattern_phrase(line, instruments))
        assert.are.equal(80, lines[1].note_columns[1].volume_value)
        assert.are.equal(64, lines[1].note_columns[1].panning_value)
        assert.are.equal(10, lines[1].note_columns[1].delay_value)
    end)

    it("iterator stops after passthrough", function()
        local line = { note_columns = { { note_value = 60, instrument_value = 0 } }, effect_columns = {} }
        local iter = PR.resolve_pattern_phrase(line, instruments)
        iter()  -- first line
        assert.is_nil(iter())  -- done
    end)

    it("respects col_index option", function()
        local line = {
            note_columns = {
                { note_value = PR.NOTE_EMPTY, instrument_value = PR.EMPTY_INSTRUMENT },
                { note_value = 48, instrument_value = 0,
                  effect_number_string = "0Z", effect_amount_value = 1 },
            },
            effect_columns = {},
        }
        local notes = collect_notes(PR.resolve_pattern_phrase(line, instruments, { col_index = 2 }))
        assert.are.same({ 48, 52, 55 }, notes)
    end)

    it("returns looping iterator for looping phrase", function()
        local looping_instruments = {
            { phrases = {
                [1] = make_phrase({ { 48 }, { 52 } }, { looping = true }),
            } },
        }
        local line = make_pattern_line_fx(48, 0, 1)
        local iter = PR.resolve_pattern_phrase(line, looping_instruments)
        local lines = collect(iter, 10)
        assert.are.equal(10, #lines)
    end)
end)

---------------------------------------------------------------------------
-- Integration: looping arpeggio
---------------------------------------------------------------------------

describe("integration: arpeggio phrase", function()
    it("loops correctly with timing", function()
        local phrase = make_phrase(
                { { 48 }, { 52 }, { 55 } },
                { looping = true, loop_start = 1, loop_end = 3, lpb = 4 }
        )
        local phrase_iter = PR.resolve_phrase_iter(48, phrase, { song_lpb = 4 })
        local iter = PR.pattern_line_iter(phrase_iter, 4)
        local lines = collect(iter, 9)

        assert.are.equal(9, #lines)
        assert.are.equal(48, lines[1].note_columns[1].note_value)
        assert.are.equal(52, lines[2].note_columns[1].note_value)
        assert.are.equal(55, lines[3].note_columns[1].note_value)
        assert.are.equal(48, lines[4].note_columns[1].note_value)  -- loop
        assert.are.equal(52, lines[5].note_columns[1].note_value)
        assert.are.equal(55, lines[6].note_columns[1].note_value)
    end)
end)