local util = require("acmoj.util")
local api_module = require("acmoj.api")
local cache_module = require("acmoj.cache")
local files_module = require("acmoj.files")
local commands = require("acmoj.commands")
local notify_module = require("acmoj.notify")
local runner_module = require("acmoj.runner")
local problem_mod = require("acmoj.problem")
local ui_module = require("acmoj.ui")

local M = {}

local config = {
	base_url = "https://acm.sjtu.edu.cn/OnlineJudge/api/v1",
	web_base_url = nil,
	token_file = vim.fs.joinpath(vim.fn.stdpath("config"), "acmoj", "token.txt"),
	language = "cpp",
	poll_interval_ms = 1200,
	timeout_ms = 120000,
	notify_prefix = "[ACMOJ] ",
	map_problem_nav = true,
	map_problemsets_lhs = "<leader>ra",
	map_problem_list_lhs = "<leader>rl",
	map_problem_next_lhs = "<leader>rn",
	map_problem_prev_lhs = "<leader>rp",
	map_quick = true,
	map_quick_test_lhs = "<leader>rt",
	map_quick_run_lhs = "<leader>rr",
	map_quick_submit_lhs = "<leader>rs",
	solution_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "acmoj.nvim"),
	solution_ext = "cpp",
	template_file = vim.fs.joinpath(vim.fn.stdpath("config"), "acmoj", "template.cpp"),
	cache_file = vim.fs.joinpath(vim.fn.stdpath("state"), "acmoj", "cache.json"),
	accepted_cache_page_limit = 50,
	compile_cmd = "g++ -std=c++17 -O2 -pipe {src} -o {bin}",
	run_cmd = "{bin}",
	show_problem_description = true,
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
	problem_desc_buf = nil,
	problem_desc_cache = {},
	problem_desc_visible = true,
	samples_cache = {},
	cache = {
		accepted_problems = {},
		token_to_username = {},
		cache_username = nil,
		accepted_cache_refreshed_at = nil,
	},
}

local commands_created = false
local highlights_created = false
local active_poll = {}

local api = api_module.create(config, util)
local cache = cache_module.create(config, state, util, api)
local files = files_module.create(config, state, util)
local notify_mod = notify_module.create(config)
local runner = runner_module.create(config)

local ui = ui_module.create(config, state, cache, api, files, notify_mod, {
	problemset = function(id)
		M.problemset(id)
	end,
	problemsets = function()
		M.problemsets()
	end,
	problem_next = function()
		M.problem_next()
	end,
	problem_prev = function()
		M.problem_prev()
	end,
	problem_jump = function(idx)
		M.problem_jump(idx)
	end,
})

local function notify(msg, level, opts)
	return notify_mod.notify(msg, level, opts)
end

local function set_normal_keymap(lhs, rhs, desc)
	if lhs == false or lhs == nil then
		return
	end
	if type(lhs) ~= "string" then
		return
	end
	if util.trim(lhs) == "" then
		return
	end
	vim.keymap.set("n", lhs, rhs, { desc = desc })
end

local function ensure_highlights()
	if highlights_created then
		return
	end
	notify_mod.ensure_highlights()
	highlights_created = true
end

local function open_problem_by_index(index, silent)
	local problems = ui.get_problems(state.problemset)
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

	ui.open_file_in_code_window(path)
	ui.render_problemset_view()
	ui.show_problem_description(problem)
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
		local problems = ui.get_problems(body)
		for i, p in ipairs(problems) do
			if not cache.is_problem_accepted(p.id) then
				state.current_index = i
				break
			end
		end

		ui.render_problemset_view()
		local reuse_current = state.selector_buf
			and vim.api.nvim_buf_is_valid(state.selector_buf)
			and vim.api.nvim_win_get_buf(0) == state.selector_buf
		ui.focus_buffer({ buf = state.problemset_buf, reuse_current = reuse_current })
		ui.close_windows_with_buffer(state.selector_buf)
		ui.focus_problemset_preferred_item()
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
		ui.render_problemset_selector()
		local reuse_current = state.problemset_buf
			and vim.api.nvim_buf_is_valid(state.problemset_buf)
			and vim.api.nvim_win_get_buf(0) == state.problemset_buf
		ui.focus_buffer({ buf = state.selector_buf, reuse_current = reuse_current })
		ui.close_windows_with_buffer(state.problemset_buf)
		ui.focus_selector_preferred_item()

		cache.refresh_accepted_cache_if_stale(token, 7 * 24 * 60 * 60, function(cache_err, refreshed)
			if cache_err then
				notify("refresh accepted cache failed: " .. cache_err, vim.log.levels.WARN)
				return
			end
			if refreshed then
				ui.refresh_views()
			end
		end)
	end)
