# MF launcher — pass the injected flags in equals form (`--flag=value`)

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper emitted by
`claude/install.sh` (not a repo file, hence this note rather than a PR).
**Impact:** every `claude` invocation that takes a positional argument is broken.
One-line fix. Verified on Claude Code 2.1.232, 10.9.5.

## Symptom

```
$ claude mcp list
Error: Invalid MCP configuration:
MCP config file not found: /Users/schmonz/some/project/mcp

$ claude install 2.1.197
MCP config file not found: /Users/schmonz/some/project/install
```

The path in the error is the user's first positional argument, resolved against
`$PWD`. Bare `claude`, `claude -c`, `claude --version` are all fine.

## Cause

The wrapper injects its flags in the space form:

```sh
set -- --mcp-config "$CU/mcp-config.json" "$@"
```

but `--mcp-config` is **variadic**. From `claude --help`:

```
  --mcp-config <configs...>    Load MCP servers from JSON files or strings
                               (space-separated)
```

So the parser keeps consuming tokens after the config path and swallows the
user's first positional. `--settings <file-or-json>` is single-arity and is not
affected, but there's no reason not to fix both the same way.

This is why it has gone unnoticed: the flag is injected ahead of `"$@"`, so it
only bites when the user passes a positional. Interactive `claude` never does.
We hit it constantly because we script the wrapper (pinning versions, querying
MCP state).

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
-exec "$REAL" "$@"
+ARGS=""
+[ -f "$MF/settings.json" ] && ARGS="--settings=$MF/settings.json"
+if [ -f "$CU/mcp-config.json" ] && [ -x "$CU/mcp_server.py" ]; then
+    ARGS="$ARGS --mcp-config=$CU/mcp-config.json"
+fi
+
+exec "$REAL" $ARGS "$@"
```

`$ARGS` is intentionally unquoted — it holds two whitespace-separated flags, and
neither `$MF` nor `$CU` contains spaces (both are under `$HOME/.local/share`).
If you'd rather not rely on that, the equivalent quoted form is:

```sh
set -- "--mcp-config=$CU/mcp-config.json" "$@"     # inside the existing if
set -- "--settings=$MF/settings.json" "$@"
```

which keeps your current structure and only adds the `=`.

## Verified

Claude Code 2.1.232, same binary, same wrapper, only the flag form changed:

| form | `claude mcp list` |
|---|---|
| `--mcp-config <file>` | `MCP config file not found: $PWD/mcp` |
| `--mcp-config=<file>` | `Checking MCP server health… ✔ Connected` |

Running here since 2026-08-13.
