#!/usr/bin/env python3
"""x86Sim: mDNSResponder stand-in for the iOS simulator under Darling.

On a Mac the simulator has no mDNSResponder of its own: its libsystem_dnssd (mDNSResponder-2881's
dnssd_clientstub) connects to the host's daemon at /var/run/mDNSResponder (MDNS_UDS_SERVERPATH, overridable with
DNSSD_UDS_PATH). Network.framework (nw_resolver), CFNetwork and libinfo's getaddrinfo all resolve through it.
Here this Linux process plays the host daemon: it listens on var/run/mDNSResponder, the container's
/var/run/mDNSResponder is a symlink to it (cli/libexec/arm64/boot-a64.sh), and it answers with real Linux DNS lookups.

Protocol: Apple's mDNSShared/dnssd_ipc.h (VERSION 1). A request is a 28-byte ipc_msg_hdr (version, datalen,
ipc_flags, op, client_context[8], reg_index; all big-endian except client_context, which is echoed raw) and datalen
bytes. Requests on their own connection get their 4-byte error code back on that connection; subordinate requests
of a shared connection (kDNSServiceFlagsShareConnection) and record operations send one end of a socketpair with
SCM_RIGHTS along with the last data byte (their data then starts with an empty control-path string) and get the
error code there. Replies: header (op = request op's reply op, client_context of the request) + flags, interface
index, error, then the operation's fields.

Answered: GetAddrInfo, QueryRecord (any type, via dnspython, so TTLs, CNAMEs and raw rdata are the server's),
GetProperty (DaemonVersion), GetPID. Accepted without results (they must not fail): Register (the reply confirms
the name), RegisterRecord/AddRecord/UpdateRecord/RemoveRecord, Browse, Resolve (no multicast DNS here),
EnumerateDomains ("local."), Reconfirm, SetDomain, NAT port mapping (reports unsupported), delegate connections.

Usage: mdnsresponder.py <socket path>   (cli/libexec/arm64/boot-a64.sh starts it; X86SIM_MDNS_LOG=1 logs every request)
"""
import os
import socket
import struct
import sys
import threading
import time

# x86Sim release: the AppImage carries dnspython (ISC) for hosts without python3-dnspython; run with -I, so the path
# comes from X86SIM_PYLIB (set by the AppImage's entry), appended after the system's own packages
if os.environ.get("X86SIM_PYLIB"):
    sys.path.append(os.environ["X86SIM_PYLIB"])
import dns.exception  # noqa: E402
import dns.flags
import dns.rdatatype
import dns.resolver

VERSION = 1
IPC_FLAGS_NOREPLY, IPC_FLAGS_TRAILING_TLVS, IPC_FLAGS_NOERRSD = 1, 2, 4
(CONNECTION, REG_RECORD, REMOVE_RECORD, ENUMERATION, REG_SERVICE, BROWSE, RESOLVE, QUERY, RECONFIRM, ADD_RECORD,
 UPDATE_RECORD, SETDOMAIN, GETPROPERTY, PORT_MAPPING, ADDRINFO, SEND_BPF, GETPID, RELEASE, CONNECTION_DELEGATE) = range(1, 20)
CANCEL = 63
REPLY = {ENUMERATION: 64, REG_SERVICE: 65, BROWSE: 66, RESOLVE: 67, QUERY: 68, REG_RECORD: 69, GETPROPERTY: 70,
         PORT_MAPPING: 71, ADDRINFO: 72}
ASYNC_ERROR_OP = 73
F_MORE, F_ADD, F_DEFAULT = 0x1, 0x2, 0x4
F_RETURN_INTERMEDIATES, F_SHARE, F_TIMEOUT = 0x1000, 0x4000, 0x10000
ERR_NONE, ERR_UNKNOWN, ERR_NOSUCHNAME, ERR_BADPARAM, ERR_NOSUCHRECORD = 0, -65537, -65538, -65540, -65554
ERR_NATPM_UNSUPPORTED, ERR_TIMEOUT = -65564, -65568
T_A, T_AAAA, T_CNAME = 1, 28, 5
IF_LOCALONLY = 0xFFFFFFFF
LOG = os.environ.get("X86SIM_MDNS_LOG") == "1"


REG_PROBE_S = 0.75   # mDNSResponder's probing before a registration is answered