end

local function poll_submission(submission_id, token, status_map, on_finish)
	local start_at = vim.uv.now()

	local function finish()
		active_poll[submission_id] = false
		if type(on_finish) == "function" then
			on_finish()
		end
	end

	local function poll_once()
		if active_poll[submission_id] == false then
			return
		end

		api.get(token, "/submission/" .. submission_id, function(sub, err)
			if err then
				notify_mod.notify_sticky("submit", "query submission failed: " .. err, vim.log.levels.ERROR)
				finish()
				return
			end

			if type(sub) ~= "table" or type(sub.status) ~= "string" then
				notify_mod.notify_sticky("submit", "invalid submission response", vim.log.levels.ERROR)
				finish()
				return
			end

			local finished = not sub.should_auto_reload
			if finished then
				local problem_id = sub.problem and sub.problem.id
				local accepted = problem_mod.is_accepted_status(sub.status)
				if accepted and type(problem_id) == "number" then
					cache.mark_problem_accepted(problem_id)
					ui.refresh_views()
				end

				local status_text = problem_mod.human_status(sub.status, status_map)
				local msg = string.format("#%d %s%s", submission_id, status_text, problem_mod.format_resource(sub))
				local level = accepted and vim.log.levels.INFO or vim.log.levels.WARN
				local status_hl = accepted and "AcmojStatusAC" or "AcmojStatusBad"
				notify_mod.notify_sticky(
					"submit",
					msg,
					level,
					notify_mod.inline_highlight_opts(status_text, status_hl)
				)
				finish()
				return
			end

			if vim.uv.now() - start_at >= config.timeout_ms then
				notify_mod.notify_sticky(
					"submit",
					string.format("#%d still running, stop polling (timeout)", submission_id),
					vim.log.levels.WARN
				)
				finish()
				return
			end

			vim.defer_fn(poll_once, config.poll_interval_ms)
		end)
	end

	poll_once()
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

local function problem_web_page_url(problem_id)
	local base = config.web_base_url
	if type(base) ~= "string" or base == "" then
		base = config.base_url:match("^(.*)/api/v1/?$") or "https://acm.sjtu.edu.cn/OnlineJudge"
	end
	base = base:gsub("/$", "")
	return string.format("%s/problem?problem_id=%d", base, problem_id)
end

local function open_system_uri(uri)
	if vim.ui and type(vim.ui.open) == "function" then
		local ok = pcall(vim.ui.open, uri)
		if ok then
			return nil
		end
	end
	local cmd
	if vim.fn.has("win32") == 1 then
		cmd = { "cmd", "/c", "start", "", uri }
	elseif vim.fn.has("macunix") == 1 then
		cmd = { "open", uri }
	else
		cmd = { "xdg-open", uri }
	end
	local pid = vim.fn.jobstart(cmd, { detach = true })
	if pid == 0 or pid == -1 then
		return "failed to start system browser"
	end
	return nil
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

function M.clear_cache()
	cache.clear_cache_file()
	state.problem_desc_cache = {}
	ui.refresh_views()
	notify("cache cleared")
end

function M.template()
	local path, created, err = files.init_template_file()
	if err then
		notify(err, vim.log.levels.ERROR)
		return
	end

	ui.open_file_in_code_window(path)
	if created then
		notify("template initialized and opened: " .. path)
	else
		notify("opened template: " .. path)
	end
end

function M.open_problem_web()
	local problem_id, id_err = files.get_problem_id_from_first_line()
	if id_err then
		notify(id_err, vim.log.levels.ERROR)
		return
	end

	local url = problem_web_page_url(problem_id)
	local open_err = open_system_uri(url)
	if open_err then
		notify(open_err, vim.log.levels.ERROR)
		return
	end
	notify(string.format("opened problem %d in browser", problem_id))
end

