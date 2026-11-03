#!/usr/bin/env bash
# WSL2 helpers for install.sh (sourced). The places they look at can be redirected
# with PA_WSL_* / PA_RUN_USER_DIR, so the tests never touch the real /run or /mnt.

# Preflight on WSL only. A refusal is a die; a thing that merely limits the install is
# a warning, because a try-out without systemd still works.
pa_wsl_preflight() {
  local mnt="${PA_WSL_MNT_ROOT:-/mnt}"
  case "$PI_AGENT_HOME" in
    "$mnt"/*)
      die "PI_AGENT_HOME ($PI_AGENT_HOME) is on a Windows drive. Windows drives are slow from Linux and keep no Linux file permissions, which the Omnigent plugin needs. Install on the Linux filesystem (the default is under your Linux home)." ;;
  esac
  if [ ! -d "${PA_WSL_SYSTEMD_DIR:-/run/systemd/system}" ]; then
    warn "systemd is not running in this WSL distro, so Pi Agent will not start by itself. Turn it on: add [boot] systemd=true to /etc/wsl.conf, then run 'wsl --shutdown' in Windows PowerShell and open the distro again."
  fi
}

# systemd --user needs XDG_RUNTIME_DIR and the user bus. A login through PAM sets them;
# `wsl.exe -u USER --exec ...`, which is how the Windows-side installer runs this, is
# not a PAM login. Fill in what is missing from the uid.
pa_wsl_prepare_user_bus() {
  local dir; dir="${PA_RUN_USER_DIR:-/run/user}/$(id -u)"
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "$dir" ]; then
    export XDG_RUNTIME_DIR="$dir"
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -e "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
}
