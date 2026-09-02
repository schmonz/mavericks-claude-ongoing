# MF launcher — pass the injected flags in equals form (`--flag=value`)

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper emitted by
`claude/install.sh` (not a repo file, hence this note rather than a PR).

Every `claude` invocation that takes a positional argument is broken.
`--mcp-config <configs...>` and `--allowedTools <tools...>` are variadic, so the
space form keeps consuming tokens and swallows the user's arguments.

## Symptoms

```
$ claude mcp list
Error: Invalid MCP configuration:
MCP config file not found: /path/to/cwd/mcp
MCP config file not found: /path/to/cwd/list

$ claude install 2.1.197
MCP config file not found: /path/to/cwd/install
```

`--allowedTools` fails silently — no error, the subcommand just vanishes:

```
$ claude install --help
Usage: claude [options] [command] [prompt]      ← top-level help, not `install`
```

Bare `claude`, `claude -c`, `claude --version` are fine: the flags are injected
ahead of `"$@"`, so it only bites when the user passes a positional.

## Fix

```diff
 CU="$MF/computer-use"
-if [ -f "$CU/mcp-config.json" ] && [ -x "$CU/mcp_server.py" ]; then
-    set -- --mcp-config "$CU/mcp-config.json" "$@"
-fi
-if [ -f "$MF/settings.json" ]; then
-    set -- --settings "$MF/settings.json" "$@"
-fi
-
-set -- --allowedTools Grep "$@"
-
-exec "$REAL" "$@"
+ARGS="--allowedTools=Grep"
+[ -f "$MF/settings.json" ] && ARGS="$ARGS --settings=$MF/settings.json"
+if [ -f "$CU/mcp-config.json" ] && [ -x "$CU/mcp_server.py" ]; then
+    ARGS="$ARGS --mcp-config=$CU/mcp-config.json"
+fi
+
+exec "$REAL" $ARGS "$@"
```

(`--settings` is single-arity and unaffected, but no reason not to match. The
comment above `--allowedTools` is elided. `$ARGS` unquoted is safe — neither
`$MF` nor `$CU` contains spaces; `set -- "--flag=value" "$@"` works too if you'd
rather keep the existing structure.)

## Verified

`MF_GEN=3` wrapper extracted verbatim from the current `install.sh`, against the
same wrapper with only the flag form changed. Claude Code 2.1.258, 10.9.5.

| command | upstream | with `=` |
|---|---|---|
| `claude mcp list` | `MCP config file not found: $PWD/mcp` | `Checking MCP server health… ✔` |
| `claude install --help` | top-level usage | `Usage: claude install [options] [target]` |

Running here in equals form since 2026-08-13.
