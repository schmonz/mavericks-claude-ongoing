#!/usr/bin/env python3
# Render, then TYPE into it and check if the screen responds. Also print the pid
# so the caller can lsof it. Confirms whether the main thread is wedged.
import os, pty, time, select, sys, fcntl, termios, struct, hashlib
import pyte
COLS, ROWS = 120, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    _L=os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185'); os.execv(_L,[_L]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
open('/tmp/spin.pid','w').write(str(pid))
screen = pyte.Screen(COLS, ROWS)
try: stream=pyte.ByteStream(screen); feed=stream.feed
except AttributeError: stream=pyte.Stream(screen); feed=lambda d: stream.feed(d.decode('utf-8','replace'))
screen.write_process_input = lambda d: os.write(fd, d.encode('latin1','replace') if isinstance(d,str) else d)
def shot(): return hashlib.md5(('\n'.join(screen.display)).encode()).hexdigest()[:8]
def pump(dur):
    end=time.time()+dur
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: d=os.read(fd,65536)
            except OSError: return
            if not d: return
            feed(d)
            if b'\x1b[c' in d: os.write(fd,b'\x1b[?1;2c')
pump(7.0)
h0=shot()
print("pid=%d  rendered screen=%s" % (pid, h0))
# type some characters
for ch in [b'h', b'e', b'l', b'l', b'o', b'/', b'h', b'e', b'l', b'p']:
    os.write(fd, ch); time.sleep(0.15)
pump(3.0)
h1=shot()
print("after typing 'hello/help': screen=%s  CHANGED=%s" % (h1, h1!=h0))
# show input-line area (last few non-empty lines)
lines=[l.rstrip() for l in screen.display if l.strip()]
for l in lines[-3:]: print("   | "+l[:100])
sys.stdout.flush()
time.sleep(8)   # stay alive for lsof
os.kill(pid,9)
