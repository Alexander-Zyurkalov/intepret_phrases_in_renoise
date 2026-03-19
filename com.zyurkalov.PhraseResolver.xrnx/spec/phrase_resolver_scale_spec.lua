---------------------------------------------------------------------------
--- phrase_resolver_scale_spec.lua — tests for scale snapping in the
--- phrase resolver.
---------------------------------------------------------------------------

local PR = require("phrase_resolver")

---------------------------------------------------------------------------
-- Test helpers (same as phrase_resolver_spec.lua)
---------------------------------------------------------------------------

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

--- Helper: get MIDI note value from a note name string.
local n = PR.string_to_note

---------------------------------------------------------------------------
-- SCALE_DEGREES table
---------------------------------------------------------------------------

describe("SCALE_DEGREES", function()
    it("has nil for 'None'", function()
        assert.is_nil(PR.SCALE_DEGREES["None"])
    end)

    it("Natural Major has 7 degrees", function()
        local count = 0
        for _ in pairs(PR.SCALE_DEGREES["Natural Major"]) do
            count = count + 1
        end
        assert.are.equal(7, count)
    end)

    it("Chromatic has 12 degrees", function()
        local count = 0
        for _ in pairs(PR.SCALE_DEGREES["Chromatic"]) do
            count = count + 1
        end
        assert.are.equal(12, count)
    end)

    it("Pentatonic has 5 degrees", function()
        local count = 0
        for _ in pairs(PR.SCALE_DEGREES["Pentatonic"]) do
            count = count + 1
        end
        assert.are.equal(5, count)
    end)

    it("Natural Major contains correct intervals", function()
        local maj = PR.SCALE_DEGREES["Natural Major"]
        -- C D E F G A B → 0 2 4 5 7 9 11
        assert.is_true(maj[0])
        assert.is_true(maj[2])
        assert.is_true(maj[4])
        assert.is_true(maj[5])
        assert.is_true(maj[7])
        assert.is_true(maj[9])
        assert.is_true(maj[11])
        assert.is_nil(maj[1])
        assert.is_nil(maj[3])
        assert.is_nil(maj[6])
    end)
end)

---------------------------------------------------------------------------
-- SCALE_KEY_OFFSETS table
---------------------------------------------------------------------------

describe("SCALE_KEY_OFFSETS", function()
    it("C is 0", function()
        assert.are.equal(0, PR.SCALE_KEY_OFFSETS["C"])
    end)
    it("C# is 1", function()
        assert.are.equal(1, PR.SCALE_KEY_OFFSETS["C#"])
    end)
    it("D is 2", function()
        assert.are.equal(2, PR.SCALE_KEY_OFFSETS["D"])
    end)
    it("B is 11", function()
        assert.are.equal(11, PR.SCALE_KEY_OFFSETS["B"])
    end)
    it("Db aliases to 1", function()
        assert.are.equal(1, PR.SCALE_KEY_OFFSETS["Db"])
    end)
end)

---------------------------------------------------------------------------
-- _snap_to_scale
---------------------------------------------------------------------------

