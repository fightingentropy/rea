---
name: rea
description: Reverse engineer shipped software (Electron/JS bundles, native Mach-O/ELF/PE, Go/Rust/.NET/Flutter/WASM binaries, APKs, SQLite, pcaps, firmware, websites, running apps). Plain CLI recon first; escalates to the REA MCP server (Ghidra pseudocode, xrefs, call graphs, version diffs, runtime capture, Evidence bundles) only when the question needs it. Use to explain how a feature works, extract versions/deps, compare builds, decompile, or rebuild a feature. Skip for ordinary source-repository analysis.
---

# rea: shell first, REA when it pays

Two tiers. Tier 1 (shell) answers most questions in 2–4 tool calls. Tier 2 (REA MCP, `mcp__rea__*`, 207 tools) is slower per call but goes deeper. Pick the tier from the question before the first call, and drop into Tier 2 only for the specific gap Tier 1 can't close.

## Rules (both tiers)
- Work on a copy (`cp -c` on APFS is instant). Put each extraction in a new dir under `$TMPDIR/re/<name>`; reuse one if it exists.
- Route by `file -b T` and the magic bytes first. Cheapest inventory next. Only then decompile or read code.
- `rg` skips hidden/ignored files and bundlers hide code in `.webpack/`, `.vite/`: always search extracted trees with `rg -uu`.
- Never `cat` a big or minified file. Slice: `rg -o '.{0,200}NEEDLE.{0,200}' F | head`. Dump a disassembly once to a file, then grep that file.
- Batch independent probes into ONE shell call with `;` and `echo '--- name'` markers (quoted: zsh expands a bare `==x`). Cap every output with `head` or `-m`.
- Turns cost more than bytes. Stop when every item asked has evidence; do not re-verify what you already saw or repeat an identical REA call without a changed input.
- A missing tool is not a blocker: use the fallback in the same row, the other tier, or `brew install <x>` if the user allows it.
- If the user says only "my app" with no name or path, ask which app. Never pick an example target for them.

## Pick the tier
**Tier 1 (default)**: versions, toolchains, deps; exports/imports/linked libs; entitlements, plists, Info.plist, URL schemes; strings and where they're used; Electron IPC channels, preload, fuses; a specific needle in a JS bundle; SQLite schema/rows; a short native call trail you can read from `otool -tV`.

**Escalate to Tier 2** when one of these is true:
- The user asks to **decompile** or for **pseudocode**, or you need value flow or callers/xrefs/call graph for a native function, or two targeted otool slices haven't converged (stripped C++/Swift, large binaries, obfuscation). Don't hand-lift more than a few instructions from disassembly: compilers defer rotates and fold multiplies across loop iterations, and manual lifting gets those off by one.
- Deep Swift/ObjC structure (`analyze_swift_types`, `get_objc_classes`), dylib resolution, signature/Mach-O detail beyond nm/otool.
- Comparing behavior between two builds, not just version strings.
- The target must run: browser/Electron/native-UI scenarios, process capture, LLDB call observation, Frida, GDB.
- Android class/method references beyond grep over jadx output; Dart AOT/Flutter internals.
- A JS app where grep returns too much and you need the module graph plus a feature trace.
- The user wants Evidence IDs, an exported Evidence bundle, or a reconstruction ledger/coverage check.

**Hybrid (usual for deep native work)**: Tier 1 recon → candidate symbols/strings/addresses → Tier 2 on just those functions. Don't redo in REA what the shell already established.

## Tier 1: first moves (one call each, paste and run)
Native (Mach-O):
```sh
T=./bin; D=$TMPDIR/re/$(basename $T); mkdir -p $D; file $T; lipo -info $T; otool -L $T; echo '--- EXPORTS'; nm -gU $T | head -150; echo '--- IMPORTS'; nm -u $T | rg -v '^__Z|napi_' | tr '\n' ' '; echo; echo '--- STRINGS'; strings -a -n 6 $T | rg -v '^[_$.]' | head -400; otool -tV $T > $D/dis.txt; echo '--- FUNCS'; rg '^[_a-zA-Z].*:$' $D/dis.txt | rg -v '^_?_?Z?N?St3' | head -150
```
Then read one function: `awk '/^FUNC_LABEL:$/{p=1;next} p&&/^[_a-zA-Z].*:$/{exit} p' $D/dis.txt | rg 'bl|b\.|cmp|literal|mov\s+w2'`.

