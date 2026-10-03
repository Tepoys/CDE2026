#!/usr/bin/env bash
# CDE Box 5 defensive toolkit controller
# Designed for Team 1 / Box 5 (Ubuntu 20.04 + MariaDB + SSH)
#
# IMPORTANT CDE RULE ASSUMPTIONS (Blue Team Packet v1.1):
# - Host -> competition box copying is allowed.
# - Competition box -> host copying is prohibited.
# - This script NEVER downloads files from the competition target.
# - clean-baseline downloads ONLY from a user-specified PRACTICE VM and
#   refuses to use the configured competition target as its source.
# - If deployed during CDE, publish this script/tooling at an unauthenticated
#   public URL first, as required by the scripting/tool rule.
#
# Usage examples:
#   ./cde.sh status
#   ./cde.sh clean-baseline 192.168.56.101
#   ./cde.sh compare-clean
#   ./cde.sh baseline
#   ./cde.sh compare
#   ./cde.sh users
#   ./cde.sh persistence
#   ./cde.sh network
#   ./cde.sh ssh
#   ./cde.sh mariadb
#   ./cde.sh audit
#
# Override defaults:
#   ./cde.sh --target 192.168.1.5 --user blueteam --port 22 status
#
# Environment equivalents:
#   CDE_TARGET, CDE_SSH_USER, CDE_SSH_PORT, CDE_CLEAN_DIR

set -euo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
DEFAULT_TARGET="${CDE_TARGET:-192.168.1.5}"
SSH_USER="${CDE_SSH_USER:-blueteam}"
SSH_PORT="${CDE_SSH_PORT:-22}"
CLEAN_DIR="${CDE_CLEAN_DIR:-$HOME/.cde-box5/known-clean}"
TARGET="$DEFAULT_TARGET"
REMOTE_HELPER="/tmp/cde-box5-helper-${USER:-user}-$$.sh"
REMOTE_CLEAN_TAR="/tmp/cde-known-clean-${USER:-user}-$$.tgz"
LOCAL_TMP=""

usage() {
  cat <<'USAGE'
CDE Box 5 Defensive Toolkit

Usage:
  cde.sh [global options] <command> [command options]

Global options:
  --target HOST     Competition Box 5 target (default: 192.168.1.5)
  --user USER       SSH user (default: blueteam)
  --port PORT       SSH port (default: 22)
  --clean-dir DIR   Local known-clean baseline directory
  -h, --help        Show help
  --version         Show version

Commands:
  clean-baseline PRACTICE_HOST
      Verify and capture a known-clean reference from a separate practice VM.
      The verifier requires Ubuntu 20.04 plus SSH and MariaDB to be installed
      and active. This is the ONLY command that copies data from a remote host
      to your machine, and it refuses to run when PRACTICE_HOST equals --target.

  status
      Fast health/status check for SSH, MariaDB, listeners, UID 0 accounts,
      failed units, and obvious high-confidence findings.

  baseline [--replace]
      Create the minute-zero baseline ON Box 5 at /root/.cde-baseline.
      Existing baseline is preserved unless --replace is explicitly supplied.

  compare
      Compare current Box 5 state against the minute-zero baseline on Box 5.

  compare-clean
      Upload the LOCAL known-clean reference to Box 5 temporarily, compare
      there, print the findings, and remove the temporary copy. No Box 5 files
      are downloaded to your host.

  users
      Accounts, UID 0, sudo, login shells, authorized_keys summary.

  persistence
      Cron, systemd local units/timers, suspicious ExecStart paths,
      authorized_keys, writable security-sensitive files.

  network
      Listening sockets and active connections.

  ssh
      SSH service and effective sshd configuration highlights.

  mariadb
      MariaDB service/listener/config/account checks. Uses local socket auth
      when available; does not embed or transmit database passwords.

  audit
      Full focused audit (status + users + persistence + network + ssh + DB).

Typical workflow:
  1. On your practice network:
       ./cde.sh clean-baseline <clean-ubuntu-vm-ip>
  2. At CDE minute zero:
       ./cde.sh status
       ./cde.sh compare-clean
       ./cde.sh baseline
  3. During CDE:
       ./cde.sh status
       ./cde.sh compare
       ./cde.sh audit
USAGE
}

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${LOCAL_TMP:-}" && -d "$LOCAL_TMP" ]]; then
    rm -rf "$LOCAL_TMP"
  fi
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required local command not found: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (("$1" >= 1 && "$1" <= 65535)) || die "Invalid SSH port: $1"
}

