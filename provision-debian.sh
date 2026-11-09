#!/usr/bin/env bash
#
# provision-debian.sh -- the fakevm's tooling on a bare Debian machine.
#
# Derived from two files next to this one:
#
#   Containerfile     the development package list, and `fd` for `fdfind`
#   setupdevkits.sh   fnm + node LTS, pnpm, uv, pi and pi's two extensions
#
# Scope: tooling, not system administration. The only thing written outside the
# calling user's home is the package set -- no service is enabled, restarted or
# reconfigured, no /etc file is created, no unit, sudoer, user, locale or
# timezone is touched. Everything else lands in the home of whoever runs it.
#
# Run it as the user who should own the devkits, on Debian installed without a
# desktop. It calls sudo for the packages only. A fresh login shell is needed
# afterwards for PATH.
#
#   ./provision-debian.sh
#   ./provision-debian.sh --help
#
# ---------------------------------------------------------------------------
# What is deliberately NOT copied from those two files, and why
#
#   journald's persist.conf drop-in, and the `try-restart` that follows it
#       A machine-wide logging policy is not a development tool. The journal
#       keeps its Debian default.
#
#   `systemctl enable ssh`
#       Enabling sshd also starts it, with Debian's password authentication on,
#       on a machine that may or may not be meant to be reachable. That call is
#       the operator's.
#
#   The /usr/local/bin/fd symlink
#       Same name, same effect, no system directory: the symlink goes to
#       ~/.local/bin, which uv's own shell setup already puts on PATH.
#
#   systemd, systemd-sysv, dbus, openssh-server, openssh-client
#       In a standard Debian install already -- systemd always, ssh because it
#       is selected in the installer's task list. The image needs the units
#       because a base image is not bootable; listed here they are a no-op.
#
#   Baked SSH host keys, /etc/machine-id pinning
#       Both are container build artefacts: they give a rebuilt image the same
#       identity so clients do not see the key change. On real hardware that
#       identity is the machine's own, and rewriting it invalidates every
#       known_hosts entry that already trusts this host.
#
#   containerinit.service, the /etc/skel copy, the emoji PS1, `chmod 700 $HOME`
#       Those build the fakevm's throwaway home directory on first boot. A
#       human's home directory is not rebuilt from an image, and silently
#       replacing its dotfiles or its mode is destructive here.
#
#   devuser, `devuser:devuser`, passwordless sudo
#       On a network-reachable machine that hands out a sudoer with a known
#       password. The devkits belong to whoever runs this script instead.
#
#   `systemctl set-default multi-user.target`
#       A Debian install with no desktop task is multi-user.target already.
#
#   The locale and timezone override (Asia/Jakarta, LANG=C.UTF-8)
#       Both are chosen during the install and are about this machine's
#       location, not about tooling. C.UTF-8 is Debian's default anyway, so
#       the package list still installs `locales` and changes nothing else.
#
#   `apt-get upgrade`
#       Patching a real machine -- possibly a kernel -- is the operator's
#       decision, not a side effect of installing tools. Run it yourself.
#
#   Overriding the installers' own configuration
#       fnm, pnpm and uv are left to set themselves up exactly as they do by
#       default: each appends its own block to the shell config, uv writes
#       ~/.local/bin/env, and none of their settings are redirected, so there
#       is no .npmrc, no uv.toml and no pnpm rc file that this script chose.
#       npm is used only for pi, with the command pi's own README documents
#       verbatim (`npm install -g --ignore-scripts ...`), so the lifecycle
#       behaviour there is upstream's choice rather than a setting made here.
#       The consequence, accepted deliberately: re-running the script appends
#       fnm's and pnpm's shell blocks a second time, because that is what
#       re-running those installers does.
#
#   setupdevkits.sh's first-run flag
#       That flag protects a container home that is thrown away and rebuilt
#       from an image. Here it would turn a half-finished run into a dead end,
#       so the script can simply be run again.
#
# What IS kept: the package list verbatim (minus the container-only entries
# above), `fd` under its own name, and the same devkit installers in the same
# order with the same post-install sanity check.
# ---------------------------------------------------------------------------

