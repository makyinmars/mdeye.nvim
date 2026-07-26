std = "luajit"
cache = true
codes = true

-- `vim` is a mutable namespace: option/variable writes go through vim.o,
-- vim.bo, vim.wo, and vim.g.
globals = {
  "vim",
}

-- The dependency-free test harness (tests/run.lua) defines these globals;
-- scripts run under `nvim -l`, where `arg` holds script arguments.
files["tests"] = {
  globals = { "describe", "it", "eq", "ok", "arg" },
}

-- Line length is stylua's job.
max_line_length = false
max_code_line_length = false
max_string_line_length = false
max_comment_line_length = false
