# Cross-platform setup installer

A single script that takes a fresh machine from stock to usable:

- switches system package mirrors to **[USTC mirrors](https://mirrors.ustc.edu.cn)**
- installs basic packages: `curl`, `git`, `htop`, `neovim`
- sets up **Homebrew / Linuxbrew** with USTC mirrors
- installs the **Nix** package manager (Linux: multi-user daemon, macOS: default)
- bootstraps **sudo** for the target user (minimal installs)

## Supported platforms

| Platform                     | Package manager       | Mirror                                          | Homebrew | Nix |
|------------------------------|-----------------------|-------------------------------------------------|----------|-----|
| Debian 12 (bookworm), 13 (trixie) | `apt` (deb822)   | `mirrors.ustc.edu.cn/debian`                    | Linuxbrew at `/home/linuxbrew/.linuxbrew` | multi-user daemon |
| macOS (Intel & Apple Silicon) | Homebrew             | `mirrors.ustc.edu.cn` (brew / core / cask / bottles) | Native Homebrew | multi-user daemon |
| FreeBSD 14+                  | `pkg`                | `mirrors.ustc.edu.cn/freebsd-pkg`               | not supported — `pkg` covers packages | not supported |

> **FreeBSD**: Homebrew/Linuxbrew and Nix do not support FreeBSD. The script
> keeps FreeBSD on its native `pkg` manager and skips both steps.

## Usage

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
USTC `brew-install.sh` (profile at `/etc/profile.d/linuxbrew.sh`), and finally
installs Nix in multi-user daemon mode:
`curl ... https://nixos.org/nix/install | sh -s -- --daemon`.

**macOS** — writes the `HOMEBREW_*` USTC mirror exports into `~/.zprofile`,
installs Homebrew (if missing) from the USTC installer, then
`brew install curl git htop neovim`, and installs Nix with the official
installer (defaults to the multi-user daemon via launchd; it may prompt for
your sudo password).

**FreeBSD** — configures `/usr/local/etc/pkg.conf` to use
`mirrors.ustc.edu.cn/freebsd-pkg` (with `${ABI}` substitution), runs
`pkg update -f`, installs the basic packages, installs `sudo` and adds the
user to the `wheel` group. Homebrew and Nix are skipped (unsupported).

## Extending: add a platform

The script is built around a small, explicit **platform contract**. To support
a new OS:

1. Register the OS id in `SUPPORTED_OS`:

   ```sh
   SUPPORTED_OS=(debian macos freebsd arch)
   ```

2. Extend `detect_os()` to recognize it (usually via `/etc/os-release`).

3. Implement the five step functions — a step may be a no-op returning 0:

   ```sh
   platform_sudo_arch()      { ... }   # ensure <user> has sudo access
   platform_mirror_arch()    { ... }   # switch mirrors; nonzero aborts the rest
   platform_packages_arch()  { ... }   # install ${BASIC_PACKAGES[@]}
   platform_brew_arch()      { ... }   # set up Homebrew, or a no-op
   platform_nix_arch()       { ... }   # install Nix, or a no-op
   ```

4. Only if the platform does **not** need root:

   ```sh
   platform_requires_root_arch() { return 1; }
   ```

Dispatch is automatic — `run_platform_step` looks up `<step>_<os>` by name and
skips (with a warning) any step that has no handler. See the *Platform
registry* section in `install.sh` for the full contract.

## Notes

- Homebrew refuses to run as root. If you install as root, run
  `sudo ./install.sh <non-root-user>` so that user owns the Homebrew install.
- The macOS Nix installer may prompt for your sudo password interactively —
  run the script in a terminal, not from a non-interactive context.
- `apt-get update` / `pkg update` failures abort the remaining steps so you can
  fix network or keyring issues first.
- Existing mirror configuration files are backed up with a timestamp
  (`*.bak.YYYYMMDDHHMMSS`) before being replaced.
- USTC mirror references: <https://mirrors.ustc.edu.cn>

## License

Apache-2.0 — see [LICENSE](LICENSE).
