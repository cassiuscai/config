#!/usr/bin/env bash
#
# install.sh — one-shot setup for a fresh machine:
#
#   * switches system package mirrors to USTC (mirrors.ustc.edu.cn)
#   * installs basic packages (curl, git, htop, neovim)
#   * sets up virtualization on headless servers (no desktop): libvirt/QEMU
#     with KVM acceleration on Debian, bhyve/vm-bhyve on FreeBSD — macOS is
#     skipped
#   * sets up Homebrew / Linuxbrew with BFSU mirrors (mirrors.bfsu.edu.cn)
#   * installs the Nix package manager (Linux: multi-user daemon; macOS: default)
#   * initializes an ed25519 SSH key for the target user (if missing)
#   * bootstraps sudo for the target user (minimal installs)
#
# Supported platforms:
#   debian  — apt (deb822) → mirrors.ustc.edu.cn, Linuxbrew at /home/linuxbrew
#   macos   — Homebrew     → mirrors.bfsu.edu.cn (brew/core/cask/bottles)
#   freebsd — pkg          → mirrors.ustc.edu.cn/freebsd-pkg (no Homebrew)
#
# Extensible by design: every platform implements the same small set of step
# functions and is registered in SUPPORTED_OS. To add a new OS, see the
# "Platform registry" section below — dispatch is automatic.
#
# Usage:
#   sudo ./install.sh [--username USER] [--profile PROFILE]   # Deb/FreeBSD
#   ./install.sh [--username USER] [--profile PROFILE]        # macOS
#
#   --username  target user (flag > SUDO_USER > current user > interactive)
#   --profile   'server' or 'client'; prompted interactively if not given:
#               server — full setup incl. the virtualization stack (vmm)
#               client — skip vmm (no local VM management), passwordless sudo
#
# The virtualization step (vmm) is skipped for the 'client' profile on every
# platform. On the server profile it installs libvirt/QEMU+libvirtd (Debian)
# or bhyve/vm-bhyve (FreeBSD); macOS has no vmm step in either profile.
#
# The 'client' profile also grants the target user passwordless sudo
# (NOPASSWD); 'server' keeps password-protected sudo.
#
# The target user (CLI arg > SUDO_USER > current user > interactive prompt)
# gets sudo privileges and owns the Homebrew install. If prompted, the sole
# login user is suggested as the default.
set -euo pipefail

# --- shared config ---------------------------------------------------------

BASIC_PACKAGES=(curl git htop neovim just)

# BFSU Homebrew mirrors (https://mirrors.bfsu.edu.cn/help/homebrew/). USTC's
# brew mirror proved TLS-unstable, so git remotes, bottles, the JSON API and
# the installer repo all come from BFSU. HOMEBREW_INSTALL_FROM_API=1 makes
# brew use the API JSON instead of cloning the huge homebrew-core repo.
BREW_GIT_REMOTE='https://mirrors.bfsu.edu.cn/git/homebrew/brew.git'
BREW_CORE_GIT_REMOTE='https://mirrors.bfsu.edu.cn/git/homebrew/homebrew-core.git'
BREW_CASK_GIT_REMOTE='https://mirrors.bfsu.edu.cn/git/homebrew/homebrew-cask.git'
BREW_BOTTLE_DOMAIN='https://mirrors.bfsu.edu.cn/homebrew-bottles'
BREW_API_DOMAIN='https://mirrors.bfsu.edu.cn/homebrew-bottles/api'
BREW_INSTALL_GIT='https://mirrors.bfsu.edu.cn/git/homebrew/install.git'
BREW_INSTALL_FROM_API=1
# Upstream fallback for the installer *script* only (mirror TLS has been
# flaky from some networks) — brew's git/bottle/API mirrors stay on BFSU.
BREW_INSTALL_URL='https://github.com/Homebrew/install/raw/HEAD/install.sh'

NIX_INSTALL_URL='https://mirrors.bfsu.edu.cn/nix/latest/install'

# --- helpers ---------------------------------------------------------------

say()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

# Interactive prompt. Reads from the controlling terminal (/dev/tty) when one
# is available so prompts keep working even when stdin is a pipe (e.g. under
# `curl ... | sudo bash`); falls back to stdin when there is no tty.
prompt() {
  local msg="$1" reply="" tty
  printf '%s' "${msg}" >&2
  if [[ -r /dev/tty ]]; then
    if ! read -r reply < /dev/tty; then
      return 1
    fi
  elif ! read -r reply; then
    return 1
  fi
  printf '%s\n' "${reply}"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "must run as root (directly, or via: sudo $0)"
  fi
}

