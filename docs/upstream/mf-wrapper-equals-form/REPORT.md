# MF launcher — pass the injected flags in equals form (`--flag=value`)

**For:** mavericksforever.com / Wowfunhappy — the `claude` wrapper emitted by
`claude/install.sh` (not a repo file, hence this note rather than a PR).
**Impact:** every `claude` invocation that takes a positional argument is broken.
One-line-per-flag fix. Verified end to end on Claude Code 2.1.251 and 2.1.258,
10.9.5, running the **`MF_GEN=3`** wrapper exactly as `install.sh` emits it.

## Symptom

```
$ claude mcp list
Error: Invalid MCP configuration:
MCP config file not found: /Users/schmonz/some/project/mcp
MCP config file not found: /Users/schmonz/some/project/list

$ claude install 2.1.197
MCP config file not found: /Users/schmonz/some/project/install
```

The paths in the error are the user's positional arguments, resolved against
`$PWD`. Bare `claude`, `claude -c`, `claude --version` are all fine.

## Cause

The wrapper injects its flags in the space form:

```sh
set -- --mcp-config "$CU/mcp-config.json" "$@"
...
set -- --allowedTools Grep "$@"
```

but both of those flags are **variadic**. From `claude --help`:

```
  --mcp-config <configs...>    Load MCP servers from JSON files or strings
                               (space-separated)
  --allowedTools <tools...>    Comma or space-separated list of tool names to allow
```

So the parser keeps consuming tokens after the injected value and swallows the
user's positionals. `--settings <file-or-json>` is single-arity and is not
affected, but there's no reason not to fix all three the same way.

This is why it has gone unnoticed: the flags are injected ahead of `"$@"`, so it
only bites when the user passes a positional. Interactive `claude` never does.
We hit it constantly because we script the wrapper (pinning versions, querying
MCP state).

**`--allowedTools Grep` arrived in `MF_GEN=2`, is still there in `MF_GEN=3`, and
has the same bug.** It is worth flagging separately because it fails far less
legibly than `--mcp-config` does: no error at all, the swallowed subcommand
simply vanishes and you get top-level help.

```
$ claude install --help
Usage: claude [options] [command] [prompt]

Claude Code - starts an interactive session by default, use -p/--print for
non-interactive output
```

`--allowedTools` consumes `Grep` *and* `install`, leaving `--help` to print the
generic page. A user would conclude `claude install --help` is broken, with
nothing to suggest the wrapper is involved.

## Fix

Against the current (`MF_GEN=3`) wrapper — this block is unchanged from
`MF_GEN=2`, so the same diff applies to both. The comment above
`--allowedTools` is elided for brevity:

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

`$ARGS` is intentionally unquoted — it holds whitespace-separated flags, and
neither `$MF` nor `$CU` contains spaces (both are under `$HOME/.local/share`).
If you'd rather not rely on that, the equivalent quoted form is:

```sh
set -- "--mcp-config=$CU/mcp-config.json" "$@"     # inside the existing if
set -- "--settings=$MF/settings.json" "$@"
set -- "--allowedTools=Grep" "$@"
```

which keeps your current structure and only adds the `=`.

(We drop `--allowedTools` here entirely rather than fix it, because on this
machine the search shims it exists to avoid work correctly — see
`../../native-search-recheck.md`. That is a separate question from the flag
form; the `=` is worth adding either way.)

## Verified

Two wrappers, same machine, same binary (Claude Code 2.1.258): the `MF_GEN=3`
wrapper extracted verbatim from the current `install.sh`, against the same
wrapper with only the flag form changed.

| command | upstream `MF_GEN=3` | with `=` |
|---|---|---|
| `claude mcp list` | `MCP config file not found: $PWD/mcp`, `$PWD/list` | `Checking MCP server health… ✔` |
| `claude install --help` | top-level `claude` usage — subcommand silently eaten | `Usage: claude install [options] [target]` |

Also reproduced by invoking the binary directly with each flag form, on 2.1.251
and 2.1.258. Running here in equals form since 2026-08-13.
