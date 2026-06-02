-- Shared test helpers. Each spec under tests/specs/ requires this and
-- uses the wait_for / assert_eq / call helpers to keep individual specs
-- terse. Specs return an exit code via os.exit(); the runner picks that up.

local H = {}

H.HOST = os.getenv("PLURNK_HOST") or "127.0.0.1"
H.PORT = tonumber(os.getenv("PLURNK_PORT") or "3044")

H.setup = function()
  vim.opt.rtp:append(os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim")
  require("plurnk").setup({ host = H.HOST, port = H.PORT })
end

H.call = function(method, params, timeout_ms)
  local got_result, got_err
  require("plurnk.client").send(method, params or {}, false, function(result)
    got_result = result or vim.NIL
  end)
  -- We can't observe `error` separately through send(); the dispatch
  -- layer logs and surfaces it. Spec authors should pass valid params.
  local fired = vim.wait(timeout_ms or 5000, function() return got_result ~= nil end, 25)
  if not fired then error("call(" .. method .. ") timed out after " .. (timeout_ms or 5000) .. "ms") end
  if got_result == vim.NIL then return nil end
  return got_result
end

H.notify_only = function(method, params)
  require("plurnk.client").send(method, params or {}, true)
end

H.wait_for = function(predicate, timeout_ms, label)
  local fired = vim.wait(timeout_ms or 5000, predicate, 25)
  if not fired then error("wait_for(" .. (label or "?") .. ") timed out") end
end

H.assert_eq = function(actual, expected, msg)
  if actual ~= expected then
    error(string.format("ASSERT %s: expected %s, got %s",
      msg or "?", vim.inspect(expected), vim.inspect(actual)))
  end
end

H.assert_truthy = function(val, msg)
  if not val then error("ASSERT truthy " .. (msg or "?")) end
end

H.assert_type = function(val, t, msg)
  if type(val) ~= t then
    error(string.format("ASSERT %s: expected type %s, got %s (%s)",
      msg or "?", t, type(val), vim.inspect(val)))
  end
end

H.assert_match = function(s, pat, msg)
  if type(s) ~= "string" or not s:match(pat) then
    error(string.format("ASSERT %s: %s does not match %s",
      msg or "?", vim.inspect(s), pat))
  end
end

H.finish = function(name)
  print("PASS " .. name)
  -- transport.stop() so background nvim subprocess goes away cleanly.
  pcall(function() require("plurnk.client").stop() end)
  vim.cmd("qa!")
end

H.fail = function(name, err)
  print("FAIL " .. name .. ": " .. tostring(err))
  pcall(function() require("plurnk.client").stop() end)
  vim.cmd("cq")
end

return H
