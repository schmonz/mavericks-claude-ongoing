#!/usr/bin/env python3
# Launch claude in a pty (inherits BUN_OPTIONS from parent env), write its pid to
# /tmp/spin.pid, and KEEP THE PTY OPEN pumping output for HOLD_SECS so the child
# keeps running (and does not SIGHUP-die) while an external tool (lldb) works on
# it. Does NOT signal/kill the child itself — the orchestrator owns teardown.
import os, pty, time, select, sys, fcntl, termios, struct
HOLD_SECS = float(os.environ.get('HOLD_SECS', '300'))
COLS, ROWS = 120, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ['DISABLE_AUTOUPDATER']='1'; os.environ['TERM']='xterm-256color'
    os.environ.pop('TMUX',None); os.environ.pop('STY',None)
    _L=os.environ.get('LAUNCHER') or os.path.join(os.path.dirname(os.path.abspath(__file__)),'claude_185')
    os.execv(_L,[_L]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
open('/tmp/spin.pid','w').write(str(pid))
print("HELD pid=%d" % pid); sys.stdout.flush()
end=time.time()+HOLD_SECS
while time.time()<end:
    r,_,_=select.select([fd],[],[],0.2)
    if r:
        try: d=os.read(fd,65536)
        except OSError: break
        if not d: break
        if b'\x1b[c' in d:
            try: os.write(fd,b'\x1b[?1;2c')
            except OSError: pass
    # stop early if child already gone
    try:
        if os.waitpid(pid, os.WNOHANG)!=(0,0): print("child exited"); break
    except ChildProcessError: print("child reaped"); break
print("hold done"); sys.stdout.flush()