function M.submit_current_buffer()
	notify_mod.clear_all_sticky_notifications()

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

	api.get(token, "/meta/info/judge-status", function(status_map, status_err)
		if status_err then
			notify("fetch status map failed: " .. status_err, vim.log.levels.WARN)
			status_map = nil
		end

		api.submit(problem_id, config.language, code, token, function(submission_id, submit_err)
			if submit_err then
				notify_mod.notify_sticky("submit", submit_err, vim.log.levels.ERROR)
				return
			end

			notify_mod.notify_sticky(
				"submit",
				string.format("submitted: #%d, waiting for judge...", submission_id),
				vim.log.levels.INFO
			)
			active_poll[submission_id] = true
			poll_submission(submission_id, token, status_map)
		end)
	end)
end

function M.test_samples(sample_index_arg)
	vim.cmd("silent! w")
	notify_mod.clear_all_sticky_notifications()

	local sample_index = nil
	if sample_index_arg and sample_index_arg ~= "" then
		sample_index = tonumber(sample_index_arg)
		if not sample_index or sample_index < 1 or sample_index ~= math.floor(sample_index) then
			notify("sample index must be a positive integer", vim.log.levels.ERROR)
			return
		end
	end

	if config.language ~= "cpp" then
		notify("sample testing currently supports only language=cpp", vim.log.levels.ERROR)
		return
	end

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

	notify_mod.notify_sticky(
		"test",
		string.format("loading samples for problem %d ...", problem_id),
		vim.log.levels.INFO,
		{ timeout = 2000 }
	)

	local function run_sample_tests_async(samples)
		if #samples == 0 then
			notify("no available samples for this problem", vim.log.levels.WARN)
			return
		end

		local test_targets = {}
		if sample_index then
			if sample_index > #samples then
				notify(
					string.format("sample index out of range: %d (total: %d)", sample_index, #samples),
					vim.log.levels.ERROR
				)
				return
			end
			table.insert(test_targets, { idx = sample_index, sample = samples[sample_index] })
		else
			for i, sample in ipairs(samples) do
				table.insert(test_targets, { idx = i, sample = sample })
			end
		end

		runner.compile_cpp_code_async(code, function(binary, temp_dir, compile_err)
			if compile_err then
				notify_mod.notify_sticky("test", "编译失败:\n" .. compile_err, vim.log.levels.ERROR)
				if temp_dir then
					pcall(vim.fn.delete, temp_dir, "rf")
				end
				return
			end

			local mismatch = 0
			local first_mismatch_detail = nil
			local current = 1

			local function run_next()
				if current > #test_targets then
					pcall(vim.fn.delete, temp_dir, "rf")
					local total = #test_targets
					if mismatch == 0 then
						notify_mod.notify_sticky(
							"test",
							string.format("sample tests passed (%d/%d)", total, total),
							vim.log.levels.INFO,
							{ timeout = 3500 }
						)
					else
						if first_mismatch_detail then
							local lines = {
								first_mismatch_detail,
								string.format(
									"sample tests finished: %d passed, %d failed",
									total - mismatch,
									mismatch
								),
							}
							if mismatch > 1 then
								table.insert(lines, string.format("(%d more failed not showing)", mismatch - 1))
							end
							notify_mod.notify_sticky("test", table.concat(lines, "\n"), vim.log.levels.WARN)
						else
							notify_mod.notify_sticky(
								"test",
								string.format("sample tests finished: %d passed, %d failed", total - mismatch, mismatch),
								vim.log.levels.WARN
							)
						end
					end
					return
				end

				local target = test_targets[current]
				local i = target.idx
				local sample = target.sample

				runner.run_binary_with_input_async(binary, sample.input, function(actual, run_err)
					if run_err then
						actual = (actual or "") .. "\n[runtime error] " .. run_err
					end

					local expected_norm = problem_mod.normalize_output(sample.expected)
					local actual_norm = problem_mod.normalize_output(actual)
					if expected_norm ~= actual_norm then
						mismatch = mismatch + 1
						if not first_mismatch_detail then
							first_mismatch_detail = table.concat({
								string.format("测试点 #%d 结果不一致", i),
								"输入:",
								"```",
								problem_mod.render_text_or_empty(sample.input),
								"```",
								"理论输出:",
								"```",
								problem_mod.render_text_or_empty(sample.expected),
								"```",
								"实际输出:",
								"```",
								problem_mod.render_text_or_empty(actual),
								"```",
							}, "\n")
						end
					end

					current = current + 1
					run_next()
				end)
			end

			run_next()
		end)
	end

	local cached_samples = state.samples_cache[problem_id]
	if cached_samples and #cached_samples > 0 then
		run_sample_tests_async(cached_samples)
		return
	end

	api.get(token, "/problem/" .. problem_id, function(problem, err)
		if err then
			notify("load problem failed: " .. err, vim.log.levels.ERROR)
			return
		end

		local samples = problem_mod.extract_samples(problem)
		if #samples > 0 then
			state.samples_cache[problem_id] = samples
		end
		run_sample_tests_async(samples)
	end)
end

function M.run_current()
	vim.cmd("silent! w")
	notify_mod.clear_all_sticky_notifications()

	local src = vim.fn.expand("%:p")
	if src == "" then
		notify("no current file to run", vim.log.levels.ERROR)
		return
	end

	local cwd = vim.fn.expand("%:p:h")
	local bin = vim.fn.expand("%:p:r")
	local compile_cmd, compile_err = runner.build_command(config.compile_cmd, { src = src, bin = bin })
	if compile_err then
		notify_mod.notify_sticky("run", "invalid compile_cmd: " .. compile_err, vim.log.levels.ERROR)
		return
	end
	local run_cmd, run_err = runner.build_command(config.run_cmd, { src = src, bin = bin })
	if run_err then
		notify_mod.notify_sticky("run", "invalid run_cmd: " .. run_err, vim.log.levels.ERROR)
		return
	end

	runner.run_shell_command_async(compile_cmd, { text = true }, function(result)
		if result.code ~= 0 then
			local err = util.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
			if err == "" then
				err = string.format("compile failed (exit %d)", result.code)
			end
			notify_mod.notify_sticky("run", err, vim.log.levels.ERROR)
			return
		end
		runner.open_interactive_command(run_cmd, cwd)
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

	local problems = ui.get_problems(state.problemset)
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
	ui.render_problemset_view()
	ui.focus_buffer(state.problemset_buf)
	ui.focus_problemset_preferred_item()
end

function M.toggle_problem_description()
	state.problem_desc_visible = not state.problem_desc_visible
	if not state.problem_desc_visible then
		ui.hide_problem_description()
		notify("problem description panel: off")
		return
	end

	notify("problem description panel: on")
	if not state.problemset or not state.current_index then
		return
	end
	local problems = ui.get_problems(state.problemset)
	ui.show_problem_description(problems[state.current_index])
end

function M.stop_poll(submission_id)
	active_poll[submission_id] = false
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	state.problem_desc_visible = config.show_problem_description ~= false
	if not state.problem_desc_visible then
		ui.hide_problem_description()
	end
	api = api_module.create(config, util)
	cache = cache_module.create(config, state, util, api)
	files = files_module.create(config, state, util)
	notify_mod = notify_module.create(config)
	runner = runner_module.create(config)

	ui = ui_module.create(config, state, cache, api, files, notify_mod, {
		problemset = function(id)
			M.problemset(id)
		end,
		problemsets = function()
			M.problemsets()
		end,
		problem_next = function()
			M.problem_next()
		end,
		problem_prev = function()
			M.problem_prev()
		end,
		problem_jump = function(idx)
			M.problem_jump(idx)
		end,
	})

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
			test_samples = M.test_samples,
			run_current = M.run_current,
			problemsets = M.problemsets,
			problemset = M.problemset,
			problem_next = M.problem_next,
			problem_prev = M.problem_prev,
			problem_jump = M.problem_jump,
			problem_list = M.problem_list,
			prompt_set_token = prompt_and_set_token,
			template = M.template,
			clear_cache = M.clear_cache,
			toggle_problem_description = M.toggle_problem_description,
			open_problem_web = M.open_problem_web,
		}, notify)
		commands_created = true
	end

	if config.map_problem_nav then
		set_normal_keymap(config.map_problemsets_lhs, M.problemsets, "ACMOJ problemset selector")
		set_normal_keymap(config.map_problem_next_lhs, M.problem_next, "ACMOJ next problem")
		set_normal_keymap(config.map_problem_prev_lhs, M.problem_prev, "ACMOJ previous problem")
		set_normal_keymap(config.map_problem_list_lhs, M.problem_list, "ACMOJ problem list")
	end

	if config.map_quick then
		set_normal_keymap(config.map_quick_test_lhs, M.test_samples, "ACMOJ test samples")
		set_normal_keymap(config.map_quick_run_lhs, M.run_current, "ACMOJ run current code")
		set_normal_keymap(config.map_quick_submit_lhs, M.submit_current_buffer, "ACMOJ submit current problem")
	end
end

return M
