# fakereceiver.py: a stand-in FiveK receiver for testing the sender on one Mac, no second computer needed.
# Listens on 127.0.0.1:5959, reports a screen + capabilities like the real receiver, acks every frame, counts
# cursor datagrams on UDP 5959, and prints what arrives.
#
#   defaults write com.fivek.sender Host 127.0.0.1      # point FiveK at it (delete the key afterwards)
#   python3 tools/fakereceiver.py 30 2560,1440,5120,2880 5 597,336
#     args: seconds  pointsW,pointsH,pixelsW,pixelsH  caps(1=4:4:4, 2=hw, 4=UDP cursor)  [mmW,mmH]
import socket, struct, sys, time, threading

secs = float(sys.argv[1])
screen = [int(x) for x in sys.argv[2].split(",")]
caps = int(sys.argv[3]) if len(sys.argv) > 3 else 0
mm = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else None

udp_count = [0]
def udp_loop():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("127.0.0.1", 5959)); u.settimeout(1)
    while True:
        try: d, _ = u.recvfrom(64)
        except socket.timeout: continue
        if d[:2] == b"F5": udp_count[0] += 1
threading.Thread(target=udp_loop, daemon=True).start()

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 5959)); srv.listen(1); srv.settimeout(30)
c, _ = srv.accept(); c.settimeout(1)
hello = b"R" + struct.pack(">HHHH", *screen) + b"C" + bytes([caps])
if mm: hello += b"P" + struct.pack(">HH", *mm)
c.sendall(hello)
print("connected; reported screen", screen, "caps", caps, "mm", mm, flush=True)

def readn(n):
    b = b""
    while len(b) < n:
        try: chunk = c.recv(n - len(b))
        except socket.timeout: return None
        if not chunk: raise EOFError
        b += chunk
    return b

end = time.time() + secs; counts = {}; total = 0
try:
    while time.time() < end:
        h = readn(5)
        if h is None: continue
        t, n = h[0], struct.unpack(">I", h[1:])[0]
        p = readn(n) if n else b""
        while p is None: p = readn(n)
        counts[t] = counts.get(t, 0) + 1; total += n
        if t == 2:
            c.sendall(b"\x01")
            if p[0] == 1: print("  keyframe %d KB" % (len(p) // 1024), flush=True)
        if t == 5:
            print("display info: pt %dx%d px %dx%d" % struct.unpack(">HHHH", p[:8]),
                  "4:4:4" if len(p) > 8 and p[8] & 1 else "4:2:0", flush=True)
except EOFError:
    print("sender closed the connection", flush=True)
print("final:", counts, "bytes", total, "| UDP cursor datagrams:", udp_count[0], flush=True)
