# Cross-platform setup installer

A single script that takes a fresh machine from stock to usable:

- switches system package mirrors to **[USTC mirrors](https://mirrors.ustc.edu.cn)**
- installs basic packages: `curl`, `git`, `htop`, `neovim`
- sets up **virtualization** on headless servers: **libvirt/QEMU** with **KVM** acceleration (`virsh`, `virt-install`) on Debian, **bhyve/vm-bhyve** on FreeBSD — skipped on macOS
- sets up **Homebrew / Linuxbrew** with USTC mirrors
- installs the **Nix** package manager (Linux: multi-user daemon, macOS: default)
- initializes an **ed25519 SSH key** for the target user (if missing)
- bootstraps **sudo** for the target user (minimal installs)

## One-line install

No clone needed — pipe the script straight from GitHub:

**Debian / FreeBSD** — run as root; `<username>` gets sudo + Homebrew + Nix:

```sh
curl -fsSL https://raw.githubusercontent.com/cassiuscai/config/master/install.sh | sudo bash -s -- <username>
```

**macOS** — run as your own (admin) user; no sudo needed:

```sh
curl -fsSL https://raw.githubusercontent.com/cassiuscai/config/master/install.sh | bash
```

> The script uses bash features (arrays, `[[ ]]`), so pipe it to **`bash`** —
> not `sh` (on Debian `sh` is dash and will fail).
>
> The username is optional: without one, the target user is resolved from
> `$SUDO_USER` (when run via `sudo`) or the current user (macOS). The
> interactive prompt only appears when running as root with no sudo context —
> in that case a piped install can't prompt, so pass a username explicitly.

## Supported platforms

| Platform                     | Package manager       | Mirror                                          | Homebrew | Nix | Virtualization |
|------------------------------|-----------------------|-------------------------------------------------|----------|-----|----------------|
| Debian 12 (bookworm), 13 (trixie) | `apt` (deb822)   | `mirrors.ustc.edu.cn/debian`                    | Linuxbrew at `/home/linuxbrew/.linuxbrew` | multi-user daemon | libvirt/QEMU + KVM (`virsh`, `virt-install`) |
| macOS (Intel & Apple Silicon) | Homebrew             | `mirrors.ustc.edu.cn` (brew / core / cask / bottles) | Native Homebrew | multi-user daemon | none — skipped |
| FreeBSD 14+                  | `pkg`                | `mirrors.ustc.edu.cn/freebsd-pkg`               | not supported — `pkg` covers packages | not supported | bhyve + `vm-bhyve` |

> **FreeBSD**: Homebrew/Linuxbrew and Nix do not support FreeBSD. The script
> keeps FreeBSD on its native `pkg` manager and skips both steps.

## From a local checkout

```sh
# Debian / FreeBSD — run as root (directly, or via sudo)
sudo ./install.sh [username]

# macOS — run as your own (admin) user; no sudo needed
./install.sh [username]
```

The target user is chosen in this order:

1. the command-line argument, if given
2. `$SUDO_USER` — the user who invoked `sudo`
3. the current user (macOS / direct non-root run)
4. an interactive prompt (root with no sudo context) — the sole login user is suggested

That user gets sudo privileges and owns the Homebrew/Linuxbrew install.

## What happens per platform

**Debian** — rewrites `/etc/apt/sources.list.d/debian.sources` (deb822 format)
to `mirrors.ustc.edu.cn` for the detected release (trixie / bookworm),
disables any legacy one-line `sources.list`, runs `apt-get update`, installs
the basic packages, then installs Linuxbrew into `/home/linuxbrew` using the
upstream `brew-install.sh` (git/bottle mirrors stay on USTC; profile at
`/etc/profile.d/linuxbrew.sh`), and finally
installs Nix in multi-user daemon mode:
`curl ... https://nixos.org/nix/install | sh -s -- --daemon`.

Then it sets up the **vmm** stack — libvirt/QEMU with KVM acceleration:
`libvirt-daemon-system`, `libvirt-clients`, `virtinst`, `qemu-system-x86`,
`qemu-utils`. It enables the `libvirtd` service, adds the user to the
`libvirt` and `kvm` groups, and starts libvirt's default NAT network — so
`virsh` and `virt-install` work out of the box on a headless server (no GUI
tools are installed). If `/dev/kvm` is missing, a warning is printed and VMs
fall back to software emulation.

**macOS** — writes the `HOMEBREW_*` USTC mirror exports into `~/.zprofile`,
installs Homebrew (if missing) from the upstream installer, then
`brew install curl git htop neovim just`, and installs Nix with the official
installer (defaults to the multi-user daemon via launchd; it may prompt for
your sudo password). No virtualization stack is installed on macOS.

**FreeBSD** — configures `/usr/local/etc/pkg.conf` to use
`mirrors.ustc.edu.cn/freebsd-pkg` (with `${ABI}` substitution), runs
`pkg update -f`, installs the basic packages, installs `sudo` and adds the
user to the `wheel` group. It then sets up the **vmm** stack — bhyve (the
native hypervisor, KVM's counterpart) with `vm-bhyve` and `bhyve-firmware`:
loads the `vmm` kernel module now and at boot (`/boot/loader.conf`), enables
tap interfaces (`net.link.tap.up_on_open=1`), enables the `vm` rc service,
and initializes the VM directory with `vm init`. Homebrew and Nix are skipped
(unsupported).

All three platforms run the same SSH step: if `~/.ssh/id_ed25519` doesn't
exist, a passphrase-less ed25519 key is created for the target user, with no
comment (email) embedded.

## Extending: add a platform

The script is built around a small, explicit **platform contract**. To support
a new OS:

1. Register the OS id in `SUPPORTED_OS`:

   ```sh
   SUPPORTED_OS=(debian macos freebsd arch)
   ```

2. Extend `detect_os()` to recognize it (usually via `/etc/os-release`).

3. Implement the six step functions — a step may be a no-op returning 0:

   ```sh
   platform_sudo_arch()      { ... }   # ensure <user> has sudo access
   platform_mirror_arch()    { ... }   # switch mirrors; nonzero aborts the rest
   platform_packages_arch()  { ... }   # install ${BASIC_PACKAGES[@]}
   platform_brew_arch()      { ... }   # set up Homebrew, or a no-op
   platform_nix_arch()       { ... }   # install Nix, or a no-op
   platform_ssh_arch()       { ... }   # init an SSH key, or a no-op
   ```

   Optionally, a virtualization stack (define only if the platform should get
   one — macOS deliberately omits it):

   ```sh
   platform_vmm_arch()       { ... }   # set up virsh/QEMU, vm-bhyve, etc.
   ```

4. Only if the platform does **not** need root:

   ```sh
   platform_requires_root_arch() { return 1; }
   ```

Dispatch is automatic — `run_platform_step` looks up `<step>_<os>` by name and
skips (with a warning) any step that has no handler. See the *Platform
registry* section in `install.sh` for the full contract.

## Notes

- On Debian, the `libvirt` and `kvm` group memberships apply to new login
  sessions — log out and back in before using `virsh` as a non-root user.
- The script makes the host VM-ready; create machines afterwards with
  `virt-install` (Debian) or `sudo vm create` (FreeBSD). `virsh` runs without
  root after a fresh login; `vm` is run via sudo.
- Homebrew refuses to run as root. If you install as root, run
  `sudo ./install.sh <non-root-user>` so that user owns the Homebrew install.
- The macOS Nix installer may prompt for your sudo password interactively —
  run the script in a terminal, not from a non-interactive context.
- The SSH key is created passphrase-less and with no email comment so the
  bootstrap runs non-interactively; add a passphrase later with `ssh-keygen -p`.
- `apt-get update` / `pkg update` failures abort the remaining steps so you can
  fix network or keyring issues first.
- USTC mirror references: <https://mirrors.ustc.edu.cn>

## License

Apache-2.0 — see [LICENSE](LICENSE).
