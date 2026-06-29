#!/usr/bin/env python3
# Watch the spin over a long window via pyte: every ~3s log CPU%, a hash of the
# screen, and note screen changes. Answers DA/DSR. Tells us: does it terminate?
# does the screen keep changing (animation/reflow) or stay static (compute loop)?
import os, pty, time, subprocess, select, sys, fcntl, termios, struct, hashlib
import pyte

DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 90
COLS, ROWS = 120, 40

pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER'] = '1'
    os.environ['TERM'] = 'xterm-256color'
    os.environ.pop('TMUX', None); os.environ.pop('STY', None)
    L=(os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185')); os.execv(L,[L])
    os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

screen = pyte.Screen(COLS, ROWS)
try:
    stream = pyte.ByteStream(screen); feed = stream.feed
except AttributeError:
    stream = pyte.Stream(screen); feed = lambda d: stream.feed(d.decode('utf-8','replace'))
def send(data):
    try: os.write(fd, data)
    except OSError: pass
screen.write_process_input = lambda d: send(d.encode('latin1','replace') if isinstance(d,str) else d)

def cputime(p):
    try:
        out = subprocess.check_output(['ps','-o','cputime=','-p',str(p)],stderr=subprocess.DEVNULL).decode().strip()
    except Exception: return -1.0
    s=0.0
    for x in out.split(':'): s=s*60+float('0'+x)
    return s

def shot():
    return hashlib.md5(('\n'.join(screen.display)).encode()).hexdigest()[:8]

bytes_total = 0
def pump(dur):
    global bytes_total
    end=time.time()+dur
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: d=os.read(fd,65536)
            except OSError: return True
            if not d: return True
            bytes_total+=len(d); feed(d)
            if b'\x1b[>0q' in d: send(b'\x1bP>|xterm(370)\x1b\\')
            if b'\x1b]11;?' in d: send(b'\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\')
            if b'\x1b[c' in d: send(b'\x1b[?1;2c')
    return False

pump(6.0)
prev=cputime(pid); prevb=bytes_total; prevh=shot()
print("t   cpu%%  dbytes  screen  note")
t=6
while t < DUR:
    dead = pump(3.0); t+=3
    cur=cputime(pid); h=shot()
    pct=(cur-prev)/3.0*100; db=bytes_total-prevb
    note=""
    if h!=prevh: note+="SCREEN-CHANGED "
    if pct<15: note+="IDLE "
    if dead: note+="EOF "
    print("%3d  %5.0f  %6d  %s  %s" % (t, pct, db, h, note))
    prev=cur; prevb=bytes_total; prevh=h
    if dead: break
print(">>> total bytes=%d final screen hash=%s" % (bytes_total, shot()))
try: os.kill(pid,9)
except Exception: pass
