# Phase-A forensic: identify WHAT string the spin keeps re-materializing.
# Run inside lldb (py2.7 on lldb-320) after attaching to the pegged pid:
#   lldb -p $PID -o 'script exec(open(".../lldb_phasea_forensic.py").read())' -o detach -o quit
# Output: /tmp/forensic.out
# Strategy: interrupt-sample until (a) any phase-A stop -> deep backtrace + thunk
# pc, (b) a stop with frame0 in the APP rope-resolver region -> real registers ->
# dump +-4KB around every pointer-looking register as ASCII and UTF-16LE.
# Then measure the loop rate via breakpoint hit-count at the thunk pc over 20s.
import lldb, time, os

OUT = '/tmp/forensic.out'
INTERP_OFF = 0x37cee8b          # bytecode-interpreter self-recursion frame (static)
ROPE_LO, ROPE_HI = 0x2560000, 0x2580000   # rope/UTF-16 resolver fn region (static)
MAX_TRIES = 120
RATE_SECS = 20.0

dbg = lldb.debugger
target = lldb.target
proc = lldb.process
dbg.HandleCommand('process handle SIGILL --pass true --stop false --notify false')
dbg.SetAsync(True)
ci = dbg.GetCommandInterpreter()
out = open(OUT, 'w')

def log(s):
    out.write(s + '\n'); out.flush()

def cmd(c):
    ro = lldb.SBCommandReturnObject()
    ci.HandleCommand(c, ro)
    return (ro.GetOutput() or '') + (ro.GetError() or '')

# load BASE via the __TEXT segment (docs' static offsets are pc - BASE;
# NOT the ASLR slide: __TEXT's preferred vmaddr is 0x100000000, so
# BASE = slide + 0x100000000 = GetLoadAddress of the __TEXT segment)
base = None
mod = target.GetModuleAtIndex(0)
for si in range(mod.GetNumSections()):
    sec = mod.GetSectionAtIndex(si)
    if sec.GetName() == '__TEXT':
        base = sec.GetLoadAddress(target)
        break
log('module=%s base=%s' % (mod.GetFileSpec().GetFilename(), hex(base) if base is not None else 'None'))
if base is None:
    base = 0x100000000

