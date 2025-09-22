-- Rust Lifetimes: visualize rough Rust lifetimes using Tree-sitter + rust-analyzer (optional).
-- Closures are ignored for now to avoid rendering glitches.
-- Composite painter with proper columns, elbows, tees, and compact one-liners (►'a).
local M = {}

local ns = vim.api.nvim_create_namespace("rust-lifetimes")
local ts = vim.treesitter

-- timeouts (ms)
local HOVER_TIMEOUT, REFS_TIMEOUT = 1200, 1200

-- spacing knobs
local RIGHT_MARGIN_PAD = 6 -- spaces from window edge
local LANE_CELL = 5        -- visual columns per lane “cell”

-- optional lane colors; link to existing groups to avoid theme fights
local LANE_HL = {
	"DiagnosticHint",
	"DiagnosticInfo",
	"DiagnosticWarn",
	"DiagnosticOk", -- Neovim 0.10+, falls back below
}

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
-- NOTE: closures removed on purpose
local query = ts.query.parse(
	"rust",
	[[
 (let_declaration)            @owner
 (parameter)                  @owner
 (self_parameter)             @owner
 (for_expression)             @owner
]]
)

-- ───────────────────── utils ─────────────────────

local function pad_cell(s)
	local w = vim.fn.strdisplaywidth(s)
	if w < LANE_CELL then
		return s .. string.rep(" ", LANE_CELL - w)
	end
	return s
end

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
		-- Not used now (closures ignored), but keep for future.
		local out = {}
		local function walk(n)
			local nt = n:type()
			if nt == "identifier" then
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

	local pat = owner:field("pattern")[1]
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

local function hover_is_ref(buf, ident)
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
			if txt and #txt > 0 and (txt:find("&%s*mut") or txt:find("&%S")) then
				return true
			end
		end
	end
	return false
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
	return txt:find("&") ~= nil
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

-- ────────────── composite painter per function/closure ──────────────
local function paint_group(buf, lanes, token)
	if #lanes == 0 then
		return
	end

	local function lane_hl(idx)
		local name = LANE_HL[((idx - 1) % #LANE_HL) + 1]
		if name == "DiagnosticOk" and vim.fn.hlexists("DiagnosticOk") ~= 1 then
			return "DiagnosticHint"
		end
		return name
	end

	local margin = string.rep(" ", RIGHT_MARGIN_PAD)

	local minl, maxl = math.huge, -1
	for _, L in ipairs(lanes) do
		if L.s < minl then
			minl = L.s
		end
		if L.e > maxl then
			maxl = L.e
		end
	end

	local CELL_TAIL = pad_cell("└►")
	local CELL_BLNK = pad_cell(" ")

	local starts_on_line = {}
	for idx, L in ipairs(lanes) do
		local t = starts_on_line[L.s] or {}
		t[#t + 1] = idx
		starts_on_line[L.s] = t
	end

	for line = minl, maxl do
		if token and token ~= GEN[buf] then
			return
		end
		local chunks = { { margin, "Comment" } }

		for idx, L in ipairs(lanes) do
			local cell
			if line == L.s then
				cell = pad_cell((L.one and "►" or "┌") .. L.label)
			elseif not L.one and line == L.e and L.e > L.s then
				cell = CELL_TAIL
			elseif not L.one and line > L.s and line < L.e then
				local tee = false
				local starters = starts_on_line[line]
				if starters then
					for _, j in ipairs(starters) do
						if j > idx then
							tee = true
							break
						end
					end
				end
				cell = pad_cell(tee and "├" or "│")
			else
				cell = CELL_BLNK
			end
			chunks[#chunks + 1] = { cell, lane_hl(idx) }
		end

		vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
			virt_text = chunks,
			virt_text_pos = "right_align",
			hl_mode = "combine",
			priority = 100,
		})
	end
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

	local lanes, last_group_start = {}, -1
	local function flush_group()
		if token ~= GEN[buf] then
			return
		end
		paint_group(buf, lanes, token)
		lanes = {}
	end

	for id, owner in query:iter_captures(root, buf, 0, -1) do
		if token ~= GEN[buf] then
			return
		end
		if query.captures[id] == "owner" then
			-- Extra safety: ignore closures even if they slip in
			if owner:type() == "closure_parameters" then
				goto continue
			end

			local gstart, gend = enclosing_fn_bounds(owner)
			if gstart ~= last_group_start then
				flush_group()
				last_group_start = gstart
			end

			local is_ref = syntax_is_ref(owner, buf)
			if not is_ref and has_ra then
				local ids_for_hover = bound_identifiers(owner)
				if #ids_for_hover > 0 then
					local hr = hover_is_ref(buf, ids_for_hover[1])
					if hr ~= nil then
						is_ref = hr
					end
				end
			end

			if is_ref then
				for _, ident in ipairs(bound_identifiers(owner)) do
					local sline = select(1, ident:range())
					local eline = has_ra and last_use_line(buf, ident) or sline
					if eline > gend then
						eline = gend
					end
					if eline < sline then
						eline = sline
					end

					-- Strict one-liner rule only
					local is_one = (eline == sline)
					if is_one then
						eline = sline
					end

					lanes[#lanes + 1] = {
						s = sline,
						e = eline,
						one = is_one,
						label = "'" .. string.char(97 + (#lanes % 26)),
					}
				end
			end
		end
		::continue::
	end
	flush_group()
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