# Parse global options before command.
while [[ $# -gt 0 ]]; do
  case "$1" in
  --target)
    [[ $# -ge 2 ]] || die "--target requires a value"
    TARGET="$2"
    shift 2
    ;;
  --user)
    [[ $# -ge 2 ]] || die "--user requires a value"
    SSH_USER="$2"
    shift 2
    ;;
  --port)
    [[ $# -ge 2 ]] || die "--port requires a value"
    SSH_PORT="$2"
    shift 2
    ;;
  --clean-dir)
    [[ $# -ge 2 ]] || die "--clean-dir requires a value"
    CLEAN_DIR="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --version)
    echo "$VERSION"
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    die "Unknown global option: $1"
    ;;
  *)
    break
    ;;
  esac
done

[[ $# -ge 1 ]] || {
  usage
  exit 1
}
COMMAND="$1"
shift
validate_port "$SSH_PORT"

need_cmd ssh
need_cmd scp
need_cmd tar
need_cmd mktemp

LOCAL_TMP="$(mktemp -d)"
HELPER_LOCAL="$LOCAL_TMP/remote-helper.sh"

write_remote_helper() {
  cat >"$HELPER_LOCAL" <<'REMOTE_HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

BASELINE_DIR="/root/.cde-baseline"

say()   { printf '%s\n' "$*"; }
ok()    { printf '[OK]   %s\n' "$*"; }
info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*"; }
crit()  { printf '[CRIT] %s\n' "$*"; }
section(){ printf '\n========== %s ==========\n' "$*"; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

# Print a stable hash list for files under a target.
hash_target() {
  local target="$1"
  if [[ -f "$target" ]]; then
    sha256sum "$target" 2>/dev/null || true
  elif [[ -d "$target" ]]; then
    find "$target" -xdev -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 -r sha256sum 2>/dev/null || true
  fi
}

stat_target() {
  local target="$1"
  if [[ -e "$target" ]]; then
    find "$target" -xdev -printf '%m\t%u\t%g\t%p\n' 2>/dev/null || true
  fi
}

capture_snapshot() {
  local out="$1"
  rm -rf "$out"
  mkdir -p "$out"
  chmod 700 "$out"

  # System identity. Timestamp intentionally omitted so clean references stay stable.
  {
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "kernel=$(uname -r 2>/dev/null || true)"
    if [[ -r /etc/os-release ]]; then
      grep -E '^(ID|VERSION_ID|PRETTY_NAME)=' /etc/os-release || true
    fi
  } > "$out/system.txt"

  # Sensitive account files: hashes are useful for minute-zero change detection,
  # but are intentionally not used as the primary clean-reference semantic check.
  {
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
      [[ -f "$f" ]] && sha256sum "$f"
    done
  } | sort -k2 > "$out/account_file_hashes.txt"

  # Semantic local account/group views.
  awk -F: '{printf "%s\t%s\t%s\t%s\t%s\n",$1,$3,$4,$6,$7}' /etc/passwd \
    | sort > "$out/local_accounts.tsv"
  awk -F: '$3 == 0 {printf "%s\tUID=%s\tGID=%s\tHOME=%s\tSHELL=%s\n",$1,$3,$4,$6,$7}' /etc/passwd \
    | sort > "$out/uid0.txt"
  awk -F: '{printf "%s\t%s\t%s\n",$1,$3,$4}' /etc/group \
    | sort > "$out/local_groups.tsv"
  awk -F: '$7 !~ /(nologin|false)$/ {printf "%s\tUID=%s\tSHELL=%s\n",$1,$3,$7}' /etc/passwd \
    | sort > "$out/login_accounts.txt"

  # Config hashes for requested baseline areas, excluding account DBs above.
  {
    for t in /etc/pam.d /etc/sudoers /etc/sudoers.d /etc/security \
             /etc/sysctl.conf /etc/sysctl.d /etc/crontab /etc/fstab; do
      hash_target "$t"
    done
    find /etc -maxdepth 1 -type d -name 'cron.*' -print0 2>/dev/null \
      | while IFS= read -r -d '' d; do hash_target "$d"; done
  } | sort -k2 > "$out/config_hashes.txt"

  # Permissions/ownership for the requested areas.
  {
    for t in /etc/passwd /etc/shadow /etc/group /etc/gshadow \
             /etc/pam.d /etc/sudoers /etc/sudoers.d /etc/security \
             /etc/sysctl.conf /etc/sysctl.d /etc/crontab /etc/fstab; do
      stat_target "$t"
    done
    find /etc -maxdepth 1 -type d -name 'cron.*' -print0 2>/dev/null \
      | while IFS= read -r -d '' d; do stat_target "$d"; done
  } | sort -k4 > "$out/security_permissions.tsv"

  # Active sudo configuration.
  {
    if [[ -r /etc/sudoers ]]; then
      awk 'BEGIN{p="/etc/sudoers"} /^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print p ":" $0}' /etc/sudoers
    fi
    if [[ -d /etc/sudoers.d ]]; then
      find /etc/sudoers.d -maxdepth 1 -type f -print0 2>/dev/null \
        | sort -z \
        | while IFS= read -r -d '' f; do
            awk -v p="$f" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print p ":" $0}' "$f" 2>/dev/null || true
          done
    fi
  } | sort > "$out/sudo_rules.txt"

  # Active PAM configuration.
  if [[ -d /etc/pam.d ]]; then
    grep -RHE '^[[:space:]]*(auth|account|password|session)[[:space:]]' /etc/pam.d 2>/dev/null \
      | sort > "$out/pam_rules.txt" || true
  else
    : > "$out/pam_rules.txt"
  fi

  # sysctl config (static files) and runtime security-relevant values.
  {
    grep -RHE '^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true
  } | sort > "$out/sysctl_static.txt"

  {
    for k in \
      kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope \
      fs.protected_hardlinks fs.protected_symlinks \
      net.ipv4.ip_forward net.ipv4.conf.all.accept_redirects \
      net.ipv4.conf.default.accept_redirects net.ipv4.conf.all.send_redirects \
      net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies \
      net.ipv6.conf.all.accept_redirects; do
      sysctl "$k" 2>/dev/null || true
    done
  } | sort > "$out/sysctl_runtime.txt"

  # Cron and timers.
  {
    [[ -r /etc/crontab ]] && awk -v p="/etc/crontab" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print p ":" $0}' /etc/crontab
    if [[ -d /etc/cron.d ]]; then
      find /etc/cron.d -maxdepth 1 -type f -print0 2>/dev/null \
        | sort -z \
        | while IFS= read -r -d '' f; do
            awk -v p="$f" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print p ":" $0}' "$f" 2>/dev/null || true
          done
    fi
    for spool in /var/spool/cron/crontabs /var/spool/cron; do
      [[ -d "$spool" ]] || continue
      find "$spool" -maxdepth 1 -type f -print0 2>/dev/null \
        | sort -z \
        | while IFS= read -r -d '' f; do
            awk -v p="$f" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print p ":" $0}' "$f" 2>/dev/null || true
          done
    done
  } | sort > "$out/cron_rules.txt"

  if have systemctl; then
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
      | awk '{print $1"\t"$2}' | sort > "$out/systemd_unit_files.tsv" || true
    systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
      | awk '{print $1}' | sort > "$out/systemd_running.txt" || true
    systemctl list-timers --all --no-legend --no-pager 2>/dev/null \
      | awk 'NF>=2 {print $(NF-1)"\t"$NF}' | sort -u > "$out/systemd_timers.txt" || true
  else
    : > "$out/systemd_unit_files.tsv"
    : > "$out/systemd_running.txt"
    : > "$out/systemd_timers.txt"
  fi

  {
    for d in /etc/systemd/system /usr/local/lib/systemd/system; do
      [[ -d "$d" ]] || continue
      find "$d" -type f -print0 2>/dev/null \
        | sort -z \
        | xargs -0 -r sha256sum 2>/dev/null || true
    done
  } | sort -k2 > "$out/systemd_local_hashes.txt"

  # Normalized listening ports: protocol + local port only (no PID/time noise).
  if have ss; then
    ss -H -lntu 2>/dev/null \
      | awk '{addr=$5; sub(/^.*:/,"",addr); print $1"\t"addr}' \
      | sort -u > "$out/listeners.tsv" || true
  else
    : > "$out/listeners.tsv"
  fi

  # Authorized keys: location, ownership/mode, and hash, but not key contents.
  {
    find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -print0 2>/dev/null \
      | sort -z \
      | while IFS= read -r -d '' f; do
          printf '%s\t' "$f"
          stat -c '%a\t%U\t%G\t' "$f" 2>/dev/null || printf '?\t?\t?\t'
          sha256sum "$f" 2>/dev/null | awk '{print $1}' || true
        done
  } > "$out/authorized_keys.tsv"

  # SUID/SGID inventory on the root filesystem.
  find / -xdev -type f \( -perm -4000 -o -perm -2000 \) \
    -printf '%m\t%u\t%g\t%p\n' 2>/dev/null \
    | sort -k4 > "$out/suid_sgid.tsv" || true

  # fstab semantic view.
  if [[ -r /etc/fstab ]]; then
    awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print}' /etc/fstab | sort > "$out/fstab.txt"
  else
    : > "$out/fstab.txt"
  fi

  # SSH effective configuration.
  if have sshd; then
    sshd -T 2>/dev/null | sort > "$out/sshd_effective.txt" || true
  else
    : > "$out/sshd_effective.txt"
  fi

  # MariaDB service/config/user metadata. No password is embedded.
  {
    if have systemctl; then
      printf 'service_active='; systemctl is-active mariadb 2>/dev/null || true
      printf 'service_enabled='; systemctl is-enabled mariadb 2>/dev/null || true
    fi
    if have mariadb; then mariadb --version 2>/dev/null || true
    elif have mysql; then mysql --version 2>/dev/null || true
    fi
    grep -RHE '^[[:space:]]*(bind-address|port)[[:space:]]*=' /etc/mysql /etc/my.cnf 2>/dev/null || true
    if have mariadb && mariadb -NBe 'SELECT 1' >/dev/null 2>&1; then
      mariadb -NBe "SELECT CONCAT(User,'@',Host) FROM mysql.user ORDER BY User,Host" 2>/dev/null || true
    elif have mysql && mysql -NBe 'SELECT 1' >/dev/null 2>&1; then
      mysql -NBe "SELECT CONCAT(User,'@',Host) FROM mysql.user ORDER BY User,Host" 2>/dev/null || true
    else
      echo 'db_account_query=unavailable_without_auth'
    fi
  } | sort > "$out/mariadb.txt"

  # Package list is informational; it can be noisy across images/patch levels.
  if have dpkg-query; then
    dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort > "$out/packages.tsv" || true
  else
    : > "$out/packages.tsv"
  fi

  # Snapshot manifest.
  (cd "$out" && find . -maxdepth 1 -type f ! -name manifest.sha256 -print0 \
    | sort -z | xargs -0 -r sha256sum) > "$out/manifest.sha256"
}

show_service_health() {
  section "SCORED SERVICE HEALTH"
  if have systemctl; then
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
      ok "SSH service active"
    else
      crit "SSH service is not active"
    fi
    if systemctl is-active --quiet mariadb 2>/dev/null; then
      ok "MariaDB service active"
    else
      crit "MariaDB service is not active"
    fi
  else
    warn "systemctl unavailable"
  fi

  if have ss; then
    if ss -H -lnt 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)22$'; then
      ok "TCP/22 is listening"
    else
      crit "TCP/22 is NOT listening"
    fi
    if ss -H -lnt 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)3306$'; then
      ok "TCP/3306 is listening"
    else
      crit "TCP/3306 is NOT listening"
    fi
  fi
}

high_confidence_checks() {
  section "HIGH-CONFIDENCE SECURITY CHECKS"
  local found=0

  # Additional UID 0 accounts.
  while IFS=: read -r user _ uid _; do
    if [[ "$uid" == "0" && "$user" != "root" ]]; then
      crit "Additional UID 0 account: $user"
      found=1
    fi
  done < /etc/passwd

  # NOPASSWD sudo rules.
  if grep -RHE '^[[:space:]]*[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q .; then
    warn "NOPASSWD sudo rule(s) present:"
    grep -RHE '^[[:space:]]*[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | sed 's/^/       /' || true
    found=1
  fi

  # Writable security-sensitive files/directories.
  local writable
  writable="$(find /etc/sudoers /etc/sudoers.d /etc/pam.d /etc/security /etc/systemd/system /etc/cron.d \
      -xdev \( -type f -o -type d \) -perm -0002 -print 2>/dev/null | head -n 30 || true)"
  if [[ -n "$writable" ]]; then
    crit "World-writable security/persistence paths found:"
    printf '%s\n' "$writable" | sed 's/^/       /'
    found=1
  fi

  # Systemd units executing from high-risk writable/temp locations.
  if [[ -d /etc/systemd/system ]]; then
    local suspect_units
    suspect_units="$(grep -RHE '^[[:space:]]*Exec(Start|StartPre|StartPost)=.*(/tmp/|/var/tmp/|/dev/shm/)' /etc/systemd/system 2>/dev/null || true)"
    if [[ -n "$suspect_units" ]]; then
      crit "systemd unit executes from temporary memory/writable path:"
      printf '%s\n' "$suspect_units" | sed 's/^/       /'
      found=1
    fi
  fi

  # Cron invoking common temp locations.
  local suspect_cron
  suspect_cron="$(grep -RHE '^[[:space:]]*[^#].*(/tmp/|/var/tmp/|/dev/shm/)' /etc/crontab /etc/cron.d /var/spool/cron 2>/dev/null || true)"
  if [[ -n "$suspect_cron" ]]; then
    crit "Cron entry references temporary/writable path:"
    printf '%s\n' "$suspect_cron" | sed 's/^/       /'
    found=1
  fi

  # Unexpected listeners relative to the two Box 5 scored service ports.
  if have ss; then
    local extras
    extras="$(ss -H -lntu 2>/dev/null | awk '{a=$5; sub(/^.*:/,"",a); if (a != "22" && a != "3306") print $1"/"a}' | sort -u || true)"
    if [[ -n "$extras" ]]; then
      warn "Listeners besides TCP/22 and TCP/3306 exist (investigate; may be legitimate dependencies):"
      printf '%s\n' "$extras" | sed 's/^/       /'
      found=1
    fi
  fi

  [[ "$found" -eq 0 ]] && ok "No high-confidence findings from this ruleset"
  return 0
}

show_status() {
  need_root
  section "BOX 5 QUICK STATUS"
  info "Host: $(hostname)"
  info "OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  show_service_health

  section "UID 0 ACCOUNTS"
  awk -F: '$3 == 0 {printf "%s\tUID=%s\tSHELL=%s\n",$1,$3,$7}' /etc/passwd

  section "FAILED SYSTEMD UNITS"
  if have systemctl; then
    systemctl --failed --no-pager --no-legend 2>/dev/null || true
  fi

  section "LISTENING SOCKETS"
  if have ss; then
    ss -lntup 2>/dev/null || true
  fi

  high_confidence_checks
}

show_users() {
  need_root
  section "LOCAL ACCOUNTS"
  awk -F: '{printf "%-24s uid=%-6s gid=%-6s shell=%s\n",$1,$3,$4,$7}' /etc/passwd

  section "UID 0"
  awk -F: '$3 == 0 {print}' /etc/passwd

  section "LOGIN-CAPABLE LOCAL ACCOUNTS"
  awk -F: '$7 !~ /(nologin|false)$/ {printf "%s\t%s\t%s\n",$1,$3,$7}' /etc/passwd

  section "SUDO RULES"
  grep -RHE '^[[:space:]]*[^#[:space:]].*' /etc/sudoers /etc/sudoers.d 2>/dev/null || true

  section "AUTHORIZED_KEYS LOCATIONS"
  find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) \
    -printf '%m %u %g %p\n' 2>/dev/null || true

  section "CURRENT LOGINS"
  who 2>/dev/null || true
  w -h 2>/dev/null || true

  section "RECENT LOGINS"
  last -a -n 30 2>/dev/null || true
}

