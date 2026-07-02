# Interrupt-sampler for the pegged spin: run inside lldb's script interpreter
# after attaching (lldb -p PID). Emits FAULTSNAP-compatible records to
# /tmp/lldbsnap.out so scripts/faultsnap_recur.py can analyze recurrence.
# Env knobs (read via os.environ): LSNAP_N (samples), LSNAP_DT (seconds between).
import lldb, time, os

N = int(os.environ.get('LSNAP_N', '180'))
DT = float(os.environ.get('LSNAP_DT', '1.0'))
OUT = '/tmp/lldbsnap.out'

REGS = ['rax','rbx','rcx','rdx','rdi','rsi','rbp','rsp',
        'r8','r9','r10','r11','r12','r13','r14','r15']

dbg = lldb.debugger
proc = lldb.process
dbg.HandleCommand('process handle SIGILL --pass true --stop false --notify false')
dbg.SetAsync(True)

out = open(OUT, 'w')

def wait_state(want, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if proc.GetState() == want:
            return True
        time.sleep(0.02)
    return False

def printable_runs(buf):
    # py2 (lldb-320 embeds 2.7): iterating str yields chars; py3 bytes yields ints
    runs, run = [], ''
    for c in buf:
        o = ord(c) if isinstance(c, str) else c
        if 0x20 <= o < 0x7F:
            run += chr(o)
        else:
            if len(run) >= 6: runs.append(run)
            run = ''
    if len(run) >= 6: runs.append(run)
    return runs

for i in range(N):
    if proc.GetState() == lldb.eStateStopped:
        pass
    else:
        proc.SendAsyncInterrupt()
        if not wait_state(lldb.eStateStopped):
            out.write('--- snap %d t %d rip 0xdead-nostop\n' % (i, time.time()*1e9))
            out.flush(); continue
    # all threads' frame-0 pc, then dump regs of the BUSY thread: prefer the first
    # whose pc moved since the last sample (a parked thread shows a frozen pc —
    # the 2026-07-02 phase-D misattribution), else thread 0.
    nth = proc.GetNumThreads()
    allpcs = [proc.GetThreadAtIndex(k).GetFrameAtIndex(0).GetPC() for k in range(nth)]
    try:
        prev_pcs
    except NameError:
        prev_pcs = []
    busy = 0
    for k in range(nth):
        if k < len(prev_pcs) and prev_pcs[k] is not None and allpcs[k] != prev_pcs[k]:
            busy = k
            break
    prev_pcs = list(allpcs)
    th = proc.GetThreadAtIndex(busy)
    fr = th.GetFrameAtIndex(0)
    rip = fr.GetPC()
    out.write('--- snap %d t %d rip 0x%x\n' % (i, int(time.time()*1e9), rip))
    out.write('threads=%s busy=%d\n' % (','.join('0x%x' % p for p in allpcs), busy))
    # a short pc chain for context (frames 1..3)
    pcs = []
    for k in range(1, min(4, th.GetNumFrames())):
        pcs.append('0x%x' % th.GetFrameAtIndex(k).GetPC())
    out.write('pcs=%s\n' % ','.join(pcs))
    for ri, rn in enumerate(REGS):
        rv = fr.FindRegister(rn)
        v = rv.GetValueAsUnsigned() if rv.IsValid() else 0
        line = 'r%d=0x%x' % (ri, v)
        if 0x100000000 <= v < 0x800000000000:
            err = lldb.SBError()
            mem = proc.ReadMemory(v & ~0xF, 128, err)
            if err.Success() and mem:
                for run in printable_runs(mem):
                    line += ' "%s"' % run
        out.write(line + '\n')
    out.flush()
    proc.Continue()
    if not wait_state(lldb.eStateRunning, 2.0):
        pass
    time.sleep(DT)

out.write('--- done %d samples\n' % N)
out.close()
print('SAMPLER DONE -> %s' % OUT)
