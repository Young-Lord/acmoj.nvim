local M = {}

function M.create(config)
	local function notify(msg, level, opts)
		return vim.notify(config.notify_prefix .. msg, level or vim.log.levels.INFO, opts)
	end

	local function dismiss_notification(notification_id)
		if notification_id == nil then
			return
		end

		local ok, notify_module = pcall(require, "notify")
		if not ok or type(notify_module) ~= "table" or type(notify_module.dismiss) ~= "function" then
			return
		end

		pcall(notify_module.dismiss, notification_id, { pending = true, silent = true })
	end

	local sticky_notifications = {
		test = {},
		run = {},
	}

	local function clear_sticky_notifications(scope)
		local notifications = sticky_notifications[scope]
		if type(notifications) ~= "table" then
			return
		end

		for _, notification_id in ipairs(notifications) do
			dismiss_notification(notification_id)
		end
		sticky_notifications[scope] = {}
	end

	local function notify_sticky(scope, msg, level, opts)
		local merged_opts = vim.tbl_extend("force", { timeout = false }, opts or {})
		local notification_id = notify(msg, level, merged_opts)
		if type(sticky_notifications[scope]) == "table" then
			table.insert(sticky_notifications[scope], notification_id)
		end
	end

	local function ensure_highlights()
		vim.api.nvim_set_hl(0, "AcmojDim", { link = "Comment", default = true })
		vim.api.nvim_set_hl(0, "AcmojHeader", { bold = true, default = true })
		vim.api.nvim_set_hl(0, "AcmojStatusAC", { link = "DiagnosticOk", default = true })
		vim.api.nvim_set_hl(0, "AcmojStatusBad", { link = "DiagnosticError", default = true })
	end

	local function notify_with_inline_highlight(msg, level, needle, hl_group)
		if type(needle) ~= "string" or needle == "" or type(hl_group) ~= "string" or hl_group == "" then
			return notify(msg, level)
		end

		ensure_highlights()
		return notify(msg, level, {
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
		})
	end

	return {
		notify = notify,
		dismiss_notification = dismiss_notification,
		clear_sticky_notifications = clear_sticky_notifications,
		notify_sticky = notify_sticky,
		ensure_highlights = ensure_highlights,
		notify_with_inline_highlight = notify_with_inline_highlight,
	}
end

return M