# Resolve the target user's home directory across platforms.
user_home() {
  local user="$1" home
  home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)"
  if [[ -z "${home}" ]]; then
    home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  fi
  printf '%s\n' "${home:-}"
}

# Run a command as <user>: directly when we are that user, via sudo when root.
run_as_user() {
  local user="$1"; shift
  if [[ ${EUID} -ne 0 ]]; then
    if [[ "$(id -un)" != "${user}" ]]; then
      die "running as '$(id -un)' but target user is '${user}' — re-run via sudo"
    fi
    "$@"
    return 0
  fi
  sudo -u "${user}" -H "$@"
}

# Append a marker-guarded block to a file (idempotent).
# Usage: write_marked_block <file> <marker> <line>...
write_marked_block() {
  local file="$1" marker="$2"
  shift 2
  if [[ -f "${file}" ]] && grep -qF "${marker}" "${file}"; then
    say "already configured: ${file} (${marker})"
    return 0
  fi
  mkdir -p "$(dirname "${file}")"
  {
    printf '\n# === %s ===\n' "${marker}"
    printf '%s\n' "$@"
    printf '# === end %s ===\n' "${marker}"
  } >> "${file}"
  say "configured: ${file} (${marker})"
}

# Is the Nix package manager already installed? (multi-user installs live in /nix)
nix_installed() {
  [[ -x /nix/var/nix/profiles/default/bin/nix ]] || command -v nix >/dev/null 2>&1
}

# Initialize an ed25519 SSH key for <user> if none exists. Passphrase-less so
# the bootstrap runs non-interactively; add a passphrase later with
# `ssh-keygen -p`. No comment (e.g. email) is embedded in the key.
ensure_ssh_key() {
  local user="$1"
  local home key
  home="$(user_home "${user}")"
  key="${home}/.ssh/id_ed25519"
  if [[ -f "${key}" ]]; then
    say "SSH key exists at ${key}"
    return 0
  fi
  say "creating SSH key ${key} ..."
  if ! run_as_user "${user}" bash -c "mkdir -p \"${home}/.ssh\" && chmod 700 \"${home}/.ssh\" && ssh-keygen -t ed25519 -C '' -N '' -f \"${key}\""; then
    die "failed to create SSH key — check the output above"
  fi
  say "done — SSH key ready at ${key}"
}

# SSH key init is identical on every platform — one shared implementation.
platform_ssh_debian()  { ensure_ssh_key "$1"; }
platform_ssh_macos()   { ensure_ssh_key "$1"; }
platform_ssh_freebsd() { ensure_ssh_key "$1"; }

resolve_target_user() {
  local arg_user="${1:-}"
  if [[ -n "${arg_user}" ]]; then
    printf '%s\n' "${arg_user}"
    return 0
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi
  if [[ ${EUID} -ne 0 ]]; then
    printf '%s\n' "$(id -un)"
    return 0
  fi

  local candidates default entered
  candidates="$(awk -F: '$3 >= 1000 && $6 == "/home/" $1 {print $1}' /etc/passwd)"
  if [[ "$(printf '%s\n' "${candidates}" | grep -c . || true)" -eq 1 ]]; then
    default="${candidates}"
  fi

  if ! entered="$(prompt "Enter the username to set up sudo and Homebrew for: [${default:-}] ")"; then
    die "no username entered"
  fi
  entered="${entered:-${default:-}}"
  if [[ -z "${entered}" ]]; then
    die "no username entered"
  fi
  printf '%s\n' "${entered}"
}

# --- platform registry ------------------------------------------------------
#
# To add a platform:
#   1. append its OS id to SUPPORTED_OS
#   2. extend detect_os() to recognize it
#   3. define the step functions (all are required; a step may be a no-op
#      that returns 0):
#        platform_sudo_<os>      <user>   ensure the user has sudo access
#        platform_mirror_<os>    <user>   switch package mirrors; return
#                                         nonzero to abort the remaining steps
#        platform_packages_<os>  <user>   install ${BASIC_PACKAGES[@]}
#        platform_brew_<os>      <user>   set up Homebrew (or a no-op)
#        platform_nix_<os>       <user>   install the Nix package manager (or a no-op)
#        platform_ssh_<os>       <user>   init an SSH key for the user (or a no-op)
#   Optional — define only for platforms that get a virtualization stack
#   (deliberately omitted on macOS):
#        platform_vmm_<os>       <user>   set up virsh/QEMU, vm-bhyve, etc.
#   Optional — define only on platforms whose minimal installs lack core
#   tools (Debian and FreeBSD ship without curl and sudo):
#        platform_bootstrap_<os> <user>   install curl + sudo up front
#   4. optionally define platform_requires_root_<os> if root is NOT required
#      (the default is that root is required)
#
# Dispatch is automatic: run_platform_step looks up "<step>_<os>" by name and
# skips (with a warning) any step that has no handler.

