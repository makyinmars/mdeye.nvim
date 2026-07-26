std = "luajit"
cache = true
codes = true

read_globals = {
  "vim",
}

-- Test and spike scripts run under `nvim -l`, where `arg` holds script args.
files["tests"] = {
  read_globals = { "arg" },
}

-- Line-length is stylua's job.
max_line_length = false
max_code_line_length = false
max_string_line_length = false
max_comment_line_length = false
