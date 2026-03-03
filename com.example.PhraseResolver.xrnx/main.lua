---
--- Phrase Resolver Tool – main.lua
--- Step 1: Monitor pattern line changes and print them to the scripting console.
---

local phrase_resolver = require("phrase_resolver")

--------------------------------------------------------------------------------
-- Notifier management
--------------------------------------------------------------------------------

-- We keep a reference to the pattern we're currently watching
-- so we can remove the notifier before attaching to a new one.
local watched_pattern_index = nil

--- Format a single NoteColumn into a readable string.
--- Example output: "C-4 00 80 .. 00 .... .."
local function format_note_column(nc)
  return string.format("%s %s %s %s %s %s%s",
          nc.note_string,
          nc.instrument_string,
          nc.volume_string,
          nc.panning_string,
          nc.delay_string,
          nc.effect_number_string,
          nc.effect_amount_string
  )
end

--- Format a single EffectColumn into a readable string.
local function format_effect_column(ec)
  return string.format("%s%s",
          ec.number_string,
          ec.amount_string
  )
end

--- Print the full contents of a pattern line.
local function intepret_line(pos)
  local song = renoise.song()
  local instruments = renoise.song().instruments

  -- Bounds check: the pattern/track may have been deleted between
  -- the notification and the time we process it.
  if pos.pattern < 1 or pos.pattern > #song.patterns then return end
  local pattern = song:pattern(pos.pattern)
  if pos.track < 1 or pos.track > #pattern.tracks then return end

  local line = pattern:track(pos.track):line(pos.line)

  local resolved, err = phrase_resolver.resolve_pattern_phrase(line, instruments)
  if resolved == nil then
    print(err)
    return
  end

  local pattern_from_phrase = phrase_resolver.resolved_to_pattern_lines(resolved, renoise.song().transport.lpb)
  local target_track_idx = pos.track + 1

  -- Bounds check
  if target_track_idx > #song.tracks then return end

  local track = pattern:track(target_track_idx)
  local rns_track = song:track(target_track_idx)  -- for adjusting visible columns

  -- Find the max note/effect columns we need
  local max_note_cols = 0
  local max_fx_cols = 0
  for _, pline in ipairs(pattern_from_phrase) do
    if #pline.note_columns > max_note_cols then
      max_note_cols = #pline.note_columns
    end
    if #pline.effect_columns > max_fx_cols then
      max_fx_cols = #pline.effect_columns
    end
  end

  -- Expand visible columns if needed
  if max_note_cols > rns_track.visible_note_columns then
    rns_track.visible_note_columns = max_note_cols
  end
  if max_fx_cols > rns_track.visible_effect_columns then
    rns_track.visible_effect_columns = max_fx_cols
  end

  -- Write lines
  for i, pline in ipairs(pattern_from_phrase) do
    local line_idx = pos.line + (i - 1)
    if line_idx > pattern.number_of_lines then break end

    local target_line = track:line(line_idx)
    target_line:clear()

    for col_i, col in ipairs(pline.note_columns) do
      local nc = target_line:note_column(col_i)
      nc.note_value          = col.note_value          or 121
      nc.instrument_value    = col.instrument_value    or 255
      nc.volume_value        = col.volume_value        or 255
      nc.panning_value       = col.panning_value       or 255
      nc.delay_value         = col.delay_value         or 0
      nc.effect_number_value = col.effect_number_value or 0
      nc.effect_amount_value = col.effect_amount_value or 0
    end

    for fx_i, fc in ipairs(pline.effect_columns) do
      local ec = target_line:effect_column(fx_i)
      ec.number_value = fc.number_value or 0
      ec.amount_value = fc.amount_value or 0
    end
  end

end

--- The callback handed to add_line_notifier.
local function on_line_changed(pos)
  intepret_line(pos)
end

--- Attach a line notifier to the given pattern (by index).
local function attach_to_pattern(pat_idx)
  local song = renoise.song()

  -- Remove the old notifier, if any.
  if watched_pattern_index then
    local ok, old_pat = pcall(function()
      return song:pattern(watched_pattern_index)
    end)
    if ok and old_pat:has_line_notifier(on_line_changed) then
      old_pat:remove_line_notifier(on_line_changed)
    end
    watched_pattern_index = nil
  end

  -- Attach to the new pattern.
  if pat_idx >= 1 and pat_idx <= #song.patterns then
    local pat = song:pattern(pat_idx)
    if not pat:has_line_notifier(on_line_changed) then
      pat:add_line_notifier(on_line_changed)
    end
    watched_pattern_index = pat_idx
    print(string.format(">> Phrase Resolver: watching pattern %d", pat_idx))
  end
end

--- Called whenever selected_pattern_observable fires.
local function on_selected_pattern_changed()
  local idx = renoise.song().selected_pattern_index
  attach_to_pattern(idx)
end

--------------------------------------------------------------------------------
-- Song lifecycle
--------------------------------------------------------------------------------

local function setup_song_notifiers()
  local song = renoise.song()
  -- Follow the currently selected pattern.
  if song.selected_pattern_observable:has_notifier(on_selected_pattern_changed) then
    song.selected_pattern_observable:remove_notifier(on_selected_pattern_changed)
  end
  song.selected_pattern_observable:add_notifier(on_selected_pattern_changed)
  -- Immediately attach to the current pattern.
  attach_to_pattern(song.selected_pattern_index)
end

local function teardown_song_notifiers()
  -- The old song (and its observables) is about to be discarded,
  -- so Renoise will clean up notifiers automatically. But we reset
  -- our bookkeeping.
  watched_pattern_index = nil
end

--------------------------------------------------------------------------------
-- Tool entry point
--------------------------------------------------------------------------------

-- React to new documents (songs) being loaded.
renoise.tool().app_new_document_observable:add_notifier(function()
  setup_song_notifiers()
end)

-- If a song is already loaded when the tool starts, attach now.
if rawget(_G, "renoise") and renoise.song() then
  setup_song_notifiers()
end

print(">> Phrase Resolver tool loaded.")