SUPPORTED_OS=(debian macos freebsd)

platform_requires_root() {
  local fn="platform_requires_root_${1}"
  if declare -F "${fn}" >/dev/null 2>&1; then
    "${fn}"
  else
    return 0   # default: root required
  fi
}

run_platform_step() {
  local os="$1" step="$2" user="$3"
  shift 3
  local fn="platform_${step}_${os}"
  if ! declare -F "${fn}" >/dev/null 2>&1; then
    warn "no '${fn}' handler for ${os} — skipping"
    return 0
  fi
  say "== ${os}: ${step} =="
  "${fn}" "${user}" "$@"
}

# --- platform detection -----------------------------------------------------

detect_os() {
  case "$(uname -s)" in
    Darwin)  printf '%s\n' 'macos'   ; return 0 ;;
    FreeBSD) printf '%s\n' 'freebsd' ; return 0 ;;
    Linux)
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-unknown}" == "debian" ]]; then
          printf '%s\n' 'debian'
          return 0
        fi
      fi
      die "unsupported Linux distribution ('${ID:-unknown}') — supported: debian"
      ;;
    *)
      die "unsupported OS ('$(uname -s)') — supported: debian, macos, freebsd"
      ;;
  esac
}

detect_codename() {
  # Debian release codename: prefer VERSION_CODENAME, fall back to ID mapping.
  # Read /etc/os-release directly: detect_os() sources it inside a subshell,
  # so its variables never survive into this function.
  local codename="" version_id="" os_release="/etc/os-release"
  if [[ -f "${os_release}" ]]; then
    # shellcheck disable=SC1091
    . "${os_release}"
    codename="${VERSION_CODENAME:-}"
    version_id="${VERSION_ID:-}"
  fi
  if [[ -n "${codename}" ]]; then
    printf '%s\n' "${codename}"
    return 0
  fi
  case "${version_id}" in
    13*) printf '%s\n' 'trixie'   ;;
    12*) printf '%s\n' 'bookworm' ;;
    *)   printf '%s\n' ''         ;;
  esac
}

# Detect whether we are running inside a virtual machine. Returns 0 (true) if
# in a VM, 1 (false) if on bare metal / container / unknown. Used to pick a
# sensible default profile: VMs default to 'client', bare metal to 'server'.
# Shared keyword probe: true if any of the given files contain a
# virtualization hint. Used by the DMI/cpuinfo fallbacks on Linux.
_virt_probe_files() {
  local f
  for f in "$@"; do
    grep -qiE 'hypervisor|virtual|vmware|qemu|kvm|virtualbox|xen|bhyve|hvm' "${f}" 2>/dev/null \
      && return 0
  done
  return 1
}

# Detect whether we are running inside a virtual machine. Returns 0 (true) if
# in a VM, 1 (false) if on bare metal / container / unknown. Used to pick a
# sensible default profile: VMs default to 'client', bare metal to 'server'.
# Detection is OS-specific and supports Linux, the BSDs and Solaris/illumos.
detect_virt() {
  case "$(uname -s)" in
    Linux)
      local v
      if command -v systemd-detect-virt >/dev/null 2>&1; then
        v="$(systemd-detect-virt 2>/dev/null || true)"
        if [[ -n "${v}" && "${v}" != "none" ]]; then
          return 0
        fi
      fi
      # Fallback heuristics when systemd-detect-virt is unavailable.
      _virt_probe_files \
        /sys/class/dmi/id/product_name \
        /sys/class/dmi/id/sys_vendor \
        /proc/cpuinfo
      return $?
      ;;
    FreeBSD|DragonFly)
      # kern.vm_guest reports vmware/hv/xen/bhyve/kvm/qemu/vbox/etc.; empty
      # or "none" on bare metal. This is the canonical FreeBSD/DragonFly test.
      case "$(sysctl -n kern.vm_guest 2>/dev/null || true)" in
        ""|"none") return 1 ;;
        *) return 0 ;;
      esac
      ;;
    OpenBSD|NetBSD)
      # hw.vendor/hw.product reveal the OEM/firmware ("QEMU", "VMware, Inc.",
      # "innotek GmbH" ...); NetBSD also exposes DMI via machdep.dmi.*.
      sysctl hw.vendor hw.product machdep.dmi.system-product machdep.dmi.system-vendor 2>/dev/null \
        | grep -qiE 'hypervisor|virtual|vmware|qemu|kvm|virtualbox|xen|hvm' \
        && return 0
      return 1
      ;;
    SunOS)
      # Solaris / illumos (OmniOS, SmartOS, OpenIndiana, Tribblix, ...):
      # smbios reports the system manufacturer ("QEMU", "VMware", ...).
      if command -v smbios >/dev/null 2>&1; then
        smbios 2>/dev/null | grep -qiE 'vmware|qemu|kvm|virtualbox|xen|hvm' \
          && return 0
      fi
      return 1
      ;;
    Darwin)
      # macOS: the hypervisor framework exposes VMM presence; treat any
      # virtualization-aware Mac conservatively as bare metal by default.
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Suggested default profile for unattended / no-flag installs: 'client' in a
# virtual machine, 'server' on bare metal.
default_profile() {
  if detect_virt; then
    printf '%s\n' 'client'
  else
    printf '%s\n' 'server'
  fi
}