show_persistence() {
  need_root
  section "SYSTEMD LOCAL UNITS"
  find /etc/systemd/system /usr/local/lib/systemd/system -type f \
    -printf '%m %u %g %p\n' 2>/dev/null | sort || true

  section "ENABLED SERVICES"
  if have systemctl; then
    systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null || true
  fi

  section "SYSTEMD TIMERS"
  if have systemctl; then
    systemctl list-timers --all --no-pager 2>/dev/null || true
  fi

  section "CRON"
  [[ -r /etc/crontab ]] && cat /etc/crontab
  if [[ -d /etc/cron.d ]]; then
    find /etc/cron.d -maxdepth 1 -type f -print0 2>/dev/null \
      | sort -z \
      | while IFS= read -r -d '' f; do echo "--- $f"; cat "$f"; done
  fi
  for spool in /var/spool/cron/crontabs /var/spool/cron; do
    [[ -d "$spool" ]] || continue
    find "$spool" -maxdepth 1 -type f -print0 2>/dev/null \
      | sort -z \
      | while IFS= read -r -d '' f; do echo "--- $f"; cat "$f"; done
  done

  section "AUTHORIZED_KEYS"
  find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) \
    -printf '%m %u %g %p\n' 2>/dev/null || true

  high_confidence_checks
}

