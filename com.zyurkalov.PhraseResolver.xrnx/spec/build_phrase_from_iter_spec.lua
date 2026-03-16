---------------------------------------------------------------------------
--- build_phrase_from_iter_spec.lua
---
--- Unit tests for M.build_phrase_from_iter, M._build_phrase_line,
--- and M.resolved_track_iter.
---
--- Run with:  busted build_phrase_from_iter_spec.lua
---------------------------------------------------------------------------

local M = require("phrase_resolver")

---------------------------------------------------------------------------
-- Helpers: build pattern lines for test inputs
---------------------------------------------------------------------------

--- Make a simple note column table.
local function ncol(note_value, opts)
    opts = opts or {}
    return {
        note_value          = note_value,
        instrument_value    = opts.instrument_value or M.EMPTY_INSTRUMENT,
        volume_value        = opts.volume_value or M.EMPTY_VOLUME,
        panning_value       = opts.panning_value or M.EMPTY_PANNING,
        delay_value         = opts.delay_value or M.EMPTY_DELAY,
        effect_number_value = opts.effect_number_value or M.EMPTY_EFFECT_NUMBER,
        effect_number_string = opts.effect_number_string,
        effect_amount_value = opts.effect_amount_value or M.EMPTY_EFFECT_AMOUNT,
    }
end

--- Make a pattern line from a single note column.
local function pline(note_col, fx_cols)
    return {
        note_columns   = note_col and { note_col } or {},
        effect_columns = fx_cols or {},
    }
end

