# devinstall

One script that turns a freshly installed Debian machine into the same development
environment the `devstack` fakevm ships — the tooling half of that container, on
real hardware.

The fakevm builds its environment from a `Containerfile` plus a first-boot script
that installs the language toolchains. This repository reproduces that environment
on a machine Debian installed itself on: a standard install, no desktop task, SSH
selected during the install. Nothing here is container-aware.

> Status: the package list and the three installers have been checked on Debian 13
> (trixie); the script as a whole has not yet been run end to end on a machine
> straight out of the installer.

## Contents

- [What it installs](#what-it-installs)
- [Requirements](#requirements)
- [Install](#install)
- [What it deliberately does not do](#what-it-deliberately-does-not-do)
- [Re-running it](#re-running-it)
- [Verifying an install](#verifying-an-install)
- [Repository layout](#repository-layout)
- [Security notes](#security-notes)
- [Licence](#licence)

## What it installs

`provision-debian.sh` does two things, in this order.

### 1. Packages

The 11 packages from the fakevm image's list that a Debian install does not
already provide:

```
tmux unzip python3-pil build-essential git curl vim jq fd-find ripgrep
imagemagick
```

The rest of the image's list repeats what is already there, so it is not carried
over:

| Left out | Why |
|---|---|
| `systemd`, `systemd-sysv`, `dbus` | The base system. The image needs them only because a base image is not bootable. |
| `openssh-server`, `openssh-client` | The Debian installer's SSH task. `openssh-client` is in the standard task as well. |
| `ca-certificates`, `procps`, `iproute2`, `iputils-ping`, `lsof`, `netcat-openbsd`, `man-db`, `file`, `perl`, `bash-completion`, `bind9-dnsutils`, `wget`, `locales` | `Priority: standard` or higher, so they arrive with the standard system utilities task. |
| `python3` | In the standard task on a live install, and a dependency of `python3-pil` in any case. |
| `sudo` | Required before anything can be installed at all, so an `apt` line for it could never do anything. `_preflight` stops with an error when it is missing. |

Debian ships `fd` as `fdfind` (the name `fd` belongs to an older package), so the
script links `~/.local/bin/fd` at it. In the home directory, not `/usr/local/bin`:
same name, same result, no system directory touched.

### 2. Language toolchains

Into the home directory of whoever runs the script:

| Tool | How | Where |
|---|---|---|
| fnm | its own installer, then `fnm install --lts` | `~/.local/share/fnm` |
| Node.js | latest LTS, set as fnm's default | `~/.local/share/fnm/node-versions` |
| pnpm | standalone installer (`pnpm setup`) | `~/.local/share/pnpm` |
| uv | its own installer | `~/.local/bin` |
| pi | `npm install -g --ignore-scripts @earendil-works/pi-coding-agent` | fnm's global prefix |
| pi extensions | `pi install npm:@xynogen/pix-gate`, `pi install npm:pi-web-access` | `~/.pi` |

Every one of them runs at its own defaults. fnm appends its `# fnm` block to
`~/.bashrc`, pnpm adds `PNPM_HOME` to it, uv writes `~/.local/bin/env` and sources
it from the shell profile. This repository writes no shell config of its own and
overrides none of their settings: no `.npmrc`, no `uv.toml`, no pnpm rc file. The
one npm flag in the script, `--ignore-scripts`, is part of pi's documented install
line rather than a setting made here.

## Requirements

- Debian, installed without a desktop. Targeted at Debian 13 (trixie), where
  every package name in the list was checked with `dpkg`. Nothing in the script is
  trixie-specific, but that is the only release it has been written against; on an
  older one, run `bash -n` and read the package list first.
- A normal user account in the `sudo` group. The script installs packages through
  `sudo` and everything else into `$HOME`, so it refuses to run as root — root's
  home is the wrong home.
- Network access: apt, plus three installer scripts and the npm registry.
- A login shell afterwards. PATH comes from the config the installers write, which
  a non-interactive script never reads; the script assembles its own PATH for the
  checks it runs at the end.

`openssh-server` is not in the package list. It is selected in the Debian
installer's task list, so a machine set up for remote access already has it.

## Install

```bash
git clone git@github.com:arinanto/devinstall.git
cd devinstall
./provision-debian.sh
```

The script prints a `==>` line per step and a version table at the end. It asks
for the sudo password once, at the start, rather than in the middle of a wall of
apt output. Expect a few minutes; most of it is the package install and the Node
LTS download.

Then open a new login shell:

```bash
exec bash -l
node --version && pnpm --version && uv --version && pi --version
```

## What it deliberately does not do

This is the boundary that matters, because the fakevm's `Containerfile` does more
than install tools. None of the following is copied here:

| Not done | Why |
|---|---|
| `apt-get upgrade` | Patching a real machine, possibly its kernel, is the operator's decision. |
| Enabling or reconfiguring any service | No `systemctl enable`, no journald drop-in, no unit files. Remote access and logging policy are set up by the install, or by you. |
| Writing under `/etc` | Nothing in `/etc` is created or edited. |
| Creating users, sudoers, locale, timezone | The machine already has an identity and a location; the fakevm's `devuser` with a known password and passwordless sudo would be a hole on a network-reachable box. |
| Baked SSH host keys, `machine-id` pinning | Container build artefacts. On hardware they are the machine's own identity, and rewriting them breaks every client that already trusts it. |
| The fakevm's skel copy, emoji prompt, `chmod 700 $HOME` | Those build a throwaway home from an image. A human's home directory is not rebuilt, and replacing its dotfiles is destructive. |
| A first-run flag file | That flag protects a container home rebuilt from an image. Here it would only make a half-finished run unrecoverable. |

The whole of the script's footprint outside `$HOME` is the package installation.

## Re-running it

Safe, with one visible consequence:

- apt already has the packages → no-op.
- `~/.local/bin/fd` exists → skipped, with a note.
- The three installers run again, and fnm's and pnpm's shell blocks get appended to
  `~/.bashrc` a second time. That is what re-running those installers does; the
  script does not fight it, because fighting it would mean overriding their
  defaults.

## Verifying an install

The script ends with its own check. A healthy run looks like this:

```
=== base tools ===
  git      git version 2.47.3
  rg       ripgrep 14.1.1
  fd       fdfind 10.2.0
  jq       jq-1.7
  tmux     tmux 3.5a
  python3  Python 3.13.5
  vim      VIM - Vi IMproved 9.1 (2024 Jan 02, compiled ...)
=== devkits ===
  fnm      fnm 1.39.0
  node     v26.13.0
  npm      11.20.0
  pnpm     12.18.0
  uv       uv 0.13.7 (x86_64-unknown-linux-gnu)
  pi       1.5.0
```

Those are the versions on the trixie machine this was developed against; the
script prints whatever is actually installed. Version numbers move — a `MISSING`
line is the thing to look at. `--help` prints usage and exits without touching
anything.

## Repository layout

```
LICENSE               Apache-2.0
.gitignore            platform cruft only (linux, windows, macos)
README.md             this file
provision-debian.sh   the installer: packages, then toolchains
```

There is no test suite and no build step. `bash -n provision-debian.sh` is the
only static check.

## Security notes

- Run it against a machine you installed, not against a shared box: it installs
  packages and writes into one user's home.
- It installs pi plus two extensions from npm, and pi is the agent that will then
  run on that machine. The approval gate extension (`@xynogen/pix-gate`) is one of
  them; its rules live in its own package, not here.
- `--ignore-scripts` on the npm install follows pi's README. The pi extensions
  are installed by `pi install`, which is not npm.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE).
