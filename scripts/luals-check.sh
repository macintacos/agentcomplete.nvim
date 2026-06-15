#!/usr/bin/env bash
# Static type-check the Lua sources with lua-language-server (LuaCATS).
#
# Runs headlessly and fails if any diagnostic at/above the check level is found.
# Real type/API correctness lives here; selene handles lint hygiene separately.
set -euo pipefail

log_dir=".luals-log"
rm -rf "$log_dir"
mkdir -p "$log_dir"

# Resolve Neovim's runtime path so its bundled LuaCATS API annotations (vim.*)
# are on the library path. .luarc.json carries the literal "$VIMRUNTIME" token,
# substituted here into an effective config (keeps .luarc.json editor-friendly).
vimruntime="$(nvim --headless --clean --cmd 'lua io.write(vim.env.VIMRUNTIME or "")' --cmd 'quit' 2>/dev/null)"
config="$PWD/$log_dir/luarc.effective.json"
sed "s|\$VIMRUNTIME|${vimruntime}|g" .luarc.json >"$config"

set +e
lua-language-server --check . \
	--checklevel Warning \
	--configpath "$config" \
	--logpath "$log_dir"
status=$?
set -e

# lua_ls writes check.json only when it finds problems.
if [ -s "$log_dir/check.json" ]; then
	echo "lua-language-server found type/diagnostic issues:" >&2
	cat "$log_dir/check.json" >&2
	exit 1
fi

if [ "$status" -ne 0 ]; then
	echo "lua-language-server exited with status $status" >&2
	exit "$status"
fi

echo "lua-language-server: no type issues found."
