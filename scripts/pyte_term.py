#!/usr/bin/env python3
# Faithful terminal via pyte: parses the app's output into a real screen, answers
# capability queries (DA/DSR via pyte, XTVERSION/OSC11 manually), measures CPU.
# Usage: pyte_term.py <label> <ANSWER|SILENT>
import os, pty, time, subprocess, select, sys, fcntl, termios, struct
import pyte

label = sys.argv[1]
answer = sys.argv[2] == 'ANSWER'
COLS, ROWS = 120, 40

pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER'] = '1'
    os.environ['TERM'] = 'xterm-256color'
    os.environ.pop('TMUX', None); os.environ.pop('STY', None)
    _L=os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185'); os.execv(_L,[_L])
    os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

screen = pyte.Screen(COLS, ROWS)
try:
    stream = pyte.ByteStream(screen)
    def feed(d): stream.feed(d)
except AttributeError:
    stream = pyte.Stream(screen)
    def feed(d): stream.feed(d.decode('utf-8', 'replace'))

def send(data):
    if not answer: return
    if isinstance(data, str): data = data.encode('latin1', 'replace')
    try: os.write(fd, data)
    except OSError: pass

# pyte calls this for DA/DSR auto-responses
screen.write_process_input = lambda d: send(d)

def cputime(p):
    try:
        out = subprocess.check_output(['ps','-o','cputime=','-p',str(p)],
                                      stderr=subprocess.DEVNULL).decode().strip()
    except Exception: return -1.0
    s = 0.0
    for x in out.split(':'): s = s*60 + float('0'+x)
    return s

total = 0
def pump(dur):
    global total
    end = time.time() + dur
    while time.time() < end:
        r,_,_ = select.select([fd], [], [], 0.1)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return True
            if not d: return True
            total += len(d)
            feed(d)
            if answer:
                if b'\x1b[>0q' in d or b'\x1b[>q' in d: send(b'\x1bP>|xterm(370)\x1b\\')
                if b'\x1b]11;?' in d:                   send(b'\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\')
                if b'\x1b[c' in d or b'\x1b[0c' in d:    send(b'\x1b[?1;2c')
    return False

pump(7.0)
prev = cputime(pid); vals = []
for _ in range(5):
    pump(2.0); cur = cputime(pid); vals.append((cur-prev)/2.0); prev = cur

lines = [l for l in screen.display if l.strip()]
print(">>> %s (%s) busy: %s  bytes=%d  screen_lines=%d" %
      (label, 'ANSWER' if answer else 'SILENT',
       ' '.join('%.2f'%v for v in vals), total, len(lines)))
for l in lines[:4]:
    print("    | " + l.rstrip()[:100])
try: os.kill(pid, 9)
except Exception: pass
