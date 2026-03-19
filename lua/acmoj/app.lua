local util = require("acmoj.util")
local api_module = require("acmoj.api")
local cache_module = require("acmoj.cache")
local files_module = require("acmoj.files")
local commands = require("acmoj.commands")

local M = {}

local config = {
  base_url = "https://acm.sjtu.edu.cn/OnlineJudge/api/v1",
  token_file = "~/.config/nvim/acmoj/token.txt",
  language = "cpp",
  poll_interval_ms = 1200,
  timeout_ms = 120000,
  notify_prefix = "[ACMOJ] ",
  map_submit = true,
  map_lhs = "<leader>s",
  map_problem_nav = true,
  map_problem_next_lhs = "<leader>sn",
  map_problem_prev_lhs = "<leader>sp",
  map_problem_list_lhs = "<leader>sl",
  map_problemsets_lhs = "<leader>ss",
  solution_dir = "solutions",
  solution_ext = "cpp",
  template_file = "~/.config/nvim/acmoj/template.cpp",
  cache_file = "~/.local/state/nvim/acmoj/cache.json",
  accepted_cache_page_limit = 50,
}

local state = {
  problemset = nil,
  current_index = nil,
  problemsets = {},
  problemsets_by_id = {},
  problemset_buf = nil,
  selector_buf = nil,
  problem_line_to_index = {},
  problem_back_line = nil,
  selector_line_to_id = {},
  cache = {
    accepted_problems = {},
    token_to_username = {},
    cache_username = nil,
  },
}

local commands_created = false
local highlights_created = false
local active_poll = {}

local api = api_module.create(config, util)
local cache = cache_module.create(config, state, util, api)
local files = files_module.create(config, state, util)

local function notify(msg, level)
  vim.notify(config.notify_prefix .. msg, level or vim.log.levels.INFO)
end

