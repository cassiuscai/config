#!/usr/bin/env bash
#
# install.sh — one-shot setup for a fresh machine:
#
#   * switches system package mirrors to USTC (mirrors.ustc.edu.cn)
#   * installs basic packages (curl, git, htop, neovim)
#   * sets up Homebrew / Linuxbrew with USTC mirrors
#   * installs the Nix package manager (Linux: multi-user daemon; macOS: default)
#   * initializes an ed25519 SSH key for the target user (if missing)
#   * bootstraps sudo for the target user (minimal installs)
#
# Supported platforms:
#   debian  — apt (deb822) → mirrors.ustc.edu.cn, Linuxbrew at /home/linuxbrew
#   macos   — Homebrew     → mirrors.ustc.edu.cn (brew/core/cask/bottles)
#   freebsd — pkg          → mirrors.ustc.edu.cn/freebsd-pkg (no Homebrew)
#
# Extensible by design: every platform implements the same small set of step
# functions and is registered in SUPPORTED_OS. To add a new OS, see the
# "Platform registry" section below — dispatch is automatic.
#
# Usage:
#   sudo ./install.sh [username]     # Debian / FreeBSD — run as root
#   ./install.sh [username]          # macOS — run as your own user
#
# The target user (CLI arg > SUDO_USER > current user > interactive prompt)
# gets sudo privileges and owns the Homebrew install. If prompted, the sole
# login user is suggested as the default.
set -euo pipefail

# --- shared config ---------------------------------------------------------

BASIC_PACKAGES=(curl git htop neovim just)

# USTC Homebrew mirrors (https://mirrors.ustc.edu.cn/help/)
BREW_GIT_REMOTE='https://mirrors.ustc.edu.cn/brew.git'
BREW_CORE_GIT_REMOTE='https://mirrors.ustc.edu.cn/homebrew-core.git'
BREW_CASK_GIT_REMOTE='https://mirrors.ustc.edu.cn/homebrew-cask.git'
BREW_BOTTLE_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles'
BREW_API_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles/api'
BREW_INSTALL_URL='https://mirrors.ustc.edu.cn/misc/brew-install.sh'

NIX_INSTALL_URL='https://nixos.org/nix/install'

# --- helpers ---------------------------------------------------------------

say()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

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

  if ! read -r -p "Enter the username to set up sudo and Homebrew for: [${default:-}] " entered; then
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
#   3. define the step functions (all six are required; a step may be a
#      no-op that returns 0):
#        platform_sudo_<os>      <user>   ensure the user has sudo access
#        platform_mirror_<os>    <user>   switch package mirrors; return
#                                         nonzero to abort the remaining steps
#        platform_packages_<os>  <user>   install ${BASIC_PACKAGES[@]}
#        platform_brew_<os>      <user>   set up Homebrew (or a no-op)
#        platform_nix_<os>       <user>   install the Nix package manager (or a no-op)
#        platform_ssh_<os>       <user>   init an SSH key for the user (or a no-op)
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
  local fn="platform_${step}_${os}"
  if ! declare -F "${fn}" >/dev/null 2>&1; then
    warn "no '${fn}' handler for ${os} — skipping"
    return 0
  fi
  say "== ${os}: ${step} =="
  "${fn}" "${user}"
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
  local codename="${VERSION_CODENAME:-}"
  local version_id="${VERSION_ID:-}"
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

# --- debian (apt + Linuxbrew) ----------------------------------------------

DEB_MIRROR_DIR="/etc/apt/sources.list.d"
DEB_MIRROR_FILE="${DEB_MIRROR_DIR}/debian.sources"
DEB_LEGACY_FILE="/etc/apt/sources.list"
DEB_COMPONENTS='main contrib non-free non-free-firmware'
DEB_SUPPORTED_RELEASES=(trixie bookworm)

BREW_PREFIX='/home/linuxbrew/.linuxbrew'
BREW_PROFILE='/etc/profile.d/linuxbrew.sh'
BREW_BIN="${BREW_PREFIX}/bin/brew"