# Grant <user> full sudo via an isolated sudoers.d rule. Unlike relying on the
# sudo/wheel group rule in /etc/sudoers, this cannot silently break if that
# group line is missing or malformed. The rule is validated with visudo before
# being installed. Pass a second truthy arg for passwordless (NOPASSWD) sudo.
grant_user_sudo() {
  local user="$1" nopasswd="${2:-0}"
  local rule_file="/etc/sudoers.d/${user}"
  local rule
  if [[ "${nopasswd}" =~ ^(1|yes|true|NOPASSWD)$ ]]; then
    rule="${user} ALL=(ALL:ALL) NOPASSWD:ALL"
  else
    rule="${user} ALL=(ALL:ALL) ALL"
  fi
  if [[ -f "${rule_file}" ]] && grep -qF "${rule}" "${rule_file}"; then
    say "already configured: ${rule_file}"
    return 0
  fi
  printf '%s\n' "${rule}" > "${rule_file}.new"
  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "${rule_file}.new" >/dev/null 2>&1; then
      rm -f "${rule_file}.new"
      die "refusing to write invalid sudoers rule for '${user}'"
    fi
  fi
  mv -f "${rule_file}.new" "${rule_file}"
  chown root:root "${rule_file}"
  chmod 0440 "${rule_file}"
  say "configured: ${rule_file}"
}

# --- debian (apt + Linuxbrew) ----------------------------------------------

DEB_MIRROR_DIR="/etc/apt/sources.list.d"
DEB_MIRROR_FILE="${DEB_MIRROR_DIR}/debian.sources"
DEB_LEGACY_FILE="/etc/apt/sources.list"
DEB_COMPONENTS='main contrib non-free non-free-firmware'
DEB_SUPPORTED_RELEASES=(trixie bookworm)

BREW_PREFIX='/home/linuxbrew/.linuxbrew'
BREW_PROFILE='/etc/profile.d/linuxbrew.sh'
BREW_BIN="${BREW_PREFIX}/bin/brew"

# Minimal Debian installs ship without curl and sudo — install both up front
# so the rest of the script can rely on them.
platform_bootstrap_debian() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v sudo >/dev/null 2>&1 || missing+=(sudo)
  if [[ ${#missing[@]} -gt 0 ]]; then
    say "installing base tools: ${missing[*]}"
    apt-get install -y "${missing[@]}"
  fi
}

platform_sudo_debian() {
  local target_user="$1" profile="${2:-server}"

  if ! id -u "${target_user}" >/dev/null 2>&1; then
    die "user '${target_user}' does not exist"
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    say "installing sudo ..."
    apt-get install -y sudo
  fi
  nopasswd=0
  [[ "${profile}" == "client" ]] && nopasswd=1
  grant_user_sudo "${target_user}" "${nopasswd}"
  say "sudo ready for '${target_user}'"
}

platform_mirror_debian() {
  local codename
  codename="$(detect_codename)"
  case " ${DEB_SUPPORTED_RELEASES[*]} " in
    *" ${codename} "*) ;;
    *) die "unsupported Debian release '${codename:-unknown}' — supported: ${DEB_SUPPORTED_RELEASES[*]}" ;;
  esac

  mkdir -p "${DEB_MIRROR_DIR}"
  cat > "${DEB_MIRROR_FILE}" <<EOF
Types: deb
URIs: http://mirrors.ustc.edu.cn/debian
Suites: ${codename} ${codename}-updates
Components: ${DEB_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://mirrors.ustc.edu.cn/debian-security
Suites: ${codename}-security
Components: ${DEB_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  say "wrote ${DEB_MIRROR_FILE} (${codename}, ${DEB_COMPONENTS})"

  # Disable any leftover legacy one-line sources.list to avoid duplicate
  # sources alongside the new deb822 file.
  if [[ -f "${DEB_LEGACY_FILE}" ]] && grep -qE '^[^#]' "${DEB_LEGACY_FILE}"; then
    sed -i -E 's/^([^#])/# \1/' "${DEB_LEGACY_FILE}"
    say "disabled legacy ${DEB_LEGACY_FILE}"
  fi

  say "running apt-get update ..."
  if apt-get update; then
    say "done — apt now uses mirrors.ustc.edu.cn (${codename})"
    return 0
  fi
  warn "apt-get update reported errors; check network or keyring."
  return 1
}

platform_packages_debian() {
  say "installing: ${BASIC_PACKAGES[*]}"
  if apt-get install -y "${BASIC_PACKAGES[@]}"; then
    say "installed: ${BASIC_PACKAGES[*]}"
  else
    die "failed to install packages — check the output above"
  fi
}

brew_env_linux() {
  cat <<EOF
HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}"
HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}"
HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}"
HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}"
HOMEBREW_INSTALL_FROM_API=1
EOF
}