set -e
set -u
set -o pipefail

# The package set from the Containerfile, minus the container-only entries and
# the two SSH packages explained above. Kept in the image's order so the two can
# be diffed.
APT_PACKAGES=(
  ca-certificates
  sudo
  procps
  iproute2
  iputils-ping
  lsof
  netcat-openbsd
  tmux
  man-db
  unzip
  file
  python3
  python3-pil
  perl
  bash-completion
  build-essential
  bind9-dnsutils
  git
  curl
  wget
  vim
  jq
  fd-find
  ripgrep
  imagemagick
  locales
)

# Where the three installers put themselves, at their defaults: fnm under
# ~/.local/share/fnm, pnpm under ~/.local/share/pnpm with executables in its
# bin/, uv in ~/.local/bin (which is also where the fd symlink below goes).
# Only used to assemble PATH for this run's own checks; the installers add the
# same directories to the shell config themselves.
FNM_PATH="$HOME/.local/share/fnm"
PNPM_BIN="$HOME/.local/share/pnpm/bin"
LOCAL_BIN="$HOME/.local/bin"

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

_usage() {
  cat <<'EOF'
usage: provision-debian.sh [-h]

Install the fakevm's tooling on a real Debian machine: the Containerfile's
packages, then fnm + node LTS, pnpm, uv and pi in the calling user's home.

Needs sudo for the packages only; nothing on the machine is reconfigured and
no service is enabled. Run it as a normal user, not as root.

  -h, --help   this text
EOF
}

_parsing_args() {
  while (($# > 0)); do
    case "$1" in
      -h|--help)
        _usage
        exit 0
        ;;
      *)
        printf 'error: unknown argument %s\n\n' "$1" >&2
        _usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

_have() {
  command -v "$1" >/dev/null 2>&1
}

_preflight() {
  # The devkits must land in the caller's home, and the script assumes $HOME is
  # that. Root's home is the wrong home, and quietly installing there is worse
  # than refusing.
  if [[ $EUID -eq 0 ]]; then
    printf 'error: run this as your normal user account, not as root.\n' >&2
    printf '       it calls sudo itself for the packages and installs the\n' >&2
    printf '       devkits into the home of whoever runs it.\n' >&2
    exit 1
  fi

  if [[ ! -r /etc/os-release ]]; then
    printf 'error: /etc/os-release is missing; this does not look like Debian.\n' >&2
    exit 1
  fi
  local id="" like=""
  # shellcheck disable=SC1091
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
  case "$id" in
    debian) ;;
    *)
      printf 'warning: ID=%s, not debian -- the script assumes Debian package\n' "${id:-unknown}" >&2
      printf '         names and an apt that works without prompts%s\n' \
        "${like:+ (ID_LIKE=$like)}" >&2
      ;;
  esac

  if ! _have apt-get; then
    printf 'error: apt-get not found.\n' >&2
    exit 1
  fi
  if ! _have sudo; then
    printf 'error: sudo not found; install it and add yourself to the sudoers group.\n' >&2
    exit 1
  fi

  # One prompt here, up front, instead of the first one landing in the middle
  # of a wall of apt output. If the timestamp expires during a long install,
  # apt asks again -- sudo handles that itself.
  printf 'sudo is needed for the packages; asking once now.\n'
  if ! sudo -v; then
    printf 'error: sudo failed.\n' >&2
    exit 1
  fi
}

_apt() {
  # --force-confold: keep the existing config file when a package ships a new
  # default (ca-certificates is the usual one), instead of stopping to ask a
  # question nobody is there to answer.
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confold "$@"
}

_install_packages() {
  printf '\n==> packages (%d)\n' "${#APT_PACKAGES[@]}"
  _apt update
  # This is the whole of the script's system-wide footprint: packages, and
  # nothing else. No `upgrade` (see the header), and no
  # `--no-install-recommends` -- the image installs with recommends, so
  # matching it keeps the two comparable.
  _apt install -y "${APT_PACKAGES[@]}"
}

