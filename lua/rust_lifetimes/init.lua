-- Rust Lifetimes: inline badges for defs/last-use with real lifetime names + reborrow + ref/ref mut patterns.
local M = {}

local ns = vim.api.nvim_create_namespace("rust-lifetimes")
local ts = vim.treesitter

-- timeouts (ms)
local HOVER_TIMEOUT, REFS_TIMEOUT = 1200, 1200

-- refresh control (debounce + generation guard)
local GEN, TIMERS = {}, {}
local DEBOUNCE_MS = 60

-- global enable/disable
local ENABLED = true
local function clear_buf(buf)
	if buf and vim.api.nvim_buf_is_loaded(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
end

-- ───────────────────── Query ─────────────────────
-- Add pattern forms so `&pat`, `ref`, and `ref mut` get badges too.
local query = ts.query.parse(
	"rust",
	[[
 (let_declaration)            @owner
 (parameter)                  @owner
 (self_parameter)             @owner
 (closure_parameters)         @owner
 (for_expression)             @owner
 (reference_pattern)          @owner
 (ref_pattern)                @owner
]]
)

-- ───────────────────── utils ─────────────────────

local function enclosing_fn_bounds(n)
	local cur = n
	while cur do
		local t = cur:type()
		if t == "function_item" or t == "closure_expression" then
			local srow, _, erow = cur:range()
			return srow, erow
		end
		cur = cur:parent()
	end
	return 0, vim.api.nvim_buf_line_count(0) - 1
end

local function bound_identifiers(owner)
	local typ = owner:type()
	if typ == "self_parameter" then
		return { owner }
	end

	if typ == "closure_parameters" then
		local out = {}
		local function walk(n)
			local nt = n:type()
			if nt == "identifier" then
				-- Avoid grabbing type idents
				local p = n:parent()
				while p and p ~= owner do
					local pt = p:type()
					if pt == "type_identifier" or pt == "reference_type" then
						return
					end
					p = p:parent()
				end
				table.insert(out, n)
				return
			end
			for i = 0, n:child_count() - 1 do
				walk(n:child(i))
			end
		end
		walk(owner)
		return out
	end

	local pat = owner:field("pattern") and owner:field("pattern")[1] or nil
	local out = {}

	local function walk_pattern(n)
		if not n then
			return
		end
		if n:type() == "identifier" then
			table.insert(out, n)
			return
		end
		for i = 0, n:child_count() - 1 do
			walk_pattern(n:child(i))
		end
	end

	if pat then
		walk_pattern(pat)
	else
		-- fallback: grab first identifier under owner
		local function first_ident(n)
			if n:type() == "identifier" then
				table.insert(out, n)
				return true
			end
			for i = 0, n:child_count() - 1 do
				if first_ident(n:child(i)) then
					return true
				end
			end
			return false
		end
		first_ident(owner)
	end
	return out
end

local function flatten_hover(contents)
	local lines = vim.lsp.util.convert_input_to_markdown_lines(contents) or {}
	if #lines == 0 and type(contents) == "string" then
		lines = { contents }
	end
	local out, in_fence = {}, false
	for _, ln in ipairs(lines) do
		if ln:match("^```") then
			in_fence = not in_fence
		else
			table.insert(out, ln)
		end
	end
	return (table.concat(out, " "):gsub("%s+", " "))
end

-- Parse lifetime name and mutability from hover text
local function parse_lifetime_from_hover(txt)
	if not txt or txt == "" then
		return nil, false, false
	end
	local is_static = txt:find("'static") ~= nil
	local mut = txt:find("&%s*mut") ~= nil
	local name = txt:match("&%s*'%s*([%w_]+)") or txt:match("'(%w+)_?")
	if is_static then
		return "'static", mut, true
	end
	if name then
		return "'" .. name, mut, false
	end
	return nil, mut, false
end

local function hover_info(buf, ident)
	local srow, scol = ident:range()
	local params = {
		textDocument = vim.lsp.util.make_text_document_params(buf),
		position = { line = srow, character = scol },
	}
	local res = vim.lsp.buf_request_sync(buf, "textDocument/hover", params, HOVER_TIMEOUT)
	if not res then
		return nil
	end
	for _, r in pairs(res) do
		if r.result and r.result.contents then
			local txt = flatten_hover(r.result.contents)
			if txt and #txt > 0 then
				return txt
			end
		end
	end
	return nil
end

local function syntax_is_ref(owner, buf)
	local function has_ref(n)
		local t = n:type()
		if t == "reference_expression" or t == "reference_type" then
			return true
		end
		for i = 0, n:child_count() - 1 do
			if has_ref(n:child(i)) then
				return true
			end
		end
		return false
	end
	if has_ref(owner) then
		return true
	end
	local txt = vim.treesitter.get_node_text(owner, buf) or ""
	return txt:find("&") ~= nil or txt:find("%f[%w]ref%f[%W]") ~= nil
end

-- Fallback mutability from syntax (when hover isn’t conclusive)
local function syntax_is_mut(owner, buf)
	local txt = (vim.treesitter.get_node_text(owner, buf) or ""):gsub("%s+", " ")
	return txt:find("&%s*mut") ~= nil or txt:find("%f[%w]ref%f[%W]%s*%f[%w]mut%f[%W]") ~= nil
end

local function last_use_line(buf, ident)
	local srow, scol = ident:range()
	local params = {
		textDocument = vim.lsp.util.make_text_document_params(buf),
		position = { line = srow, character = scol },
		context = { includeDeclaration = true },
	}
	local res = vim.lsp.buf_request_sync(buf, "textDocument/references", params, REFS_TIMEOUT)
	local maxl = srow
	for _, r in pairs(res or {}) do
		for _, ref in ipairs(r.result or {}) do
			local l = ref.range and ref.range.start and ref.range.start.line
			if l and l > maxl then
				maxl = l
			end
		end
	end
	return maxl
end

-- Detect **reborrow** (reference-to-a-reference) from hover OR syntax
local function is_reborrow(hover_txt, owner, buf)
	local t = (hover_txt or ""):gsub("%s+", " ")
	if t ~= "" then
		if t:find("&%s*&") or t:find("&%s*mut%s*&") or t:find("&%s*&%s*mut") or t:find("&&") then
			return true
		end
	end
	local s = (vim.treesitter.get_node_text(owner, buf) or ""):gsub("%s+", " ")
	if s:find("&&") or s:find("&%s*&") or s:find("&%s*mut%s*&") or s:find("&%s*&%s*mut") then
		return true
	end
	return false
end

-- category -> symbol & hl (includes reborrow)
local function classify(owner_typ, name, mut, is_static, reborrow)
	if is_static then
		-- same symbol both ends, to imply "never ends"
		return {
			start_sym = "󰓏",
			end_sym = "󰓏",
			hl = (vim.fn.hlexists("DiagnosticOk") == 1 and "DiagnosticOk" or "DiagnosticHint"),
		}
	end
	if reborrow then
		-- 󱍸 = reborrow/narrowed scope; info for immut, warn for mut
		return { start_sym = "󱍸", end_sym = "", hl = (mut and "DiagnosticWarn" or "DiagnosticInfo") }
	end
	if owner_typ == "closure_parameters" then
		if mut then
			return { start_sym = "󰚕", end_sym = "", hl = "DiagnosticWarn" } -- closure param (mut)
		else
			return { start_sym = "", end_sym = "", hl = "DiagnosticHint" } -- closure param (immut)
		end
	end
	if mut then
		return { start_sym = "󰘻", end_sym = "", hl = "DiagnosticWarn" }
	end
	return { start_sym = "", end_sym = "", hl = "DiagnosticHint" }
end

-- Accumulate badges per line; render later with a middle-dot separator.
local LINE_BADGES ---@type table<number, { [1]:string, [2]:string }[]>
local LINE_SEEN ---@type table<number, table<string, boolean>>

local function queue_badge(line, text, hl, label_key)
	LINE_BADGES = LINE_BADGES or {}
	LINE_SEEN = LINE_SEEN or {}
	LINE_BADGES[line] = LINE_BADGES[line] or {}
	LINE_SEEN[line] = LINE_SEEN[line] or {}
	if label_key and LINE_SEEN[line][label_key] then
		return
	end
	if label_key then
		LINE_SEEN[line][label_key] = true
	end
	table.insert(LINE_BADGES[line], { text, hl })
end

-- ───────────────────── refresh worker (token-guarded) ─────────────────────
_G.__rust_lifetimes_refresh = function(buf, token)
	if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].filetype ~= "rust" then
		return
	end
	if token ~= GEN[buf] then
		return
	end

	local ok, parser = pcall(ts.get_parser, buf, "rust")
	if not ok then
		return
	end

	local trees = parser:parse()
	if not trees or not trees[1] then
		return
	end
	local root = trees[1]:root()

	local has_ra = false
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
		if c.name == "rust_analyzer" then
			has_ra = true
			break
		end
	end

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	LINE_BADGES, LINE_SEEN = {}, {}

	local gen_idx = 0
	local function gen_label()
		local ch = string.char(97 + (gen_idx % 26))
		gen_idx = gen_idx + 1
		return "'" .. ch
	end

	for id, owner in query:iter_captures(root, buf, 0, -1) do
		if token ~= GEN[buf] then
			return
		end
		if query.captures[id] ~= "owner" then
			goto continue
		end

		-- Avoid double-badging closure params via parameter capture
		if owner:type() == "parameter" then
			local p = owner:parent()
			if p and p:type() == "closure_parameters" then
				goto continue
			end
		end

		local gstart, gend = enclosing_fn_bounds(owner)
		local looks_ref = syntax_is_ref(owner, buf)

		for _, ident in ipairs(bound_identifiers(owner)) do
			local sline = select(1, ident:range())

			local hover_txt = has_ra and hover_info(buf, ident) or nil
			local h_name, h_mut, is_static = parse_lifetime_from_hover(hover_txt or "")
			local syn_mut = syntax_is_mut(owner, buf)
			local reborrow = is_reborrow(hover_txt or "", owner, buf)
			local is_ref = looks_ref or (hover_txt and (hover_txt:find("&") or hover_txt:find("'")))
			if not is_ref then
				goto next_ident
			end

			local eline = has_ra and last_use_line(buf, ident) or sline
			if eline > gend then
				eline = gend
			end
			if eline < sline then
				eline = sline
			end

			local ident_text = vim.treesitter.get_node_text(ident, buf)
			local label = h_name or (ident_text and ("'" .. ident_text)) or gen_label()
			local cat = classify(owner:type(), label, (h_mut or syn_mut), is_static, reborrow)

			local start_text = cat.start_sym .. " " .. label
			local end_text = cat.end_sym .. " " .. label
			local key = label
				.. "|"
				.. (owner:type() or "")
				.. (reborrow and "|rb" or "")
				.. ((h_mut or syn_mut) and "|mut" or "")

			if sline == eline then
				queue_badge(sline, start_text .. " " .. cat.end_sym, cat.hl, key)
			else
				queue_badge(sline, start_text, cat.hl, key)
				queue_badge(eline, end_text, cat.hl, key .. "#end")
			end

			::next_ident::
		end
		::continue::
	end

	-- Render badges with a white middle dot between each on the same line
	for line, chunks in pairs(LINE_BADGES) do
		local spaced = {}
		for i, c in ipairs(chunks) do
			if i > 1 then
				table.insert(spaced, { "", "RustLifetimesSep" })
			end
			table.insert(spaced, c)
		end
		vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
			virt_text = spaced,
			virt_text_pos = "right_align",
			hl_mode = "combine",
			priority = 100,
		})
	end