Electron:
```sh
A=./app.asar; X=$TMPDIR/re/asar; rm -rf $X; npx -y @electron/asar extract $A $X && jq '{name,version,main}' $X/package.json; find $X -path '*/node_modules' -prune -o -type f \( -name '*.js' -o -name '*.node' \) -print | head -60; ls ${A}.unpacked/node_modules 2>/dev/null; rg -uu -l --glob '!node_modules' 'exposeInMainWorld' $X
```
Then slice the needle: `rg -uu -o --glob '!node_modules' '.{0,250}NEEDLE.{0,250}' $X | head -20`.

Go: `go version -m T` alone usually answers it.

## Tier 1: router
- **Electron** (`*.app/Contents/Resources/app.asar`): extract as above (also `app.asar.unpacked/` for `.node` addons). Entry: `jq .main X/package.json`. Surface sweep:
  `rg -uu -n -o --glob '!node_modules' '.{0,120}(ipcMain\.(handle|handleOnce|on|once)|ipcRenderer\.(invoke|send|sendSync|on)|contextBridge\.exposeIn(Main|Isolated)World|webPreferences|preload:|nodeIntegration|contextIsolation|sandbox|\.node\b).{0,160}' X`
  Wrapped channels: `rg -uu -o '"[a-z]+:[a-z0-9:-]+"' X/<main> | sort -u`. Fuses: `npx -y @electron/fuses read --app A.app`.
- **Web bundle / minified JS**: find `sourceMappingURL`; if the map has `sourcesContent`, dump it (`jq -r '.sources[]'`). Webpack: grep module ids, slice around hits. Pretty-print: `npx -y prettier --parser babel F > F.pretty.js`, read by line ranges.
- **Hermes / bytenode**: Hermes magic `c6 1f bc 03`: `hermes-dec` / `hbc-decompiler`. `.jsc` (bytenode) can't be decompiled: strings + runtime hooks.
- **Mach-O**: `lipo -info` (thin first: `lipo -thin arm64 -o T1 T`). `otool -L`; `xcrun dyld_info -exports -imports`; `nm -gU` / `nm -u` (imports = capability map); `strings -a -n 6`; `otool -l | rg -A3 'LC_(RPATH|BUILD_VERSION)'`; `codesign -d --entitlements :- T`; `otool -ov` (ObjC); `xcrun swift-demangle --compact`.
- **Native code logic**: `otool -tV T > $D/dis.txt` (or `llvm-objdump -d --no-show-raw-insn -C`). Find: `rg -n '^_?.*Name.*:$' $D/dis.txt`. Call/string trail: `awk '/^FUNC:/{p=1} p&&/^[_a-zA-Z].*:$/&&!/FUNC/{exit} p' $D/dis.txt | rg 'bl|call|literal|cmp'`. Pseudocode or exact arithmetic → Tier 2 (Ghidra).
- **ELF / PE**: `readelf -hlSW`, `readelf -dW`, `nm -D --defined-only`, `objdump -d -M intel`. PE: `objdump -x`; resources via REA `inspect_pe_resources`.
- **Go**: `go version -m T` (toolchain, path, mod, deps, flags). No Go: `strings -a T | rg -m1 -A200 'Go buildinf'`. Symbols survive stripping: `go tool nm T | rg 'main\.'`.
- **Rust**: `cargo audit bin T` or REA `inspect_rust_binary`. Compiler: `strings -a T | rg -o '/rustc/[0-9a-f]{40}' | sort -u`. Crates: `strings -a T | rg -o '[a-z0-9_-]+-[0-9]+\.[0-9]+\.[0-9]+/src' | sort -u`.
- **.NET**: `ilspycmd -p -o X T.dll` then `rg` (P/Invoke: `rg DllImport X`), or REA `inspect_managed_artifact`. NativeAOT/IL2CPP are native.
- **Android APK**: `jadx -d X --show-bad-code a.apk` then `rg`. Manifest/resources: `apktool d --no-src -o X a.apk`. `lib/*/libflutter.so` = Flutter (REA `identify_flutter_build`, `inspect_dart_aot`); `libhermes.so` = React Native (Hermes row).
- **Flutter snapshot hash**: in `libapp.so`, magic `f5 f5 dc dc`; the 32 hex chars at +20 are the snapshot hash.
- **WASM**: `wasm-objdump -x`, `wasm2wat`, `wasm-decompile` (WABT), or REA `inspect_wasm_artifact`.
- **SQLite**: copy the db plus any `-wal`. `sqlite3 'file:C?mode=ro' '.schema'`, then `SELECT * FROM t LIMIT 20`.
- **plist / nib / car**: `plutil -p F`; `assetutil --info Assets.car`; compiled nibs: REA `decode_interface_builder`.
- **pcap / HAR**: `tshark -r C -q -z conv,tcp`; `tshark -r C -T fields -e dns.qry.name -e tls.handshake.extensions_server_name -e http.request.full_uri | sort -u`. HAR: `jq -r '.log.entries[].request | .method+" "+.url' F` or REA `inspect_web_network_capture`.
- **Firmware**: `binwalk -e F` or `unblob -e X F`, then route each extracted binary through this list.
- **Website**: `curl -sL URL` for HTML and script srcs, fetch the JS, slice it. Runtime → Tier 2 browser tools.
- **Running app**: `lldb -p PID`, `log stream --predicate 'process=="X"'`, `fs_usage`. Electron main `--inspect` only if fuses allow. Android: `adb logcat`. Structured capture → Tier 2.