platform_sudo_debian() {
  local target_user="$1"

  if ! id -u "${target_user}" >/dev/null 2>&1; then
    die "user '${target_user}' does not exist"
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    say "installing sudo ..."
    apt-get install -y sudo
  fi
  if ! id -nG "${target_user}" | grep -qw sudo; then
    say "granting sudo to '${target_user}' ..."
    usermod -aG sudo "${target_user}"
  fi
  say "sudo ready for '${target_user}'"
}

platform_mirror_debian() {
  local codename
  codename="$(detect_codename)"
  case " ${DEB_SUPPORTED_RELEASES[*]} " in
    *" ${codename} "*) ;;
    *) die "unsupported Debian release '${codename:-unknown}' — supported: ${DEB_SUPPORTED_RELEASES[*]}" ;;
  esac

  # Keep an untouched copy of any previous mirror file.
  if [[ -f "${DEB_MIRROR_FILE}" ]]; then
    cp -a "${DEB_MIRROR_FILE}" "${DEB_MIRROR_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    say "backed up existing ${DEB_MIRROR_FILE}"
  fi

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
    local backup="${DEB_LEGACY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${DEB_LEGACY_FILE}" "${backup}"
    sed -i -E 's/^([^#])/# \1/' "${DEB_LEGACY_FILE}"
    say "disabled legacy ${DEB_LEGACY_FILE} (backup: ${backup})"
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
EOF
}

run_brew_as_user() {
  local user="$1"; shift
  run_as_user "${user}" env NONINTERACTIVE=1 \
    HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}" \
    HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}" \
    HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}" \
    HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}" \
    bash -c "$*"
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

  say "installing Linuxbrew from USTC mirror ..."
  if ! run_brew_as_user "${brew_user}" \
      "/bin/bash -c \"\$(curl -fsSL ${BREW_INSTALL_URL})\""; then
    die "Linuxbrew install failed — check the output above"
  fi

  say "running brew update ..."
  if run_brew_as_user "${brew_user}" "${BREW_BIN} update"; then
    say "done — Homebrew ready at ${BREW_PREFIX} (USTC mirrors)"
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
  local target_user="$1"

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
    say "installing Homebrew from USTC mirror ..."
    if ! run_as_user "${user}" env NONINTERACTIVE=1 \
        HOMEBREW_BREW_GIT_REMOTE="${BREW_GIT_REMOTE}" \
        HOMEBREW_CORE_GIT_REMOTE="${BREW_CORE_GIT_REMOTE}" \
        HOMEBREW_CASK_GIT_REMOTE="${BREW_CASK_GIT_REMOTE}" \
        HOMEBREW_BOTTLE_DOMAIN="${BREW_BOTTLE_DOMAIN}" \
        HOMEBREW_API_DOMAIN="${BREW_API_DOMAIN}" \
        /bin/bash -c "$(curl -fsSL "${BREW_INSTALL_URL}")"; then
      die "Homebrew install failed — check the output above"
    fi
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

platform_sudo_freebsd() {
  local target_user="$1"

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
  say "sudo ready for '${target_user}'"
}

platform_mirror_freebsd() {
  local conf="/usr/local/etc/pkg.conf"
  if [[ -f "${conf}" ]] && grep -q 'mirrors.ustc.edu.cn' "${conf}"; then
    say "pkg already configured for USTC — skipping"
  else
    if [[ -f "${conf}" ]]; then
      cp -a "${conf}" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
      say "backed up existing ${conf}"
    fi
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

# --- main ------------------------------------------------------------------

main() {
  local os target_user
  os="$(detect_os)"

  case " ${SUPPORTED_OS[*]} " in
    *" ${os} "*) ;;
    *) die "platform '${os}' is not in SUPPORTED_OS — register it first" ;;
  esac

  say "platform: ${os}"

  if platform_requires_root "${os}"; then
    require_root
  fi

  target_user="$(resolve_target_user "${1:-}")"
  run_platform_step "${os}" sudo "${target_user}"
  run_platform_step "${os}" ssh "${target_user}"

  # The mirror step gates the rest: if mirror setup fails, abort rather than
  # installing packages from a broken repository state.
  if run_platform_step "${os}" mirror "${target_user}"; then
    run_platform_step "${os}" packages "${target_user}"
    run_platform_step "${os}" brew "${target_user}"
    run_platform_step "${os}" nix "${target_user}"
  fi

  say "done — ${os} setup complete"
}

main "$@"