run_brew_as_user() {
  local user="$1"; shift
  run_as_user "${user}" env NONINTERACTIVE=1 \
    HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}" \
    HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}" \
    HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}" \
    HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}" \
    HOMEBREW_INSTALL_FROM_API=1 \
    bash -c "$*"
}

# Fetch the Homebrew installer into a user-owned temp dir; prints the repo
# path. Prefers a BFSU git clone (mirrors the upstream repo layout); falls
# back to the GitHub raw script when the mirror is unreachable. Errors are
# not suppressed so a failed fetch is diagnosable.
fetch_brew_installer() {
  local user="$1" dir
  dir="$(run_as_user "${user}" mktemp -d '/tmp/brew-install.XXXXXX')" \
    || die "failed to create a temp dir for the brew installer"
  if run_as_user "${user}" git clone --depth=1 "${BREW_INSTALL_GIT}" "${dir}/install.git"; then
    if ! mv -f "${dir}/install.git/install.sh" "${dir}/install.sh" 2>/dev/null; then
      rm -rf "${dir}"
      die "cloned brew installer has no install.sh — check the output above"
    fi
    rm -rf "${dir}/install.git"
  elif curl -fsSL "${BREW_INSTALL_URL}" -o "${dir}/install.sh"; then
    warn "BFSU clone failed — fell back to ${BREW_INSTALL_URL}"
  else
    rm -rf "${dir}"
    die "failed to fetch brew installer from ${BREW_INSTALL_GIT} or ${BREW_INSTALL_URL} — check the output above"
  fi
  printf '%s\n' "${dir}"
}

platform_brew_debian() {
  local brew_user="$1"

  if [[ -z "${brew_user}" || "${brew_user}" == "root" ]]; then
    warn "Homebrew refuses to install as root — skipping brew setup."
    warn "Re-run this script via sudo from a non-root user to include it."
    return 1
  fi

  cat > "${BREW_PROFILE}" <<EOF
$(brew_env_linux)
eval "\$(${BREW_BIN} shellenv)"
EOF
  say "wrote ${BREW_PROFILE}"

  if [[ -x "${BREW_BIN}" ]]; then
    say "Homebrew already installed at ${BREW_PREFIX}"
    if run_brew_as_user "${brew_user}" "${BREW_BIN} update"; then
      say "done — Homebrew remote switched to ${BREW_GIT_REMOTE}"
    else
      die "brew update failed — check the output above"
    fi
    return 0
  fi

  if ! dpkg -s build-essential procps >/dev/null 2>&1; then
    say "installing Linuxbrew build dependencies ..."
    apt-get install -y build-essential procps
  fi

  if [[ ! -d /home/linuxbrew ]]; then
    mkdir -p /home/linuxbrew
    chown "${brew_user}" /home/linuxbrew
  fi

  local installer
  installer="$(fetch_brew_installer "${brew_user}")"
  say "installing Linuxbrew ..."
  if ! run_brew_as_user "${brew_user}" "bash '${installer}/install.sh'"; then
    rm -rf "${installer}"
    die "Linuxbrew install failed — check the output above"
  fi
  rm -rf "${installer}"

  say "running brew update ..."
  if run_brew_as_user "${brew_user}" "${BREW_BIN} update"; then
    say "done — Homebrew ready at ${BREW_PREFIX} (BFSU mirrors)"
  else
    die "brew update failed — check the output above"
  fi
}

platform_nix_debian() {
  # Multi-user (daemon) install: sets up the nix-daemon service + nixbld users.
  if nix_installed; then
    say "Nix already installed — skipping"
    return 0
  fi
  say "installing Nix (multi-user daemon) ..."
  if ! curl --proto '=https' --tlsv1.2 -L "${NIX_INSTALL_URL}" | sh -s -- --daemon; then
    die "Nix install failed — check the output above"
  fi
  say "done — Nix installed (multi-user); run 'nix-shell' from a fresh shell"
}

