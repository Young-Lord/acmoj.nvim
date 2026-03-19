local M = {}

local function default_template_lines()
  return {
    "// ACMOJ {problem_id}",
    "// {problem_title}",
    "#include <bits/stdc++.h>",
    "using namespace std;",
    "",
    "int main() {",
    "  ios::sync_with_stdio(false);",
    "  cin.tie(nullptr);",
    "",
    "  return 0;",
    "}",
  }
end

function M.create(config, state, util)
  local function read_token()
    if not config.token_file or config.token_file == "" then
      return nil, "token_file is not configured"
    end

    local path = util.expand_path(config.token_file)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      return nil, string.format("token file not found: %s", path)
    end

    local token = util.trim(lines[1] or "")
    if token == "" then
      return nil, string.format("token file is empty: %s", path)
    end
    return token, nil
  end

  local function get_problem_id_from_first_line()
    local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
    local id = line:match("ACMOJ.*(%d+)")
    if not id then
      return nil, "first line must match ACMOJ(.+)?(\\d+) and contain problem id"
    end
    return tonumber(id), nil
  end

  local function current_buffer_code()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return table.concat(lines, "\n")
  end

  local function template_path()
    if not config.template_file or config.template_file == "" then
      return nil, "template_file is not configured"
    end
    return util.expand_path(config.template_file), nil
  end

  local function init_template_file()
    local path, path_err = template_path()
    if path_err then
      return nil, false, path_err
    end
    if util.path_exists(path) then
      return path, false, nil
    end

    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local ok, write_err = pcall(vim.fn.writefile, default_template_lines(), path)
    if not ok then
      return nil, false, "write template failed: " .. tostring(write_err)
    end
    return path, true, nil
  end

  local function render_template_lines(problem, problemset)
    local path, path_err = template_path()
    if path_err then
      return nil, path_err
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      return nil, string.format("template file not found: %s", path)
    end

    local full_name = util.sanitize_full_name(problem.title)
    local replacements = {
      ["{problem_id}"] = tostring(problem.id or ""),
      ["{full_name}"] = full_name,
      ["{problem_title}"] = tostring(problem.title or ""),
      ["{problemset_id}"] = tostring((problemset and problemset.id) or ""),
      ["{problemset_name}"] = tostring((problemset and problemset.name) or ""),
    }

    local out = {}
    for _, line in ipairs(lines) do
      local value = tostring(line)
      for key, rep in pairs(replacements) do
        value = value:gsub(vim.pesc(key), rep)
      end
      table.insert(out, value)
    end
    return out, nil
  end

  local function build_solution_path(problem)
    local dir = util.expand_path(config.solution_dir)
    local full_name = util.sanitize_full_name(problem.title)
    local filename = string.format("%d-%s.%s", problem.id, full_name, config.solution_ext)
    return vim.fs.joinpath(dir, filename), filename
  end

  local function ensure_solution_file(problem)
    local path, filename = build_solution_path(problem)
    if util.path_exists(path) then
      return path, false, filename, nil
    end

    local lines, err = render_template_lines(problem, state.problemset)
    if err then
      return nil, false, nil, err
    end

    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
    return path, true, filename, nil
  end

  return {
    read_token = read_token,
    get_problem_id_from_first_line = get_problem_id_from_first_line,
    current_buffer_code = current_buffer_code,
    init_template_file = init_template_file,
    ensure_solution_file = ensure_solution_file,
  }
end

return M
