std = "luajit"
globals = { "G_reader_settings" }
read_globals = { "bit" }
max_line_length = false
ignore = { "212" }  -- unused argument
files["spec/"] = { std = "+busted" }