describe("_snap_to_scale", function()

    -- C Major: C D E F G A B
    describe("C Natural Major", function()
        it("passes through C (in scale)", function()
            assert.are.equal(n("C-4"), PR._snap_to_scale(n("C-4"), "C", "Natural Major"))
        end)

        it("passes through E (in scale)", function()
            assert.are.equal(n("E-4"), PR._snap_to_scale(n("E-4"), "C", "Natural Major"))
        end)

        it("snaps C# down to C", function()
            assert.are.equal(n("C-4"), PR._snap_to_scale(n("C#4"), "C", "Natural Major"))
        end)

        it("snaps D# down to D", function()
            assert.are.equal(n("D-4"), PR._snap_to_scale(n("D#4"), "C", "Natural Major"))
        end)

        it("snaps F# down to F", function()
            assert.are.equal(n("F-4"), PR._snap_to_scale(n("F#4"), "C", "Natural Major"))
        end)

        it("snaps G# down to G", function()
            assert.are.equal(n("G-4"), PR._snap_to_scale(n("G#4"), "C", "Natural Major"))
        end)

        it("snaps A# down to A", function()
            assert.are.equal(n("A-4"), PR._snap_to_scale(n("A#4"), "C", "Natural Major"))
        end)
    end)

    -- D Major: D E F# G A B C#
    describe("D Natural Major", function()
        it("passes through D (root, in scale)", function()
            assert.are.equal(n("D-4"), PR._snap_to_scale(n("D-4"), "D", "Natural Major"))
        end)

        it("passes through F# (in D major)", function()
            assert.are.equal(n("F#4"), PR._snap_to_scale(n("F#4"), "D", "Natural Major"))
        end)

        it("snaps F natural down to E in D major", function()
            -- F is semitone 5, relative to D (key=2): (5-2)%12 = 3
            -- degree 3 is not in Major {0,2,4,5,7,9,11}
            -- Down 1: E (semitone 4), relative (4-2)%12 = 2, which IS in scale
            assert.are.equal(n("E-4"), PR._snap_to_scale(n("F-4"), "D", "Natural Major"))
        end)

        it("snaps C natural down to B in D major", function()
            -- C (semitone 0), relative to D: (0-2)%12 = 10, not in major
            -- Down 1: B (semitone 11), relative (11-2)%12 = 9, which IS in major
            assert.are.equal(n("B-3"), PR._snap_to_scale(n("C-4"), "D", "Natural Major"))
        end)
    end)

    describe("edge cases", function()
        it("returns note unchanged when scale_mode is 'None'", function()
            assert.are.equal(n("C#4"), PR._snap_to_scale(n("C#4"), "C", "None"))
        end)

        it("returns note unchanged when scale_mode is nil", function()
            assert.are.equal(n("C#4"), PR._snap_to_scale(n("C#4"), "C", nil))
        end)

        it("returns note unchanged for unknown scale name", function()
            assert.are.equal(n("C#4"), PR._snap_to_scale(n("C#4"), "C", "NonExistentScale"))
        end)

        it("Chromatic scale passes everything through", function()
            for note = 0, 119 do
                assert.are.equal(note, PR._snap_to_scale(note, "C", "Chromatic"))
            end
        end)

        it("does not go below 0", function()
            -- C#0 (note 1) in C Major should snap to C-0 (note 0)
            assert.are.equal(0, PR._snap_to_scale(1, "C", "Natural Major"))
        end)

        it("does not go above 119", function()
            -- B-9 is 119 and in C Major, no problem
            assert.are.equal(119, PR._snap_to_scale(119, "C", "Natural Major"))
        end)

        it("handles nil scale_key by defaulting offset to 0", function()
            -- Should behave like key of C
            assert.are.equal(n("C-4"), PR._snap_to_scale(n("C#4"), nil, "Natural Major"))
        end)
    end)

    describe("Natural Minor (C)", function()
        -- C Natural Minor: C D Eb F G Ab Bb → 0 2 3 5 7 8 10
        it("passes through Eb (in C minor)", function()
            assert.are.equal(n("D#4"), PR._snap_to_scale(n("D#4"), "C", "Natural Minor"))
        end)

        it("snaps E natural down to Eb in C minor", function()
            -- E (4) not in {0,2,3,5,7,8,10}. Down 1→D#(3) IS in set.
            assert.are.equal(n("D#4"), PR._snap_to_scale(n("E-4"), "C", "Natural Minor"))
        end)

        it("snaps B natural down to Bb in C minor", function()
            -- B (11) not in set. Down 1→A#(10) IS in set.
            assert.are.equal(n("A#4"), PR._snap_to_scale(n("B-4"), "C", "Natural Minor"))
        end)
    end)

    describe("Pentatonic (C)", function()
        -- C Pentatonic: C D E G A → 0 2 4 7 9
        it("snaps F down to E", function()
            -- F (5) not in {0,2,4,7,9}. Down 1→E(4) IS in set.
            assert.are.equal(n("E-4"), PR._snap_to_scale(n("F-4"), "C", "Pentatonic"))
        end)

        it("snaps F# up to G (nearest in-scale note)", function()
            -- F# (6) not in set. Down 1→F(5) no. Up 1→G(7) yes → G
            assert.are.equal(n("G-4"), PR._snap_to_scale(n("F#4"), "C", "Pentatonic"))
        end)

        it("snaps Bb down to A", function()
            -- Bb (10) not in set. Down 1→A(9) yes.
            assert.are.equal(n("A-4"), PR._snap_to_scale(n("A#4"), "C", "Pentatonic"))
        end)

        it("snaps B up to C (nearest in-scale note)", function()
            -- B (11) not in set. Down 1→A#(10) no. Up 1→C(0) yes → C-5
            assert.are.equal(n("C-5"), PR._snap_to_scale(n("B-4"), "C", "Pentatonic"))
        end)
    end)
end)

---------------------------------------------------------------------------
-- _transpose_note with scale parameters
---------------------------------------------------------------------------