show_network() {
  need_root
  section "LISTENING SOCKETS"
  ss -lntup 2>/dev/null || true

  section "ESTABLISHED TCP CONNECTIONS"
  ss -H -tnp state established 2>/dev/null || true

  section "ROUTES"
  ip route 2>/dev/null || true
}

show_ssh() {
  need_root
  section "SSH SERVICE"
  if have systemctl; then
    systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || true
  fi

  section "SSHD EFFECTIVE SECURITY-RELEVANT SETTINGS"
  if have sshd; then
    sshd -T 2>/dev/null \
      | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|usepam|allowusers|allowgroups|denyusers|denygroups|maxauthtries|x11forwarding|allowtcpforwarding|permituserenvironment|authorizedkeysfile) ' \
      | sort || true
  else
    warn "sshd binary not found"
  fi

  section "SSHD CONFIG FILES"
  find /etc/ssh -maxdepth 2 -type f -name 'sshd_config*' -printf '%m %u %g %p\n' 2>/dev/null || true
}

show_mariadb() {
  need_root
  section "MARIADB SERVICE"
  if have systemctl; then
    systemctl status mariadb --no-pager 2>/dev/null || true
  fi

  section "TCP/3306"
  ss -lntup 2>/dev/null | grep -E '(^|:)3306([[:space:]]|$)' || warn "No TCP/3306 listener shown"

  section "MARIADB VERSION"
  if have mariadb; then mariadb --version 2>/dev/null || true
  elif have mysql; then mysql --version 2>/dev/null || true
  else warn "No mariadb/mysql client found"
  fi

  section "MARIADB NETWORK CONFIG"
  grep -RHE '^[[:space:]]*(bind-address|port)[[:space:]]*=' /etc/mysql /etc/my.cnf 2>/dev/null || true

  section "DATABASE ACCOUNTS (socket auth if available)"
  if have mariadb && mariadb -NBe 'SELECT 1' >/dev/null 2>&1; then
    mariadb -NBe "SELECT User,Host,plugin FROM mysql.user ORDER BY User,Host" 2>/dev/null || true
  elif have mysql && mysql -NBe 'SELECT 1' >/dev/null 2>&1; then
    mysql -NBe "SELECT User,Host,plugin FROM mysql.user ORDER BY User,Host" 2>/dev/null || true
  else
    warn "Could not query mysql.user without credentials. No password is embedded by this tool."
  fi
}

