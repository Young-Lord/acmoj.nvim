local M = {}

function M.create(config)
	local function notify(msg, level, opts)
		return vim.notify(config.notify_prefix .. msg, level or vim.log.levels.INFO, opts)
	end

	local function dismiss_notification_record(record)
		if record == nil then
			return
		end

		if type(record) == "table" and record.win and vim.api.nvim_win_is_valid(record.win) then
			pcall(vim.api.nvim_win_close, record.win, true)
			local buf = record.buf
			if buf and vim.api.nvim_buf_is_valid(buf) then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
			return
		end

		pcall(vim.notify, "", vim.log.levels.INFO, {
			replace = record,
			hide_from_history = true,
			timeout = 1,
		})
	end

	local sticky_notifications = {
		test = nil,
		run = nil,
		submit = nil,
	}

	local function clear_sticky_notifications(scope)
		dismiss_notification_record(sticky_notifications[scope])
		sticky_notifications[scope] = nil
	end

	local function clear_all_sticky_notifications()
		for scope, _ in pairs(sticky_notifications) do
			clear_sticky_notifications(scope)
		end
	end

	local function notify_sticky(scope, msg, level, opts)
		clear_sticky_notifications(scope)

		local merged_opts = vim.tbl_extend("force", { timeout = false }, opts or {})
		local record = notify(msg, level, merged_opts)

		sticky_notifications[scope] = record
	end

	local function ensure_highlights()
		vim.api.nvim_set_hl(0, "AcmojDim", { link = "Comment", default = true })
		vim.api.nvim_set_hl(0, "AcmojHeader", { bold = true, default = true })
		vim.api.nvim_set_hl(0, "AcmojStatusAC", { link = "DiagnosticOk", default = true })
		vim.api.nvim_set_hl(0, "AcmojStatusBad", { link = "DiagnosticError", default = true })
	end

	local function inline_highlight_opts(needle, hl_group)
		if type(needle) ~= "string" or needle == "" or type(hl_group) ~= "string" or hl_group == "" then
			return {}
		end

		ensure_highlights()
		return {
			on_open = function(win)
				local buf = vim.api.nvim_win_get_buf(win)
				local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
				local line = lines[1]
				if type(line) ~= "string" then
					return
				end
				local s, e = line:find(needle, 1, true)
				if not s then
					return
				end
				vim.api.nvim_buf_add_highlight(buf, -1, hl_group, 0, s - 1, e)
			end,
		}
	end

	local function notify_with_inline_highlight(msg, level, needle, hl_group)
		local opts = inline_highlight_opts(needle, hl_group)
		if next(opts) == nil then
			return notify(msg, level)
		end
		return notify(msg, level, opts)
	end

	return {
		notify = notify,
		dismiss_notification = dismiss_notification_record,
		clear_sticky_notifications = clear_sticky_notifications,
		clear_all_sticky_notifications = clear_all_sticky_notifications,
		notify_sticky = notify_sticky,
		ensure_highlights = ensure_highlights,
		inline_highlight_opts = inline_highlight_opts,
		notify_with_inline_highlight = notify_with_inline_highlight,
	}
end

return M
