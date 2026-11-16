machine.wait_for_unit("ike.service")
machine.wait_for_open_port(8970)
machine.succeed("curl -fsS http://127.0.0.1:8970/health | grep -x ok")
# the schema was migrated into the state directory
machine.succeed("test -s /var/lib/ike/ike.db")

# a first snapshot is taken at once, and it is a database
machine.wait_until_succeeds("ls /var/lib/ike/backups/*Z.db")
machine.succeed("head -c 15 /var/lib/ike/backups/*Z.db | grep -q 'SQLite format 3'")

# caddy serves the rendered index from disk, with ike's headers, and
# passes on what is not a page
machine.wait_for_unit("caddy.service")
machine.wait_for_open_port(80)
machine.wait_for_file("/var/cache/ike/pages/index.html")
machine.succeed("curl -fsS http://localhost/ | cmp - /var/cache/ike/pages/index.html")
machine.succeed("curl -fsSI http://localhost/ | grep -i '^content-security-policy: default-src .none.'")
machine.succeed("curl -fsSI http://localhost/ | grep -i '^server: caddy'")
machine.succeed("curl -fsS http://localhost/health | grep -x ok")
machine.succeed("curl -fsS http://localhost/board | cmp - /var/cache/ike/pages/board.html")
machine.succeed("curl -fsSI http://localhost/board/b | grep -i '^server: caddy'")
machine.succeed("curl -fsS http://localhost/board/b | grep -q random")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost/board/nope) = 404")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost/board/b/1) = 404")
# and caddy reads the pages, never the database
machine.succeed("su -s /bin/sh caddy -c 'test -r /var/cache/ike/pages/index.html'")
machine.fail("su -s /bin/sh caddy -c 'test -r /var/lib/ike/ike.db'")

# forms and login come from cowboy, through caddy. without a provider
# that answers, login says so and nothing falls over
machine.succeed("curl -fsS http://localhost/board/b/new | grep -q 'log in'")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost/login) = 503")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -d body=x http://localhost/board/b/new) = 403")
# where a post is, is asked of ike each time; there is no post yet
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost/p/1) = 404")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -F body=x http://localhost/board/b/new) = 403")
# posts are counted by where caddy says they came from, whatever became
# of them: these make six from one address, where four are let through.
# what the client says of itself is not believed
for _ in range(2):
    machine.succeed("curl -s -o /dev/null -d body=x http://localhost/board/b/new")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -d body=x http://localhost/board/b/new) = 429")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.9' -d body=x http://localhost/board/b/new) = 429")
machine.succeed("curl -s -D - -o /dev/null -d body=x http://localhost/board/b/new | grep -i '^retry-after: 60'")
# reading is never counted
machine.succeed("curl -fsS http://localhost/board/b/new | grep -q 'log in'")
# uploads: the stripper answers on its socket, one sandboxed unit per
# upload, and what it makes of a png is a png of the same size
machine.wait_for_unit("ike-strip.socket")
# (the answer whole into a file first: head would cut the pipe short)
machine.succeed("socat -t 60 - UNIX-CONNECT:/run/ike-strip/strip.sock </etc/ike-test/base.png >/tmp/stripped")
machine.succeed("head -n1 /tmp/stripped | grep '^ok png 61 47 '")
machine.succeed("echo not-an-image | socat -t 60 - UNIX-CONNECT:/run/ike-strip/strip.sock | grep -x 'no not-an-image'")
for prop in ["PrivateNetwork=yes", "DynamicUser=yes", "NoNewPrivileges=yes", "MemoryDenyWriteExecute=yes"]:
	machine.succeed(f"systemctl show -p {prop.split('=')[0]} ike-strip@probe.service | grep -x '{prop}'")
machine.succeed("systemctl cat ike-strip@probe.service | grep -x 'RestrictAddressFamilies=none'")
# the upload form says how to log in; the media origin has nothing but
# what a signed link names, and pages may show images from it only
machine.succeed("curl -fsS http://localhost/upload | grep -q 'log in'")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: media.localhost' http://localhost/staged/1/9999999999/x) = 404")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: media.localhost' http://localhost/board) = 404")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: media.localhost' http://localhost/" + "0" * 64 + ".png) = 404")
machine.succeed("su -s /bin/sh caddy -c 'test -d /var/cache/ike/media'")
# (a file put where ike would put one is served, typed by its name; the
# writer would take it away again at the next start)
machine.succeed("install -m 0640 -o ike -g ike /etc/ike-test/base.png /var/cache/ike/media/" + "a" * 64 + ".png")
machine.succeed("curl -fsS -D - -o /dev/null -H 'Host: media.localhost' http://localhost/" + "a" * 64 + ".png | grep -i '^content-type: image/png'")
machine.succeed("curl -fsS -D - -o /dev/null -H 'Host: media.localhost' http://localhost/" + "a" * 64 + ".png | grep -i \"^content-security-policy: default-src 'none'; sandbox\"")
machine.succeed("rm /var/cache/ike/media/" + "a" * 64 + ".png")
machine.succeed("curl -fsS -D - -o /dev/null http://localhost/ | grep -i \"^content-security-policy: default-src 'none'; img-src http://media.localhost;\"")
# the secret is a credential of the unit's, not a file ike's user owns
machine.succeed("grep -qx not-a-secret /run/credentials/ike.service/oidc-secret")
machine.succeed("curl -fsS -H 'X-Forwarded-For: 203.0.113.77' http://localhost/health | grep -x ok")

# invariant 1: after all these requests, no address in any log or file
machine.fail("journalctl -u ike.service -u caddy.service --no-pager | grep -E '127\\.0\\.0\\.1:[0-9]+|::1|203\\.0\\.113|remote_ip|client_ip'")
machine.fail("ls /var/log/caddy/ | grep access")
machine.fail("grep -rE '127\\.0\\.0\\.1|::1|203\\.0\\.113' /var/lib/ike /var/cache/ike")

# sigterm is a clean stop, not a failure
machine.succeed("systemctl stop ike.service")
machine.fail("systemctl is-failed ike.service")
# and the pages are files: caddy serves them with ike down
machine.succeed("curl -fsS http://localhost/ | grep -q '<h1>ike</h1>'")