local function ensure_highlights()
  if highlights_created then
    return
  end
  vim.api.nvim_set_hl(0, "AcmojDim", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AcmojHeader", { bold = true, default = true })
  highlights_created = true
end

local function human_status(status, status_map)
  local info = status_map and status_map[status]
  if info and info.name_short then
    return string.format("%s (%s)", info.name_short, status)
  end
  return status
end

local function is_accepted_status(status)
  if type(status) ~= "string" then
    return false
  end
  return status:lower() == "accepted"
end

local function format_resource(sub)
  local parts = {}
  if sub.time_msecs ~= vim.NIL and sub.time_msecs ~= nil then
    table.insert(parts, string.format("time=%dms", sub.time_msecs))
  end
  if sub.memory_bytes ~= vim.NIL and sub.memory_bytes ~= nil then
    table.insert(parts, string.format("memory=%dKB", math.floor(sub.memory_bytes / 1024)))
  end
  if #parts == 0 then
    return ""
  end
  return " | " .. table.concat(parts, " ")
end

local function get_problems(problemset)
  if not problemset or type(problemset.problems) ~= "table" then
    return {}
  end
  return problemset.problems
end

local function accepted_count(problemset)
  local total = 0
  local accepted = 0
  for _, p in ipairs(get_problems(problemset)) do
    total = total + 1
    if cache.is_problem_accepted(p.id) then
      accepted = accepted + 1
    end
  end
  return accepted, total
end

local function ensure_view_buffer(kind)
  local key = kind == "selector" and "selector_buf" or "problemset_buf"
  local buf = state[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end

  buf = vim.api.nvim_create_buf(false, true)
  state[key] = buf
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  if kind == "selector" then
    vim.api.nvim_set_option_value("filetype", "acmojproblemsets", { buf = buf })
    vim.keymap.set("n", "<CR>", function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local id = state.selector_line_to_id[line]
      if id then
        M.problemset(id)
      end
    end, { buffer = buf, nowait = true, desc = "Load ACMOJ problemset" })
    vim.keymap.set("n", "r", function()
      M.problemsets()
    end, { buffer = buf, nowait = true, desc = "Refresh ACMOJ problemsets" })
  else
    vim.api.nvim_set_option_value("filetype", "acmojproblemset", { buf = buf })
    vim.keymap.set("n", "n", M.problem_next, { buffer = buf, nowait = true, desc = "ACMOJ next problem" })
    vim.keymap.set("n", "p", M.problem_prev, { buffer = buf, nowait = true, desc = "ACMOJ prev problem" })
    vim.keymap.set("n", "<CR>", function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if state.problem_back_line and line == state.problem_back_line then
        M.problemsets()
        return
      end
      local index = state.problem_line_to_index[line]
      if index then
        M.problem_jump(index)
      end
    end, { buffer = buf, nowait = true, desc = "Open ACMOJ problem" })
  end

  return buf
end

local function focus_buffer(buf)
  local opts = nil
  if type(buf) == "table" then
    opts = buf
    buf = opts.buf
  end
  opts = opts or {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end

  if opts.reuse_current then
    vim.api.nvim_win_set_buf(0, buf)
    return
  end

  vim.cmd("botright 18split")
  vim.api.nvim_win_set_buf(0, buf)
end

local function close_windows_with_buffer(buf, skip_win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= skip_win and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function focus_preferred_list_item(line_map, preferred)
  local lines = {}
  for line, _ in pairs(line_map or {}) do
    table.insert(lines, line)
  end
  table.sort(lines)

  local target = nil
  for _, line in ipairs(lines) do
    local value = line_map[line]
    if preferred and preferred(value, line) then
      target = line
      break
    end
  end

  if not target then
    target = lines[1] or 1
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

local function focus_selector_preferred_item()
  focus_preferred_list_item(state.selector_line_to_id, function(problemset_id)
    local ps = state.problemsets_by_id[problemset_id]
    if not ps then
      return false
    end
    local accepted, total = accepted_count(ps)
    return accepted < total
  end)
end

local function focus_problemset_preferred_item()
  local accepted, total = accepted_count(state.problemset)
  if accepted == total and state.problem_back_line then
    vim.api.nvim_win_set_cursor(0, { state.problem_back_line, 0 })
    return
  end

  local problems = get_problems(state.problemset)
  focus_preferred_list_item(state.problem_line_to_index, function(index)
    local p = problems[index]
    return p and not cache.is_problem_accepted(p.id)
  end)
end

local function open_file_in_code_window(path)
  local target = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    if bt == "" then
      target = win
      break
    end
  end

  if not target then
    target = vim.api.nvim_get_current_win()
  end

  close_windows_with_buffer(state.selector_buf, target)
  close_windows_with_buffer(state.problemset_buf, target)

  vim.api.nvim_set_current_win(target)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function render_problemset_selector()
  ensure_highlights()
  local buf = ensure_view_buffer("selector")
  local lines = {
    "ACMOJ Problemsets (newest first)",
    "Press <CR> to load, r to refresh",
    "",
  }
  local line_map = {}
  local grey_lines = {}

  for idx, ps in ipairs(state.problemsets) do
    local accepted, total = accepted_count(ps)
    local line = string.format("[%d] #%d %s (%d/%d)", idx, ps.id, ps.name or "", accepted, total)
    table.insert(lines, line)
    line_map[#lines] = ps.id
    if total > 0 and accepted == total then
      table.insert(grey_lines, #lines)
    end
  end

  state.selector_line_to_id = line_map
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "AcmojHeader", 0, 0, -1)
  for _, line_no in ipairs(grey_lines) do
    vim.api.nvim_buf_add_highlight(buf, -1, "AcmojDim", line_no - 1, 0, -1)
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_name(buf, "acmoj://problemsets")
end

local function render_problemset_view()
  if not state.problemset then
    return
  end

  ensure_highlights()
  local buf = ensure_view_buffer("problemset")
  local problems = get_problems(state.problemset)
  local lines = {}
  local line_map = {}
  local grey_lines = {}

  local accepted, total = accepted_count(state.problemset)
  table.insert(lines, string.format("Problemset #%d: %s (%d/%d)", state.problemset.id, state.problemset.name or "", accepted, total))
  table.insert(lines, "")
  table.insert(lines, "Description:")
  local desc = tostring(state.problemset.description or "")
  desc = desc:gsub("\r\n", "\n")
  if desc == "" then
    table.insert(lines, "(empty)")
  else
    for _, line in ipairs(vim.split(desc, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Problems:")
  table.insert(lines, "返回题单列表")
  local back_line = #lines
  for i, p in ipairs(problems) do
    local mark = cache.is_problem_accepted(p.id) and "✓" or "✗"
    local title = p.title or "(hidden)"
    table.insert(lines, string.format("[%d] %s %d %s", i, mark, p.id, title))
    line_map[#lines] = i
    if mark == "✓" then
      table.insert(grey_lines, #lines)
    end
  end

  state.problem_line_to_index = line_map
  state.problem_back_line = back_line
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "AcmojHeader", 0, 0, -1)
  for _, line_no in ipairs(grey_lines) do
    vim.api.nvim_buf_add_highlight(buf, -1, "AcmojDim", line_no - 1, 0, -1)
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_name(buf, string.format("acmoj://problemset/%d", state.problemset.id))
end

local function refresh_views()
  if state.selector_buf and vim.api.nvim_buf_is_valid(state.selector_buf) then
    render_problemset_selector()
  end
  if state.problemset and state.problemset_buf and vim.api.nvim_buf_is_valid(state.problemset_buf) then
    render_problemset_view()
  end
end

local function poll_submission(submission_id, token, status_map)
  local start_at = vim.uv.now()

  local function poll_once()
    if active_poll[submission_id] == false then
      return
    end

    api.get(token, "/submission/" .. submission_id, function(sub, err)
      if err then
        notify("query submission failed: " .. err, vim.log.levels.ERROR)
        active_poll[submission_id] = false
        return
      end

      if type(sub) ~= "table" or type(sub.status) ~= "string" then
        notify("invalid submission response", vim.log.levels.ERROR)
        active_poll[submission_id] = false
        return
      end

      local finished = not sub.should_auto_reload
      if finished then
        local problem_id = sub.problem and sub.problem.id
        local accepted = is_accepted_status(sub.status)
        if accepted and type(problem_id) == "number" then
          cache.mark_problem_accepted(problem_id)
          refresh_views()
        end

        local msg = string.format(
          "#%d %s%s",
          submission_id,
          human_status(sub.status, status_map),
          format_resource(sub)
        )
        local level = accepted and vim.log.levels.INFO or vim.log.levels.WARN
        notify(msg, level)
        active_poll[submission_id] = false
        return
      end

      if vim.uv.now() - start_at >= config.timeout_ms then
        notify(string.format("#%d still running, stop polling (timeout)", submission_id), vim.log.levels.WARN)
        active_poll[submission_id] = false
        return
      end

      vim.defer_fn(poll_once, config.poll_interval_ms)
    end)
  end

  poll_once()
end

local function open_problem_by_index(index, silent)
  local problems = get_problems(state.problemset)
  if #problems == 0 then
    notify("problemset has no problems", vim.log.levels.WARN)
    return
  end

  if index < 1 then
    index = #problems
  elseif index > #problems then
    index = 1
  end

  state.current_index = index
  local problem = problems[index]
  local path, created, filename, err = files.ensure_solution_file(problem)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  open_file_in_code_window(path)
  render_problemset_view()

  if not silent then
    if created then
      notify(string.format("created %s", filename))
    else
      notify(string.format("opened %s", filename))
    end
  end
end

local function set_problemsets(problemsets)
  local by_id = {}
  table.sort(problemsets, function(a, b)
    local x = tonumber(a.id) or 0
    local y = tonumber(b.id) or 0
    return x > y
  end)
  for _, ps in ipairs(problemsets) do
    if type(ps.id) == "number" then
      by_id[ps.id] = ps
    end
  end
  state.problemsets = problemsets
  state.problemsets_by_id = by_id
end

local function load_problemset_by_id(problemset_id)
  local token, token_err = files.read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  api.get(token, "/problemset/" .. problemset_id, function(body, err)
    if err then
      notify("load problemset failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if type(body) ~= "table" or type(body.id) ~= "number" then
      notify("invalid problemset response", vim.log.levels.ERROR)
      return
    end

    state.problemset = body
    state.current_index = 1
    local problems = get_problems(body)
    for i, p in ipairs(problems) do
      if not cache.is_problem_accepted(p.id) then
        state.current_index = i
        break
      end
    end

    render_problemset_view()
    local reuse_current = state.selector_buf
      and vim.api.nvim_buf_is_valid(state.selector_buf)
      and vim.api.nvim_win_get_buf(0) == state.selector_buf
    focus_buffer({ buf = state.problemset_buf, reuse_current = reuse_current })
    close_windows_with_buffer(state.selector_buf)
    focus_problemset_preferred_item()
  end)
end

local function load_problemsets_and_show()
  local token, token_err = files.read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  api.get(token, "/user/problemsets", function(body, err)
    if err then
      notify("load problemsets failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if type(body) ~= "table" or type(body.problemsets) ~= "table" then
      notify("invalid problemsets response", vim.log.levels.ERROR)
      return
    end

    set_problemsets(body.problemsets)
    render_problemset_selector()
    local reuse_current = state.problemset_buf
      and vim.api.nvim_buf_is_valid(state.problemset_buf)
      and vim.api.nvim_win_get_buf(0) == state.problemset_buf
    focus_buffer({ buf = state.selector_buf, reuse_current = reuse_current })
    close_windows_with_buffer(state.problemset_buf)
    focus_selector_preferred_item()
  end)
end

function M.set_token(raw_token)
  local token = util.trim(raw_token or "")
  if token == "" then
    notify("token cannot be empty", vim.log.levels.ERROR)
    return
  end

  local path = util.expand_path(config.token_file)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, write_err = pcall(vim.fn.writefile, { token }, path)
  if not ok then
    notify("write token failed: " .. tostring(write_err), vim.log.levels.ERROR)
    return
  end

  notify("token saved")
  cache.refresh_cache_for_new_token(token, function(err)
    notify(err, vim.log.levels.ERROR)
  end)
end

local function prompt_and_set_token()
  local token = vim.fn.inputsecret("ACMOJ token: ")
  token = util.trim(token or "")
  if token == "" then
    notify("token input canceled", vim.log.levels.WARN)
    return
  end
  M.set_token(token)
end

function M.clear_cache()
  cache.clear_cache_file()
  refresh_views()
  notify("cache cleared")
end

function M.template()
  local path, created, err = files.init_template_file()
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  open_file_in_code_window(path)
  if created then
    notify("template initialized and opened: " .. path)
  else
    notify("opened template: " .. path)
  end
end

function M.submit_current_buffer()
  local token, token_err = files.read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  local problem_id, id_err = files.get_problem_id_from_first_line()
  if id_err then
    notify(id_err, vim.log.levels.ERROR)
    return
  end

  local code = files.current_buffer_code()
  if code == "" then
    notify("buffer is empty", vim.log.levels.ERROR)
    return
  end

  notify(string.format("submitting problem %d ...", problem_id))

  api.get(token, "/meta/info/judge-status", function(status_map, status_err)
    if status_err then
      notify("fetch status map failed: " .. status_err, vim.log.levels.WARN)
      status_map = nil
    end

    api.submit(problem_id, config.language, code, token, function(submission_id, submit_err)
      if submit_err then
        notify(submit_err, vim.log.levels.ERROR)
        return
      end

      notify(string.format("submitted: #%d, waiting for judge...", submission_id))
      active_poll[submission_id] = true
      poll_submission(submission_id, token, status_map)
    end)
  end)
end

function M.problemset(id)
  local pid = tonumber(id)
  if not pid then
    notify("problemset id must be a number", vim.log.levels.ERROR)
    return
  end
  load_problemset_by_id(pid)
end

function M.problemsets()
  load_problemsets_and_show()
end

function M.problem_next()
  if not state.problemset then
    notify("no problemset loaded", vim.log.levels.WARN)
    return
  end
  open_problem_by_index((state.current_index or 1) + 1)
end

function M.problem_prev()
  if not state.problemset then
    notify("no problemset loaded", vim.log.levels.WARN)
    return
  end
  open_problem_by_index((state.current_index or 1) - 1)
end

function M.problem_jump(target)
  if not state.problemset then
    notify("no problemset loaded", vim.log.levels.WARN)
    return
  end

  local n = tonumber(target)
  if not n then
    notify("jump target must be index or problem id", vim.log.levels.ERROR)
    return
  end

  local problems = get_problems(state.problemset)
  local as_index = math.floor(n)
  if as_index >= 1 and as_index <= #problems then
    open_problem_by_index(as_index)
    return
  end

  for i, p in ipairs(problems) do
    if p.id == as_index then
      open_problem_by_index(i)
      return
    end
  end
  notify(string.format("problem not found: %d", as_index), vim.log.levels.ERROR)
end

function M.problem_list()
  if not state.problemset then
    notify("no problemset loaded", vim.log.levels.WARN)
    return
  end
  render_problemset_view()
  focus_buffer(state.problemset_buf)
  focus_problemset_preferred_item()
end

function M.stop_poll(submission_id)
  active_poll[submission_id] = false
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  api = api_module.create(config, util)
  cache = cache_module.create(config, state, util, api)
  files = files_module.create(config, state, util)

  cache.load_cache()
  local token, token_err = files.read_token()
  if not token_err then
    cache.refresh_cache_for_new_token(token, function(err)
      notify(err, vim.log.levels.ERROR)
    end)
  end

  if not commands_created then
    commands.create({
      submit = M.submit_current_buffer,
      problemsets = M.problemsets,
      problemset = M.problemset,
      problem_next = M.problem_next,
      problem_prev = M.problem_prev,
      problem_jump = M.problem_jump,
      problem_list = M.problem_list,
      prompt_set_token = prompt_and_set_token,
      template = M.template,
      clear_cache = M.clear_cache,
    }, notify)
    commands_created = true
  end

  if config.map_submit then
    vim.keymap.set("n", config.map_lhs, M.submit_current_buffer, { desc = "Submit current buffer to ACMOJ" })
  end

  if config.map_problem_nav then
    vim.keymap.set("n", config.map_problemsets_lhs, M.problemsets, { desc = "ACMOJ problemset selector" })
    vim.keymap.set("n", config.map_problem_next_lhs, M.problem_next, { desc = "ACMOJ next problem" })
    vim.keymap.set("n", config.map_problem_prev_lhs, M.problem_prev, { desc = "ACMOJ previous problem" })
    vim.keymap.set("n", config.map_problem_list_lhs, M.problem_list, { desc = "ACMOJ problemset list" })
  end
end

return M