_link_fd() {
  printf '\n==> fd\n'
  # Debian ships the binary as `fdfind` because `fd` collides with an older
  # package's name. The image symlinks it into /usr/local/bin; this puts the
  # same link in the user's ~/.local/bin instead, which uv's own shell setup
  # already puts ahead of /usr/bin. -L is tested separately: a dangling symlink
  # is not -e, and overwriting one is still overwriting.
  if [[ ! -x /usr/bin/fdfind ]]; then
    printf 'warning: /usr/bin/fdfind is missing; skipping the fd symlink.\n' >&2
    return
  fi
  mkdir -p "$LOCAL_BIN"
  if [[ -e "$LOCAL_BIN/fd" || -L "$LOCAL_BIN/fd" ]]; then
    printf '%s/fd already exists, leaving it alone.\n' "$LOCAL_BIN"
    return
  fi
  ln -s /usr/bin/fdfind "$LOCAL_BIN/fd"
  printf 'linked %s/fd -> /usr/bin/fdfind\n' "$LOCAL_BIN"
}

_install_fnm_node() {
  printf '\n==> fnm + node LTS\n'
  # The installer appends its own `# fnm` block to ~/.bashrc, which is its
  # default and is left alone.
  curl -fsSL https://fnm.vercel.app/install | bash

  export PATH="$FNM_PATH:$PATH"
  eval "$(fnm env --shell bash)"

  fnm install --lts
  fnm default lts/latest
}

_install_pnpm() {
  printf '\n==> pnpm\n'
  # Default behaviour throughout: pnpm's installer runs `pnpm setup`, which
  # places pnpm under ~/.local/share/pnpm and adds PNPM_HOME to ~/.bashrc.
  curl -fsSL https://get.pnpm.io/install.sh | sh -
}

_install_uv() {
  printf '\n==> uv\n'
  # Default behaviour: uv installs into ~/.local/bin and writes
  # ~/.local/bin/env, which the installer sources from the shell profile.
  curl -LsSf https://astral.sh/uv/install.sh | sh
}

_install_pi() {
  printf '\n==> pi\n'
  # pi's documented install line, verbatim -- README.md and docs/quickstart.md
  # both use it with --ignore-scripts, and the package is built to work that
  # way. This is the one npm invocation in the script, and it changes no npm
  # setting: no .npmrc is written and npm's own defaults are otherwise intact.
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  pi install npm:@xynogen/pix-gate
  pi install npm:pi-web-access
}

_show_version() {
  local name="$1"
  shift

  if ! _have "$name"; then
    printf '  %-8s MISSING\n' "$name"
    return 0
  fi
  printf '  %-8s %s\n' "$name" "$("$name" "$@" 2>&1 | head -n 1)"
}

_verify() {
  printf '\n=== base tools ===\n'
  _show_version git --version
  _show_version rg --version
  _show_version fd --version
  _show_version jq --version
  _show_version tmux -V
  _show_version python3 --version
  _show_version vim --version

  printf '\n=== devkits ===\n'
  _show_version fnm --version
  _show_version node --version
  _show_version npm --version
  _show_version pnpm --version
  _show_version uv --version
  _show_version pi --version
}

_main() {
  _parsing_args "$@"

  _preflight
  _install_packages
  _link_fd

  # PATH for the rest of this run only. The installers write their own blocks
  # into ~/.bashrc, which a non-interactive script never reads.
  export PATH="$FNM_PATH:$PNPM_BIN:$LOCAL_BIN:$PATH"
  _install_fnm_node
  _install_pnpm
  _install_uv
  _install_pi

  _verify

  printf '\nDone. Open a new login shell so the shell config the installers\n'
  printf 'wrote gets read, then check `node --version` and `pi --version`.\n'
}

if ! _is_sourced; then
  _main "$@"
fi