# Debian vmm: libvirt/QEMU with KVM acceleration where available. virsh
# manages VMs, virt-install provisions them, qemu-utils ships qemu-img.
# Headless server — no GUI tools (virt-manager / virt-viewer) are installed.
VMM_PACKAGES_DEBIAN=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst)

platform_vmm_debian() {
  local target_user="$1"

  say "installing libvirt/QEMU: ${VMM_PACKAGES_DEBIAN[*]}"
  if ! apt-get install -y "${VMM_PACKAGES_DEBIAN[@]}"; then
    die "failed to install virtualization packages — check the output above"
  fi

  # Group members manage VMs without root; takes effect on next login.
  usermod -aG libvirt,kvm "${target_user}"
  say "added '${target_user}' to groups: libvirt, kvm"

  if [[ -e /dev/kvm ]]; then
    say "KVM acceleration available (/dev/kvm)"
  else
    warn "/dev/kvm not found — VMs will run without KVM (software emulation)."
    warn "Enable VT-x/AMD-V (BIOS) or nested virtualization to use KVM."
  fi

  # libvirtd must run (and start on boot) for virsh/virt-install to work.
  if ! systemctl enable --now libvirtd; then
    warn "failed to start libvirtd — run: systemctl enable --now libvirtd"
  fi

  # Start libvirt's default NAT network so virt-install works out of the box.
  if virsh net-info default >/dev/null 2>&1; then
    virsh net-start default >/dev/null 2>&1 || true
    virsh net-autostart default >/dev/null 2>&1 || true
    say "libvirt 'default' NAT network enabled"
  else
    warn "no libvirt 'default' network — check libvirt-daemon-system"
  fi

  say "virtualization ready — virsh / virt-install (KVM where available)"
}

# --- macos (Homebrew) ------------------------------------------------------

# Homebrew does not require root; run this script as your own (admin) user.
platform_requires_root_macos() { return 1; }

brew_path_macos() {
  case "$(uname -m)" in
    arm64) printf '%s\n' '/opt/homebrew/bin/brew' ;;
    *)     printf '%s\n' '/usr/local/bin/brew'    ;;
  esac
}

brew_env_macos() {
  cat <<EOF
HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}"
HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}"
HOMEBREW_CASK_GIT_REMOTE="${BREW_CASK_GIT_REMOTE}"
HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}"
HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}"
EOF
}

platform_sudo_macos() {
  local target_user="$1" profile="${2:-server}"

  if ! id -u "${target_user}" >/dev/null 2>&1; then
    die "user '${target_user}' does not exist"
  fi
  if [[ ${EUID} -ne 0 ]]; then
    say "sudo ready for '${target_user}' (preinstalled on macOS)"
    return 0
  fi
  if ! dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -qw "${target_user}"; then
    say "granting admin (sudo) to '${target_user}' ..."
    dscl . -append /Groups/admin GroupMembership "${target_user}"
  fi
  # Client profile: passwordless sudo via an isolated sudoers.d rule.
  if [[ "${profile}" == "client" ]]; then
    grant_user_sudo "${target_user}" 1
  fi
  say "sudo ready for '${target_user}'"
}

platform_mirror_macos() {
  local user="$1" profile
  profile="$(user_home "${user}")/.zprofile"
  write_marked_block "${profile}" 'cassius-brew-mirrors' "$(brew_env_macos)"
  if [[ ${EUID} -eq 0 ]]; then
    chown "${user}" "${profile}" 2>/dev/null || true
  fi
}

platform_packages_macos() {
  local user="$1" brew
  brew="$(brew_path_macos)"

  if [[ ! -x "${brew}" ]]; then
    local installer
    installer="$(fetch_brew_installer "${user}")"
    say "installing Homebrew ..."
    if ! run_as_user "${user}" env NONINTERACTIVE=1 \
        HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}" \
        HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}" \
        HOMEBREW_CASK_GIT_REMOTE="${BREW_CASK_GIT_REMOTE}" \
        HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}" \
        HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}" \
        HOMEBREW_INSTALL_FROM_API=1 \
        bash "${installer}/install.sh"; then
      rm -rf "${installer}"
      die "Homebrew install failed — check the output above"
    fi
    rm -rf "${installer}"
  else
    say "Homebrew already installed at $(dirname "$(dirname "${brew}")")"
  fi

  say "installing: ${BASIC_PACKAGES[*]}"
  if ! run_as_user "${user}" env \
      HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}" \
      HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}" \
      "${brew}" install "${BASIC_PACKAGES[@]}"; then
    die "failed to install packages — check the output above"
  fi
}

