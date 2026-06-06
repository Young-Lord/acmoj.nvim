local problem_mod = require("acmoj.problem")
local time_mod = require("acmoj.time")

local M = {}

function M.create(config, state, cache, api, files, notify_mod, actions)
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
					actions.problemset(id)
				end
			end, { buffer = buf, nowait = true, desc = "Load ACMOJ problemset" })
			vim.keymap.set("n", "r", function()
				actions.problemsets()
			end, { buffer = buf, nowait = true, desc = "Refresh ACMOJ problemsets" })
		else
			vim.api.nvim_set_option_value("filetype", "acmojproblemset", { buf = buf })
			vim.keymap.set("n", "n", actions.problem_next, { buffer = buf, nowait = true, desc = "ACMOJ next problem" })
			vim.keymap.set("n", "p", actions.problem_prev, { buffer = buf, nowait = true, desc = "ACMOJ prev problem" })
			vim.keymap.set("n", "<CR>", function()
				local line = vim.api.nvim_win_get_cursor(0)[1]
				if state.problem_back_line and line == state.problem_back_line then
					actions.problemsets()
					return
				end
				local index = state.problem_line_to_index[line]
				if index then
					actions.problem_jump(index)
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

	local function ensure_problem_desc_buffer()
		local buf = state.problem_desc_buf
		if buf and vim.api.nvim_buf_is_valid(buf) then
			return buf
		end

		buf = vim.api.nvim_create_buf(false, true)
		state.problem_desc_buf = buf
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
		vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
		vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_set_option_value("readonly", true, { buf = buf })
		vim.api.nvim_set_option_value("filetype", "text", { buf = buf })
		return buf
	end

	local function focus_or_open_desc_window(buf)
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == buf then
				vim.api.nvim_set_option_value("wrap", true, { win = win })
				vim.api.nvim_set_option_value("linebreak", true, { win = win })
				return win
			end
		end

		vim.cmd("botright 14split")
		vim.api.nvim_win_set_buf(0, buf)
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("wrap", true, { win = win })
		vim.api.nvim_set_option_value("linebreak", true, { win = win })
		return win
	end

	local function render_problem_description(problem, problem_detail)
		local buf = ensure_problem_desc_buffer()
		local lines = problem_mod.render_problem_statement_lines(problem, problem_detail)

		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_set_option_value("readonly", false, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_set_option_value("readonly", true, { buf = buf })
		vim.api.nvim_buf_set_name(buf, string.format("acmoj://problem-desc/%s", tostring(problem.id or "current")))
	end

	local function show_problem_description(problem)
		if not state.problem_desc_visible then
			return
		end
		if type(problem) ~= "table" or type(problem.id) ~= "number" then
			return
		end

		local previous_win = vim.api.nvim_get_current_win()
		local buf = ensure_problem_desc_buffer()
		focus_or_open_desc_window(buf)
		vim.api.nvim_set_current_win(previous_win)

		local cached = state.problem_desc_cache[problem.id]
		if type(cached) == "table" then
			render_problem_description(problem, cached)
			return
		end
		if type(cached) == "string" then
			render_problem_description(problem, { description = cached })
			return
		end

		render_problem_description(problem, { description = "loading description ..." })
		local token, token_err = files.read_token()
		if token_err then
			render_problem_description(problem, { description = "load description failed: " .. token_err })
			return
		end

		api.get(token, "/problem/" .. problem.id, function(body, err)
			if err then
				render_problem_description(problem, { description = "load description failed: " .. err })
				return
			end

			local detail = {}
			if type(body) == "table" then
				detail = body
			end
			state.problem_desc_cache[problem.id] = detail
			local samples = problem_mod.extract_samples(detail)
			if #samples == 0 then
				samples = problem_mod.extract_samples(problem)
			end
			if #samples > 0 then
				state.samples_cache[problem.id] = samples
			end
			render_problem_description(problem, detail)
		end)
	end

	local function hide_problem_description()
		if state.problem_desc_buf and vim.api.nvim_buf_is_valid(state.problem_desc_buf) then
			close_windows_with_buffer(state.problem_desc_buf)
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
		close_windows_with_buffer(state.problem_desc_buf, target)

		vim.api.nvim_set_current_win(target)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		pcall(vim.cmd, "only")
	end

	local function render_problemset_selector()
		notify_mod.ensure_highlights()
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
			local deadline = time_mod.problemset_deadline_epoch(ps)
			local expired = deadline ~= nil and os.time() > deadline
			if expired or (total > 0 and accepted == total) then
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

		notify_mod.ensure_highlights()
		local buf = ensure_view_buffer("problemset")
		local problems = get_problems(state.problemset)
		local lines = {}
		local line_map = {}
		local grey_lines = {}

		local accepted, total = accepted_count(state.problemset)
		table.insert(
			lines,
			string.format("Problemset #%d: %s (%d/%d)", state.problemset.id, state.problemset.name or "", accepted, total)
		)
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

	return {
		get_problems = get_problems,
		accepted_count = accepted_count,
		ensure_view_buffer = ensure_view_buffer,
		focus_buffer = focus_buffer,
		close_windows_with_buffer = close_windows_with_buffer,
		ensure_problem_desc_buffer = ensure_problem_desc_buffer,
		render_problem_description = render_problem_description,
		show_problem_description = show_problem_description,
		hide_problem_description = hide_problem_description,
		focus_selector_preferred_item = focus_selector_preferred_item,
		focus_problemset_preferred_item = focus_problemset_preferred_item,
		open_file_in_code_window = open_file_in_code_window,
		render_problemset_selector = render_problemset_selector,
		render_problemset_view = render_problemset_view,
		refresh_views = refresh_views,
	}
end

return M