## Tier 2: REA MCP
**Loading.** If your client defers MCP tools (Claude Code does), load exactly the ones you need in ONE search call, e.g. `ToolSearch` `select:mcp__rea__open_binary,mcp__rea__analyze_function,mcp__rea__xrefs,mcp__rea__close_binary`. If no REA tools exist in the session, use the `rea` CLI (`rea --help` lists commands; most are the tool name in kebab-case, `rea <cmd> --help` for options). It is stateless: every call takes the path and re-runs analysis, so prefer one rich call over many small ones. Native: `rea analyze T` (overview), `rea search T PATTERN` (strings and procedure names), `rea function T SYM --format json | jq '.normalized_result | {pseudocode, callers, callees, referenced_strings}'` (one call = pseudocode, assembly, callers/callees, references, strings), `rea decompile T SYM --format json | jq -r .normalized_result` (pseudocode only), `rea xrefs T SYM`, `rea trace T QUERY`. JS: `rea analyze-javascript-application PATH --source-path main.js --format json`. Don't run `rea doctor`/setup before every task; only when a call fails, read [connection and recovery](references/connection-and-recovery.md).

| Need | Tools (in order) |
|---|---|
| Native function, pseudocode | `open_binary` {path} (Ghidra; fat Mach-O: thin a copy with `lipo` first) → `search_procedures` / `search_strings` / `find_xrefs_to_name` → `analyze_function` or `procedure_pseudo_code` / `batch_decompile` → `procedure_callers`, `procedure_callees`, `xrefs`, `get_call_graph`, `trace_call_path`, `trace_native_values` → `close_binary` when done. `binary_overview` only if metadata context helps. |
| Mach-O depth | `inspect_macho` (`detail:"summary"` on big frameworks, then page facets), `inspect_signature`, `get_objc_classes`, `analyze_swift_types`, `demangle_swift`, `trace_dylib_resolution` |
| Observed native calls | `observe_native_calls` (launches under LLDB with explicit breakpoints and bounded `duration_ms`/`max_events`; the target RUNS). `capture_native_ui_scenario`, `trace_native_ui_action` |
| JS / Electron app | `analyze_javascript_application` with `source_paths` (e.g. `["package.json","main.js","preload.js"]`) when the question names files, and `detail:"summary"` when size is large or unknown → `inspect_analysis_view` on `parent_evidence_id` → `trace_application_feature` once you have a seed. `inspect_electron_fuses` before any `--inspect` attempt. |
| Web | `analyze_web_bundle`, `export_web_scripts`, `capture_browser_scenario` (declared actions), `list_browser_targets` / `observe_web_session` (user-owned page), `capture_web_screenshot` |
| Electron runtime | `list_electron_targets` (already open), `capture_electron_scenario` (agent drives it), `reconcile_javascript_runtime` |
| Process / dynamic | `capture_process_scenario`, `compare_process_captures`, `instrument_with_frida`, `start_gdb_session`, `start_rizin_debug_session` |
| Compare builds | `compare_application_versions` (JS), `compare_artifacts`, `compare_functions`, `compare_bundles`, `find_changed_behavior`, `compare_source_to_bundle` |
| Android | `inspect_android_package` → `search_android_classes` → `inspect_android_class` / `inspect_android_method` → `trace_android_references`; `decode_android_resources` |
| Other formats | `inspect_artifact` / `extract_artifact` (ZIP/APK/IPA/DMG/MSIX), `inspect_managed_artifact`, `inspect_go_binary`, `inspect_rust_binary`, `inspect_wasm_artifact`, `inspect_sqlite_database`, `inspect_pe_resources`, `inspect_evm_interface`, `inspect_recorded_crash` |
| Evidence | `get_evidence_bundle` (`detail:"summary"` + filters), `export_evidence_bundle`, `list_unknowns`, `build_reconstruction_obligation_ledger`, `evaluate_reconstruction_coverage`, `verify_reconstruction` |

