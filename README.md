# Rust Lifetimes NVIM Plugin

## Config

```sh
vim.keymap.set("n", "<leader>r",  { desc = "Rust" })
vim.keymap.set("n", "<leader>rl", ":RustLifetimesRefresh<CR>", { desc = "Refresh lifetimes" })
vim.keymap.set("n", "<leader>rt", ":RustLifetimesToggle<CR>",  { desc = "Toggle lifetimes" })
```

## AstroNvim

```sh
["<Leader>r"] = { desc = "⏳Rust Lifetimes" },
["<Leader>rr"] = { ":RustLifetimesRefresh<CR>", desc = "Refresh Rust lifetimes" },
["<Leader>rt"] = { ":RustLifetimesToggle<CR>", desc = "Toggle Rust lifetimes" },
```
