-- Unified diff patch parser and applicator.
-- Handles standard udiff format: @@ -start,count +start,count @@

local M = {}

-- Parse a unified diff string into a list of hunks.
-- Each hunk: { old_start, old_count, new_start, new_count, lines }
-- lines: array of { op = "+"|"-"|" ", text = "..." }
M.parse = function(patch_text)
  local hunks = {}
  local current_hunk = nil

  for line in (patch_text .. "\n"):gmatch("([^\n]*)\n") do
    local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      if current_hunk then table.insert(hunks, current_hunk) end
      current_hunk = {
        old_start = tonumber(os),
        old_count = tonumber(oc ~= "" and oc or "1"),
        new_start = tonumber(ns),
        new_count = tonumber(nc ~= "" and nc or "1"),
        lines = {},
      }
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      local text = line:sub(2)
      if prefix == "+" or prefix == "-" or prefix == " " then
        table.insert(current_hunk.lines, { op = prefix, text = text })
      elseif line == "\\ No newline at end of file" then
        -- skip
      end
    end
    -- Skip --- and +++ header lines
  end
  if current_hunk then table.insert(hunks, current_hunk) end

  return hunks
end

-- Apply parsed hunks to an array of lines (0-indexed internally, 1-indexed input/output).
-- Returns new_lines array, or nil + error message on failure.
M.apply = function(original_lines, hunks)
  local result = {}
  local src_idx = 1  -- 1-indexed position in original_lines

  for _, hunk in ipairs(hunks) do
    -- Copy unchanged lines before this hunk
    while src_idx < hunk.old_start do
      table.insert(result, original_lines[src_idx])
      src_idx = src_idx + 1
    end

    -- Apply hunk
    for _, hl in ipairs(hunk.lines) do
      if hl.op == " " then
        -- Context line — verify match, advance source
        if original_lines[src_idx] ~= hl.text then
          return nil, string.format(
            "Context mismatch at line %d: expected '%s', got '%s'",
            src_idx, hl.text, tostring(original_lines[src_idx])
          )
        end
        table.insert(result, hl.text)
        src_idx = src_idx + 1
      elseif hl.op == "-" then
        -- Remove line — verify match, advance source without outputting
        if original_lines[src_idx] ~= hl.text then
          return nil, string.format(
            "Remove mismatch at line %d: expected '%s', got '%s'",
            src_idx, hl.text, tostring(original_lines[src_idx])
          )
        end
        src_idx = src_idx + 1
      elseif hl.op == "+" then
        -- Add line
        table.insert(result, hl.text)
      end
    end
  end

  -- Copy remaining lines after last hunk
  while src_idx <= #original_lines do
    table.insert(result, original_lines[src_idx])
    src_idx = src_idx + 1
  end

  return result
end

-- Convenience: parse patch and apply to file content string.
-- Returns new content string, or nil + error.
M.apply_patch = function(original_content, patch_text)
  local hunks = M.parse(patch_text)
  if #hunks == 0 then return nil, "No hunks found in patch" end

  local original_lines = vim.split(original_content, "\n")
  -- Remove trailing empty line from split if content ends with newline
  if #original_lines > 0 and original_lines[#original_lines] == "" then
    table.remove(original_lines)
  end

  local new_lines, err = M.apply(original_lines, hunks)
  if not new_lines then return nil, err end

  return table.concat(new_lines, "\n") .. "\n"
end

return M