report_diff() {
  local label="$1" base="$2" cur="$3" max_lines="${4:-80}"
  if [[ ! -e "$base" || ! -e "$cur" ]]; then
    warn "$label: comparison file missing"
    return 0
  fi
  if cmp -s "$base" "$cur"; then
    ok "$label unchanged"
  else
    warn "$label changed"
    diff -u "$base" "$cur" 2>/dev/null | sed -n "1,${max_lines}p" || true
    local total
    total="$(diff -u "$base" "$cur" 2>/dev/null | wc -l | tr -d ' ' || true)"
    if [[ "${total:-0}" -gt "$max_lines" ]]; then
      info "$label diff truncated to first $max_lines lines (total diff lines: $total)"
    fi
  fi
}

compare_dirs() {
  local base="$1" cur="$2" mode="$3"
  section "COMPARISON: $mode"

  if [[ "$mode" == "minute-zero" ]]; then
    report_diff "Account database hashes" "$base/account_file_hashes.txt" "$cur/account_file_hashes.txt"
  else
    info "Clean comparison intentionally ignores account database file hashes (password/account state is expected to differ)."
  fi

  report_diff "Local accounts" "$base/local_accounts.tsv" "$cur/local_accounts.tsv"
  report_diff "UID 0 accounts" "$base/uid0.txt" "$cur/uid0.txt"
  report_diff "Login-capable local accounts" "$base/login_accounts.txt" "$cur/login_accounts.txt"
  report_diff "Local groups" "$base/local_groups.tsv" "$cur/local_groups.tsv"
  report_diff "Security config hashes" "$base/config_hashes.txt" "$cur/config_hashes.txt"
  report_diff "Security-sensitive permissions" "$base/security_permissions.tsv" "$cur/security_permissions.tsv"
  report_diff "Sudo rules" "$base/sudo_rules.txt" "$cur/sudo_rules.txt"
  report_diff "PAM rules" "$base/pam_rules.txt" "$cur/pam_rules.txt"
  report_diff "Static sysctl" "$base/sysctl_static.txt" "$cur/sysctl_static.txt"
  report_diff "Runtime sysctl subset" "$base/sysctl_runtime.txt" "$cur/sysctl_runtime.txt"
  report_diff "Cron rules" "$base/cron_rules.txt" "$cur/cron_rules.txt"
  report_diff "Systemd unit-file states" "$base/systemd_unit_files.tsv" "$cur/systemd_unit_files.tsv"
  report_diff "Running services" "$base/systemd_running.txt" "$cur/systemd_running.txt"
  report_diff "Systemd timers" "$base/systemd_timers.txt" "$cur/systemd_timers.txt"
  report_diff "Local systemd unit hashes" "$base/systemd_local_hashes.txt" "$cur/systemd_local_hashes.txt"
  report_diff "Listening ports" "$base/listeners.tsv" "$cur/listeners.tsv"
  report_diff "authorized_keys metadata/hashes" "$base/authorized_keys.tsv" "$cur/authorized_keys.tsv"
  report_diff "SUID/SGID inventory" "$base/suid_sgid.tsv" "$cur/suid_sgid.tsv"
  report_diff "fstab" "$base/fstab.txt" "$cur/fstab.txt"
  report_diff "Effective sshd configuration" "$base/sshd_effective.txt" "$cur/sshd_effective.txt"
  report_diff "MariaDB metadata" "$base/mariadb.txt" "$cur/mariadb.txt"

  if [[ "$mode" == "clean-reference" ]]; then
    section "CLEAN-REFERENCE NOTES"
    info "Package/version differences are not auto-flagged because patch/image levels may legitimately differ."
    info "Domain-join configuration is not modeled because the packet does not identify its implementation."
    info "A difference means INVESTIGATE, not automatically malicious or safe to remove."
  fi

  high_confidence_checks
}