def wait_state(want, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if proc.GetState() == want:
            return True
        time.sleep(0.02)
    return False

def interrupt():
    if proc.GetState() == lldb.eStateStopped:
        return True
    proc.SendAsyncInterrupt()
    return wait_state(lldb.eStateStopped)

def cont():
    proc.Continue()
    wait_state(lldb.eStateRunning, 2.0)

def busy_thread(prev):
    n = proc.GetNumThreads()
    pcs = [proc.GetThreadAtIndex(k).GetFrameAtIndex(0).GetPC() for k in range(n)]
    b = 0
    for k in range(n):
        if k < len(prev) and prev[k] is not None and pcs[k] != prev[k]:
            b = k; break
    return b, pcs

def in_module(pc):
    a = target.ResolveLoadAddress(pc)
    return a.IsValid() and a.GetModule().IsValid() and \
        a.GetModule().GetFileSpec().GetFilename() == mod.GetFileSpec().GetFilename()

REGS = ['rax','rbx','rcx','rdx','rdi','rsi','rbp','rsp',
        'r8','r9','r10','r11','r12','r13','r14','r15']

def printable_ascii(buf):
    runs, run = [], ''
    for c in buf:
        o = ord(c) if isinstance(c, str) else c
        if 0x20 <= o < 0x7F: run += chr(o)
        else:
            if len(run) >= 5: runs.append(run)
            run = ''
    if len(run) >= 5: runs.append(run)
    return runs

def printable_u16(buf):
    # UTF-16LE printable runs (ASCII subset), py2-safe
    runs, run = [], ''
    i = 0
    while i + 1 < len(buf):
        lo = ord(buf[i]) if isinstance(buf[i], str) else buf[i]
        hi = ord(buf[i+1]) if isinstance(buf[i+1], str) else buf[i+1]
        if hi == 0 and (0x20 <= lo < 0x7F or lo in (0x9, 0xa)):
            run += chr(lo) if lo >= 0x20 else ('\\n' if lo == 0xa else '\\t')
        else:
            if len(run) >= 5: runs.append(run)
            run = ''
        i += 2
    if len(run) >= 5: runs.append(run)
    return runs

def dump_ptr(name, v, before=4096, after=4096):
    if not (0x100000000 <= v < 0x800000000000): return
    base = (v - before) & ~0xF
    err = lldb.SBError()
    mem = proc.ReadMemory(base, before + after, err)
    if not err.Success() or not mem:
        # retry small window at the pointer itself
        err2 = lldb.SBError()
        mem = proc.ReadMemory(v & ~0xF, 512, err2)
        if not (err2.Success() and mem): return
        base = v & ~0xF
    log('== %s = 0x%x (window 0x%x +%d bytes)' % (name, v, base, len(mem)))
    a = printable_ascii(mem)
    u = printable_u16(mem)
    if a: log('  ascii: ' + ' | '.join(x[:140] for x in a[:25]))
    if u: log('  utf16: ' + ' | '.join(x[:140] for x in u[:25]))

got_bt = False
got_app = False
thunk_pc = None
prev_pcs = []

for attempt in range(MAX_TRIES):
    if not interrupt():
        log('no-stop attempt %d' % attempt); continue
    b, pcs = busy_thread(prev_pcs); prev_pcs = pcs
    th = proc.GetThreadAtIndex(b)
    proc.SetSelectedThread(th)
    pc = th.GetFrameAtIndex(0).GetPC()
    fpcs = [th.GetFrameAtIndex(k).GetPC() for k in range(min(8, th.GetNumFrames()))]
    log('stop %d: pcs %s' % (attempt, ' '.join(hex(p) for p in fpcs)))
    phaseA = any(p == base + INTERP_OFF for p in fpcs[1:])
    if not phaseA:
        # accept also: frame0 in rope region counts as phase-A-ish
        phaseA = in_module(pc) and ROPE_LO <= pc - base < ROPE_HI
    if phaseA and not got_bt:
        log('--- PHASE-A STOP (attempt %d) thread=%d pc=0x%x' % (attempt, b, pc))
        log(cmd('bt 40'))
        got_bt = True
    if phaseA and not in_module(pc) and thunk_pc is None:
        thunk_pc = pc
        log('thunk pc candidate: 0x%x' % pc)
        log(cmd('disassemble --start-address 0x%x --count 8' % pc))
    if phaseA and in_module(pc) and ROPE_LO <= pc - base < ROPE_HI and not got_app:
        log('--- APP-FRAME STOP (attempt %d) pc=0x%x (static +0x%x)' % (attempt, pc, pc - base))
        log(cmd('disassemble --start-address 0x%x --count 6' % pc))
        fr = th.GetFrameAtIndex(0)
        vals = {}
        for rn in REGS:
            rv = fr.FindRegister(rn)
            vals[rn] = rv.GetValueAsUnsigned() if rv.IsValid() else 0
        log('regs: ' + ' '.join('%s=0x%x' % (rn, vals[rn]) for rn in REGS))
        for rn in REGS:
            if rn in ('rsp', 'rbp'): continue
            dump_ptr(rn, vals[rn])
        # also the stack top often holds string ptrs
        err = lldb.SBError()
        sp = vals['rsp']
        mem = proc.ReadMemory(sp, 256, err)
        if err.Success() and mem:
            qs = []
            for k in range(0, 256, 8):
                q = 0
                for j in range(8):
                    q |= (ord(mem[k+j]) if isinstance(mem[k+j], str) else mem[k+j]) << (8*j)
                qs.append(q)
            log('stack qwords: ' + ' '.join(hex(q) for q in qs[:16]))
            for qi, q in enumerate(qs[:16]):
                dump_ptr('stk[%d]' % qi, q, before=256, after=1024)
        got_app = True
    if got_bt and got_app and thunk_pc is not None:
        break
    cont()
    time.sleep(0.4)

log('summary: got_bt=%s got_app=%s thunk_pc=%s' % (got_bt, got_app, hex(thunk_pc) if thunk_pc else None))

# loop rate via breakpoint hit-count at the thunk pc. CAVEAT: every hit is a
# host-side stop even with ignore-count, so this is a LOWER BOUND on the real
# rate (debugger throughput ~1e2-1e3 stops/s), not a measurement.
if thunk_pc is not None:
    bp = target.BreakpointCreateByAddress(thunk_pc)
    bp.SetIgnoreCount(2000000000)
    t0 = time.time()
    cont()
    time.sleep(6.0)
    interrupt()
    dt = time.time() - t0
    hits = bp.GetHitCount()
    log('rate LOWER BOUND: %d hits at 0x%x in %.1fs = %.0f/s (debugger-bound)' % (hits, thunk_pc, dt, hits / dt if dt > 0 else 0))
    target.BreakpointDelete(bp.GetID())
    cont()

out.close()
print('FORENSIC DONE -> %s' % OUT)
