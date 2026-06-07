local M = {}

function M.create(config)
	local function shellescape(value)
		return vim.fn.shellescape(tostring(value or ""))
	end

	local function build_command(template, vars)
		local cmd = tostring(template or "")
		if cmd == "" then
			return nil, "command template is empty"
		end

		for key, value in pairs(vars or {}) do
			cmd = cmd:gsub(vim.pesc("{" .. key .. "}"), shellescape(value))
		end
		return cmd, nil
	end

	local function run_shell_command(cmd, opts)
		local obj = vim.system({ "sh", "-c", cmd }, opts or {})
		return obj:wait(config.timeout_ms)
	end

	local function run_shell_command_async(cmd, opts, on_done)
		vim.system({ "sh", "-c", cmd }, vim.tbl_extend("force", opts or {}, { text = true }), function(obj)
			vim.schedule(function()
				on_done(obj)
			end)
		end)
	end

	local function split_lines_keep_empty(text)
		local value = tostring(text or "")
		value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
		return vim.split(value, "\n", { plain = true, trimempty = false })
	end

	local function compile_cpp_code(code)
		local temp_dir = vim.fn.tempname()
		vim.fn.mkdir(temp_dir, "p")
		local source = vim.fs.joinpath(temp_dir, "main.cpp")
		local binary = vim.fs.joinpath(temp_dir, "main.out")

		local lines = split_lines_keep_empty(code)
		local ok, write_err = pcall(vim.fn.writefile, lines, source)
		if not ok then
			return nil, nil, "write temp source failed: " .. tostring(write_err)
		end

		local compile_cmd, cmd_err = build_command(config.compile_cmd, { src = source, bin = binary })
		if cmd_err then
			return nil, temp_dir, "invalid compile_cmd: " .. cmd_err
		end

		local result = run_shell_command(compile_cmd, { text = true })
		if result.code ~= 0 then
			local util = require("acmoj.util")
			local err = util.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
			if err == "" then
				err = string.format("compile command exited with code %d", result.code)
			end
			return nil, temp_dir, err
		end

		return binary, temp_dir, nil
	end

	local function compile_cpp_code_async(code, on_done)
		local temp_dir = vim.fn.tempname()
		vim.fn.mkdir(temp_dir, "p")
		local source = vim.fs.joinpath(temp_dir, "main.cpp")
		local binary = vim.fs.joinpath(temp_dir, "main.out")

		local lines = split_lines_keep_empty(code)
		local ok, write_err = pcall(vim.fn.writefile, lines, source)
		if not ok then
			on_done(nil, temp_dir, "write temp source failed: " .. tostring(write_err))
			return
		end

		local compile_cmd, cmd_err = build_command(config.compile_cmd, { src = source, bin = binary })
		if cmd_err then
			on_done(nil, temp_dir, "invalid compile_cmd: " .. cmd_err)
			return
		end

		run_shell_command_async(compile_cmd, { text = true }, function(result)
			if result.code ~= 0 then
				local util = require("acmoj.util")
				local err = util.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				if err == "" then
					err = string.format("compile command exited with code %d", result.code)
				end
				on_done(nil, temp_dir, err)
				return
			end

			on_done(binary, temp_dir, nil)
		end)
	end

	local function run_binary_with_input(binary, input)
		local run_cmd, cmd_err = build_command(config.run_cmd, { bin = binary })
		if cmd_err then
			return "", "invalid run_cmd: " .. cmd_err
		end

		local result = run_shell_command(run_cmd, {
			stdin = tostring(input or ""),
			text = true,
		})
		if result.code ~= 0 then
			local util = require("acmoj.util")
			local err = util.trim(result.stderr or "")
			if err == "" then
				err = string.format("run command exited with code %d", result.code)
			end
			return result.stdout or "", err
		end
		return result.stdout or "", nil
	end

	local function run_binary_with_input_async(binary, input, on_done, timeout_ms)
		local run_cmd, cmd_err = build_command(config.run_cmd, { bin = binary })
		if cmd_err then
			on_done("", "invalid run_cmd: " .. cmd_err)
			return
		end

		local opts = {
			stdin = tostring(input or ""),
			text = true,
		}
		if type(timeout_ms) == "number" and timeout_ms > 0 then
			opts.timeout = timeout_ms
		end

		run_shell_command_async(run_cmd, opts, function(result)
			if type(timeout_ms) == "number" and timeout_ms > 0 and (result.signal == 15 or result.signal == 9) then
				on_done(result.stdout or "", string.format("超时 (>%dms)", timeout_ms))
				return
			end
			if result.code ~= 0 then
				local util = require("acmoj.util")
				local err = util.trim(result.stderr or "")
				if err == "" then
					err = string.format("run command exited with code %d", result.code)
				end
				on_done(result.stdout or "", err)
				return
			end
			on_done(result.stdout or "", nil)
		end)
	end

	local function open_interactive_command(cmd, cwd)
		local snacks = rawget(_G, "Snacks")
		if snacks and snacks.terminal and type(snacks.terminal.open) == "function" then
			snacks.terminal.open(cmd, {
				cwd = cwd,
				interactive = true,
				auto_close = false,
			})
			return
		end

		vim.cmd("botright 15split")
		vim.fn.termopen({ "sh", "-c", cmd }, { cwd = cwd })
		vim.cmd("startinsert")
	end

	return {
		build_command = build_command,
		run_shell_command = run_shell_command,
		run_shell_command_async = run_shell_command_async,
		split_lines_keep_empty = split_lines_keep_empty,
		compile_cpp_code = compile_cpp_code,
		compile_cpp_code_async = compile_cpp_code_async,
		run_binary_with_input = run_binary_with_input,
		run_binary_with_input_async = run_binary_with_input_async,
		open_interactive_command = open_interactive_command,
	}
end

return M