end

-- ───────────────────── debounce scheduler ─────────────────────
local function schedule_refresh(buf)
	if not buf or not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	if not ENABLED then
		clear_buf(buf)
		return
	end

	if TIMERS[buf] then
		TIMERS[buf]:stop()
		TIMERS[buf]:close()
		TIMERS[buf] = nil
	end
	local timer = vim.uv.new_timer()
	TIMERS[buf] = timer
	timer:start(DEBOUNCE_MS, 0, function()
		if TIMERS[buf] then
			TIMERS[buf]:stop()
			TIMERS[buf]:close()
			TIMERS[buf] = nil
		end
		vim.schedule(function()
			GEN[buf] = (GEN[buf] or 0) + 1
			_G.__rust_lifetimes_refresh(buf, GEN[buf])
		end)
	end)
end

-- ───────────────────── setup ─────────────────────
function M.setup()
	-- white separator for middle dot
	if not pcall(vim.api.nvim_get_hl_by_name, "RustLifetimesSep", true) then
		vim.api.nvim_set_hl(0, "RustLifetimesSep", { fg = "#ffffff" })
	end

	vim.api.nvim_create_user_command("RustLifetimesRefresh", function()
		schedule_refresh(vim.api.nvim_get_current_buf())
	end, {})

	vim.api.nvim_create_user_command("RustLifetimesToggle", function()
		ENABLED = not ENABLED
		local buf = vim.api.nvim_get_current_buf()
		if not ENABLED then
			clear_buf(buf)
			vim.notify("[rust-lifetimes] disabled", vim.log.levels.INFO)
		else
			vim.notify("[rust-lifetimes] enabled", vim.log.levels.INFO)
			schedule_refresh(buf)
		end
	end, {})

	local grp = vim.api.nvim_create_augroup("RustLifetimes", { clear = true })

	vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
		group = grp,
		pattern = "*.rs",
		callback = function(args)
			schedule_refresh(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("WinResized", {
		group = grp,
		callback = function()
			schedule_refresh(vim.api.nvim_get_current_buf())
		end,
	})

	vim.api.nvim_create_autocmd("LspAttach", {
		group = grp,
		callback = function(args)
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			if client and client.name == "rust_analyzer" then
				schedule_refresh(args.buf)
			end
		end,
	})
end

return M