platform_brew_macos() {
  # Homebrew *is* the macOS package manager — already handled by the packages
  # step; nothing extra to set up.
  say "Homebrew is native on macOS — already set up by the packages step"
  return 0
}

platform_nix_macos() {
  # Official installer; defaults to the multi-user daemon (launchd). Run as the
  # target user so the installer can prompt for their sudo password if needed.
  if nix_installed; then
    say "Nix already installed — skipping"
    return 0
  fi
  say "installing Nix (macOS) ..."
  if ! run_as_user "$1" /bin/bash -c "curl --proto '=https' --tlsv1.2 -L '${NIX_INSTALL_URL}' | sh"; then
    die "Nix install failed — check the output above"
  fi
  say "done — Nix installed; run 'nix-shell' from a fresh shell"
}

# --- freebsd (pkg) ---------------------------------------------------------

# FreeBSD base has fetch(1), not curl, and no sudo — install both up front.
platform_bootstrap_freebsd() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v sudo >/dev/null 2>&1 || missing+=(sudo)
  if [[ ${#missing[@]} -gt 0 ]]; then
    say "installing base tools: ${missing[*]}"
    pkg update -f
    pkg install -y "${missing[@]}"
  fi
}

platform_sudo_freebsd() {
  local target_user="$1" profile="${2:-server}"

  if ! id -u "${target_user}" >/dev/null 2>&1; then
    die "user '${target_user}' does not exist"
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    say "installing sudo ..."
    pkg install -y sudo
  fi
  if ! id -nG "${target_user}" | grep -qw wheel; then
    say "granting sudo (wheel) to '${target_user}' ..."
    pw groupmod wheel -m "${target_user}"
  fi
  # Client profile: passwordless sudo via an isolated sudoers.d rule.
  if [[ "${profile}" == "client" ]]; then
    grant_user_sudo "${target_user}" 1
  fi
  say "sudo ready for '${target_user}'"
}

platform_mirror_freebsd() {
  local conf="/usr/local/etc/pkg.conf"
  if [[ -f "${conf}" ]] && grep -q 'mirrors.ustc.edu.cn' "${conf}"; then
    say "pkg already configured for USTC — skipping"
  else
    mkdir -p "$(dirname "${conf}")"
    cat > "${conf}" <<EOF
# USTC FreeBSD pkg mirror (install.sh)
FreeBSD: {
  url: "pkg+http://mirrors.ustc.edu.cn/freebsd-pkg/\${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
    say "wrote ${conf}"
  fi

  say "running pkg update ..."
  if pkg update -f; then
    say "done — pkg now uses mirrors.ustc.edu.cn"
    return 0
  fi
  warn "pkg update reported errors; check network or repository config."
  return 1
}

platform_packages_freebsd() {
  say "installing: ${BASIC_PACKAGES[*]}"
  if pkg install -y "${BASIC_PACKAGES[@]}"; then
    say "installed: ${BASIC_PACKAGES[*]}"
  else
    die "failed to install packages — check the output above"
  fi
}

platform_brew_freebsd() {
  warn "Homebrew/Linuxbrew does not support FreeBSD — packages come from pkg."
  return 0
}

platform_nix_freebsd() {
  warn "Nix does not officially support FreeBSD — skipping (use pkg instead)."
  return 0
}

# FreeBSD vmm: bhyve (the native hypervisor, KVM's counterpart) + vm-bhyve
# for VM management. Headless server — manage VMs with the `vm` CLI via sudo.
VMM_PACKAGES_FREEBSD=(vm-bhyve bhyve-firmware)

platform_vmm_freebsd() {
  say "installing bhyve/vm-bhyve: ${VMM_PACKAGES_FREEBSD[*]}"
  if ! pkg install -y "${VMM_PACKAGES_FREEBSD[@]}"; then
    die "failed to install virtualization packages — check the output above"
  fi

  # Load the vmm(4) hypervisor now, and at every boot via /boot/loader.conf.
  if kldstat -m vmm >/dev/null 2>&1; then
    say "vmm(4) hypervisor module already loaded"
  elif kldload vmm 2>/dev/null; then
    say "vmm(4) hypervisor module loaded"
  else
    warn "could not load vmm(4) — enable VT-x/AMD-V (BIOS) or nested virt"
  fi
  write_marked_block /boot/loader.conf 'cassius-bhyve' 'vmm_load="YES"'

  # Bring tap(4) interfaces up as soon as they are opened (needed by bridges).
  write_marked_block /etc/sysctl.conf 'cassius-bhyve' 'net.link.tap.up_on_open=1'
  sysctl net.link.tap.up_on_open=1 2>/dev/null || true

  # Enable the vm rc service and initialize the VM directory (/vm).
  sysrc vm_enable="YES"
  sysrc vm_dir="/vm"
  if vm init; then
    say "vm-bhyve initialized (vm_dir=/vm)"
  else
    warn "vm init failed — re-run it manually as root"
  fi

  say "virtualization ready — manage VMs with: sudo vm list / sudo vm create"
}

# --- main ------------------------------------------------------------------

usage() {
  local os
  os="$(uname -s)"
  cat <<EOF
Usage: $0 [options]

One-shot setup for a fresh machine (${os}).

Options:
  --username USER   Target user to set up sudo/Homebrew/SSH for. If omitted,
                    resolved from SUDO_USER > current user > interactive prompt.
  --profile PROFILE Setup profile: 'server' or 'client'. If omitted, prompted.
                      server — full setup incl. the virtualization stack (vmm)
                      client — skip vmm (no VM management), passwordless sudo
  -h, --help        Show this help and exit.

Supported platforms: debian, macos, freebsd.
EOF
}

# Prompt interactively for the setup profile. The suggested default is dynamic:
# 'client' when running inside a VM, 'server' on bare metal.
prompt_profile() {
  local entered dflt
  dflt="$(default_profile)"
  while true; do
    if ! entered="$(prompt "Select setup profile (server/client) [${dflt}]: ")"; then
      die "no profile entered"
    fi
    entered="${entered:-${dflt}}"
    case "${entered}" in
      server|client) printf '%s\n' "${entered}"; return 0 ;;
      *) warn "unknown profile '${entered}' — expected 'server' or 'client'" ;;
    esac
  done
}

# Parse --username / --profile / --help / -h. Unknown options are rejected.
# Sets the global USERNAME_ARG / PROFILE_ARG; calling with no --username or
# --profile simply leaves those empty (prompts happen later).
parse_args() {
  local arg prev=""
  USERNAME_ARG=""
  PROFILE_ARG=""
  for arg in "$@"; do
    case "${arg}" in
      --help|-h)
        usage
        exit 0
        ;;
      --username|--profile)
        prev="${arg}"
        ;;
      --username=*)
        USERNAME_ARG="${arg#*=}"; prev=""
        ;;
      --profile=*)
        PROFILE_ARG="${arg#*=}"; prev=""
        ;;
      -*) die "unknown option '${arg}' — see --help" ;;
      *)
        case "${prev}" in
          --username) USERNAME_ARG="${arg}" ;;
          --profile)  PROFILE_ARG="${arg}" ;;
          *) die "unexpected argument '${arg}' — see --help" ;;
        esac
        prev=""
        ;;
    esac
  done
  if [[ -n "${prev}" ]]; then
    die "option '${prev}' requires a value — see --help"
  fi
}

