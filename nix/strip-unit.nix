# ike's stripper, one instance per connection (hazard P1): it can reach
# nothing and change nothing but its scratch directory, within limits.
# shared by the unit on ike's host (strip.isolation = "sandbox"), the
# microvm (strip-microvm.nix) and a host of its own (strip-host.nix), so
# that the stripper is the same wherever it runs. a connection passed in
# by the socket is the instance's only way out: its own IP access list
# does not apply to that socket, and it can open no other
{ strip, maxBytes, maxSide, maxPixels, thumb, maxSeconds }: {
	description = "ike's stripper, for one upload";
	serviceConfig = {
		ExecStart = "${strip}/bin/ike-strip ${toString maxBytes} ${toString maxSide} ${toString maxPixels} ${toString thumb} ${toString maxSeconds}";
		StandardInput = "socket";
		StandardOutput = "socket";
		StandardError = "journal";
		DynamicUser = true;
		PrivateNetwork = true;
		IPAddressDeny = "any";
		RestrictAddressFamilies = "none";
		PrivateTmp = true;
		PrivateDevices = true;
		PrivateUsers = true;
		ProtectSystem = "strict";
		ProtectHome = true;
		ProtectProc = "invisible";
		ProcSubset = "pid";
		ProtectClock = true;
		ProtectHostname = true;
		ProtectKernelLogs = true;
		ProtectKernelModules = true;
		ProtectKernelTunables = true;
		ProtectControlGroups = true;
		NoNewPrivileges = true;
		LockPersonality = true;
		MemoryDenyWriteExecute = true;
		RestrictNamespaces = true;
		RestrictRealtime = true;
		RestrictSUIDSGID = true;
		CapabilityBoundingSet = "";
		SystemCallArchitectures = "native";
		SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
		UMask = "0077";
		MemoryMax = "1G";
		CPUQuota = "100%";
		TasksMax = 32;
		RuntimeMaxSec = 60;
	};
}
