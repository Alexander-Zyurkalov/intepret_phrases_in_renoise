---------------------------------------------------------------------------
--- phrase_resolver.lua
---
--- Resolves Renoise phrase triggers (Zxx commands) into concrete note
--- sequences, returned as iterators for memory efficiency.
---
--- Uses Renoise API property names directly:
---   renoise.NoteColumn → { note_value, instrument_value, volume_value,
---                          panning_value, delay_value,
---                          effect_number_value, effect_number_string,
---                          effect_amount_value }
---   renoise.EffectColumn → { number_value, number_string,
---                            amount_value, amount_string }
---   renoise.PatternLine → { note_columns = {...}, effect_columns = {...} }
---------------------------------------------------------------------------

--- @class PhraseResolverModule
--- @field NOTE_OFF number
--- @field NOTE_EMPTY number
--- @field EMPTY_INSTRUMENT number
--- @field EMPTY_VOLUME number
--- @field EMPTY_PANNING number
--- @field EMPTY_DELAY number
--- @field EMPTY_EFFECT_NUMBER number
--- @field EMPTY_EFFECT_AMOUNT number
--- @field DEFAULT_BASE_NOTE number
--- @field KEY_TRACKING_NONE number
--- @field KEY_TRACKING_TRANSPOSE number
--- @field KEY_TRACKING_OFFSET number
--- @field ZXX_EFFECT_STRING string
--- @field _zxx_number_value number

--- @alias NoteColumnTable { note_value: number?, instrument_value: number?, volume_value: number?, panning_value: number?, delay_value: number?, effect_number_value: number?, effect_number_string: string?, effect_amount_value: number?, effect_amount_string: string? }
--- @alias EffectColumnTable { number_value: number?, number_string: string?, amount_value: number?, amount_string: string? }
--- @alias PatternLineTable { note_columns: NoteColumnTable[]?, effect_columns: EffectColumnTable[]? }
--- @alias ResolvedPhraseLine { note_columns: NoteColumnTable[], effect_columns: EffectColumnTable[], phrase_line_index: number, output_line_index: number, time_in_beats: number }
--- @alias PhraseLineIterator fun(): ResolvedPhraseLine?
--- @alias PatternLineIterator fun(): PatternLineTable?
--- @alias ParsedPatternLine { note_value: number?, instrument_value: number?, volume_value: number?, panning_value: number?, delay_value: number?, effect_number_value: number?, effect_amount_value: number?, phrase_index: number? }
--- @alias PhraseData { lines: PatternLineTable[], number_of_lines: number, base_note: number?, key_tracking: number?, lpb: number?, looping: boolean?, loop_start: number?, loop_end: number? }
--- @alias InstrumentData { phrases: PhraseData[]?, trigger_options: { scale_mode: string?, scale_key: string? }? }
--- @alias ResolveOptions { col_index: number?, song_lpb: number?, scale_key: string?, scale_mode: string? }

--- @type PhraseResolverModule
local M = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

M.NOTE_OFF = 120
M.NOTE_EMPTY = 121
M.EMPTY_INSTRUMENT = 255
M.EMPTY_VOLUME = 255
M.EMPTY_PANNING = 255
M.EMPTY_DELAY = 0
M.EMPTY_EFFECT_NUMBER = 0
M.EMPTY_EFFECT_AMOUNT = 0
M.DEFAULT_BASE_NOTE = 48   -- C-4

M.KEY_TRACKING_NONE = 1
M.KEY_TRACKING_TRANSPOSE = 2
M.KEY_TRACKING_OFFSET = 3

M.ZXX_EFFECT_STRING = "0Z"

---------------------------------------------------------------------------
-- Scale definitions
---------------------------------------------------------------------------

