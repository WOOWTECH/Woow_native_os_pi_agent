# N100 cold-start recovery

The native installer now pins pi-omnigent-plugin **0.3.32**, verified by SHA-256.
The official release incorporates WOOWTECH/pi-omnigent-plugin PR #29's 30-second
executable probe and matching lock deadline (PR #30 publishes the release).
Under a concurrent N100 cold boot the previous five-second probe could falsely
report installed engines missing. Native macOS/session-home/model-options/name
patches are revalidated against this release; unrelated authentication is unchanged.

On Linux/WSL, `install.sh wire service` installs `pi-agent-resume.py` and enables
`woow-native-connection.service` with Pi Web. It waits for an **already authorized
loopback HTTP server**, then invokes the plugin's supported `boot` lifecycle with
bounded retries. The service retains the host process's cgroup after the oneshot
finishes and stops/restarts with Pi Web. It never logs in, copies credentials,
changes host identity, or invokes an external model. Missing receipts and remote
servers are left to explicit setup and the plugin's existing lifecycle. Disconnect,
changed receipt, authorization failure and mismatched host ID stop recovery.

After upgrading an existing installation, run `install.sh fetch wire service`.
This replaces the plugin code but preserves its state and model logins. A newly
authorized host must outlive the terminal/temporary installer cgroup that started
it: after that installer exits, restart `woow-native-connection.service` and check
`bin/pi-omnigent status`. If an existing host already runs in another persistent
service, recovery uses it; it does not kill or take over that host.

Validation: isolated recovery tests cover unavailable local server, transient
boot failure, successful identity-preserving resume, missing/changed receipts,
remote servers, auth failure, identity mismatch and timeout. Existing native patch
and installer suites validate the official pinned artifact and patch composition.
The originating distribution's N100 physical reboot previously passed with this
recovery approach and a 0.3.31 probe overlay; that historical evidence is **not** a
claim that this new 0.3.32 native installer was physically rebooted on every OS.
macOS launchd is unchanged. See WOOWTECH/Woow_ubuntu_version_control, distribution/
docs/reboot-acceptance.md for the earlier physical evidence.