def log(*a):
    if LOG:
        print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def default_ifindex():
    """The Linux interface of the IPv4 default route (answers carry the interface they came in on, as the real
    daemon's do). Darling's interface list (NET_RT_IFLIST, getifaddrs) is Linux's, so the index means the same."""
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                p = line.split()
                if p[1] == "00000000" and int(p[3], 16) & 2:
                    return socket.if_nametoindex(p[0])
    except (OSError, IndexError, ValueError):
        pass
    return 0


class Reader:
    """Big-endian field reader over a request's data (dnssd_ipc.c's get_* functions)."""

    def __init__(self, data):
        self.d, self.p = data, 0

    def u32(self):
        v = struct.unpack_from(">I", self.d, self.p)[0]; self.p += 4; return v

    def u16(self):
        v = struct.unpack_from(">H", self.d, self.p)[0]; self.p += 2; return v

    def raw(self, n):
        v = self.d[self.p:self.p + n]; self.p += n; return v

    def string(self):
        e = self.d.index(b"\0", self.p)
        v = self.d[self.p:e].decode("utf-8", "replace"); self.p = e + 1; return v


def s(v):
    return v.encode() + b"\0"


class Connection(threading.Thread):
    def __init__(self, sock, server):
        super().__init__(daemon=True)
        self.sock, self.server = sock, server
        self.wlock = threading.Lock()
        self.shared = False          # a DNSServiceCreateConnection connection (subordinate requests follow)
        self.cancelled = set()       # client contexts of cancelled subordinate operations
        self.closed = False

    # ---- I/O
    def recv_exact(self, n, fds):
        buf = b""
        while len(buf) < n:
            data, anc, flags, _ = self.sock.recvmsg(n - len(buf), socket.CMSG_SPACE(16 * 4))
            if not data:
                raise EOFError
            for level, typ, cdata in anc:
                if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
                    fds.extend(struct.unpack("%di" % (len(cdata) // 4), cdata[:len(cdata) // 4 * 4]))
            buf += data
        return buf

    def send(self, data, sock=None):
        try:
            with self.wlock:
                (sock or self.sock).sendall(data)
            return True
        except OSError:
            return False

    def reply(self, op, ctx, flags, ifindex, err, body):
        if self.closed or ctx in self.cancelled:
            return
        payload = struct.pack(">IIi", flags & 0xFFFFFFFF, ifindex & 0xFFFFFFFF, err) + body
        hdr = struct.pack(">IIII", VERSION, len(payload), 0, op) + ctx + struct.pack(">I", 0)
        self.send(hdr + payload)

    # ---- main loop
    def run(self):
        try:
            while True:
                fds = []
                hdr = self.recv_exact(28, fds)
                version, datalen, ipc_flags, op = struct.unpack(">IIII", hdr[:16])
                ctx, reg_index = hdr[16:24], struct.unpack(">I", hdr[24:28])[0]
                if version != VERSION or datalen > 70000:
                    log("bad header", version, datalen)
                    break
                data = self.recv_exact(datalen, fds) if datalen else b""
                self.handle(op, ipc_flags, ctx, reg_index, data, fds)
        except (EOFError, OSError):
            pass
        except Exception as e:  # never let one client take the daemon down
            log("connection error:", repr(e))
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass

    def handle(self, op, ipc_flags, ctx, reg_index, data, fds):
        r = Reader(data)
        # A separate error-return socket (SCM_RIGHTS) means the data starts with its (empty) control path
        sub_ops = (REG_RECORD, ADD_RECORD, UPDATE_RECORD, REMOVE_RECORD)
        separate = bool(fds) or op in sub_ops or (self.shared and op not in (CANCEL, CONNECTION))
        if separate and op != CANCEL and data:
            r.string()
        errsock = None
        if fds:
            errsock = socket.socket(fileno=fds[0])
            for extra in fds[1:]:
                os.close(extra)

        def answer_error(err):
            if ipc_flags & IPC_FLAGS_NOERRSD:
                return
            if errsock is not None:
                try:
                    errsock.sendall(struct.pack(">i", err))
                except OSError:
                    pass
            else:
                self.send(struct.pack(">i", err))

        try:
            self.dispatch(op, ipc_flags, ctx, reg_index, r, answer_error)
        except (IndexError, ValueError, struct.error) as e:
            log("bad request op", op, repr(e))
            answer_error(ERR_BADPARAM)
        finally:
            if errsock is not None:
                errsock.close()

    def dispatch(self, op, ipc_flags, ctx, reg_index, r, answer_error):
        if op == CONNECTION or op == CONNECTION_DELEGATE:
            self.shared = True
            log("connection", "delegate" if op == CONNECTION_DELEGATE else "")
            answer_error(ERR_NONE)
        elif op == CANCEL:
            log("cancel", ctx.hex())
            self.cancelled.add(ctx)
        elif op == ADDRINFO:
            flags, ifindex, proto = r.u32(), r.u32(), r.u32()
            host = r.string()
            log("getaddrinfo", host, "flags=%#x proto=%d if=%d" % (flags, proto, ifindex))
            answer_error(ERR_NONE)
            self.server.pool(self.do_addrinfo, ctx, flags, ifindex, proto, host)
        elif op == QUERY:
            flags, ifindex = r.u32(), r.u32()
            name = r.string()
            rrtype, rrclass = r.u16(), r.u16()
            log("query", name, rrtype, rrclass, "flags=%#x" % flags)
            answer_error(ERR_NONE)
            self.server.pool(self.do_query, ctx, flags, ifindex, name, rrtype, rrclass)
        elif op == GETPROPERTY:
            prop = r.string()
            log("getproperty", prop)
            answer_error(ERR_NONE)
            if prop == "DaemonVersion":
                self.send(struct.pack(">I", 4) + struct.pack(">I", 2881 * 10000 + 1200 + 11))
            else:
                self.send(struct.pack(">I", 0))
        elif op == GETPID:
            answer_error(ERR_NONE)
            self.send(struct.pack("=i", 0))
        elif op == REG_SERVICE:
            flags, ifindex = r.u32(), r.u32()
            name, regtype, domain, host = r.string(), r.string(), r.string(), r.string()
            log("register", repr(name), regtype, domain, host)
            answer_error(ERR_NONE)
            if not (ipc_flags & IPC_FLAGS_NOREPLY):
                name = name or socket.gethostname().split(".")[0]
                # as mDNSResponder, which answers a registration only once its name is probed (3 probes, 250 ms
                # apart): an immediate reply raced a client that registers and cancels at once (MCNearbyService-
                # Advertiser start + stop): it arrived for a registration already torn down and libsystem_dnssd
                # called its NULL callback (SIGSEGV at pc 0 in DNSServiceProcessResult). reply() drops it once
                # the client cancelled or closed.
                t = threading.Timer(REG_PROBE_S, self.reply, (REPLY[REG_SERVICE], ctx, F_ADD, ifindex, ERR_NONE,
                    s(name) + s(regtype if regtype.endswith(".") else regtype + ".") + s(domain or "local.")))
                t.daemon = True
                t.start()
        elif op == REG_RECORD:
            log("register record")
            answer_error(ERR_NONE)
            if not (ipc_flags & IPC_FLAGS_NOREPLY):
                # the reply's context is the record's (create_hdr put its uid there)
                self.reply(REPLY[REG_RECORD], ctx, 0, 0, ERR_NONE, b"")
        elif op in (ADD_RECORD, UPDATE_RECORD, REMOVE_RECORD, RECONFIRM, SETDOMAIN, RELEASE):
            log("record/domain op", op)
            answer_error(ERR_NONE)
        elif op == BROWSE:
            flags, ifindex = r.u32(), r.u32()
            regtype, domain = r.string(), r.string()
            log("browse", regtype, domain)   # no multicast DNS on this host: nothing will be found
            answer_error(ERR_NONE)
        elif op == RESOLVE:
            log("resolve (no mDNS: no answer)")
            answer_error(ERR_NONE)
        elif op == ENUMERATION:
            flags, ifindex = r.u32(), r.u32()
            answer_error(ERR_NONE)
            self.reply(REPLY[ENUMERATION], ctx, F_ADD | F_DEFAULT, 0, ERR_NONE, s("local."))
        elif op == PORT_MAPPING:
            answer_error(ERR_NONE)
            self.reply(REPLY[PORT_MAPPING], ctx, 0, 0, ERR_NATPM_UNSUPPORTED,
                       struct.pack(">I", 0) + bytes([0]) + b"\0\0" + b"\0\0" + struct.pack(">I", 0))
        else:
            log("unsupported op", op)
            answer_error(ERR_NONE)

    # ---- lookups (worker threads)
    def lookup(self, name, rrtype):
        """[(owner name, type, rdata wire bytes, ttl)] for name/rrtype from the host's resolver, the CNAME chain
        first; [] if the name has no such record; None if the name doesn't exist."""
        try:
            ans = self.server.resolver.resolve(name, rrtype, raise_on_no_answer=False, search=False)
        except dns.resolver.NXDOMAIN:
            return None
        except (dns.resolver.NoNameservers, dns.exception.Timeout, dns.resolver.NoAnswer):
            return []
        except dns.exception.DNSException:
            return []
        out = []
        for rrset in ans.response.answer:
            for rd in rrset:
                out.append((rrset.name.to_text(), int(rrset.rdtype), rd.to_wire(), rrset.ttl))
        return out

    def do_addrinfo(self, ctx, flags, ifindex, proto, host):
        want = []
        if proto & 1 or proto == 0:
            want.append(T_A)
        if proto & 2 or proto == 0:
            want.append(T_AAAA)
        iface = ifindex or self.server.ifindex
        hostdot = host if host.endswith(".") else host + "."
        for t in want:
            recs = self.lookup(host, t)
            got = [x for x in (recs or []) if x[1] == t]
            if recs is not None and not got and t == T_A or recs is None:
                # not in DNS: /etc/hosts, localhost and the like (nsswitch), as the Mac's daemon also reads /etc/hosts
                fam = socket.AF_INET if t == T_A else socket.AF_INET6
                try:
                    for ai in socket.getaddrinfo(host, None, fam, socket.SOCK_STREAM):
                        packed = socket.inet_pton(fam, ai[4][0])
                        got.append((hostdot, t, packed, 60))
                except OSError:
                    pass
            if got:
                for owner, rt, rdata, ttl in got:
                    self.reply(REPLY[ADDRINFO], ctx, F_ADD, iface, ERR_NONE,
                               s(hostdot) + struct.pack(">HHH", t, 1, len(rdata)) + rdata + struct.pack(">I", ttl))
                log("  ->", host, t, len(got), "answers")
            elif flags & F_RETURN_INTERMEDIATES or flags & F_TIMEOUT:
                err = ERR_NOSUCHNAME if recs is None else ERR_NOSUCHRECORD
                self.reply(REPLY[ADDRINFO], ctx, 0, iface, err,
                           s(hostdot) + struct.pack(">HHH", t, 1, 0) + struct.pack(">I", 0))
                log("  ->", host, t, "negative", err)

    def do_query(self, ctx, flags, ifindex, name, rrtype, rrclass):
        iface = ifindex or self.server.ifindex
        try:
            rdtype = dns.rdatatype.RdataType.make(rrtype)
        except ValueError:
            rdtype = rrtype
        recs = self.lookup(name, rdtype)
        got = [x for x in (recs or []) if x[1] == rrtype or (flags & F_RETURN_INTERMEDIATES and x[1] == T_CNAME)]
        if got:
            for owner, rt, rdata, ttl in got:
                self.reply(REPLY[QUERY], ctx, F_ADD, iface, ERR_NONE,
                           s(owner) + struct.pack(">HHH", rt, rrclass, len(rdata)) + rdata + struct.pack(">I", ttl))
            log("  ->", name, rrtype, len(got), "answers")
        elif flags & (F_RETURN_INTERMEDIATES | F_TIMEOUT):
            err = ERR_NOSUCHNAME if recs is None else ERR_NOSUCHRECORD
            self.reply(REPLY[QUERY], ctx, 0, iface, err,
                       s(name if name.endswith(".") else name + ".") + struct.pack(">HHH", rrtype, rrclass, 0)
                       + struct.pack(">I", 0))
            log("  ->", name, rrtype, "negative", err)


class Server:
    def __init__(self, path):
        self.resolver = dns.resolver.Resolver()
        self.resolver.lifetime = 10
        self.ifindex = default_ifindex()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        os.chmod(path, 0o666)
        self.sock.listen(100)
        log("listening on", path, "default interface", self.ifindex)

    def pool(self, fn, *args):
        threading.Thread(target=fn, args=args, daemon=True).start()

    def serve(self):
        while True:
            c, _ = self.sock.accept()
            Connection(c, self).start()


if __name__ == "__main__":
    Server(sys.argv[1]).serve()