--- Map of scale name → set of semitone offsets (0–11) from the root.
--- Matches the built-in scales available via
--- renoise.InstrumentTriggerOptions.available_scales.
--- @type table<string, table<number, boolean>>
M.SCALE_DEGREES = {
    ["None"]              = nil,  -- no constraint
    ["Natural Major"]     = {[0]=true,[2]=true,[4]=true,[5]=true,[7]=true,[9]=true,[11]=true},
    ["Natural Minor"]     = {[0]=true,[2]=true,[3]=true,[5]=true,[7]=true,[8]=true,[10]=true},
    ["Pentatonic"]        = {[0]=true,[2]=true,[4]=true,[7]=true,[9]=true},
    ["Blues"]             = {[0]=true,[3]=true,[5]=true,[6]=true,[7]=true,[10]=true},
    ["Dorian"]            = {[0]=true,[2]=true,[3]=true,[5]=true,[7]=true,[9]=true,[10]=true},
    ["Mixolydian"]        = {[0]=true,[2]=true,[4]=true,[5]=true,[7]=true,[9]=true,[10]=true},
    ["Phrygian"]          = {[0]=true,[1]=true,[3]=true,[5]=true,[7]=true,[8]=true,[10]=true},
    ["Lydian"]            = {[0]=true,[2]=true,[4]=true,[6]=true,[7]=true,[9]=true,[11]=true},
    ["Locrian"]           = {[0]=true,[1]=true,[3]=true,[5]=true,[6]=true,[8]=true,[10]=true},
    ["Harmonic Minor"]    = {[0]=true,[2]=true,[3]=true,[5]=true,[7]=true,[8]=true,[11]=true},
    ["Melodic Minor"]     = {[0]=true,[2]=true,[3]=true,[5]=true,[7]=true,[9]=true,[11]=true},
    ["Whole Tone"]        = {[0]=true,[2]=true,[4]=true,[6]=true,[8]=true,[10]=true},
    ["Minor Pentatonic"]  = {[0]=true,[3]=true,[5]=true,[7]=true,[10]=true},
    ["Hungarian Minor"]   = {[0]=true,[2]=true,[3]=true,[6]=true,[7]=true,[8]=true,[11]=true},
    ["Ukrainian Dorian"]  = {[0]=true,[2]=true,[3]=true,[6]=true,[7]=true,[9]=true,[10]=true},
    ["Romanian Minor"]    = {[0]=true,[2]=true,[3]=true,[6]=true,[7]=true,[9]=true,[10]=true},
    ["Spanish"]           = {[0]=true,[1]=true,[3]=true,[4]=true,[5]=true,[7]=true,[8]=true,[10]=true},
    ["Gypsy"]             = {[0]=true,[2]=true,[3]=true,[6]=true,[7]=true,[8]=true,[11]=true},
    ["Arabian"]           = {[0]=true,[2]=true,[4]=true,[5]=true,[6]=true,[8]=true,[10]=true},
    ["Egyptian"]          = {[0]=true,[2]=true,[5]=true,[7]=true,[10]=true},
    ["Japanese (In Sen)"] = {[0]=true,[1]=true,[5]=true,[7]=true,[10]=true},
    ["Japanese (Hirajoshi)"] = {[0]=true,[2]=true,[3]=true,[7]=true,[8]=true},
    ["Chromatic"]         = {[0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,[9]=true,[10]=true,[11]=true},
}

--- Map scale key name → semitone offset from C.
--- @type table<string, number>
M.SCALE_KEY_OFFSETS = {
    ["C"]  = 0,  ["C#"] = 1,  ["D"]  = 2,  ["D#"] = 3,
    ["E"]  = 4,  ["F"]  = 5,  ["F#"] = 6,  ["G"]  = 7,
    ["G#"] = 8,  ["A"]  = 9,  ["A#"] = 10, ["B"]  = 11,
    -- Alternative flat names (just in case)
    ["Db"] = 1,  ["Eb"] = 3,  ["Fb"] = 4,  ["Gb"] = 6,
    ["Ab"] = 8,  ["Bb"] = 10,
}

--- Renoise returns scale_key as a 1-based integer:
---   1=C, 2=C#, 3=D, … 12=B.
--- This table maps that index to a semitone offset from C.
--- @type table<number, number>
M.SCALE_KEY_INDEX_OFFSETS = {
    [1] = 0,  [2] = 1,  [3] = 2,  [4] = 3,  [5] = 4,  [6] = 5,
    [7] = 6,  [8] = 7,  [9] = 8,  [10] = 9, [11] = 10, [12] = 11,
}

--- Normalise a scale_key value (string or 1-based integer) to a
--- semitone offset from C.  Returns nil when the key is unrecognised.
---
--- @param  scale_key  string|number|nil
--- @return number?
function M._key_to_offset(scale_key)
    if scale_key == nil then
        return nil
    end
    if type(scale_key) == "number" then
        return M.SCALE_KEY_INDEX_OFFSETS[scale_key]
    end
    return M.SCALE_KEY_OFFSETS[scale_key]
end

---------------------------------------------------------------------------
-- Scale snapping
---------------------------------------------------------------------------

--- Snap a MIDI note value to the nearest note that belongs to the given
--- scale.  Searches outward (down first, then up) by up to 6 semitones.
---
--- @param  note_value   number              MIDI note 0-119
--- @param  scale_key    string|number        Root key: name ("C", "D#") or 1-based index (1–12)
--- @param  scale_mode   string              Scale name, e.g. "Natural Major"
--- @return number                           Snapped MIDI note (clamped 0-119)
function M._snap_to_scale(note_value, scale_key, scale_mode)
    if not scale_mode or scale_mode == "None" then
        return note_value
    end

    local degrees = M.SCALE_DEGREES[scale_mode]
    if not degrees then
        -- Unknown scale → pass through unchanged
        return note_value
    end

    local key_offset = M._key_to_offset(scale_key) or 0

    -- Check if note is already in the scale
    local relative = (note_value - key_offset) % 12
    if degrees[relative] then
        return note_value
    end

    -- Search outward: prefer going down, then up
    for offset = 1, 6 do
        local below = note_value - offset
        if below >= 0 then
            local rel_below = (below - key_offset) % 12
            if degrees[rel_below] then
                return below
            end
        end
        local above = note_value + offset
        if above <= 119 then
            local rel_above = (above - key_offset) % 12
            if degrees[rel_above] then
                return above
            end
        end
    end

    -- Fallback (should not happen with any real scale)
    return note_value
end

---------------------------------------------------------------------------
-- Zxx detection
---------------------------------------------------------------------------

--- Check whether an effect number (string or value) represents the Zxx command.
---
--- @param  number_string  string|nil  e.g. "0Z"
--- @param  number_value   number|nil  e.g. the numeric encoding of "0Z"
--- @return boolean

function M._is_zxx(number_string, number_value)
    if number_string then
        return number_string:upper() == M.ZXX_EFFECT_STRING
    end
    if number_value and number_value ~= M.EMPTY_EFFECT_NUMBER then
        return number_value == M._zxx_number_value
    end
    return false
end

--- Encode a 2-character effect string into the numeric value Renoise
--- uses for effect_number_value / number_value.
---
--- @param  s  string  e.g. "0Z"
--- @return number

function M.encode_effect_string(s)
    s = s:upper()
    local function char_val(c)
        if c >= '0' and c <= '9' then
            return c:byte() - 0x30
        else
            return c:byte() - 0x41 + 10
        end
    end
    return char_val(s:sub(1, 1)) * 256 + char_val(s:sub(2, 2))
end

M._zxx_number_value = M.encode_effect_string(M.ZXX_EFFECT_STRING)

---------------------------------------------------------------------------
-- Empty-column helpers
---------------------------------------------------------------------------

--- Check if a note column table contains any actual data.
--- @param col NoteColumnTable?
--- @return boolean
function M.is_note_column_empty(col)
    if not col then
        return true
    end
    local nv = col.note_value
    if nv ~= nil and nv ~= M.NOTE_EMPTY then
        return false
    end
    if col.instrument_value and col.instrument_value ~= M.EMPTY_INSTRUMENT then
        return false
    end
    if col.volume_value and col.volume_value ~= M.EMPTY_VOLUME then
        return false
    end
    if col.panning_value and col.panning_value ~= M.EMPTY_PANNING then
        return false
    end
    if col.delay_value and col.delay_value ~= M.EMPTY_DELAY then
        return false
    end
    if col.effect_number_value and col.effect_number_value ~= M.EMPTY_EFFECT_NUMBER then
        return false
    end
    if col.effect_amount_value and col.effect_amount_value ~= M.EMPTY_EFFECT_AMOUNT then
        return false
    end
    return true
end

--- Check if an effect column table contains any actual data.
--- @param col EffectColumnTable?
--- @return boolean
function M.is_effect_column_empty(col)
    if not col then
        return true
    end
    if col.number_value and col.number_value ~= M.EMPTY_EFFECT_NUMBER then
        return false
    end
    if col.amount_value and col.amount_value ~= M.EMPTY_EFFECT_AMOUNT then
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Internal: transpose a single note value
---------------------------------------------------------------------------

--- @param note_value  number
--- @param semitones   number
--- @param scale_key   string?  Root key for scale snapping (e.g. "C")
--- @param scale_mode  string?  Scale name (e.g. "Natural Major"), nil or "None" to skip
--- @return number
function M._transpose_note(note_value, semitones, scale_key, scale_mode)
    if note_value == M.NOTE_OFF or note_value == M.NOTE_EMPTY then
        return note_value
    end
    local result = note_value + semitones
    result = math.max(0, math.min(119, result))
    if scale_mode and scale_mode ~= "None" and scale_key then
        result = M._snap_to_scale(result, scale_key, scale_mode)
    end
    return result
end

---------------------------------------------------------------------------
-- Core: phrase iterator
---------------------------------------------------------------------------

--- Return an iterator that yields one resolved phrase line per call.
---
--- For one-shot phrases the iterator stops at the phrase length.
--- For looping phrases the iterator runs forever — the caller decides
--- when to stop pulling.
---
--- Each yielded table has:
---   { note_columns, effect_columns, phrase_line_index,
---     output_line_index, time_in_beats }
---
--- @param trigger_note  number         MIDI-style note 0-119
--- @param phrase        PhraseData      Phrase data
--- @param options       ResolveOptions? { song_lpb = 4 }
--- @return PhraseLineIterator           Iterator function

function M.resolve_phrase_iter(trigger_note, phrase, options)
    options = options or {}

    local song_lpb = options.song_lpb or 4
    local base_note = phrase.base_note or M.DEFAULT_BASE_NOTE
    local key_tracking = phrase.key_tracking or M.KEY_TRACKING_TRANSPOSE
    local phrase_lpb = phrase.lpb or song_lpb
    local total = phrase.number_of_lines
    local looping = phrase.looping or false
    local loop_start = phrase.loop_start or 1
    local loop_end = phrase.loop_end or total

    loop_start = math.max(1, math.min(loop_start, total))
    loop_end = math.max(loop_start, math.min(loop_end, total))

    local transpose = 0
    if key_tracking == M.KEY_TRACKING_TRANSPOSE then
        transpose = trigger_note - base_note
    end

    local scale_key = options.scale_key
    local scale_mode = options.scale_mode

    local beat_per_phrase_line = 1.0 / phrase_lpb
    local ph_idx = 1
    local out_idx = 0
    local finished = false

    return function()
        if finished then
            return nil
        end

        -- One-shot: stop at the end of the phrase
        if not looping and ph_idx > total then
            finished = true
            return nil
        end

        out_idx = out_idx + 1
        local current_ph_idx = ph_idx

        -- Build resolved note columns
        local ph_line = phrase.lines[current_ph_idx] or {}
        local columns = ph_line.note_columns or {}
        local res_cols = {}

        for col_i, col in ipairs(columns) do
            local nv = col.note_value
            if nv == nil then
                nv = M.NOTE_EMPTY
            end
            res_cols[col_i] = {
                note_value = M._transpose_note(nv, transpose, scale_key, scale_mode),
                instrument_value = col.instrument_value,
                volume_value = col.volume_value,
                panning_value = col.panning_value,
                delay_value = col.delay_value,
                effect_number_value = col.effect_number_value,
                effect_amount_value = col.effect_amount_value,
            }
        end

        -- Build resolved effect columns
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

        -- Advance phrase index
        if looping then
            if ph_idx >= loop_end then
                ph_idx = loop_start
            else
                ph_idx = ph_idx + 1
            end
        else
            ph_idx = ph_idx + 1
        end

        return {
            note_columns = res_cols,
            effect_columns = res_fx,
            phrase_line_index = current_ph_idx,
            output_line_index = out_idx,
            time_in_beats = (out_idx - 1) * beat_per_phrase_line,
        }
    end
end

---------------------------------------------------------------------------
-- Pattern-grid iterator
---------------------------------------------------------------------------

--- Wrap a phrase iterator and yield one PatternLine-shaped table per song
--- line offset (0, 1, 2, …).
---
--- Phrase lines are placed on the pattern grid only if they align perfectly
--- with a song line (based on their time_in_beats and the song LPB).
--- Any phrase lines that fall between song lines are completely discarded.
---
--- @param  phrase_iter  PhraseLineIterator  Iterator from resolve_phrase_iter
--- @param  song_lpb     number?            The song's lines-per-beat
--- @return PatternLineIterator              Iterator yielding PatternLine tables

function M.pattern_line_iter(phrase_iter, song_lpb)
    song_lpb = song_lpb or 4

    local current_offset = -1
    local pending = nil    -- buffered phrase line for a future offset
    local exhausted = false

    return function()
        if exhausted and not pending then
            return nil
        end

        current_offset = current_offset + 1
        local note_cols = {}
        local fx_cols = {}
        local placed = false

        while true do
            -- Get the next phrase line if we don't have one buffered
            if not pending then
                if exhausted then
                    break
                end
                pending = phrase_iter()
                if not pending then
                    exhausted = true
                    break
                end
            end

            -- Map phrase time → song line offset + delay
            local exact_line = pending.time_in_beats * song_lpb
            local offset = math.floor(exact_line)
            local frac = exact_line - offset
            local delay = math.floor(frac * 256 + 0.5)
            if delay > 255 then
                delay = 0
                offset = offset + 1
            end

            -- This phrase line belongs to a future song line — stop
            if offset > current_offset then
                break
            end

            if offset == current_offset and not placed then
                -- Take only the first phrase line for this song line
                for _, col in ipairs(pending.note_columns or {}) do
                    if not M.is_note_column_empty(col) then
                        note_cols[#note_cols + 1] = {
                            note_value = col.note_value,
                            instrument_value = col.instrument_value,
                            volume_value = col.volume_value,
                            panning_value = col.panning_value,
                            delay_value = (delay > 0) and delay or (col.delay_value or 0),
                            effect_number_value = col.effect_number_value,
                            effect_amount_value = col.effect_amount_value,
                        }
                    end
                end

                for _, fc in ipairs(pending.effect_columns or {}) do
                    if not M.is_effect_column_empty(fc) then
                        fx_cols[#fx_cols + 1] = {
                            number_value = fc.number_value,
                            number_string = fc.number_string,
                            amount_value = fc.amount_value,
                            amount_string = fc.amount_string,
                        }
                    end
                end

                placed = true
            end
            -- Skip additional phrase lines for the same offset, or past offsets

            pending = nil  -- consumed
        end

        -- Nothing for this offset and phrase is done → signal end
        if not placed and exhausted and not pending then
            return nil
        end

        return { note_columns = note_cols, effect_columns = fx_cols }
    end
end

---------------------------------------------------------------------------
-- Pattern line parsing: extract Zxx phrase trigger
---------------------------------------------------------------------------

--- Parse a pattern-editor line and extract the Zxx phrase trigger.
---
--- Checks for Zxx in two places (matching Renoise behaviour):
---   1. The specified note column's own effect sub-column
---   2. The line's effect columns
---
--- @param  line        renoise.PatternLine|PatternLineTable  PatternLine-shaped table
--- @param  col_index   number?  Note column to inspect (default 1)
--- @return ParsedPatternLine     { note_value, instrument_value, …,
---                                 phrase_index (1-based) or nil }

function M.parse_pattern_line(line, col_index)
    col_index = col_index or 1

    local note_cols = line.note_columns or {}
    local nc = note_cols[col_index] or {}

    local result = {
        note_value = nc.note_value,
        instrument_value = nc.instrument_value,
        volume_value = nc.volume_value,
        panning_value = nc.panning_value,
        delay_value = nc.delay_value,
        effect_number_value = nc.effect_number_value,
        effect_amount_value = nc.effect_amount_value,
        phrase_index = nil,
    }

    -- 1. Check the note column's own effect sub-column
    if M._is_zxx(nc.effect_number_string, nc.effect_number_value) then
        local amount = nc.effect_amount_value or 0
        if amount > 0 then
            result.phrase_index = amount
        end
        return result
    end

    -- 2. Check the line's effect columns
    if line.effect_columns then
        for _, fx in ipairs(line.effect_columns) do
            if M._is_zxx(fx.number_string, fx.number_value) then
                local amount = fx.amount_value or 0
                if amount > 0 then
                    result.phrase_index = amount
                end
                return result
            end
        end
    end

    return result
end

---------------------------------------------------------------------------
-- High-level: resolve a pattern line → pattern_line_iter
---------------------------------------------------------------------------

--- Build a passthrough iterator: yields one line with just the trigger
--- note, then stops.
--- @param parsed ParsedPatternLine
--- @param song_lpb number?
--- @return PatternLineIterator
function M._passthrough_iter(parsed, song_lpb)
    song_lpb = song_lpb or 4
    local done = false
    return function()
        if done then
            return nil
        end
        done = true
        return {
            note_columns = {
                {
                    note_value = parsed.note_value,
                    instrument_value = parsed.instrument_value,
                    volume_value = parsed.volume_value,
                    panning_value = parsed.panning_value,
                    delay_value = parsed.delay_value,
                    effect_number_value = parsed.effect_number_value,
                    effect_amount_value = parsed.effect_amount_value,
                },
            },
            effect_columns = {},
        }
    end
end

--- Given a pattern line and the song's instruments array, return an
--- iterator that yields PatternLine-shaped tables one per song line.
---
--- The instrument is determined from the note column's instrument_value.
--- When a Zxx command selects a phrase, that phrase is resolved with
--- transposition.  In all other cases the function returns a passthrough
--- iterator yielding one line with the original trigger note.
---
--- @param  pattern_line  renoise.PatternLine|PatternLineTable  PatternLine-shaped table
--- @param  instruments   InstrumentData[]  Array of instrument tables (1-based)
--- @param  options       ResolveOptions?   { col_index=1, song_lpb=4 }
--- @return PatternLineIterator             Iterator yielding PatternLine tables

function M.resolve_pattern_phrase(pattern_line, instruments, options)
    options = options or {}
    local col_index = options.col_index or 1
    local song_lpb = options.song_lpb or 4

    local parsed = M.parse_pattern_line(pattern_line, col_index)

    -- No playable note → passthrough
    if not parsed.note_value or
            parsed.note_value == M.NOTE_OFF or
            parsed.note_value == M.NOTE_EMPTY then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- No Zxx phrase trigger → passthrough
    if not parsed.phrase_index then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- Look up instrument
    local instrument
    if parsed.instrument_value and
            parsed.instrument_value ~= M.EMPTY_INSTRUMENT and
            instruments then
        instrument = instruments[parsed.instrument_value + 1]
    end

    -- No instrument or no phrases → passthrough
    if not instrument or not instrument.phrases or #instrument.phrases == 0 then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- Phrase index out of range → passthrough
    local phrase = instrument.phrases[parsed.phrase_index]
    if not phrase then
        return M._passthrough_iter(parsed, song_lpb)
    end

    -- Inject instrument scale parameters into options if present
    if instrument.trigger_options then
        local sm = instrument.trigger_options.scale_mode
        local sk = instrument.trigger_options.scale_key
        if sm and sm ~= "None" then
            options.scale_mode = options.scale_mode or sm
            options.scale_key  = options.scale_key  or sk
        end
    end

    local phrase_iter = M.resolve_phrase_iter(parsed.note_value, phrase, options)
    return M.pattern_line_iter(phrase_iter, song_lpb)
end

---------------------------------------------------------------------------
-- Internal: build a single phrase line from a pattern line
---------------------------------------------------------------------------

--- Strip instrument values and 0Zxx effects from a pattern line,
--- producing a phrase-line-shaped table.  When trigger_note and
--- base_note are provided, note values are transposed by the
--- difference (trigger_note − base_note), matching Renoise's
--- key-tracking transpose behaviour.
---
--- NOTE: Scale snapping is NOT applied here.  This function converts
--- notes from the resolved (_res) track back into phrase space by
--- reversing the transpose.  Scales are a forward-path concern only
--- (applied during resolve_phrase_iter when notes are played back).
---
--- @param  pattern_line  PatternLineTable  PatternLine-shaped table
--- @param  trigger_note  number?           MIDI note that triggered the phrase (0-119)
--- @param  base_note     number?           Phrase base note (default DEFAULT_BASE_NOTE)
--- @return PatternLineTable               Phrase-line-shaped table

function M.build_phrase_line(pattern_line, trigger_note, base_note)
    base_note = base_note or M.DEFAULT_BASE_NOTE
    local transpose = 0
    if trigger_note then
        transpose = base_note - trigger_note
    end

    local note_cols = {}
    for i, col in ipairs(pattern_line.note_columns or {}) do
        local eff_num = col.effect_number_value
        local eff_amt = col.effect_amount_value
        -- Strip 0Zxx from note column effect sub-column
        if M._is_zxx(col.effect_number_string, col.effect_number_value) then
            eff_num = M.EMPTY_EFFECT_NUMBER
            eff_amt = M.EMPTY_EFFECT_AMOUNT
        end
        local nv = col.note_value
        if nv and transpose ~= 0 then
            nv = M._transpose_note(nv, transpose)
        end
        note_cols[i] = {
            note_value = nv,
            instrument_value = M.EMPTY_INSTRUMENT,
            volume_value = col.volume_value,
            panning_value = col.panning_value,
            delay_value = col.delay_value,
            effect_number_value = eff_num,
            effect_amount_value = eff_amt,
        }
    end

    local fx_cols = {}
    for _, fx in ipairs(pattern_line.effect_columns or {}) do
        -- Skip 0Zxx effect columns entirely
        if not M._is_zxx(fx.number_string, fx.number_value) then
            fx_cols[#fx_cols + 1] = {
                number_value = fx.number_value,
                number_string = fx.number_string,
                amount_value = fx.amount_value,
                amount_string = fx.amount_string,
            }
        end
    end

    return { note_columns = note_cols, effect_columns = fx_cols }
end

---------------------------------------------------------------------------
-- Mapping: pattern line offset → phrase line index
---------------------------------------------------------------------------

--- Given a pattern line offset (relative to where the phrase trigger sits
--- in the pattern) and a phrase, return the 1-based phrase line index that
--- would sound on that pattern line.
---
--- The mapping accounts for the LPB ratio between the song grid and the
--- phrase grid.  For looping phrases, the index wraps around using the
--- phrase's loop_start / loop_end range.  For one-shot phrases, returns
--- nil when the offset falls past the last phrase line.
---
--- @param  pattern_offset  number      0-based song-line offset from the trigger
--- @param  phrase          PhraseData  Phrase data
--- @param  song_lpb        number?     Song lines-per-beat (default 4)
--- @return number?                     1-based phrase line index, or nil if past end

function M.phrase_line_from_pattern_offset(pattern_offset, phrase, song_lpb)
    song_lpb = song_lpb or 4

    local phrase_lpb = phrase.lpb or song_lpb
    local total = phrase.number_of_lines
    local looping = phrase.looping or false
    local loop_start = phrase.loop_start or 1
    local loop_end = phrase.loop_end or total

    loop_start = math.max(1, math.min(loop_start, total))
    loop_end = math.max(loop_start, math.min(loop_end, total))

    local phrase_line_0 = math.floor((pattern_offset - 1) / song_lpb * phrase_lpb) + 1

    if not looping then
        if phrase_line_0 > total then
            return nil
        end
        return phrase_line_0
    end

    -- Looping: first run through lines 1..loop_end, then wrap in the loop range
    if phrase_line_0 <= loop_end then
        return phrase_line_0
    end

    local loop_len = loop_end - loop_start + 1
    local past_loop = phrase_line_0 - loop_end
    return loop_start + (( past_loop - 1  )% loop_len)
end

---------------------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------------------

--- @param note_value number
--- @return string
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

--- @param s string
--- @return number?
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

--- @return PhraseResolverModule
return M