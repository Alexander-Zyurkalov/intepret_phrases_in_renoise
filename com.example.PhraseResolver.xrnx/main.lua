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


  for _, line in ipairs(resolved) do
    local row = string.format("%3d    %-6.3f",
            line.phrase_line_index, line.time_in_beats)

    for _, col in ipairs(line.note_columns) do
      local note_str = phrase_resolver.note_to_string(col.note_value)
      local vol_str  = col.volume_value and col.volume_value ~= 255
              and string.format("%3d", col.volume_value) or " .."
      row = row .. string.format("  %-5s %s", note_str, vol_str)
    end
    print(row)
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