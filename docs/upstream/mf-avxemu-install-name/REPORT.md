# `libavxemu.dylib`'s install name is the literal string `$HOME/...`

**For:** mavericksforever.com / Wowfunhappy — `avxemu/build.sh`.
**Severity:** cosmetic today, blocking for the linkage proposal. One character.

## Symptom

```
$ otool -D ~/.local/share/claude-mavericks/libavxemu.dylib
/Users/schmonz/.local/share/claude-mavericks/libavxemu.dylib:
$HOME/.local/share/claude-mavericks/libavxemu.dylib
```

`LC_ID_DYLIB` holds `$HOME/...` verbatim — dyld does no variable expansion, so
that path can never resolve. Linking anything against the dylib produces a
binary that dies at load:

```
dyld: Library not loaded: $HOME/.local/share/claude-mavericks/libavxemu.dylib
  Reason: image not found
```

## Cause

`avxemu/build.sh`, in the step-8 dylib link:

```sh
"$CC" -dynamiclib -O2 -msse4.2 -mno-avx -mno-fma \
    -install_name "\$HOME/.local/share/claude-mavericks/libavxemu.dylib" \
    $PURE $ASM -o "$OUT/libavxemu.dylib"
```

The `\$` escapes the expansion, so the literal four characters `$HOME` are baked
into the load command.

## Why it doesn't bite today

`DYLD_INSERT_LIBRARIES` takes an explicit absolute path and never consults
`LC_ID_DYLIB`, so the current wrapper is unaffected. It surfaces the moment
anyone links against the dylib rather than inserting it — which is exactly what
the linkage proposal does (`../mf-installer-link-avxemu/`), though that one
writes its own `@loader_path/../A.dylib` into the client and so dodges it too.
It also means the dylib can't be used normally by anything else.

## Fix

Either expand it at build time:

```diff
-    -install_name "\$HOME/.local/share/claude-mavericks/libavxemu.dylib" \
+    -install_name "$HOME/.local/share/claude-mavericks/libavxemu.dylib" \
```

which bakes in *your* home directory — fine only if every user's path matches.
Better, make it relocatable and let the client say where it looked:

```diff
-    -install_name "\$HOME/.local/share/claude-mavericks/libavxemu.dylib" \
+    -install_name "@rpath/libavxemu.dylib" \
```

`@rpath` costs nothing for the insert path (still ignored) and makes the linked
path work wherever the client's `LC_RPATH` or `@loader_path` points.

Found on the artifact `install.sh` downloaded 2026-08-28 (82216 bytes), while
trying to link a probe against it.