cmd_verify_practice() {
  need_root
  section "PRACTICE VM MODEL CHECK"
  local failures=0
  local version_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    version_id="${VERSION_ID:-}"
    info "OS: ${PRETTY_NAME:-unknown}"
  fi
  if [[ "$version_id" == "20.04" ]]; then
    ok "Ubuntu VERSION_ID is 20.04"
  else
    crit "Practice VM is not Ubuntu 20.04 (VERSION_ID=${version_id:-unknown})"
    failures=1
  fi

  if have sshd; then ok "OpenSSH server binary present"; else crit "sshd is not installed"; failures=1; fi
  if have mariadbd || have mysqld; then ok "MariaDB/MySQL server binary present"; else crit "MariaDB/MySQL server is not installed"; failures=1; fi

  if have systemctl; then
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
      ok "SSH service active"
    else
      crit "SSH service is not active"
      failures=1
    fi
    if systemctl is-active --quiet mariadb 2>/dev/null; then
      ok "MariaDB service active"
    else
      crit "MariaDB service is not active"
      failures=1
    fi
  fi

  if have ss; then
    if ss -H -lnt 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)22$'; then
      ok "TCP/22 listener present"
    else
      crit "TCP/22 listener missing"
      failures=1
    fi
    if ss -H -lnt 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)3306$'; then
      ok "TCP/3306 listener present (local-only binding is acceptable for the clean reference)"
    else
      crit "TCP/3306 listener missing"
      failures=1
    fi
  fi

  info "The CDE packet says Box 5 is domain joined, but does not specify the join implementation."
  info "Domain-join configuration is therefore deliberately NOT required by this practice-model check."

  [[ "$failures" -eq 0 ]] || {
    echo "Practice VM does not yet match the packet-supported Box 5 core characteristics." >&2
    exit 3
  }
  ok "Practice VM satisfies the packet-supported core model for clean baselining"
}

