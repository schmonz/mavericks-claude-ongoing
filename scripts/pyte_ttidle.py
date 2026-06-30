#!/usr/bin/env python3
# Measure TIME-TO-IDLE: run the launcher, sample CPU% every 3s, and exit as soon
# as CPU stays < IDLE_PCT for IDLE_HOLD consecutive samples (the spin finished),
# or at MAXDUR. Prints "TTIDLE=<sec>" or "TTIDLE=none". Kills only its own child.
import os, pty, time, subprocess, select, sys, fcntl, termios, struct, hashlib
import pyte
MAXDUR = int(sys.argv[1]) if len(sys.argv) > 1 else 600
IDLE_PCT = 15.0; IDLE_HOLD = 3
COLS, ROWS = 120, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    L=(os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185')); os.execv(L,[L])
    os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
screen = pyte.Screen(COLS, ROWS)
try: stream = pyte.ByteStream(screen); feed = stream.feed
except AttributeError: stream = pyte.Stream(screen); feed = lambda d: stream.feed(d.decode('utf-8','replace'))
def send(data):
    try: os.write(fd, data)
    except OSError: pass
screen.write_process_input = lambda d: send(d.encode('latin1','replace') if isinstance(d,str) else d)
def cputime(p):
    try: out=subprocess.check_output(['ps','-o','cputime=','-p',str(p)],stderr=subprocess.DEVNULL).decode().strip()
    except Exception: return -1.0
    s=0.0
    for x in out.split(':'): s=s*60+float('0'+x)
    return s
def pump(dur):
    end=time.time()+dur
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: d=os.read(fd,65536)
            except OSError: return True
            if not d: return True
            if b'\x1b[>0q' in d: send(b'\x1bP>|xterm(370)\x1b\\')
            if b'\x1b]11;?' in d: send(b'\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\')
            if b'\x1b[c' in d: send(b'\x1b[?1;2c')
            feed(d)
    return False
pump(6.0)
prev=cputime(pid); t=6; idle_run=0; ttidle=None; peak=0.0
while t < MAXDUR:
    dead=pump(3.0); t+=3
    cur=cputime(pid); pct=(cur-prev)/3.0*100; prev=cur
    if pct>peak: peak=pct
    if pct<IDLE_PCT: idle_run+=1
    else: idle_run=0
    if idle_run>=IDLE_HOLD: ttidle=t-(IDLE_HOLD-1)*3; break
    if dead: break
print("TTIDLE=%s  maxcpu=%.0f  totalcpu=%.1fs  watched=%ds" % (ttidle if ttidle else "none", peak, cputime(pid), t))
try: os.kill(pid,9)
except Exception: pass