--- Make an empty pattern line.
local function empty_line()
    return {
        note_columns   = { ncol(M.NOTE_EMPTY) },
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

---------------------------------------------------------------------------
-- Tests: _build_phrase_line
---------------------------------------------------------------------------

describe("_build_phrase_line", function()

    it("strips instrument_value from note columns", function()
        local input = pline(ncol(48, { instrument_value = 5 }))
        local result = M._build_phrase_line(input)
        assert.are.equal(M.EMPTY_INSTRUMENT, result.note_columns[1].instrument_value)
    end)

    it("preserves note_value, volume, panning, delay", function()
        local input = pline(ncol(60, {
            volume_value  = 100,
            panning_value = 64,
            delay_value   = 32,
        }))
        local r = M._build_phrase_line(input)
        local c = r.note_columns[1]
        assert.are.equal(60,  c.note_value)
        assert.are.equal(100, c.volume_value)
        assert.are.equal(64,  c.panning_value)
        assert.are.equal(32,  c.delay_value)
    end)

    it("strips 0Zxx from note column effect sub-column", function()
        local zxx_num = M.encode_effect_string("0Z")
        local input = pline(ncol(48, {
            effect_number_value  = zxx_num,
            effect_number_string = "0Z",
            effect_amount_value  = 42,
        }))
        local r = M._build_phrase_line(input)
        local c = r.note_columns[1]
        assert.are.equal(M.EMPTY_EFFECT_NUMBER, c.effect_number_value)
        assert.are.equal(M.EMPTY_EFFECT_AMOUNT, c.effect_amount_value)
    end)

    it("preserves non-Zxx note column effects", function()
        local input = pline(ncol(48, {
            effect_number_value  = 0x0F,
            effect_number_string = "0F",
            effect_amount_value  = 10,
        }))
        local r = M._build_phrase_line(input)
        assert.are.equal(0x0F, r.note_columns[1].effect_number_value)
        assert.are.equal(10,   r.note_columns[1].effect_amount_value)
    end)

    it("strips 0Zxx from effect columns", function()
        local zxx_num = M.encode_effect_string("0Z")
        local input = {
            note_columns   = { ncol(48) },
            effect_columns = {
                { number_value = zxx_num, number_string = "0Z",
                  amount_value = 1, amount_string = "01" },
                { number_value = 0x0F, number_string = "0F",
                  amount_value = 5, amount_string = "05" },
            },
        }
        local r = M._build_phrase_line(input)
        assert.are.equal(1,    #r.effect_columns)
        assert.are.equal(0x0F, r.effect_columns[1].number_value)
    end)

    it("handles line with no note columns", function()
        local input = { note_columns = {}, effect_columns = {} }
        local r = M._build_phrase_line(input)
        assert.are.equal(0, #r.note_columns)
    end)
end)

---------------------------------------------------------------------------
-- Tests: build_phrase_from_iter
---------------------------------------------------------------------------

describe("build_phrase_from_iter", function()

    it("returns nil for an empty iterator", function()
        local iter = array_iter({})
        assert.is_nil(M.build_phrase_from_iter(iter))
    end)

    it("builds a single-note phrase from one line", function()
        local lines = { pline(ncol(48)) }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.is_not_nil(phrase)
        assert.are.equal(1,  phrase.number_of_lines)
        assert.are.equal(48, phrase.base_note)
        assert.are.equal(48, phrase.lines[1].note_columns[1].note_value)
    end)

    --it("sets base_note from the first real note", function()
    --    local lines = {
    --        pline(ncol(60, { instrument_value = 3 })),
    --        empty_line(),
    --        empty_line(),
    --    }
    --    local phrase = M.build_phrase_from_iter(array_iter(lines))
    --    assert.are.equal(60, phrase.base_note)
    --    assert.are.equal(3,  phrase.number_of_lines)
    --end)

    it("collects all lines including NOTE_OFF", function()
        local lines = {
            pline(ncol(48)),
            empty_line(),
            pline(ncol(M.NOTE_OFF)),
            empty_line(),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.are.equal(4, phrase.number_of_lines)
        assert.are.equal(M.NOTE_OFF, phrase.lines[3].note_columns[1].note_value)
    end)

    it("collects all lines including subsequent notes", function()
        local lines = {
            pline(ncol(48)),
            empty_line(),
            pline(ncol(55)),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.are.equal(3,  phrase.number_of_lines)
        assert.are.equal(48, phrase.base_note)
    end)

    --it("handles leading empty lines before the first note", function()
    --    local lines = {
    --        empty_line(),
    --        empty_line(),
    --        pline(ncol(52)),
    --        empty_line(),
    --    }
    --    local phrase = M.build_phrase_from_iter(array_iter(lines))
    --    assert.are.equal(4,  phrase.number_of_lines)
    --    assert.are.equal(52, phrase.base_note)
    --    assert.are.equal(M.NOTE_EMPTY, phrase.lines[1].note_columns[1].note_value)
    --    assert.are.equal(52,           phrase.lines[3].note_columns[1].note_value)
    --end)

    it("uses DEFAULT_BASE_NOTE when no real note is found", function()
        local lines = { empty_line(), empty_line() }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.are.equal(M.DEFAULT_BASE_NOTE, phrase.base_note)
    end)

    it("strips instruments from all collected lines", function()
        local lines = {
            pline(ncol(48, { instrument_value = 7 })),
            pline(ncol(M.NOTE_EMPTY, { instrument_value = 7 })),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        for i = 1, phrase.number_of_lines do
            assert.are.equal(M.EMPTY_INSTRUMENT,
                    phrase.lines[i].note_columns[1].instrument_value)
        end
    end)

    it("strips 0Zxx effects from collected lines", function()
        local zxx_num = M.encode_effect_string("0Z")
        local lines = {
            pline(
                    ncol(48, {
                        effect_number_value  = zxx_num,
                        effect_number_string = "0Z",
                        effect_amount_value  = 1,
                    }),
                    {
                        { number_value = zxx_num, number_string = "0Z",
                          amount_value = 1, amount_string = "01" },
                    }
            ),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        local nc = phrase.lines[1].note_columns[1]
        assert.are.equal(M.EMPTY_EFFECT_NUMBER, nc.effect_number_value)
        assert.are.equal(0, #phrase.lines[1].effect_columns)
    end)

    it("sets phrase metadata correctly", function()
        local lines = {
            pline(ncol(48)),
            empty_line(),
            pline(ncol(M.NOTE_OFF)),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines), { song_lpb = 8 })
        assert.are.equal(8,     phrase.lpb)
        assert.are.equal(false, phrase.looping)
        assert.are.equal(1,     phrase.loop_start)
        assert.are.equal(3,     phrase.loop_end)
        assert.are.equal(M.KEY_TRACKING_TRANSPOSE, phrase.key_tracking)
    end)

    it("collects multiple note columns per line", function()
        local line = {
            note_columns = {
                ncol(48, { volume_value = 80 }),
                ncol(55, { volume_value = 60 }),
            },
            effect_columns = {},
        }
        local phrase = M.build_phrase_from_iter(array_iter({ line }))
        assert.are.equal(2,  #phrase.lines[1].note_columns)
        assert.are.equal(48, phrase.lines[1].note_columns[1].note_value)
        assert.are.equal(55, phrase.lines[1].note_columns[2].note_value)
    end)

    it("preserves delay values from pattern lines", function()
        local lines = { pline(ncol(48, { delay_value = 128 })) }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.are.equal(128, phrase.lines[1].note_columns[1].delay_value)
    end)

    it("preserves non-Zxx effect columns", function()
        local lines = {
            pline(
                    ncol(48),
                    {
                        { number_value = 0x0F, number_string = "0F",
                          amount_value = 10, amount_string = "0A" },
                    }
            ),
        }
        local phrase = M.build_phrase_from_iter(array_iter(lines))
        assert.are.equal(1,    #phrase.lines[1].effect_columns)
        assert.are.equal(0x0F, phrase.lines[1].effect_columns[1].number_value)
    end)
end)

---------------------------------------------------------------------------
-- Tests: resolved_track_iter
---------------------------------------------------------------------------

describe("resolved_track_iter", function()

    it("yields resolved lines while trigger has empty notes", function()
        local trigger = {
            pline(ncol(48)),
            empty_line(),
            empty_line(),
        }
        local resolved = {
            pline(ncol(48, { volume_value = 100 })),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 80 })),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 60 })),
        }
        local iter = M.resolved_track_iter(trigger, resolved)

        local r1 = iter()
        assert.is_not_nil(r1)
        assert.are.equal(100, r1.note_columns[1].volume_value)

        local r2 = iter()
        assert.is_not_nil(r2)
        assert.are.equal(80, r2.note_columns[1].volume_value)

        local r3 = iter()
        assert.is_not_nil(r3)
        assert.are.equal(60, r3.note_columns[1].volume_value)

        assert.is_nil(iter())
    end)

    it("stops at NOTE_OFF and includes that line", function()
        local trigger = {
            pline(ncol(48)),
            empty_line(),
            pline(ncol(M.NOTE_OFF)),
            empty_line(),
        }
        local resolved = {
            pline(ncol(48)),
            pline(ncol(M.NOTE_EMPTY)),
            pline(ncol(M.NOTE_OFF)),
            pline(ncol(M.NOTE_EMPTY)),
        }
        local iter = M.resolved_track_iter(trigger, resolved)
        assert.is_not_nil(iter())
        assert.is_not_nil(iter())

        local r3 = iter()
        assert.is_not_nil(r3)
        assert.are.equal(M.NOTE_OFF, r3.note_columns[1].note_value)
        assert.is_nil(iter())
    end)

    it("stops at a new note and does NOT yield that line", function()
        local trigger = {
            pline(ncol(48)),
            empty_line(),
            pline(ncol(55)),
            empty_line(),
        }
        local resolved = {
            pline(ncol(48)),
            pline(ncol(M.NOTE_EMPTY)),
            pline(ncol(55)),
            pline(ncol(M.NOTE_EMPTY)),
        }
        local iter = M.resolved_track_iter(trigger, resolved)
        assert.is_not_nil(iter())
        assert.is_not_nil(iter())
        assert.is_nil(iter())
    end)

    it("supports start_line parameter", function()
        local trigger = {
            pline(ncol(48)),
            pline(ncol(60)),
            empty_line(),
            pline(ncol(M.NOTE_OFF)),
        }
        local resolved = {
            pline(ncol(48)),
            pline(ncol(60, { volume_value = 90 })),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 70 })),
            pline(ncol(M.NOTE_OFF)),
        }
        local iter = M.resolved_track_iter(trigger, resolved, 2)

        local r1 = iter()
        assert.is_not_nil(r1)
        assert.are.equal(90, r1.note_columns[1].volume_value)

        local r2 = iter()
        assert.is_not_nil(r2)
        assert.are.equal(70, r2.note_columns[1].volume_value)

        local r3 = iter()
        assert.is_not_nil(r3)
        assert.are.equal(M.NOTE_OFF, r3.note_columns[1].note_value)

        assert.is_nil(iter())
    end)

    it("handles single-line trigger", function()
        local trigger  = { pline(ncol(48)) }
        local resolved = { pline(ncol(48, { volume_value = 100 })) }
        local iter = M.resolved_track_iter(trigger, resolved)

        local r1 = iter()
        assert.is_not_nil(r1)
        assert.are.equal(100, r1.note_columns[1].volume_value)
        assert.is_nil(iter())
    end)

    it("stops at the shorter track", function()
        local trigger = {
            pline(ncol(48)),
            empty_line(),
            empty_line(),
        }
        local resolved = {
            pline(ncol(48)),
            pline(ncol(M.NOTE_EMPTY)),
        }
        local iter = M.resolved_track_iter(trigger, resolved)
        assert.is_not_nil(iter())
        assert.is_not_nil(iter())
        assert.is_nil(iter())
    end)

    it("works with build_phrase_from_iter end-to-end", function()
        local trigger = {
            pline(ncol(48)),
            empty_line(),
            empty_line(),
            pline(ncol(M.NOTE_OFF)),
            pline(ncol(55)),
        }
        local resolved = {
            pline(ncol(48, { volume_value = 100 })),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 80 })),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 60 })),
            pline(ncol(M.NOTE_OFF)),
            pline(ncol(55)),
        }

        local iter = M.resolved_track_iter(trigger, resolved)
        local phrase = M.build_phrase_from_iter(iter, { song_lpb = 4 })

        assert.is_not_nil(phrase)
        assert.are.equal(4,          phrase.number_of_lines)
        assert.are.equal(48,         phrase.base_note)
        assert.are.equal(100,        phrase.lines[1].note_columns[1].volume_value)
        assert.are.equal(M.NOTE_OFF, phrase.lines[4].note_columns[1].note_value)
    end)