describe("_transpose_note with scale", function()
    it("transposes then snaps to C major", function()
        -- C-4 (48) + 1 semitone = C#4 (49), snapped to C-4 (48) in C Major
        assert.are.equal(48, PR._transpose_note(48, 1, "C", "Natural Major"))
    end)

    it("transposes into scale when result is already in scale", function()
        -- C-4 (48) + 2 = D-4 (50), D is in C Major → stays 50
        assert.are.equal(50, PR._transpose_note(48, 2, "C", "Natural Major"))
    end)

    it("no scale applied when scale_mode is nil", function()
        assert.are.equal(49, PR._transpose_note(48, 1, "C", nil))
    end)

    it("no scale applied when scale_mode is 'None'", function()
        assert.are.equal(49, PR._transpose_note(48, 1, "C", "None"))
    end)

    it("no scale applied when scale_key is nil", function()
        assert.are.equal(49, PR._transpose_note(48, 1, nil, "Natural Major"))
    end)

    it("leaves NOTE_OFF unchanged even with scale", function()
        assert.are.equal(PR.NOTE_OFF, PR._transpose_note(PR.NOTE_OFF, 5, "C", "Natural Major"))
    end)

    it("leaves NOTE_EMPTY unchanged even with scale", function()
        assert.are.equal(PR.NOTE_EMPTY, PR._transpose_note(PR.NOTE_EMPTY, 5, "C", "Natural Major"))
    end)

    it("clamps then snaps", function()
        -- 118 + 5 = 123 → clamped to 119 (B-9), B is in C Major → 119
        assert.are.equal(119, PR._transpose_note(118, 5, "C", "Natural Major"))
    end)

    it("transposes with D major scale", function()
        -- E-4 (52) + 1 = F-4 (53). In D Major, F is not in scale.
        -- F (53) relative to D: (53-2)%12 = 3, not in major {0,2,4,5,7,9,11}
        -- Snap down to E-4 (52)
        assert.are.equal(52, PR._transpose_note(52, 1, "D", "Natural Major"))
    end)
end)

---------------------------------------------------------------------------
-- build_phrase_line with scale parameters
---------------------------------------------------------------------------

describe("build_phrase_line (reverse path, no scale snapping)", function()
    -- Helper to build a simple pattern line with one note column
    local function make_line(note_val, opts)
        opts = opts or {}
        return {
            note_columns = { {
                                 note_value = note_val,
                                 instrument_value = opts.instrument_value or 0,
                                 volume_value = opts.volume_value or PR.EMPTY_VOLUME,
                                 panning_value = PR.EMPTY_PANNING,
                                 delay_value = PR.EMPTY_DELAY,
                                 effect_number_value = opts.effect_number_value or PR.EMPTY_EFFECT_NUMBER,
                                 effect_number_string = opts.effect_number_string,
                                 effect_amount_value = opts.effect_amount_value or PR.EMPTY_EFFECT_AMOUNT,
                             } },
            effect_columns = opts.effect_columns or {},
        }
    end

    it("transposes freely (no scale snapping)", function()
        -- trigger=C-5(60), base=C-4(48): transpose = 48-60 = -12
        -- note C#4 (49) → 49 + (-12) = 37 (C#3), no snapping
        local line = make_line(n("C#4"))
        local result = PR.build_phrase_line(line, n("C-5"), n("C-4"))
        assert.are.equal(n("C#3"), result.note_columns[1].note_value)
    end)

    it("does NOT snap out-of-scale notes (reverse path)", function()
        -- Even though C#3 is not in C Major, build_phrase_line must not snap it.
        -- This is the reverse path: _res track → phrase storage.
        local line = make_line(n("C#4"))
        local result = PR.build_phrase_line(line, n("C-5"), n("C-4"))
        -- C#4 − 12 = C#3, NOT snapped to C-3
        assert.are.equal(n("C#3"), result.note_columns[1].note_value)
    end)

    it("preserves in-scale notes after transpose", function()
        -- D-4 (50) − 12 = D-3 (38)
        local line = make_line(n("D-4"))
        local result = PR.build_phrase_line(line, n("C-5"), n("C-4"))
        assert.are.equal(n("D-3"), result.note_columns[1].note_value)
    end)

    it("no transpose when trigger is nil", function()
        local line = make_line(n("C#4"))
        local result = PR.build_phrase_line(line, nil, n("C-4"))
        assert.are.equal(n("C#4"), result.note_columns[1].note_value)
    end)

    it("no transpose when trigger == base", function()
        local line = make_line(n("C#4"))
        local result = PR.build_phrase_line(line, n("C-4"), n("C-4"))
        assert.are.equal(n("C#4"), result.note_columns[1].note_value)
    end)

    it("handles multiple note columns without snapping", function()
        local line = {
            note_columns = {
                { note_value = n("C#4"), instrument_value = 0,
                  volume_value = PR.EMPTY_VOLUME, panning_value = PR.EMPTY_PANNING,
                  delay_value = PR.EMPTY_DELAY,
                  effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                  effect_amount_value = PR.EMPTY_EFFECT_AMOUNT },
                { note_value = n("F#4"), instrument_value = 0,
                  volume_value = PR.EMPTY_VOLUME, panning_value = PR.EMPTY_PANNING,
                  delay_value = PR.EMPTY_DELAY,
                  effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                  effect_amount_value = PR.EMPTY_EFFECT_AMOUNT },
            },
            effect_columns = {},
        }
        -- trigger=base → transpose=0, notes pass through unchanged
        local result = PR.build_phrase_line(line, n("C-4"), n("C-4"))
        assert.are.equal(n("C#4"), result.note_columns[1].note_value)
        assert.are.equal(n("F#4"), result.note_columns[2].note_value)
    end)

    it("preserves NOTE_OFF", function()
        local line = make_line(PR.NOTE_OFF)
        local result = PR.build_phrase_line(line, n("D-4"), n("C-4"))
        assert.are.equal(PR.NOTE_OFF, result.note_columns[1].note_value)
    end)

    it("preserves NOTE_EMPTY", function()
        local line = make_line(PR.NOTE_EMPTY)
        local result = PR.build_phrase_line(line, n("D-4"), n("C-4"))
        assert.are.equal(PR.NOTE_EMPTY, result.note_columns[1].note_value)
    end)

    it("preserves nil note_value", function()
        local line = { note_columns = { { note_value = nil } }, effect_columns = {} }
        local result = PR.build_phrase_line(line, n("D-4"), n("C-4"))
        assert.is_nil(result.note_columns[1].note_value)
    end)

    it("still strips Zxx from note column effects", function()
        local line = make_line(n("C#4"), {
            effect_number_string = PR.ZXX_EFFECT_STRING,
            effect_number_value = PR.encode_effect_string(PR.ZXX_EFFECT_STRING),
            effect_amount_value = 3,
        })
        local result = PR.build_phrase_line(line, n("C-4"), n("C-4"))
        assert.are.equal(PR.EMPTY_EFFECT_NUMBER, result.note_columns[1].effect_number_value)
        assert.are.equal(PR.EMPTY_EFFECT_AMOUNT, result.note_columns[1].effect_amount_value)
    end)

    it("still strips instrument_value", function()
        local line = make_line(n("D-4"), { instrument_value = 5 })
        local result = PR.build_phrase_line(line, n("C-4"), n("C-4"))
        assert.are.equal(PR.EMPTY_INSTRUMENT, result.note_columns[1].instrument_value)
    end)
end)

