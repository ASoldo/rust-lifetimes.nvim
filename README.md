<img width="916" height="994" alt="image" src="https://github.com/user-attachments/assets/82a3d1cd-ada3-4122-aaba-c43b9b69c1e2" />

# Rust Lifetimes NVIM Plugin

Visualize rough Rust lifetimes directly in Neovim using Tree-sitter and rust-analyzer. This plugin draws inline annotations in the right margin to help understand borrow scopes and overlaps.

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

When enabled, lifetimes appear in the right margin as **inline markers** with real labels (from `rust-analyzer` hover) or fallback labels `'a`, `'b`, `'c` when not available. Multiple lifetimes on the same line are separated by a space for readability.

---

## Legend

The plugin uses distinct symbols and highlights to represent different categories of lifetimes:

| Symbol         | Example        | Meaning                                 |
| -------------- | -------------- | --------------------------------------- |
| `󱔀 'a `       | borrow `'a`    | Immutable borrow (default, non-mutable) |
| `󰘼 'b `       | borrow `'b`    | Mutable borrow                          |
| `󰓏 'static 󰓏`  | `'static`      | Static lifetime reference               |
| ` 'c `       | borrow `'c`    | Closure parameter lifetime              |

* **Start markers** (`󱔀`, `󰘼`, ``, `󰓏`) appear on the line where the borrow starts.  
* **End markers** (``, `󰓏`) appear on the line of the last use.  
* **Single-line borrows** compact into one badge, e.g. `󱔀 'a `.  

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
