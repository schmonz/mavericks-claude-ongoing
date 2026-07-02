#!/usr/bin/env python3
# Launch claude in a pty, let it render/run, then drive a CLEAN exit (Ctrl-C x2,
# then /quit) so Bun's on-exit CPU-profile flush fires. Unlike pyte_type.py this
# NEVER SIGKILLs — the whole point is a graceful shutdown that flushes the profile.
# Env:
#   LAUNCHER   path to launcher script (default scripts/claude_185)
#   RUN_SECS   seconds to let it run before quitting (default 12)
#   QUIT_WAIT  seconds to wait for graceful exit after /quit (default 30)
import os, pty, time, select, sys, fcntl, termios, struct, hashlib
import pyte
COLS, ROWS = 120, 40
RUN_SECS  = float(os.environ.get('RUN_SECS', '12'))
QUIT_WAIT = float(os.environ.get('QUIT_WAIT', '30'))
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
def shot(): return hashlib.md5(('\n'.join(screen.display)).encode()).hexdigest()[:8]
def pump(dur):
    end=time.time()+dur
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: d=os.read(fd,65536)
            except OSError: return False
            if not d: return False
            feed(d)
            if b'\x1b[c' in d: os.write(fd,b'\x1b[?1;2c')
    return True
def alive():
    try:
        w=os.waitpid(pid, os.WNOHANG)
        return w==(0,0)
    except ChildProcessError:
        return False

pump(RUN_SECS)
print("pid=%d  screen-after-%gs=%s  cpu=%s" % (
    pid, RUN_SECS, shot(),
    os.popen('ps -o %%cpu= -p %d'%pid).read().strip()))
sys.stdout.flush()

# Graceful exit sequence: Esc to dismiss any menu, Ctrl-C twice, then /quit ENTER.
os.write(fd, b'\x1b'); time.sleep(0.4)
os.write(fd, b'\x03'); time.sleep(0.6)      # Ctrl-C
os.write(fd, b'\x03'); time.sleep(0.6)      # Ctrl-C again (many TUIs need 2)
os.write(fd, b'/quit'); time.sleep(0.3)
os.write(fd, b'\r');    time.sleep(0.3)

# Wait for graceful exit, pumping output so the pty drains.
end=time.time()+QUIT_WAIT
exited=False
while time.time()<end:
    if not alive(): exited=True; break
    pump(0.5)
print("graceful-exit=%s  waited<=%gs" % (exited, QUIT_WAIT))
if not exited:
    # Last resort: SIGTERM (still gives atexit a chance), then report.
    try: os.kill(pid, 15)
    except ProcessLookupError: pass
    time.sleep(2)
    print("sent SIGTERM (did NOT SIGKILL)")
sys.stdout.flush()
