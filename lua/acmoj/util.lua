local M = {}

function M.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.path_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

function M.expand_path(path)
  local expanded = vim.fn.expand(path)
  if expanded:match("^/") then
    return expanded
  end
  return vim.fs.joinpath(vim.uv.cwd(), expanded)
end

function M.url_encode(value)
  return (tostring(value):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function M.sanitize_full_name(name)
  local value = tostring(name or "problem")
  value = value:gsub("%s+", "_")
  value = value:gsub("[%c]", "")
  value = value:gsub("[/\\:*?\"<>|]", "_")
  value = value:gsub("_+", "_")
  value = value:gsub("^_", "")
  value = value:gsub("_$", "")
  if value == "" then
    value = "problem"
  end
  return value
end

return M
