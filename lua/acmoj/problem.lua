local util = require("acmoj.util")

local M = {}

local function normalize_newlines(text)
	local value = tostring(text or "")
	return value:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function split_lines_keep_empty(text)
	local value = tostring(text or "")
	value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
	return vim.split(value, "\n", { plain = true, trimempty = false })
end

local function first_non_empty_string(tbl, keys)
	if type(tbl) ~= "table" then
		return ""
	end

	for _, key in ipairs(keys or {}) do
		local value = tbl[key]
		if type(value) == "string" then
			value = util.trim(normalize_newlines(value))
			if value ~= "" then
				return value
			end
		end
	end

	return ""
end

function M.extract_problem_section(problem, section)
	local section_keys = {
		description = { "description", "desc", "problem_description" },
		input = { "input", "input_description", "input_format", "input_desc" },
		output = { "output", "output_description", "output_format", "output_desc" },
		data_range = { "data_range" },
	}
	return first_non_empty_string(problem, section_keys[section] or {})
end

function M.extract_samples(problem)
	if type(problem) ~= "table" then
		return {}
	end

	local out = {}
	local examples = problem.examples
	if type(examples) ~= "table" then
		examples = problem.samples
	end
	if type(examples) ~= "table" then
		return out
	end

	for _, item in ipairs(examples) do
		if type(item) == "table" and type(item.input) == "string" and type(item.output) == "string" then
			table.insert(out, {
				input = item.input,
				expected = item.output,
			})
		end
	end

	return out
end

function M.render_problem_statement_lines(problem, problem_detail)
	local detail = type(problem_detail) == "table" and problem_detail or {}
	local title = tostring(detail.title or problem.title or "")
	local samples = M.extract_samples(detail)
	if #samples == 0 then
		samples = M.extract_samples(problem)
	end

	local lines = {
		string.format("ACMOJ %s %s", tostring(problem.id or ""), title),
		"",
	}

	local desc = M.extract_problem_section(detail, "description")
	if desc == "" then
		desc = M.extract_problem_section(problem, "description")
	end
	if desc == "" then
		table.insert(lines, "(empty)")
	else
		for _, line in ipairs(vim.split(desc, "\n", { plain = true, trimempty = false })) do
			table.insert(lines, line)
		end
	end

	table.insert(lines, "")
	table.insert(lines, "输入格式:")
	local input_desc = M.extract_problem_section(detail, "input")
	if input_desc == "" then
		input_desc = M.extract_problem_section(problem, "input")
	end
	if input_desc == "" then
		table.insert(lines, "(empty)")
	else
		for _, line in ipairs(vim.split(input_desc, "\n", { plain = true, trimempty = false })) do
			table.insert(lines, line)
		end
	end

	table.insert(lines, "")
	table.insert(lines, "输出格式:")
	local output_desc = M.extract_problem_section(detail, "output")
	if output_desc == "" then
		output_desc = M.extract_problem_section(problem, "output")
	end
	if output_desc == "" then
		table.insert(lines, "(empty)")
	else
		for _, line in ipairs(vim.split(output_desc, "\n", { plain = true, trimempty = false })) do
			table.insert(lines, line)
		end
	end

	table.insert(lines, "")
	table.insert(lines, "数据范围:")
	local range_desc = M.extract_problem_section(detail, "data_range")
	if range_desc == "" then
		range_desc = M.extract_problem_section(problem, "data_range")
	end
	if range_desc == "" then
		table.insert(lines, "(empty)")
	else
		for _, line in ipairs(vim.split(range_desc, "\n", { plain = true, trimempty = false })) do
			table.insert(lines, line)
		end
	end

	table.insert(lines, "")
	table.insert(lines, "样例:")
	if #samples == 0 then
		table.insert(lines, "(none)")
	else
		for idx, sample in ipairs(samples) do
			table.insert(lines, string.format("[样例 %d]", idx))
			table.insert(lines, "输入:")
			for _, line in ipairs(split_lines_keep_empty(sample.input)) do
				table.insert(lines, line)
			end
			table.insert(lines, "输出:")
			for _, line in ipairs(split_lines_keep_empty(sample.expected)) do
				table.insert(lines, line)
			end
			if idx < #samples then
				table.insert(lines, "")
			end
		end
	end

	return lines
end

function M.normalize_output(text)
	local lines = split_lines_keep_empty(text)
	for i, line in ipairs(lines) do
		lines[i] = util.trim(line)
	end

	while #lines > 0 and lines[1] == "" do
		table.remove(lines, 1)
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines, #lines)
	end

	return table.concat(lines, "\n")
end

function M.render_text_or_empty(text)
	local value = tostring(text or "")
	if value == "" then
		return "(empty)"
	end
	return value
end

function M.human_status(status, status_map)
	local info = status_map and status_map[status]
	local name_short = info and info.name_short
	if type(name_short) == "string" and util.trim(name_short) ~= "" then
		return name_short
	end
	return status
end

function M.is_accepted_status(status)
	if type(status) ~= "string" then
		return false
	end
	return status:lower() == "accepted"
end

function M.format_resource(sub)
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

return M
