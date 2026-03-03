---
--- Phrase Resolver Tool – main.lua
---

local phrase_resolver = require("phrase_resolver")

local RES_SUFFIX = "_res"

--------------------------------------------------------------------------------
-- Notifier management
--------------------------------------------------------------------------------

local watched_pattern_index = nil

--------------------------------------------------------------------------------
-- Track helpers
--------------------------------------------------------------------------------

--- Check if a track name ends with the _res suffix.
local function is_resolved_track(track_name)
  return track_name:sub(-#RES_SUFFIX) == RES_SUFFIX
end

--- Find or create the resolved-output track for the given source track.
--- Returns the track index of the _res track.
local function get_or_create_res_track(source_track_idx)
  local song = renoise.song()
  local source_track = song:track(source_track_idx)
  local res_name = source_track.name .. RES_SUFFIX

  -- Look for an existing _res track right after the source.
  for i = source_track_idx + 1, #song.tracks do
    local t = song:track(i)
    if t.name == res_name then
      return i
    end
    if t.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
      break
    end
  end

  -- Not found — insert a new track right after the source.
  local new_idx = source_track_idx + 1
  song:insert_track_at(new_idx)
  song:track(new_idx).name = res_name
  song:track(new_idx).color = source_track.color
  print(string.format(">> Phrase Resolver: created track '%s' at index %d",
          res_name, new_idx))
  return new_idx
end

--------------------------------------------------------------------------------
-- Writing resolved data to a track
--------------------------------------------------------------------------------

--- Ensure the target track has enough visible columns for the data.
local function ensure_visible_columns(rns_track, pattern_lines)
  local max_note_cols = 0
  local max_fx_cols = 0
  for _, pline in ipairs(pattern_lines) do
    if #pline.note_columns > max_note_cols then
      max_note_cols = #pline.note_columns
    end
    if #pline.effect_columns > max_fx_cols then
      max_fx_cols = #pline.effect_columns
    end
  end

  if max_note_cols > rns_track.visible_note_columns then
    rns_track.visible_note_columns = max_note_cols
  end
  if max_fx_cols > rns_track.visible_effect_columns then
    rns_track.visible_effect_columns = max_fx_cols
  end
end

--- Write a single PatternLine table into a real Renoise pattern line.
local function write_pattern_line(target_line, pline)
  for col_i, col in ipairs(pline.note_columns) do
    local nc = target_line:note_column(col_i)
    if col.note_value and col.note_value ~= 121 then
      nc.note_value = col.note_value
    end
    if col.instrument_value and col.instrument_value ~= 255 then
      nc.instrument_value = col.instrument_value
    end
    if col.volume_value and col.volume_value ~= 255 then
      nc.volume_value = col.volume_value
    end
    if col.panning_value and col.panning_value ~= 255 then
      nc.panning_value = col.panning_value
    end
    if col.delay_value and col.delay_value ~= 0 then
      nc.delay_value = col.delay_value
    end
    if col.effect_number_value and col.effect_number_value ~= 0 then
      nc.effect_number_value = col.effect_number_value
    end
    if col.effect_amount_value and col.effect_amount_value ~= 0 then
      nc.effect_amount_value = col.effect_amount_value
    end
  end

  for fx_i, fc in ipairs(pline.effect_columns) do
    local ec = target_line:effect_column(fx_i)
    if fc.number_value and fc.number_value ~= 0 then
      ec.number_value = fc.number_value
    end
    if fc.amount_value and fc.amount_value ~= 0 then
      ec.amount_value = fc.amount_value
    end
  end
end

--- Write an array of PatternLine tables into a pattern track,
--- starting at the given line index.
local function write_to_track(pattern, target_track_idx, start_line, pattern_lines)
  local song = renoise.song()
  local track = pattern:track(target_track_idx)
  local rns_track = song:track(target_track_idx)

  ensure_visible_columns(rns_track, pattern_lines)

  for i, pline in ipairs(pattern_lines) do
    local line_idx = start_line + (i - 1)
    if line_idx > pattern.number_of_lines then break end

    local target_line = track:line(line_idx)
    target_line:clear()
    write_pattern_line(target_line, pline)
  end
end

--------------------------------------------------------------------------------
-- Line interpretation
--------------------------------------------------------------------------------

--- Resolve a pattern line and write the result to the _res track.
local function interpret_line(pos)
  local song = renoise.song()
  local instruments = song.instruments

  -- Bounds check.
  if pos.pattern < 1 or pos.pattern > #song.patterns then return end
  local pattern = song:pattern(pos.pattern)
  if pos.track < 1 or pos.track > #pattern.tracks then return end

  -- Skip _res tracks — they are output-only.
  if is_resolved_track(song:track(pos.track).name) then return end

  local line = pattern:track(pos.track):line(pos.line)

  local resolved = phrase_resolver.resolve_pattern_phrase(line, instruments)
  local pattern_lines = phrase_resolver.resolved_to_pattern_lines(
          resolved, song.transport.lpb
  )

  local target_idx = get_or_create_res_track(pos.track)
  write_to_track(pattern, target_idx, pos.line, pattern_lines)
end

--------------------------------------------------------------------------------
-- Notifier callbacks
--------------------------------------------------------------------------------

local function on_line_changed(pos)
  interpret_line(pos)
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
  if song.selected_pattern_observable:has_notifier(on_selected_pattern_changed) then
    song.selected_pattern_observable:remove_notifier(on_selected_pattern_changed)
  end
  song.selected_pattern_observable:add_notifier(on_selected_pattern_changed)
  attach_to_pattern(song.selected_pattern_index)
end

local function teardown_song_notifiers()
  watched_pattern_index = nil
end

--------------------------------------------------------------------------------
-- Tool entry point
--------------------------------------------------------------------------------

renoise.tool().app_new_document_observable:add_notifier(function()
  setup_song_notifiers()
end)

if rawget(_G, "renoise") and renoise.song() then
  setup_song_notifiers()
end

print(">> Phrase Resolver tool loaded.")