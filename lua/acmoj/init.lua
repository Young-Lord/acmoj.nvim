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
  problemset_buf = nil,
  selector_buf = nil,
  problem_line_to_index = {},
  selector_line_to_id = {},
  cache = { accepted_problems = {} },
}

local active_poll = {}
local commands_created = false
local highlights_created = false

local function notify(msg, level)
  vim.notify(config.notify_prefix .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function expand_path(path)
  local expanded = vim.fn.expand(path)
  if expanded:match("^/") then
    return expanded
  end
  return vim.fs.joinpath(vim.uv.cwd(), expanded)
end

local function ensure_highlights()
  if highlights_created then
    return
  end
  vim.api.nvim_set_hl(0, "AcmojDim", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AcmojHeader", { bold = true, default = true })
  highlights_created = true
end

local function read_token()
  if not config.token_file or config.token_file == "" then
    return nil, "token_file is not configured"
  end

  local path = expand_path(config.token_file)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, string.format("token file not found: %s", path)
  end

  local token = trim(lines[1] or "")
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

local function request_json(args, on_done)
  vim.system(args, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local err = trim((obj.stderr or "") .. " " .. (obj.stdout or ""))
        on_done(nil, string.format("curl failed (%d): %s", obj.code, err))
        return
      end

      local body = obj.stdout or ""
      if body == "" then
        on_done({}, nil)
        return
      end

      local ok, decoded = pcall(vim.json.decode, body)
      if not ok then
        on_done(nil, "failed to parse JSON response")
        return
      end
      on_done(decoded, nil)
    end)
  end)
end

local function build_curl_headers(token)
  return {
    "-H",
    "Authorization: Bearer " .. token,
    "-H",
    "Accept: application/json",
  }
end

local function api_get(token, endpoint, on_done)
  local args = { "curl", "-sS", config.base_url .. endpoint }
  vim.list_extend(args, build_curl_headers(token))
  request_json(args, on_done)
end

local function api_submit(problem_id, language, code, token, on_done)
  local args = {
    "curl",
    "-sS",
    "-X",
    "POST",
    config.base_url .. "/problem/" .. problem_id .. "/submit",
    "-H",
    "Content-Type: application/x-www-form-urlencoded",
    "--data-urlencode",
    "language=" .. language,
    "--data-urlencode",
    "code=" .. code,
  }
  vim.list_extend(args, build_curl_headers(token))

  request_json(args, function(body, err)
    if err then
      on_done(nil, err)
      return
    end
    if type(body) ~= "table" or type(body.id) ~= "number" then
      on_done(nil, "submit failed: response does not include submission id")
      return
    end
    on_done(body.id, nil)
  end)
end

local function cache_path()
  return expand_path(config.cache_file)
end

local function save_cache()
  local path = cache_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local payload = {
    updated_at = os.time(),
    accepted_problems = state.cache.accepted_problems,
  }
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return
  end
  vim.fn.writefile({ encoded }, path)
end

local function load_cache()
  local path = cache_path()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    state.cache = { accepted_problems = {} }
    return
  end

  local raw = table.concat(lines, "\n")
  local success, decoded = pcall(vim.json.decode, raw)
  if not success or type(decoded) ~= "table" then
    state.cache = { accepted_problems = {} }
    return
  end

  local accepted = type(decoded.accepted_problems) == "table" and decoded.accepted_problems or {}
  state.cache = { accepted_problems = accepted }
end

local function mark_problem_accepted(problem_id)
  state.cache.accepted_problems[tostring(problem_id)] = true
  save_cache()
end

local function is_problem_accepted(problem_id)
  return state.cache.accepted_problems[tostring(problem_id)] == true
end

local function sanitize_full_name(name)
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

local function render_template_lines(problem, problemset)
  if not config.template_file or config.template_file == "" then
    return nil, "template_file is not configured"
  end

  local path = expand_path(config.template_file)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, string.format("template file not found: %s", path)
  end

  local full_name = sanitize_full_name(problem.title)
  local replacements = {
    ["{problem_id}"] = tostring(problem.id or ""),
    ["{full_name}"] = full_name,
    ["{problem_title}"] = tostring(problem.title or ""),
    ["{problemset_id}"] = tostring((problemset and problemset.id) or ""),
    ["{problemset_name}"] = tostring((problemset and problemset.name) or ""),
  }

  local out = {}
  for _, line in ipairs(lines) do
    local v = tostring(line)
    for key, rep in pairs(replacements) do
      v = v:gsub(vim.pesc(key), rep)
    end
    table.insert(out, v)
  end
  return out, nil
end

local function build_solution_path(problem)
  local dir = expand_path(config.solution_dir)
  local full_name = sanitize_full_name(problem.title)
  local filename = string.format("%d-%s.%s", problem.id, full_name, config.solution_ext)
  return vim.fs.joinpath(dir, filename), filename
end

local function ensure_solution_file(problem)
  local path, filename = build_solution_path(problem)
  if path_exists(path) then
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

local function human_status(status, status_map)
  local info = status_map and status_map[status]
  if info and info.name_short then
    return string.format("%s (%s)", info.name_short, status)
  end
  return status
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
    if is_problem_accepted(p.id) then
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
      local index = state.problem_line_to_index[line]
      if index then
        M.problem_jump(index)
      end
    end, { buffer = buf, nowait = true, desc = "Open ACMOJ problem" })
  end

  return buf
end

