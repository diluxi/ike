machine.wait_for_unit("ike.service")
machine.wait_for_open_port(8970)
machine.succeed("curl -fsS http://127.0.0.1:8970/health | grep -x ok")
# the schema was migrated into the state directory
machine.succeed("test -s /var/lib/ike/ike.db")

# caddy serves the rendered index from disk, with ike's headers, and
# passes on what is not a page
machine.wait_for_unit("caddy.service")
machine.wait_for_open_port(80)
machine.wait_for_file("/var/cache/ike/pages/index.html")
machine.succeed("curl -fsS http://localhost/ | cmp - /var/cache/ike/pages/index.html")
machine.succeed("curl -fsSI http://localhost/ | grep -i '^content-security-policy: default-src .none.'")
machine.succeed("curl -fsSI http://localhost/ | grep -i '^server: caddy'")
machine.succeed("curl -fsS http://localhost/health | grep -x ok")
machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost/t/1) = 404")
# and caddy reads the pages, never the database
machine.succeed("su -s /bin/sh caddy -c 'test -r /var/cache/ike/pages/index.html'")
machine.fail("su -s /bin/sh caddy -c 'test -r /var/lib/ike/ike.db'")

# invariant 1: after all these requests, no address in any log or file
machine.fail("journalctl -u ike.service -u caddy.service --no-pager | grep -E '127\\.0\\.0\\.1:[0-9]+|::1|remote_ip|client_ip'")
machine.fail("ls /var/log/caddy/ | grep access")
machine.fail("grep -rE '127\\.0\\.0\\.1|::1' /var/lib/ike /var/cache/ike")

# sigterm is a clean stop, not a failure
machine.succeed("systemctl stop ike.service")
machine.fail("systemctl is-failed ike.service")
# and the pages are files: caddy serves them with ike down
machine.succeed("curl -fsS http://localhost/ | grep -q '<h1>ike</h1>'")
