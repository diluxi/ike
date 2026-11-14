machine.wait_for_unit("ike.service")
machine.wait_for_open_port(8970)
machine.succeed("curl -fsS http://127.0.0.1:8970/health | grep -x ok")
# the schema was migrated into the state directory
machine.succeed("test -s /var/lib/ike/ike.db")
# sigterm is a clean stop, not a failure
machine.succeed("systemctl stop ike.service")
machine.fail("systemctl is-failed ike.service")
