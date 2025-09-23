<img width="948" height="1038" alt="image" src="https://github.com/user-attachments/assets/26d617d0-5995-47c3-be42-3a448dc34b1a" />

# Rust Lifetimes NVIM Plugin

Visualize rough Rust lifetimes directly in Neovim using Tree-sitter and rust-analyzer. This plugin draws lane-style annotations in the right margin to help understand borrow scopes and overlaps.

---

## Installation

With **Lazy.nvim**:

```lua
return {
  {
    "ASoldo/rust-lifetimes.nvim",
    ft = { "rust" },
    config = function()
      local ok, mod = pcall(require, "rust_lifetimes")
      if ok and type(mod.setup) == "function" then
        mod.setup()
      else
        vim.notify("rust-lifetimes.nvim: require('rust_lifetimes') failed", vim.log.levels.ERROR)
        return
      end
      vim.schedule(function()
        local buf = vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "rust" then
          pcall(vim.cmd.RustLifetimesRefresh)
        end
      end)
    end,
  },
}
```

---

## Keymaps

### Vanilla Neovim

```lua
vim.keymap.set("n", "<leader>r",  { desc = "Rust" })
vim.keymap.set("n", "<leader>rl", ":RustLifetimesRefresh<CR>", { desc = "Refresh lifetimes" })
vim.keymap.set("n", "<leader>rt", ":RustLifetimesToggle<CR>",  { desc = "Toggle lifetimes" })
```

### AstroNvim

```lua
["<Leader>r"]  = { desc = "⏳Rust Lifetimes" },
["<Leader>rr"] = { ":RustLifetimesRefresh<CR>", desc = "Refresh Rust lifetimes" },
["<Leader>rt"] = { ":RustLifetimesToggle<CR>", desc = "Toggle Rust lifetimes" },
```

---

## Commands

* `:RustLifetimesRefresh` → Redraw lifetimes for the current buffer
* `:RustLifetimesToggle` → Enable/disable lifetime visualization

---

## Preview

When enabled, lifetimes appear in the right margin as vertical lanes with labels `'a`, `'b`, `'c`, etc. Each borrow scope is drawn with distinct highlighting, making it easier to reason about overlapping references.

---

## Notes

* Requires **Tree-sitter** with the Rust parser installed
* Works best when **rust-analyzer** is attached
* Designed for Neovim 0.9+

---

## Roadmap

* Smarter label naming from actual lifetime parameters
* Custom highlight groups per-lane
* Configurable symbols for lifetime tails

---

## License

MIT
