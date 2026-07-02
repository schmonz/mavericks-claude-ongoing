// Plain-Bun repro battery for the non-Latin1 hook-payload hang.
// Mimics SessionStart hook ingestion: child process emits JSON whose
// additionalContext contains one U+2014; parent reads stdout, JSON.parses,
// and does rope-heavy string assembly/scanning like context building.
// Each step prints BEFORE and after-with-ms; a hang names itself.
const WIDE = "—";
const line = "filler line about nothing much here at all\n";
const skill = line.repeat(70) + "one em" + WIDE + "dash line\n";

function step(name, fn) {
  process.stdout.write("STEP " + name + " ...");
  const t0 = Date.now();
  const r = fn();
  console.log(" ok " + (Date.now() - t0) + "ms" + (r !== undefined ? " (" + String(r).length + ")" : ""));
}

const esc = skill.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  .replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t");
const hookJson = '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "<EXTREMELY_IMPORTANT>\\nYou have superpowers.\\n\\n' + esc + '\\n</EXTREMELY_IMPORTANT>"\n  }\n}\n';

step("json-parse", () => JSON.parse(hookJson).hookSpecificOutput.additionalContext);

step("spawn-read-parse", () => {
  const p = Bun.spawnSync(["/bin/sh", "-c", "cat /tmp/bun_test/hook.json"]);
  const out = p.stdout.toString();
  return JSON.parse(out).hookSpecificOutput.additionalContext;
});

step("rope-append-2k", () => {
  let s = "";
  for (let i = 0; i < 2000; i++) s += line;
  s += WIDE;
  for (let i = 0; i < 2000; i++) s += line;
  return s.indexOf("zzz") + s.length;
});

const ctx = JSON.parse(hookJson).hookSpecificOutput.additionalContext;

step("split-join-x100", () => {
  let n = 0;
  for (let i = 0; i < 100; i++) n += ctx.split("\n").join("\n").length;
  return n;
});

step("regex-lines-x100", () => {
  let n = 0;
  for (let i = 0; i < 100; i++) n += (ctx.match(/^.*$/gm) || []).length;
  return n;
});

step("indexOf-scan-x1000", () => {
  let n = 0;
  for (let i = 0; i < 1000; i++) n += ctx.indexOf("superpowers", i % 50);
  return n;
});

step("concat-slices-x200", () => {
  let s = "";
  for (let i = 0; i < 200; i++) s += ctx.slice(i % 10, 2000 + (i % 10));
  return s.normalize().length;
});

step("template-assembly-x200", () => {
  let s = "";
  for (let i = 0; i < 200; i++) s = `<context name="hook">${s.length % 2 ? s.slice(0, 4000) : ""}${ctx}</context>`;
  return s.length;
});

step("repeat-pad", () => {
  return ("\n".repeat(3472) + ctx.padEnd(8000, " ")).length;
});

console.log("ALL STEPS DONE");