cmd_baseline() {
  need_root
  local replace="${1:-no}"
  if [[ -e "$BASELINE_DIR" && "$replace" != "yes" ]]; then
    echo "Baseline already exists at $BASELINE_DIR. Refusing to overwrite." >&2
    echo "Re-run with baseline --replace only if you intentionally want a new reference." >&2
    exit 2
  fi
  if [[ -e "$BASELINE_DIR" ]]; then
    local backup="${BASELINE_DIR}.previous.$(date +%Y%m%d_%H%M%S)"
    mv "$BASELINE_DIR" "$backup"
    info "Previous baseline moved to $backup"
  fi
  capture_snapshot "$BASELINE_DIR"
  chmod -R go-rwx "$BASELINE_DIR"
  ok "Minute-zero baseline created ON BOX at $BASELINE_DIR"
}

cmd_compare() {
  need_root
  [[ -d "$BASELINE_DIR" ]] || { echo "No minute-zero baseline at $BASELINE_DIR" >&2; exit 2; }
  local cur
  cur="$(mktemp -d /root/.cde-current.XXXXXX)"
  trap 'rm -rf "$cur"' RETURN
  capture_snapshot "$cur"
  compare_dirs "$BASELINE_DIR" "$cur" "minute-zero"
  rm -rf "$cur"
  trap - RETURN
}

cmd_export_clean() {
  need_root
  local tar_path="$1" owner="$2"
  local tmp
  tmp="$(mktemp -d /tmp/cde-clean-capture.XXXXXX)"
  capture_snapshot "$tmp/snapshot"
  tar -C "$tmp/snapshot" -czf "$tar_path" .
  chown "$owner" "$tar_path" 2>/dev/null || true
  chmod 600 "$tar_path"
  rm -rf "$tmp"
  ok "Clean reference export prepared at $tar_path"
}

cmd_compare_clean_tar() {
  need_root
  local tar_path="$1"
  [[ -f "$tar_path" ]] || { echo "Clean tar not found: $tar_path" >&2; exit 2; }
  local work clean cur
  work="$(mktemp -d /root/.cde-clean-compare.XXXXXX)"
  clean="$work/clean"
  cur="$work/current"
  mkdir -p "$clean"
  tar -C "$clean" -xzf "$tar_path"
  capture_snapshot "$cur"
  compare_dirs "$clean" "$cur" "clean-reference"
  rm -rf "$work" "$tar_path"
}

cmd_audit() {
  show_status
  show_users
  show_persistence
  show_network
  show_ssh
  show_mariadb
}

main() {
  need_root
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    status) show_status ;;
    users) show_users ;;
    persistence) show_persistence ;;
    network) show_network ;;
    ssh) show_ssh ;;
    mariadb) show_mariadb ;;
    audit) cmd_audit ;;
    baseline) cmd_baseline "${1:-no}" ;;
    compare) cmd_compare ;;
    verify-practice) cmd_verify_practice ;;
    export-clean) cmd_export_clean "$@" ;;
    compare-clean-tar) cmd_compare_clean_tar "$@" ;;
    *) echo "Unknown remote helper command: $cmd" >&2; exit 2 ;;
  esac
}

main "$@"
REMOTE_HELPER_EOF
  chmod 700 "$HELPER_LOCAL"
}

write_remote_helper

SSH_DEST="${SSH_USER}@${TARGET}"
SSH_ARGS=(-p "$SSH_PORT")
SCP_ARGS=(-P "$SSH_PORT")

# Upload helper to an unprivileged path, then root installs it before execution.
deploy_helper() {
  local host="$1"
  local dest="${SSH_USER}@${host}"
  local remote="$REMOTE_HELPER"
  scp "${SCP_ARGS[@]}" -q "$HELPER_LOCAL" "$dest:$remote"
  printf '%s' "$remote"
}

# Run a remote helper command with interactive sudo. The helper is copied
# host -> box (allowed by packet v1.1), installed root-owned, executed, then removed.
run_remote() {
  local host="$1"
  shift
  local remote
  remote="$(deploy_helper "$host")"
  local root_helper="/root/.cde-box5-helper-$$.sh"

  local quoted=""
  local arg
  for arg in "$@"; do
    printf -v quoted '%s %q' "$quoted" "$arg"
  done

  ssh -t "${SSH_ARGS[@]}" "${SSH_USER}@${host}" \
    "set -e; sudo install -o root -g root -m 700 '$remote' '$root_helper'; rm -f '$remote'; set +e; sudo bash '$root_helper'$quoted; rc=\$?; sudo rm -f '$root_helper'; exit \$rc"
}

# Same as run_remote, but intended for practice VM source. Kept separate so the
# CDE no-copy rule is easy to reason about.
run_practice_remote() {
  local host="$1"
  shift
  local dest="${SSH_USER}@${host}"
  local remote="$REMOTE_HELPER"
  scp "${SCP_ARGS[@]}" -q "$HELPER_LOCAL" "$dest:$remote"
  local root_helper="/root/.cde-box5-helper-$$.sh"
  local quoted=""
  local arg
  for arg in "$@"; do printf -v quoted '%s %q' "$quoted" "$arg"; done
  ssh -t "${SSH_ARGS[@]}" "$dest" \
    "set -e; sudo install -o root -g root -m 700 '$remote' '$root_helper'; rm -f '$remote'; set +e; sudo bash '$root_helper'$quoted; rc=\$?; sudo rm -f '$root_helper'; exit \$rc"
}