REA working rules:
- Summary first, then page: big results come back with `parent_evidence_id`; read slices with `inspect_analysis_view` instead of re-running. On `resource_constraint` (`details.resource:"transport"`) or a client-truncated result, page the retained Evidence or `export_evidence_bundle` to a file; never parse a truncated preview as JSON.
- Availability: `binary_session` with `{}` shows the open target, provider and `result.tool_availability`. Don't call a tool it doesn't advertise.
- IDA: `open_binary` with the original binary and `provider_id:"ida"` (never the `.idb`/`.i64`); IDA has no `binary_overview`.
- Kuna (newer REA, when `REA_KUNA_COMMAND` is set): `open_binary` with `provider_id:"kuna"` answers pseudocode, assembly and `analyze_function` from a cached whole-program export. `raw_result.source` names the cached `.c`/`.asm` file and byte span: `rg` that file directly instead of decompiling function by function.
- Linux-host-only here (use Tier 1 on macOS): `inspect_packet_capture`, `inspect_pcap_capture`, `decode_signal_recording`, `recover_javascript_sources`, `inspect_firmware_regions`, `extract_firmware`.
- Runtime tools execute the declared target and actions only; don't broaden either.

Read a reference only when you are in Tier 2 for that area:
[native and artifacts](references/native-and-artifacts.md) · [JavaScript/Electron](references/javascript-applications.md) · [Android](references/android-applications.md) · [runtime observation](references/runtime-observation.md) · [evidence workflows](references/evidence-workflows.md) · [connection and recovery](references/connection-and-recovery.md)

## Speed patterns
- Strings and imports first. On a small binary, `nm -u` + `strings` + exports usually answer "what does it do" with no disassembly.
- Who uses a string: `rg -n 'literal pool for: "X' dis.txt`, then the enclosing label above. In Tier 2, `search_strings` → `xrefs`.
- A named `bl` target (`getpeereid`, `write`, `std::hash`) already tells you the protocol. Read call sequences, not every instruction.
- JS: go from the native/JS boundary inward: native call → caller class → IPC registration → renderer/preload.
- Comparing versions: diff inventories (`nm`, module list, `go version -m`) before diffing code; escalate to `compare_*` only for behavior.
- Broad investigations: turn the request into a checklist of questions first; split independent questions across parallel subagents when available; reuse existing extractions and Evidence.
- Rebuilding: write the minimal reimplementation, then test it against the original (same inputs, same outputs).

## Answer
- Mark each claim **seen** (cite file:offset, symbol/string, or REA Evidence ID), **inferred**, or **unknown**. Not found is unknown, not absent. Static reading is not observed execution; decompiled pseudocode is not original source.
- For checklists, mark each item answered, partial, or unresolved before finishing.
- Close any `open_binary` session with `close_binary`.

## Install (only on request)
`brew install jadx apktool radare2 binwalk wabt wireshark` · `npm i -g @electron/asar rea-agents` · `dotnet tool install -g ilspycmd` · `cargo install cargo-audit`. Ghidra/IDA/Hopper come in through REA's providers (`rea setup`, `rea doctor`).
