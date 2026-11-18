start_all()
stripper.wait_for_unit("ike-strip.socket")
ike.wait_for_unit("ike.service")

addr = stripper.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()

# ike's host has no stripper of its own: the remote one is the only one
ike.fail("systemctl cat ike-strip.socket")
ike.succeed("grep -F '{tcp, \"%s\", 7070}' $(systemctl show -p ExecStart ike.service | grep -o '/nix/store/[^ ]*sys.config' | head -n1)" % addr)

# ike's address is answered, over the wire, by a sandboxed instance
ike.succeed(f"socat -t 60 - TCP:{addr}:7070 </etc/ike-test/base.png >/tmp/stripped")
ike.succeed("head -n1 /tmp/stripped | grep '^ok png 61 47 '")
stripper.succeed("systemctl cat ike-strip@probe.service | grep -x 'PrivateNetwork=true'")

# nobody else is: not the stripper's own host, from its own address
stripper.succeed(f"! (socat -t 10 - TCP:{addr}:7070,connect-timeout=5 </etc/ike-test/base.png | grep -q '^ok')")
