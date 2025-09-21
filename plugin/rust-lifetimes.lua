-- plugin/rust-lifetimes.lua
-- Auto-enable on Rust buffers if user didn't call setup themselves.
vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
	pattern = "*.rs",
	callback = function()
		if package.loaded["rust_lifetimes"] then
			return
		end
		pcall(require, "rust_lifetimes") -- load module
		if require("rust_lifetimes").setup then
			require("rust_lifetimes").setup()
		end
	end,
})
