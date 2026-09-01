std = "lua54"
max_line_length = 120

-- Hammerspoon injects this one global into every Spoon.
read_globals = { "hs" }

files["spec/"] = { std = "+busted" }
files[".busted"] = { ignore = { "111", "112", "113", "121", "122", "131" } }
files[".luacov"] = { ignore = { "111", "112", "113", "121", "122", "131" } }
files[".luacheckrc"] = { ignore = { "111", "112", "113", "121", "122", "131" } }
