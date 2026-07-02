#!/usr/bin/env python3
"""Recurrence analysis of /tmp/faultsnap.out (dense AVXEMU_FAULTSNAP).

Decides the work-bound vs condition-bound fork (docs/IDEAS.md top):
- work-bound: each scanned source address is visited a bounded number of times
  (a large finite compile/link sweep) -> per-op lowering shortens the spin.
- condition-bound: the SAME addresses recur across far-apart samples for the
  whole run (the sweep re-runs) -> no per-op speedup can end it.

Reads snaps of the form:
  --- snap <seq> t <mach_abs> rip 0x...
  r0=0x... "printable run" ...
  ...
Analyzes r0 (the scanned SOURCE pointer) exactly and bucketed to 64KB regions.
"""
import re, sys, collections

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/faultsnap.out"
snap_re = re.compile(r'^--- snap (\d+) t (\d+) rip (0x[0-9a-f]+)')
reg_re  = re.compile(r'^r(\d+)=(0x[0-9a-f]+)(.*)')

snaps = []  # (idx, seq, t, rip, {reg: (val, strings)})
cur = None
with open(path) as f:
    for line in f:
        m = snap_re.match(line)
        if m:
            cur = {"seq": int(m.group(1)), "t": int(m.group(2)),
                   "rip": m.group(3), "regs": {}}
            snaps.append(cur)
            continue
        if cur is None:
            continue
        m = reg_re.match(line)
        if m:
            val = int(m.group(2), 16)
            strs = re.findall(r'"([^"]*)"', m.group(3))
            cur["regs"][int(m.group(1))] = (val, strs)

n = len(snaps)
if n == 0:
    sys.exit("no snaps parsed")
t0, t1 = snaps[0]["t"], snaps[-1]["t"]
print(f"snaps={n} seq {snaps[0]['seq']}..{snaps[-1]['seq']} "
      f"mach-time span={t1 - t0} ({(t1 - t0) / 1e9:.1f}s if 1t=1ns)")

# fault-rate sanity: seq delta / snap count
print(f"faults represented ~= {snaps[-1]['seq'] - snaps[0]['seq']}")

rips = collections.Counter(s["rip"] for s in snaps)
print("\nfaulting-RIP mix (top 8):")
for rip, c in rips.most_common(8):
    print(f"  {rip}  {c}  ({100 * c / n:.0f}%)")

def analyze(name, key):
    """key(snap) -> hashable or None; reports count + sample-index span stats."""
    occ = collections.defaultdict(list)  # key -> [sample indices]
    for i, s in enumerate(snaps):
        k = key(s)
        if k is not None:
            occ[k].append(i)
    if not occ:
        print(f"\n[{name}] nothing to analyze")
        return
    total = sum(len(v) for v in occ.values())
    counts = sorted((len(v) for v in occ.values()), reverse=True)
    spans = [(v[-1] - v[0]) for v in occ.values() if len(v) > 1]
    print(f"\n[{name}] {len(occ)} distinct / {total} occurrences "
          f"(distinct ratio {len(occ) / total:.2f})")
    print(f"  count dist: max={counts[0]} top5={counts[:5]} "
          f"once={sum(1 for c in counts if c == 1)}")
    if spans:
        spans.sort(reverse=True)
        print(f"  recurrence spans (sample-idx, run={n}): "
              f"max={spans[0]} top5={spans[:5]} "
              f"frac-of-run max={spans[0] / n:.2f}")
    # the verdict signal: how many keys recur in BOTH the first and last third?
    both = sum(1 for v in occ.values() if v[0] < n / 3 and v[-1] > 2 * n / 3)
    print(f"  keys seen in first AND last third of run: {both}/{len(occ)}")
    # top recurring with details
    top = sorted(occ.items(), key=lambda kv: -len(kv[1]))[:6]
    for k, v in top:
        print(f"    {k}  x{len(v)}  idx {v[0]}..{v[-1]}")

def r0_exact(s):
    r = s["regs"].get(0)
    if r and 0x100000000 <= r[0] < 0x800000000000:
        return hex(r[0])
    return None

def r0_bucket(s):
    r = s["regs"].get(0)
    if r and 0x100000000 <= r[0] < 0x800000000000:
        return hex(r[0] & ~0xFFFF)
    return None

def r0_string(s):
    r = s["regs"].get(0)
    if r and r[1]:
        return r[1][0][:48]
    return None

analyze("r0 exact address", r0_exact)
analyze("r0 64KB region", r0_bucket)
analyze("r0 string content (first run)", r0_string)

# timeline of 64KB regions: sweep structure at a glance (first-seen order)
order = {}
for s in snaps:
    k = r0_bucket(s)
    if k is not None and k not in order:
        order[k] = len(order)
line = []
for s in snaps:
    k = r0_bucket(s)
    line.append("." if k is None else
                (chr(ord('a') + order[k] % 26) if order[k] < 260 else "+"))
print("\nregion timeline (a=1st-seen region, b=2nd, ... mod 26; .=non-ptr):")
for i in range(0, len(line), 100):
    print("  " + "".join(line[i:i + 100]))