main() {
  local os target_user profile
  os="$(detect_os)"

  case " ${SUPPORTED_OS[*]} " in
    *" ${os} "*) ;;
    *) die "platform '${os}' is not in SUPPORTED_OS — register it first" ;;
  esac

  say "platform: ${os}"

  if platform_requires_root "${os}"; then
    require_root
  fi

  parse_args "$@"
  target_user="$(resolve_target_user "${USERNAME_ARG:-}")"
  if [[ -n "${PROFILE_ARG:-}" ]]; then
    profile="${PROFILE_ARG}"
    case "${profile}" in
      server|client) ;;
      *) die "unknown profile '${profile}' — supported: server, client" ;;
    esac
  else
    profile="$(prompt_profile)"
  fi
  say "profile: ${profile}"

  run_platform_step "${os}" bootstrap "${target_user}"
  run_platform_step "${os}" sudo "${target_user}" "${profile}"
  run_platform_step "${os}" ssh "${target_user}"

  # The mirror step gates the rest: if mirror setup fails, abort rather than
  # installing packages from a broken repository state.
  if run_platform_step "${os}" mirror "${target_user}"; then
    run_platform_step "${os}" packages "${target_user}"
    run_platform_step "${os}" brew "${target_user}"
    run_platform_step "${os}" nix "${target_user}"
    # The virtualization stack (vmm) is server-only: clients have no VM
    # management, so skip it for the 'client' profile on every platform.
    if [[ "${profile}" == "server" ]]; then
      run_platform_step "${os}" vmm "${target_user}"
    else
      say "profile 'client' — skipping virtualization (vmm)"
    fi
  fi

  say "done — ${os} setup complete (profile: ${profile})"
}

main "$@"