local function focus_buffer(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  vim.cmd("botright 18split")
  vim.api.nvim_win_set_buf(0, buf)
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

  if target then
    vim.api.nvim_set_current_win(target)
  end
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
  if desc == "" then
    table.insert(lines, "(empty)")
  else
    for _, line in ipairs(vim.split(desc, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Problems:")
  for i, p in ipairs(problems) do
    local mark = is_problem_accepted(p.id) and "✓" or "✗"
    local current = i == state.current_index and ">" or " "
    local title = p.title or "(hidden)"
    table.insert(lines, string.format("%s [%d] %s %d %s", current, i, mark, p.id, title))
    line_map[#lines] = i
    if mark == "✓" then
      table.insert(grey_lines, #lines)
    end
  end

  state.problem_line_to_index = line_map
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

    api_get(token, "/submission/" .. submission_id, function(sub, err)
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
        if sub.status == "accepted" and type(problem_id) == "number" then
          mark_problem_accepted(problem_id)
          refresh_views()
        end

        local msg = string.format(
          "#%d %s%s",
          submission_id,
          human_status(sub.status, status_map),
          format_resource(sub)
        )
        local level = sub.status == "accepted" and vim.log.levels.INFO or vim.log.levels.WARN
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

local function open_problem_by_index(index)
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
  local path, created, filename, err = ensure_solution_file(problem)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  open_file_in_code_window(path)
  render_problemset_view()

  if created then
    notify(string.format("created %s", filename))
  else
    notify(string.format("opened %s", filename))
  end
end

local function warm_accepted_cache(token, on_done)
  local page_limit = tonumber(config.accepted_cache_page_limit) or 50
  if page_limit < 1 then
    page_limit = 1
  end

  local function fetch(cursor, pages)
    if pages > page_limit then
      save_cache()
      on_done(nil)
      return
    end

    local endpoint = "/submission/?status=accepted"
    if cursor then
      endpoint = endpoint .. "&cursor=" .. cursor
    end

    api_get(token, endpoint, function(body, err)
      if err then
        on_done(err)
        return
      end

      if type(body.submissions) == "table" then
        for _, sub in ipairs(body.submissions) do
          local pid = sub and sub.problem and sub.problem.id
          if type(pid) == "number" then
            state.cache.accepted_problems[tostring(pid)] = true
          end
        end
      end
      save_cache()

      local next_url = body.next
      local next_cursor = type(next_url) == "string" and next_url:match("[?&]cursor=(%d+)") or nil
      if next_cursor then
        fetch(next_cursor, pages + 1)
        return
      end

      on_done(nil)
    end)
  end

  fetch(nil, 1)
end

local function set_problemsets(problemsets)
  table.sort(problemsets, function(a, b)
    local x = tonumber(a.id) or 0
    local y = tonumber(b.id) or 0
    return x > y
  end)
  state.problemsets = problemsets
end

local function load_problemset_by_id(problemset_id)
  local token, token_err = read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  api_get(token, "/problemset/" .. problemset_id, function(body, err)
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
    render_problemset_view()
    focus_buffer(state.problemset_buf)

    local count = #get_problems(body)
    local accepted, total = accepted_count(body)
    notify(string.format("loaded problemset #%d (%d/%d)", body.id, accepted, total))
    if count > 0 then
      open_problem_by_index(1)
    end
  end)
end

local function load_problemsets_and_show()
  local token, token_err = read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  api_get(token, "/user/problemsets", function(body, err)
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
    focus_buffer(state.selector_buf)
    notify(string.format("loaded %d problemsets", #state.problemsets))

    warm_accepted_cache(token, function(cache_err)
      if cache_err then
        notify("refresh accepted cache failed: " .. cache_err, vim.log.levels.WARN)
        return
      end
      refresh_views()
      notify("accepted cache refreshed")
    end)
  end)
end

function M.submit_current_buffer()
  local token, token_err = read_token()
  if token_err then
    notify(token_err, vim.log.levels.ERROR)
    return
  end

  local problem_id, id_err = get_problem_id_from_first_line()
  if id_err then
    notify(id_err, vim.log.levels.ERROR)
    return
  end

  local code = current_buffer_code()
  if code == "" then
    notify("buffer is empty", vim.log.levels.ERROR)
    return
  end

  notify(string.format("submitting problem %d ...", problem_id))

  api_get(token, "/meta/info/judge-status", function(status_map, status_err)
    if status_err then
      notify("fetch status map failed: " .. status_err, vim.log.levels.WARN)
      status_map = nil
    end

    api_submit(problem_id, config.language, code, token, function(submission_id, submit_err)
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
end

function M.stop_poll(submission_id)
  active_poll[submission_id] = false
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  load_cache()

  if not commands_created then
    vim.api.nvim_create_user_command("AcmojSubmit", function()
      M.submit_current_buffer()
    end, { desc = "Submit current buffer to ACMOJ" })

    vim.api.nvim_create_user_command("AcmojProblemsets", function()
      M.problemsets()
    end, { desc = "Load and select ACMOJ problemset" })

    vim.api.nvim_create_user_command("AcmojProblemset", function(cmd_opts)
      M.problemset(cmd_opts.args)
    end, { nargs = 1, desc = "Load ACMOJ problemset by id" })

    vim.api.nvim_create_user_command("AcmojProblemNext", function()
      M.problem_next()
    end, { desc = "Open next ACMOJ problem file" })

    vim.api.nvim_create_user_command("AcmojProblemPrev", function()
      M.problem_prev()
    end, { desc = "Open previous ACMOJ problem file" })

    vim.api.nvim_create_user_command("AcmojProblemJump", function(cmd_opts)
      M.problem_jump(cmd_opts.args)
    end, { nargs = 1, desc = "Jump by ACMOJ problem index or id" })

    vim.api.nvim_create_user_command("AcmojProblemList", function()
      M.problem_list()
    end, { desc = "Show ACMOJ problemset details" })

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
