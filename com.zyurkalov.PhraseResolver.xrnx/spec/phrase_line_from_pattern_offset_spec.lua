-- Tests for phrase_resolver.phrase_line_from_pattern_offset
-- Run with: busted phrase_line_from_pattern_offset_spec.lua
--
-- Both pattern_offset and the return value should be 1-based, consistent
-- with Lua conventions and the rest of the module (resolve_phrase_iter
-- uses 1-based ph_idx, loop_start/loop_end are 1-based).
--
-- pattern_offset = 1 means "the pattern line where the trigger sits"
-- (i.e. no offset), and should always map to phrase line 1.

local M = require("phrase_resolver")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Build a minimal PhraseData table with sensible defaults.
--- @param overrides table?
--- @return PhraseData
local function make_phrase(overrides)
    overrides = overrides or {}
    local total = overrides.number_of_lines or 8
    return {
        number_of_lines = total,
        lpb             = overrides.lpb or nil,       -- nil → uses song_lpb
        looping         = overrides.looping or false,
        loop_start      = overrides.loop_start or 1,
        loop_end        = overrides.loop_end or total,
        lines           = overrides.lines or {},       -- not needed by this function
    }
end

---------------------------------------------------------------------------
-- One-shot phrases, same LPB
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (one-shot, same LPB)", function()

    it("returns 1 for pattern_offset 1 (trigger line)", function()
        local phrase = make_phrase({ number_of_lines = 8 })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
    end)

    it("maps pattern offsets 1:1 when phrase LPB == song LPB", function()
        local phrase = make_phrase({ number_of_lines = 8, lpb = 4 })
        for i = 1, 8 do
            assert.are.equal(i, M.phrase_line_from_pattern_offset(i, phrase, 4),
                    "offset " .. i)
        end
    end)

    it("returns nil once past the last phrase line", function()
        local phrase = make_phrase({ number_of_lines = 4, lpb = 4 })
        assert.is_nil(M.phrase_line_from_pattern_offset(5, phrase, 4))
        assert.is_nil(M.phrase_line_from_pattern_offset(100, phrase, 4))
    end)

    it("returns the last valid line for offset == number_of_lines", function()
        local phrase = make_phrase({ number_of_lines = 16, lpb = 4 })
        assert.are.equal(16, M.phrase_line_from_pattern_offset(16, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- One-shot phrases, different LPB ratios
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (one-shot, LPB scaling)", function()

    it("doubles phrase speed when phrase_lpb is 2x song_lpb", function()
        -- phrase_lpb=8, song_lpb=4 → phrase runs at 2x speed
        -- Internally: phrase_line = (offset-1) / song_lpb * phrase_lpb + 1
        --   offset 1 → (0/4)*8 + 1 = 1
        --   offset 2 → (1/4)*8 + 1 = 3
        --   offset 3 → (2/4)*8 + 1 = 5
        --   offset 8 → (7/4)*8 + 1 = floor(14) + 1 = 15
        local phrase = make_phrase({ number_of_lines = 16, lpb = 8 })
        assert.are.equal(1,  M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(3,  M.phrase_line_from_pattern_offset(2, phrase, 4))
        assert.are.equal(5,  M.phrase_line_from_pattern_offset(3, phrase, 4))
        assert.are.equal(15, M.phrase_line_from_pattern_offset(8, phrase, 4))
    end)

    it("halves phrase speed when phrase_lpb is 0.5x song_lpb", function()
        -- phrase_lpb=2, song_lpb=4 → phrase runs at 0.5x speed
        -- phrase_line = floor((offset-1) * 2 / 4) + 1 = floor((offset-1) * 0.5) + 1
        local phrase = make_phrase({ number_of_lines = 4, lpb = 2 })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(2, phrase, 4))
        assert.are.equal(2, M.phrase_line_from_pattern_offset(3, phrase, 4))
        assert.are.equal(2, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(5, phrase, 4))
    end)

    it("returns nil past the end with non-1:1 LPB ratio", function()
        local phrase = make_phrase({ number_of_lines = 4, lpb = 8 })
        -- offset 3 → floor((2/4)*8) + 1 = 5 > 4 → nil
        assert.is_nil(M.phrase_line_from_pattern_offset(3, phrase, 4))
    end)

    it("handles phrase_lpb=1, song_lpb=4 (very slow phrase)", function()
        local phrase = make_phrase({ number_of_lines = 2, lpb = 1 })
        -- phrase_line = floor((offset-1) / 4) + 1
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(2, M.phrase_line_from_pattern_offset(5, phrase, 4))
        assert.is_nil(M.phrase_line_from_pattern_offset(9, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- song_lpb defaults to 4 when nil
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (song_lpb default)", function()

    it("defaults song_lpb to 4 when not provided", function()
        local phrase = make_phrase({ number_of_lines = 8, lpb = 4 })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase))
        assert.are.equal(4, M.phrase_line_from_pattern_offset(4, phrase))
    end)
end)

---------------------------------------------------------------------------
-- phrase.lpb defaults to song_lpb when nil
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (phrase lpb defaults to song_lpb)", function()

    it("uses song_lpb when phrase.lpb is nil → 1:1 mapping", function()
        local phrase = make_phrase({ number_of_lines = 8 })   -- lpb = nil
        for i = 1, 8 do
            assert.are.equal(i, M.phrase_line_from_pattern_offset(i, phrase, 4),
                    "offset " .. i)
        end
    end)

    it("uses song_lpb=8 when phrase.lpb is nil", function()
        local phrase = make_phrase({ number_of_lines = 16 })  -- lpb = nil
        -- phrase_lpb becomes 8, song_lpb=8 → 1:1
        for i = 1, 16 do
            assert.are.equal(i, M.phrase_line_from_pattern_offset(i, phrase, 8),
                    "offset " .. i)
        end
    end)
end)

---------------------------------------------------------------------------
-- Looping phrases (no LPB difference)
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (looping, same LPB)", function()

    it("plays through to loop_end before wrapping", function()
        -- 8 lines, loop 5..8, lpb match
        local phrase = make_phrase({
            number_of_lines = 8, lpb = 4, looping = true,
            loop_start = 5, loop_end = 8,
        })
        -- First pass: offsets 1..8 → lines 1..8
        for i = 1, 8 do
            assert.are.equal(i, M.phrase_line_from_pattern_offset(i, phrase, 4),
                    "offset " .. i)
        end
    end)

    it("wraps into the loop range after loop_end", function()
        -- 8 lines, loop_start=5, loop_end=8
        -- loop_len = 8 - 5 + 1 = 4 (lines 5,6,7,8)
        -- After playing through lines 1..8, wrap into [5..8]:
        -- offset 9  → line 5
        -- offset 10 → line 6
        -- offset 11 → line 7
        -- offset 12 → line 8
        -- offset 13 → line 5 (wraps again)
        local phrase = make_phrase({
            number_of_lines = 8, lpb = 4, looping = true,
            loop_start = 5, loop_end = 8,
        })
        assert.are.equal(5, M.phrase_line_from_pattern_offset(9, phrase, 4))
        assert.are.equal(6, M.phrase_line_from_pattern_offset(10, phrase, 4))
        assert.are.equal(7, M.phrase_line_from_pattern_offset(11, phrase, 4))
        assert.are.equal(8, M.phrase_line_from_pattern_offset(12, phrase, 4))
        assert.are.equal(5, M.phrase_line_from_pattern_offset(13, phrase, 4))
    end)

    it("never returns nil for a looping phrase", function()
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
            loop_start = 1, loop_end = 4,
        })
        for i = 1, 100 do
            assert.is_not_nil(M.phrase_line_from_pattern_offset(i, phrase, 4),
                    "offset " .. i)
        end
    end)

    it("loops the entire phrase when loop_start=1, loop_end=total", function()
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
            loop_start = 1, loop_end = 4,
        })
        -- loop_len = 4 (lines 1,2,3,4)
        -- First pass: offsets 1..4 → lines 1..4
        -- Then wraps: offset 5 → 1, offset 6 → 2, etc.
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(4, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(5, phrase, 4))
        assert.are.equal(2, M.phrase_line_from_pattern_offset(6, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(7, phrase, 4))
        assert.are.equal(4, M.phrase_line_from_pattern_offset(8, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- Looping phrases with LPB scaling
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (looping with LPB scaling)", function()

    it("scales then wraps correctly with phrase_lpb > song_lpb", function()
        -- phrase_lpb=8, song_lpb=4 → 2x speed
        -- 8 total lines, loop 5..8
        -- offset 1 → line 1
        -- offset 2 → line 3
        -- offset 4 → line 7
        -- offset 5 → phrase_line = floor(4/4*8)+1 = 9 → past loop_end(8), wraps to 5
        -- offset 6 → phrase_line = floor(5/4*8)+1 = 11 → wraps to 7
        local phrase = make_phrase({
            number_of_lines = 8, lpb = 8, looping = true,
            loop_start = 5, loop_end = 8,
        })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(2, phrase, 4))
        assert.are.equal(7, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(5, M.phrase_line_from_pattern_offset(5, phrase, 4))
        assert.are.equal(7, M.phrase_line_from_pattern_offset(6, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- Loop range clamping edge cases
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (loop clamping)", function()

    it("clamps loop_start to 1 when given 0", function()
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
            loop_start = 0, loop_end = 4,
        })
        -- loop_start clamped to 1, loop_end stays 4
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        -- offset 5 → wraps to loop_start=1
        assert.are.equal(1, M.phrase_line_from_pattern_offset(5, phrase, 4))
    end)

    it("clamps loop_end to total when it exceeds number_of_lines", function()
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
            loop_start = 1, loop_end = 999,
        })
        -- loop_end clamped to 4
        assert.are.equal(4, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(5, phrase, 4))
    end)

    it("clamps loop_end to at least loop_start", function()
        -- loop_start=3, loop_end=1
        --   loop_start = max(1, min(3, 4)) = 3
        --   loop_end   = max(3, min(1, 4)) = 3
        -- Single-line loop on line 3
        -- offset 1 → line 1, offset 2 → line 2
        -- offset 3 → line 3 == loop_end → wraps, loop_len=1 → stays on 3
        -- offset 4 → also line 3
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
            loop_start = 3, loop_end = 1,
        })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(3, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(4, phrase, 4))
        assert.are.equal(3, M.phrase_line_from_pattern_offset(11, phrase, 4))
    end)

    it("defaults loop_start=1 and loop_end=total when not set", function()
        local phrase = make_phrase({
            number_of_lines = 4, lpb = 4, looping = true,
        })
        -- loop_start=1, loop_end=4 → full loop of 4 lines
        assert.are.equal(1, M.phrase_line_from_pattern_offset(5, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- Single-line phrase edge case
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (single-line phrase)", function()

    it("returns 1 for a one-shot single-line phrase at offset 1", function()
        local phrase = make_phrase({ number_of_lines = 1, lpb = 4 })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
    end)

    it("returns nil for offset > 1 on one-shot single-line phrase", function()
        local phrase = make_phrase({ number_of_lines = 1, lpb = 4 })
        assert.is_nil(M.phrase_line_from_pattern_offset(2, phrase, 4))
    end)

    it("returns 1 forever for looping single-line phrase", function()
        local phrase = make_phrase({
            number_of_lines = 1, lpb = 4, looping = true,
            loop_start = 1, loop_end = 1,
        })
        assert.are.equal(1, M.phrase_line_from_pattern_offset(1, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(2, phrase, 4))
        assert.are.equal(1, M.phrase_line_from_pattern_offset(99, phrase, 4))
    end)
end)

---------------------------------------------------------------------------
-- Pattern offset 1 always maps to phrase line 1
---------------------------------------------------------------------------

describe("phrase_line_from_pattern_offset (offset 1 invariant)", function()

    it("returns 1 for various LPB combos at offset 1", function()
        for _, plpb in ipairs({ 1, 2, 4, 8, 12, 16 }) do
            for _, slpb in ipairs({ 1, 2, 4, 8, 12, 16 }) do
                local phrase = make_phrase({ number_of_lines = 32, lpb = plpb })
                assert.are.equal(1,
                        M.phrase_line_from_pattern_offset(1, phrase, slpb),
                        string.format("phrase_lpb=%d, song_lpb=%d", plpb, slpb))
            end
        end
    end)
end)