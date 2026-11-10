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
#   ./provision-debian.sh --force
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
#       location, not about tooling. C.UTF-8 is Debian's default anyway, so this
#       script generates no locale and sets no LANG.
#
#   `apt-get upgrade`
#       Patching a real machine -- possibly a kernel -- is the operator's
#       decision, not a side effect of installing tools. Run it yourself.
#
#   Overriding the installers' own configuration
#       fnm, pnpm, uv and pi are left to set themselves up exactly as they do
#       by default: each appends its own block to the shell config where it
#       wants one, uv writes ~/.local/bin/env, and none of their settings are
#       redirected, so there is no .npmrc, no uv.toml and no pnpm rc file that
#       this script chose. Those blocks are also why _require_clean_home reads
#       the shell config and not just the directories: they are what a second
#       run would duplicate.
#
#   The image's `npm install -g --ignore-scripts` line for pi
#       Pi's own installer replaces it: pi.dev/install.sh pins every dependency
#       and switches pi to `pi update` afterwards, where the npm line takes
#       whatever npm resolves at the time. It asks its questions on /dev/tty and
#       has no non-interactive flag, so it runs under `setsid -w` with no
#       terminal: no prompt can block this run, and its "Start pi now?" cannot
#       exec pi in place of this script. Its output goes to a temporary log,
#       deleted when the whole run succeeds and kept when anything fails.
#
#   setupdevkits.sh's first-run flag
#       Not copied as a marker file. The same "provision once" guarantee comes
#       from reading the home instead: _require_clean_home runs first and
#       refuses to start when anything this script would install is already
#       there, naming each path. A marker file and the home can disagree; the
#       home cannot disagree with itself. --force is the way past it, for a run
#       deliberately laid over an existing one, and it skips nothing else.
#
# What IS kept: the package list verbatim (minus the container-only entries
# above), `fd` under its own name, the same devkit installers in the same order
# with the same post-install sanity check -- pi being the one installer swapped,
# as described above.
# ---------------------------------------------------------------------------

set -e
set -u
set -o pipefail

# The Containerfile's development packages, minus everything a Debian install
# already has, so that a run on a configured machine is not a list of no-ops.
# Dropped from the image's list:
#   systemd, systemd-sysv, dbus          -- the base system
#   openssh-server, openssh-client       -- the installer's SSH task
#   ca-certificates, procps, iproute2, iputils-ping, lsof, netcat-openbsd,
#   man-db, file, perl, bash-completion, bind9-dnsutils, wget, locales
#                                        -- Priority standard or higher, i.e.
#                                           part of the standard task
#   python3                              -- in the standard live task, and a
#                                           dependency of python3-pil below
# `sudo` is not listed either: _preflight refuses to start without it, so an
# install line for it could never do anything. Order follows the image so the
# two can be diffed.
APT_PACKAGES=(
  tmux
  unzip
  python3-pil
  build-essential
  git
  curl
  vim
  jq
  fd-find
  ripgrep
  imagemagick
  # Not in the image's list; added here on request, and kept after it so the
  # block above still diffs cleanly against the Containerfile.
  podman
  python-is-python3
)

# Where the installers put themselves, at their defaults: fnm under
# ~/.local/share/fnm, pnpm under ~/.local/share/pnpm with executables in its
# bin/, uv in ~/.local/bin (which is also where the fd symlink below goes), and
# pi under ~/.pi/agent/install with its entrypoint symlinked into ~/.local/bin.
# Only used to assemble PATH for this run's own checks; the installers add the
# same directories to the shell config themselves.
FNM_PATH="$HOME/.local/share/fnm"
PNPM_BIN="$HOME/.local/share/pnpm/bin"
LOCAL_BIN="$HOME/.local/bin"

# Set by --force. Scoped to _require_clean_home: it does not touch the root,
# apt, setsid or sudo checks in _preflight, and does not skip any package.
FORCE=0

# Set by _install_pi. pi's installer writes its progress here instead of the
# terminal, and the log is deleted if the whole run succeeds; _cleanup_pi_log
# keeps it and names it when anything fails.
PI_INSTALL_LOG=""

# Everything in $HOME that the steps below create, for _require_clean_home.
# Caches npm and pnpm fill in (~/.npm, ~/.cache/pnpm, ~/.cache/uv) are left out
# on purpose: they are not components, and refusing over a cache would be noise.
HOME_MARKERS=(
  "$FNM_PATH"
  "$HOME/.local/share/pnpm"
  "$HOME/.local/share/pi-node"
  "$HOME/.config/uv"
  "$LOCAL_BIN/uv"
  "$LOCAL_BIN/uvx"
  "$LOCAL_BIN/pi"
  "$LOCAL_BIN/fd"
  "$HOME/.pi"
)

