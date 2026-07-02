#!/usr/bin/env python3
# Launch claude in a pty (inherits BUN_OPTIONS cpu-prof from parent env), wait
# until it is spinning, let it run SPIN_SECS to capture the runaway, then attempt
# a FLUSHING exit. Tries, in order and only as needed: SIGINT (Ctrl-C native),
# then SIGTERM. NEVER SIGKILL (that would drop the on-exit profile flush).
# Env: LAUNCHER, SPIN_SECS (default 60), SIG (INT|TERM, default INT), MAXWAIT (default 45)
import os, pty, time, select, sys, fcntl, termios, struct, signal
import pyte
COLS, ROWS = 120, 40
SPIN_SECS = float(os.environ.get('SPIN_SECS', '60'))
MAXWAIT   = float(os.environ.get('MAXWAIT', '45'))
SIG = {'INT': signal.SIGINT, 'TERM': signal.SIGTERM}[os.environ.get('SIG','INT')]
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    _L=os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185')
    os.execv(_L,[_L]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
open('/tmp/spin.pid','w').write(str(pid))
screen = pyte.Screen(COLS, ROWS)
try: stream=pyte.ByteStream(screen); feed=stream.feed
except AttributeError: stream=pyte.Stream(screen); feed=lambda d: stream.feed(d.decode('utf-8','replace'))
def cpu():
    try: return float(os.popen('ps -o %%cpu= -p %d'%pid).read().strip() or 0)
    except Exception: return 0.0
def alive():
    try: return os.waitpid(pid, os.WNOHANG)==(0,0)
    except ChildProcessError: return False
def pump(dur):
    end=time.time()+dur
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: d=os.read(fd,65536)
            except OSError: return
            if not d: return
            feed(d)
            if b'\x1b[c' in d:
                try: os.write(fd,b'\x1b[?1;2c')
                except OSError: pass

# Wait for spin to start (cpu>70).
t0=time.time(); started=False
while time.time()-t0 < 40:
    pump(2.0); c=cpu()
    if c>70: started=True; break
print("spin-started=%s cpu=%.0f after %.0fs" % (started, cpu(), time.time()-t0)); sys.stdout.flush()

# Let it spin to capture the runaway.
pump(SPIN_SECS)
print("after SPIN_SECS=%.0f cpu=%.0f" % (SPIN_SECS, cpu())); sys.stdout.flush()

# Flushing exit: send the chosen signal to the child, wait for exit.
print("sending SIG%s to pid %d" % (os.environ.get('SIG','INT'), pid)); sys.stdout.flush()
try: os.kill(pid, SIG)
except ProcessLookupError: pass
end=time.time()+MAXWAIT
while time.time()<end:
    if not alive(): print("child EXITED after signal"); break
    pump(0.5)
else:
    print("child STILL ALIVE %ds after SIG%s (wedged?) — leaving it, NOT killing" % (MAXWAIT, os.environ.get('SIG','INT')))
sys.stdout.flush()