clean_baseline() {
  [[ $# -ge 1 ]] || die "clean-baseline requires PRACTICE_HOST"
  local practice="$1"

  if [[ "$practice" == "$TARGET" ]]; then
    die "Refusing: practice host equals competition target ($TARGET). clean-baseline copies data back to your host and must NEVER be used on the CDE box."
  fi

  log "Capturing known-clean reference from PRACTICE VM: $practice"
  log "This operation copies baseline metadata FROM the practice VM to your host."
  log "It is intentionally blocked when the source equals the configured CDE target."

  log "Verifying the practice VM matches the packet-supported core model..."
  run_practice_remote "$practice" verify-practice

  local remote_tar="/tmp/cde-clean-export-${USER:-user}-$$.tgz"
  run_practice_remote "$practice" export-clean "$remote_tar" "$SSH_USER"

  local downloaded="$LOCAL_TMP/known-clean.tgz"
  scp "${SCP_ARGS[@]}" -q "${SSH_USER}@${practice}:$remote_tar" "$downloaded"
  ssh "${SSH_ARGS[@]}" "${SSH_USER}@${practice}" "rm -f '$remote_tar'" || true

  [[ -s "$downloaded" ]] || die "Practice baseline download failed or is empty"

  local staging="$LOCAL_TMP/staging-clean"
  mkdir -p "$staging"
  tar -C "$staging" -xzf "$downloaded"
  [[ -f "$staging/manifest.sha256" ]] || die "Clean baseline archive is missing manifest.sha256"

  if [[ -d "$CLEAN_DIR" ]]; then
    local backup="${CLEAN_DIR}.previous.$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$(dirname "$CLEAN_DIR")"
    mv "$CLEAN_DIR" "$backup"
    log "Previous known-clean reference moved to: $backup"
  fi
  mkdir -p "$(dirname "$CLEAN_DIR")"
  mv "$staging" "$CLEAN_DIR"
  chmod -R go-rwx "$CLEAN_DIR"

  cat >"$CLEAN_DIR/CDE_EXPECTATIONS.txt" <<EOF_EXPECT
Known packet-derived Box 5 expectations used by this toolkit:
- OS family/version target: Ubuntu 20.04
- Scored SSH service: TCP/22
- Scored MariaDB/MySQL service: TCP/3306
- Expected local Blue Team account: blueteam
- Expected database account named by packet: airship
- Protected/out-of-scope competition accounts: scorebot, blackteam, red_scoring
- Domain joined: yes, but the packet does not specify the implementation, so
  domain-join configuration is NOT modeled by the clean baseline.
EOF_EXPECT
  chmod 600 "$CLEAN_DIR/CDE_EXPECTATIONS.txt"

  log "Known-clean baseline saved locally: $CLEAN_DIR"
  log "Recommended next step: inspect the practice VM differences you intentionally want to model, then use 'compare-clean' at CDE."
}

compare_clean() {
  [[ -d "$CLEAN_DIR" ]] || die "No known-clean baseline found at $CLEAN_DIR. Run clean-baseline against your practice VM first."
  [[ -f "$CLEAN_DIR/manifest.sha256" ]] || die "Known-clean baseline is incomplete: manifest.sha256 missing"

  log "Packaging LOCAL known-clean reference for temporary host -> Box 5 upload."
  local tarball="$LOCAL_TMP/known-clean-upload.tgz"
  tar -C "$CLEAN_DIR" -czf "$tarball" .
  scp "${SCP_ARGS[@]}" -q "$tarball" "${SSH_USER}@${TARGET}:$REMOTE_CLEAN_TAR"

  # Deploy helper and compare entirely on Box 5. No Box 5 files are downloaded.
  run_remote "$TARGET" compare-clean-tar "$REMOTE_CLEAN_TAR"
}

case "$COMMAND" in
clean-baseline)
  ;;
status)
  [[ $# -eq 0 ]] || die "status takes no arguments"
  run_remote "$TARGET" status
  ;;
baseline)
  replace="no"
  if [[ "${1:-}" == "--replace" ]]; then
    replace="yes"
    shift
  fi
  [[ $# -eq 0 ]] || die "baseline only accepts optional --replace"
  run_remote "$TARGET" baseline "$replace"
  ;;
compare)
  [[ $# -eq 0 ]] || die "compare takes no arguments"
  run_remote "$TARGET" compare
  ;;
compare-clean)
  [[ $# -eq 0 ]] || die "compare-clean takes no arguments"
  compare_clean
  ;;
users | persistence | network | ssh | mariadb | audit)
  [[ $# -eq 0 ]] || die "$COMMAND takes no arguments"
  run_remote "$TARGET" "$COMMAND"
  ;;
help)
  usage
  ;;
*)
  die "Unknown command: $COMMAND (run with --help)"
  ;;
esac