# The shell blocks the installers append, which a second run would duplicate.
SHELL_FILES=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
SHELL_MARKER_PATTERNS=("# fnm" "PNPM_HOME" ".local/bin/env")

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

_usage() {
  cat <<'EOF'
usage: provision-debian.sh [-f] [-h]

Install the fakevm's tooling on a real Debian machine: the Containerfile's
packages, then fnm + node LTS, pnpm, uv and pi in the calling user's home.

Needs sudo for the packages only; nothing on the machine is reconfigured and
no service is enabled. Run it as a normal user, not as root.

It provisions a home that has nothing in it yet, and refuses to start when any
of those components, or the shell blocks their installers wrote, are already
there. It names what it found.

  -f, --force  continue anyway, over what that check found. Installers re-run
               over their old directories, and the shell blocks they append
               are appended a second time. Nothing else is skipped: root,
               apt, setsid and sudo are still required, and packages are
               still installed.
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
      -f|--force)
        FORCE=1
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

# The script provisions a home, not a home that has already been provisioned.
# Everything it would create is looked for before anything is touched, so a
# second run over its own leftovers is refused rather than silently layered on
# top of them.
_require_clean_home() {
  local found=() marker file pattern

  for marker in "${HOME_MARKERS[@]}"; do
    if [[ -e $marker || -L $marker ]]; then
      found+=("$marker")
    fi
  done

  for file in "${SHELL_FILES[@]}"; do
    [[ -f $file ]] || continue
    for pattern in "${SHELL_MARKER_PATTERNS[@]}"; do
      if grep -Fq -- "$pattern" "$file"; then
        found+=("$file: $pattern")
      fi
    done
  done

  if ((${#found[@]} == 0)); then
    return 0
  fi

  if ((FORCE)); then
    printf 'warning: --force given; continuing over an existing install:\n' >&2
    for marker in "${found[@]}"; do
      printf '         %s\n' "$marker" >&2
    done
    printf '\n' >&2
    return 0
  fi

  printf 'error: this home already has what the script installs:\n' >&2
  for marker in "${found[@]}"; do
    printf '         %s\n' "$marker" >&2
  done
  printf '\n' >&2
  printf '       It provisions a home with none of this in it yet. Remove or undo\n' >&2
  printf '       the entries above to finish or redo a run, or use a fresh account.\n' >&2
  exit 1
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
  if ! _have setsid; then
    printf "error: setsid not found; pi's installer is run without a terminal\n" >&2
    printf '       so that it cannot wait for an answer.\n' >&2
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
  # pi's documented install line, under its managed installer: it pins every
  # dependency and updates with `pi update` from then on.
  #
  # That installer asks its questions on /dev/tty, not stdin, so it is given no
  # controlling terminal at all: `setsid -w` detaches it, the prompts find no tty
  # and the run cannot sit waiting for a keypress, and `-w` makes the exit
  # status the installer's own. Two of those prompts make it necessary rather
  # than tidy: the action menu would block, and "Start pi now?" would exec pi in
  # place of this process, skipping the extensions and the check below.
  #
  # `bash -c` starts a fresh shell, so this script's `set -o pipefail` does not
  # reach the pipeline inside it. Re-stating it there is what makes a failed
  # curl fail: without it, sh reads an empty script and exits 0.
  PI_INSTALL_LOG="$(mktemp "${TMPDIR:-/tmp}/pi-install.XXXXXX.log")"
  printf 'installing without prompts; output in %s\n' "$PI_INSTALL_LOG"
  if ! setsid -w bash -c 'set -o pipefail; curl -fsSL https://pi.dev/install.sh | sh' \
      >"$PI_INSTALL_LOG" 2>&1; then
    printf 'error: pi installer failed.\n' >&2
    exit 1
  fi
  pi install npm:@xynogen/pix-gate
  pi install npm:pi-web-access
}

_cleanup_pi_log() {
  local status=$?
  if [[ -z $PI_INSTALL_LOG ]] || [[ ! -f $PI_INSTALL_LOG ]]; then
    return 0
  fi
  if [[ $status -eq 0 ]]; then
    rm -f "$PI_INSTALL_LOG"
    return 0
  fi
  printf '\npi installer output kept in:\n  %s\n' "$PI_INSTALL_LOG" >&2
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

  # First, before _preflight and before anything is installed: a home that
  # already holds these is not one this script can provision.
  _require_clean_home

  # In _main, not at the top of the file, so that sourcing this does not install
  # a trap in the caller's shell.
  trap _cleanup_pi_log EXIT

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