---------------------------------------------------------------------------
-- Round-trip integrity: forward resolve → reverse build must not corrupt
---------------------------------------------------------------------------

describe("round-trip integrity (forward + reverse)", function()
    it("D Dorian: phrase note survives forward→reverse round-trip", function()
        -- Phrase has E-4, base=C-4, trigger=D-4, scale=D Dorian
        --
        -- Forward path (resolve_phrase_iter):
        --   E-4(52) + 2 = F#4(54), snap in D Dorian → F-4(53)
        --
        -- Reverse path (build_phrase_line):
        --   F-4(53) + (48-50) = D#4(51), NO scale snap → D#4(51)
        --
        -- Next forward:
        --   D#4(51) + 2 = F-4(53), in D Dorian? (53-2)%12=3, yes → F-4(53) ✓
        --
        -- The round-trip stabilises: output stays F-4, phrase stores D#4.

        local phrase_note = n("E-4")
        local trigger = n("D-4")
        local base = n("C-4")
        local forward_transpose = trigger - base  -- +2

        -- Forward: transpose + snap
        local forward_result = PR._transpose_note(phrase_note, forward_transpose, "D", "Dorian")
        assert.are.equal(n("F-4"), forward_result)  -- F#→F snapped

        -- Reverse: plain transpose only (base - trigger = -2)
        local reverse_result = PR._transpose_note(forward_result, base - trigger)
        -- D#4 (51), NOT snapped
        assert.are.equal(n("D#4"), reverse_result)

        -- Second forward pass: must produce the same output as first
        local second_forward = PR._transpose_note(reverse_result, forward_transpose, "D", "Dorian")
        assert.are.equal(n("F-4"), second_forward)  -- stable
    end)

    it("C Major: round-trip is stable", function()
        -- Phrase note A#4 (58), trigger=D-4(50), base=C-4(48)
        -- Forward: 58+2=60 (C-5), in C Major → 60. Good, no snapping needed.
        -- Reverse: 60-2=58 (A#4). No snap.
        -- Second forward: 58+2=60. Stable.
        local forward = PR._transpose_note(n("A#4"), 2, "C", "Natural Major")
        assert.are.equal(n("C-5"), forward)
        local reverse = PR._transpose_note(forward, -2)
        assert.are.equal(n("A#4"), reverse)
        local forward2 = PR._transpose_note(reverse, 2, "C", "Natural Major")
        assert.are.equal(n("C-5"), forward2)
    end)

    it("build_phrase_line with corrupting scale would produce wrong result", function()
        -- This test documents WHY scale must not be in the reverse path.
        -- If we DID snap on reverse: F-4 −2 = D#4, snap in D Dorian → D-4
        -- Then forward: D-4 +2 = E-4 (in Dorian, stays) → E instead of F!
        --
        -- Verify the CORRECT (no-snap) reverse path:
        local line = {
            note_columns = { {
                                 note_value = n("F-4"),
                                 instrument_value = 0,
                                 volume_value = PR.EMPTY_VOLUME,
                                 panning_value = PR.EMPTY_PANNING,
                                 delay_value = PR.EMPTY_DELAY,
                                 effect_number_value = PR.EMPTY_EFFECT_NUMBER,
                                 effect_amount_value = PR.EMPTY_EFFECT_AMOUNT,
                             } },
            effect_columns = {},
        }
        local result = PR.build_phrase_line(line, n("D-4"), n("C-4"))
        -- Must be D#4 (51), NOT D-4 (50)
        assert.are.equal(n("D#4"), result.note_columns[1].note_value)
    end)
end)

---------------------------------------------------------------------------
-- resolve_phrase_iter with scale options
---------------------------------------------------------------------------

describe("resolve_phrase_iter with scale options", function()
    it("snaps transposed notes to C major", function()
        -- Phrase has C-4, C#4, D-4 (base=C-4)
        -- Trigger = D-4 → transpose = +2
        -- C-4+2=D-4 (in scale), C#4+2=D#4 (not in C major→snap to D-4),
        -- D-4+2=E-4 (in scale)
        local phrase = make_phrase({ { n("C-4") }, { n("C#4") }, { n("D-4") } })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "C", scale_mode = "Natural Major" })
        local lines = collect(iter)
        assert.are.equal(n("D-4"), lines[1].note_columns[1].note_value)
        assert.are.equal(n("D-4"), lines[2].note_columns[1].note_value)
        assert.are.equal(n("E-4"), lines[3].note_columns[1].note_value)
    end)

    it("does not snap when scale_mode is nil", function()
        local phrase = make_phrase({ { n("C-4") }, { n("C#4") } })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase, { song_lpb = 4 })
        local lines = collect(iter)
        -- transpose +2: C→D, C#→D#
        assert.are.equal(n("D-4"), lines[1].note_columns[1].note_value)
        assert.are.equal(n("D#4"), lines[2].note_columns[1].note_value)
    end)

    it("preserves NOTE_OFF and NOTE_EMPTY with scale", function()
        local phrase = make_phrase({ { PR.NOTE_OFF }, { PR.NOTE_EMPTY }, { n("C-4") } })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "C", scale_mode = "Natural Major" })
        local lines = collect(iter)
        assert.are.equal(PR.NOTE_OFF, lines[1].note_columns[1].note_value)
        assert.are.equal(PR.NOTE_EMPTY, lines[2].note_columns[1].note_value)
        assert.are.equal(n("D-4"), lines[3].note_columns[1].note_value)
    end)

    it("snaps all columns independently", function()
        -- Two note columns: C-4 and F#4, trigger D-4 → transpose +2
        -- C+2=D (ok), F#+2=G# (not in C Major, snap to G)
        local phrase = make_phrase({ { n("C-4"), n("F#4") } })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "C", scale_mode = "Natural Major" })
        local lines = collect(iter)
        assert.are.equal(n("D-4"), lines[1].note_columns[1].note_value)
        assert.are.equal(n("G-4"), lines[1].note_columns[2].note_value)
    end)

    it("D Dorian: all 12 chromatic notes produce only white keys", function()
        -- D Dorian = D E F G A B C (the white keys)
        -- Phrase: all 12 chromatic notes C-4..B-4, base=C-4
        -- Trigger = D-4 → transpose = +2
        --
        -- Note   +2    Rel to D  In Dorian?  Snap        Result
        -- C-4    D-4   0         yes                     D-4
        -- C#4    D#4   1         no          ↓ D(0)      D-4
        -- D-4    E-4   2         yes                     E-4
        -- D#4    F-4   3         yes                     F-4
        -- E-4    F#4   4         no          ↓ F(3)      F-4
        -- F-4    G-4   5         yes                     G-4
        -- F#4    G#4   6         no          ↓ G(5)      G-4
        -- G-4    A-4   7         yes                     A-4
        -- G#4    A#4   8         no          ↓ A(7)      A-4
        -- A-4    B-4   9         yes                     B-4
        -- A#4    C-5   10        yes                     C-5
        -- B-4    C#5   11        no          ↓ C(10)     C-5

        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }  -- C-4 through B-4
        end
        local phrase = make_phrase(rows, { base_note = n("C-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "D", scale_mode = "Dorian" })
        local lines = collect(iter)

        local expected = {
            n("D-4"), -- C  +2 = D
            n("D-4"), -- C# +2 = D# → D
            n("E-4"), -- D  +2 = E
            n("F-4"), -- D# +2 = F
            n("F-4"), -- E  +2 = F# → F
            n("G-4"), -- F  +2 = G
            n("G-4"), -- F# +2 = G# → G
            n("A-4"), -- G  +2 = A
            n("A-4"), -- G# +2 = A# → A
            n("B-4"), -- A  +2 = B
            n("C-5"), -- A# +2 = C
            n("C-5"), -- B  +2 = C# → C
        }

        assert.are.equal(12, #lines)
        for i, line in ipairs(lines) do
            assert.are.equal(expected[i], line.note_columns[1].note_value)
        end
    end)

    it("C Dorian: all 12 chromatic notes snap to C Dorian degrees", function()
        -- C Dorian = C D Eb F G A Bb
        -- Intervals from C: {0, 2, 3, 5, 7, 9, 10}
        -- Phrase: all 12 chromatic notes C-4..B-4, base=C-4
        -- Trigger = D-4 → transpose = +2
        --
        -- Note   +2     %12  In C Dorian?  Snap         Result
        -- C-4    D-4    2    yes                         D-4
        -- C#4    D#4    3    yes (Eb)                    D#4
        -- D-4    E-4    4    no            ↓ D#(3)       D#4
        -- D#4    F-4    5    yes                         F-4
        -- E-4    F#4    6    no            ↓ F(5)        F-4
        -- F-4    G-4    7    yes                         G-4
        -- F#4    G#4    8    no            ↓ G(7)        G-4
        -- G-4    A-4    9    yes                         A-4
        -- G#4    A#4    10   yes (Bb)                    A#4
        -- A-4    B-4    11   no            ↓ A#(10)      A#4
        -- A#4    C-5    0    yes                         C-5
        -- B-4    C#5    1    no            ↓ C(0)        C-5

        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }  -- C-4 through B-4
        end
        local phrase = make_phrase(rows, { base_note = n("C-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "C", scale_mode = "Dorian" })
        local lines = collect(iter)

        local expected = {
            n("D-4"), -- C  +2 = D     (in scale)
            n("D#4"), -- C# +2 = D#/Eb (in scale)
            n("D#4"), -- D  +2 = E     → snap ↓ D#/Eb
            n("F-4"), -- D# +2 = F     (in scale)
            n("F-4"), -- E  +2 = F#    → snap ↓ F
            n("G-4"), -- F  +2 = G     (in scale)
            n("G-4"), -- F# +2 = G#    → snap ↓ G
            n("A-4"), -- G  +2 = A     (in scale)
            n("A#4"), -- G# +2 = A#/Bb (in scale)
            n("A#4"), -- A  +2 = B     → snap ↓ A#/Bb
            n("C-5"), -- A# +2 = C     (in scale)
            n("C-5"), -- B  +2 = C#    → snap ↓ C
        }

        assert.are.equal(12, #lines)
        for i, line in ipairs(lines) do
            assert.are.equal(expected[i], line.note_columns[1].note_value)
        end
    end)

    it("Renoise verification: C Dorian phrase notes, D Dorian scale, trigger D", function()
        -- Phrase captured from Renoise (base=C-4, scale=D Dorian):
        --   C-4, D-4, D#4, F-4, G-4, A#4, B-4, C-5
        -- These are C Dorian notes, but the instrument scale is D Dorian.
        -- Trigger = D-4 → transpose = +2
        --
        -- Piano roll output captured via MIDI loopback in Bitwig:
        --   D, E, F, G, A, C, C, D  (all white keys)
        --
        -- Note    +2      Rel to D  In D Dorian?  Result
        -- C-4     D-4     0         yes           D-4
        -- D-4     E-4     2         yes           E-4
        -- D#4     F-4     3         yes           F-4
        -- F-4     G-4     5         yes           G-4
        -- G-4     A-4     7         yes           A-4
        -- A#4     C-5     10        yes           C-5
        -- B-4     C#5     11        no  ↓ C(10)   C-5
        -- C-5     D-5     0         yes           D-5

        local rows = {
            { n("C-4") }, { n("D-4") }, { n("D#4") }, { n("F-4") },
            { n("G-4") }, { n("A#4") }, { n("B-4") }, { n("C-5") },
        }
        local phrase = make_phrase(rows, { base_note = n("C-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "D", scale_mode = "Dorian" })
        local lines = collect(iter)

        local expected = {
            n("D-4"), -- C-4  +2 = D-4   (in scale)
            n("E-4"), -- D-4  +2 = E-4   (in scale)
            n("F-4"), -- D#4  +2 = F-4   (in scale)
            n("G-4"), -- F-4  +2 = G-4   (in scale)
            n("A-4"), -- G-4  +2 = A-4   (in scale)
            n("C-5"), -- A#4  +2 = C-5   (in scale)
            n("C-5"), -- B-4  +2 = C#5   → snap ↓ C-5
            n("D-5"), -- C-5  +2 = D-5   (in scale)
        }

        assert.are.equal(#expected, #lines)
        for i, line in ipairs(lines) do
            assert.are.equal(expected[i], line.note_columns[1].note_value)
        end
    end)
end)

describe("resolve_pattern_phrase with trigger_options", function()
    it("applies scale from instrument trigger_options", function()
        -- Phrase: C-4, C#4, D-4, base_note=C-4
        -- Trigger note = D-4 → transpose +2
        -- C+2=D(ok), C#+2=D#(snap to D), D+2=E(ok)
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { n("C-4") }, { n("C#4") }, { n("D-4") } }),
                },
                trigger_options = {
                    scale_mode = "Natural Major",
                    scale_key = "C",
                },
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, { song_lpb = 4 })
        )
        assert.are.same({ n("D-4"), n("D-4"), n("E-4") }, notes)
    end)

    it("no snapping when trigger_options has scale_mode 'None'", function()
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { n("C-4") }, { n("C#4") } }),
                },
                trigger_options = {
                    scale_mode = "None",
                    scale_key = "C",
                },
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, { song_lpb = 4 })
        )
        -- transpose +2: C→D, C#→D#
        assert.are.same({ n("D-4"), n("D#4") }, notes)
    end)

    it("no snapping when trigger_options is absent", function()
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { n("C-4") }, { n("C#4") } }),
                },
                -- no trigger_options
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, { song_lpb = 4 })
        )
        assert.are.same({ n("D-4"), n("D#4") }, notes)
    end)

    it("explicit options override instrument trigger_options", function()
        -- Instrument says D major, but options say C major
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { n("C-4") }, { n("C#4") } }),
                },
                trigger_options = {
                    scale_mode = "Natural Major",
                    scale_key = "D",
                },
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, {
                    song_lpb = 4,
                    scale_mode = "Natural Major",
                    scale_key = "C",
                })
        )
        -- With C major: C+2=D(ok), C#+2=D#(snap to D in C major)
        assert.are.same({ n("D-4"), n("D-4") }, notes)
    end)

    it("works with Natural Minor scale from trigger_options", function()
        -- C minor: C D Eb F G Ab Bb → 0,2,3,5,7,8,10
        -- Phrase: C-4, base=C-4, trigger=D-4 → transpose +2
        -- E-4 (52), relative (52-0)%12=4, not in minor. Snap down to Eb=D#(51).
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase({ { n("C-4") }, { n("E-4") } }),
                },
                trigger_options = {
                    scale_mode = "Natural Minor",
                    scale_key = "C",
                },
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, { song_lpb = 4 })
        )
        -- C+2=D (in C minor), E+2=F#(66), relative 6, not in minor
        -- snap down 1: F(65), relative 5, IS in minor
        assert.are.equal(n("D-4"), notes[1])
        assert.are.equal(n("F-4"), notes[2])
    end)