end)

---------------------------------------------------------------------------
-- Round-trip test: build → resolve → compare
---------------------------------------------------------------------------

describe("round-trip: build_phrase_from_iter <-> resolve_phrase_iter", function()

    it("resolve(build(lines)) reproduces the original notes", function()
        local source_lines = {
            pline(ncol(48, { volume_value = 100 })),
            empty_line(),
            pline(ncol(M.NOTE_EMPTY, { volume_value = 80 })),
            pline(ncol(M.NOTE_OFF)),
        }

        local phrase = M.build_phrase_from_iter(
                array_iter(source_lines), { song_lpb = 4 })
        assert.is_not_nil(phrase)
        assert.are.equal(4, phrase.number_of_lines)

        local iter = M.resolve_phrase_iter(48, phrase, { song_lpb = 4 })

        local r1 = iter()
        assert.is_not_nil(r1)
        assert.are.equal(48,  r1.note_columns[1].note_value)
        assert.are.equal(100, r1.note_columns[1].volume_value)

        local r2 = iter()
        assert.is_not_nil(r2)
        assert.are.equal(M.NOTE_EMPTY, r2.note_columns[1].note_value)

        local r3 = iter()
        assert.is_not_nil(r3)
        assert.are.equal(M.NOTE_EMPTY, r3.note_columns[1].note_value)
        assert.are.equal(80,           r3.note_columns[1].volume_value)

        local r4 = iter()
        assert.is_not_nil(r4)
        assert.are.equal(M.NOTE_OFF, r4.note_columns[1].note_value)

        assert.is_nil(iter())
    end)

    it("transposition works after round-trip", function()
        local source_lines = { pline(ncol(48)) }

        local phrase = M.build_phrase_from_iter(
                array_iter(source_lines), { song_lpb = 4 })
        assert.are.equal(1,  phrase.number_of_lines)
        assert.are.equal(48, phrase.base_note)

        local iter = M.resolve_phrase_iter(60, phrase, { song_lpb = 4 })
        local r1 = iter()
        assert.are.equal(60, r1.note_columns[1].note_value)
    end)
end)