end)

---------------------------------------------------------------------------
-- Integration: D Dorian → all chromatic notes resolve to white keys
---------------------------------------------------------------------------

describe("D Dorian: all output notes are white keys", function()
    -- D Dorian = D E F G A B C (all white keys, no sharps/flats)
    -- Dorian intervals from root: 0, 2, 3, 5, 7, 9, 10
    --
    -- A phrase containing all 12 chromatic notes in octave 4,
    -- triggered at D-4 with base_note=D-4 (no transpose), should
    -- produce only white-key output thanks to scale snapping.

    local white_keys = {
        [0] = true, -- C
        [2] = true, -- D
        [4] = true, -- E
        [5] = true, -- F
        [7] = true, -- G
        [9] = true, -- A
        [11] = true, -- B
    }

    local function is_white_key(midi_note)
        return white_keys[midi_note % 12] == true
    end

    it("all 12 chromatic phrase notes snap to white keys (no transpose)", function()
        -- Phrase with all 12 notes, base=D-4, trigger=D-4 → transpose=0
        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }  -- C-4 through B-4
        end
        local phrase = make_phrase(rows, { base_note = n("D-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "D", scale_mode = "Dorian" })
        local lines = collect(iter)

        assert.are.equal(12, #lines)
        for i, line in ipairs(lines) do
            local nv = line.note_columns[1].note_value
            assert(is_white_key(nv),
                    string.format("line %d: note %d (%s) is not a white key",
                            i, nv, PR.note_to_string(nv)))
        end
    end)

    it("all 12 chromatic notes snap to white keys (transpose +2)", function()
        -- base=C-4, trigger=D-4 → transpose=+2
        -- Every transposed note should land on a white key after snapping.
        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }
        end
        local phrase = make_phrase(rows, { base_note = n("C-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "D", scale_mode = "Dorian" })
        local lines = collect(iter)

        assert.are.equal(12, #lines)
        for i, line in ipairs(lines) do
            local nv = line.note_columns[1].note_value
            assert(is_white_key(nv),
                    string.format("line %d: note %d (%s) is not a white key",
                            i, nv, PR.note_to_string(nv)))
        end
    end)

    it("specific note mapping is correct with transpose +2", function()
        -- base=C-4(48), trigger=D-4(50) → transpose=+2
        -- Phrase note → transposed → snapped in D Dorian
        -- C-4(48)  +2 = D-4(50),  rel (50-2)%12=0   in {0,2,3,5,7,9,10} → D  ✓
        -- C#4(49)  +2 = D#4(51),  rel (51-2)%12=1   not in set → snap ↓ D(50) = D
        -- D-4(50)  +2 = E-4(52),  rel (52-2)%12=2   in set → E  ✓
        -- D#4(51)  +2 = F-4(53),  rel (53-2)%12=3   in set → F  ✓
        -- E-4(52)  +2 = F#4(54),  rel (54-2)%12=4   not in set → snap ↓ F(53) = F
        -- F-4(53)  +2 = G-4(55),  rel (55-2)%12=5   in set → G  ✓
        -- F#4(54)  +2 = G#4(56),  rel (56-2)%12=6   not in set → snap ↓ G(55) = G
        -- G-4(55)  +2 = A-4(57),  rel (57-2)%12=7   in set → A  ✓
        -- G#4(56)  +2 = A#4(58),  rel (58-2)%12=8   not in set → snap ↓ A(57) = A
        -- A-4(57)  +2 = B-4(59),  rel (59-2)%12=9   in set → B  ✓
        -- A#4(58)  +2 = C-5(60),  rel (60-2)%12=10  in set → C  ✓
        -- B-4(59)  +2 = C#5(61),  rel (61-2)%12=11  not in set → snap ↓ C(60) = C
        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }
        end
        local phrase = make_phrase(rows, { base_note = n("C-4") })
        local iter = PR.resolve_phrase_iter(n("D-4"), phrase,
                { song_lpb = 4, scale_key = "D", scale_mode = "Dorian" })
        local lines = collect(iter)

        local expected = {
            n("D-4"), -- C  +2 = D
            n("D-4"), -- C# +2 = D# → D
            n("E-4"), -- D  +2 = E
            n("F-4"), -- D# +2 = F
            n("F-4"), -- E  +2 = F# → F
            n("G-4"), -- F  +2 = G
            n("G-4"), -- F# +2 = G# → G
            n("A-4"), -- G  +2 = A
            n("A-4"), -- G# +2 = A# → A
            n("B-4"), -- A  +2 = B
            n("C-5"), -- A# +2 = C
            n("C-5"), -- B  +2 = C# → C
        }

        assert.are.equal(#expected, #lines)
        for i, line in ipairs(lines) do
            assert.are.equal(expected[i], line.note_columns[1].note_value,
                    string.format("line %d: expected %s, got %s",
                            i, PR.note_to_string(expected[i]),
                            PR.note_to_string(line.note_columns[1].note_value)))
        end
    end)

    it("via resolve_pattern_phrase with trigger_options", function()
        -- Same D Dorian test but through the full resolve_pattern_phrase path
        local rows = {}
        for i = 0, 11 do
            rows[i + 1] = { 48 + i }
        end
        local instruments = {
            {
                phrases = {
                    [1] = make_phrase(rows), -- base_note = C-4 (default)
                },
                trigger_options = {
                    scale_mode = "Dorian",
                    scale_key = "D",
                },
            },
        }
        local line = make_pattern_line_fx(n("D-4"), 0, 1)
        local notes = collect_notes(
                PR.resolve_pattern_phrase(line, instruments, { song_lpb = 4 })
        )

        assert.are.equal(12, #notes)
        for i, nv in ipairs(notes) do
            assert(is_white_key(nv),
                    string.format("note %d: %d (%s) is not a white key",
                            i, nv, PR.note_to_string(nv)))
        end
    end)
end)