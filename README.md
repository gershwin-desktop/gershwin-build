# gershwin-developer

This is intended for Gershwin developers only.  For more stable packaging with applied defaults use GhostBSD.

## Supported Operating Systems

* FreeBSD
* GhostBSD (requires `pkg install -g 'GhostBSD*-dev'` for building)
* OpenBSD
* Arch Linux
* Artix (Arch Linux without systemd)
* Debian
* Devuan (Debian without systemd)

## Requirements for building

* root access
* git (e.g., `pkg install git-lite`) (NOTE: Need to use `/usr/local/bin/git` on FreeBSD freshly installed system when chrooted at the end of the installation)

## Building from source, installation and uninstallation

After installing, configuring the above requirements run the following commands as root:

```
#  Get the rest of the requirements for building
git clone https://github.com/gershwin-desktop/gershwin-developer.git /Developer
/Developer/Library/Scripts/bootstrap.sh
/Developer/Library/Scripts/checkout.sh
# Build and install Gershwin from sources
cd /Developer && make install
```

To remove Gershwin installed from sources run the following as root:

```
cd /Developer && make uninstall
```

## Requirements for usage

* xorg or xlibre
* At runtime, the packages mentioned in the respective `.dependencies` file

## Usage

After making sure usage requirements are met the following should be run as regular user to start Gershwin after logging in:

```
startx /System/Library/Scripts/Gershwin.sh
```

or:

```
/System/Library/Scripts/LoginWindow.sh # Starts the X server automatically
```

or, on FreeBSD/GhostBSD: 

```
service loginwindow enable && service loginwindow start
```

## Optional libraries
* libdbus for waiting for the Global Menu to appear and for implementing the FileManager1 service that lets, e.g., web browsers, open the file manager to show the downloaded files
* libsquashfs for AppImage icons

## Build targets

`make install` builds and installs the entire system domain. The build is also
split into granular targets so a single component can be (re)built on its own —
useful for CI and incremental development. Every per-component target requires
the core libraries to be installed first (`make corelibs`). All targets run as
root, like `make install`.

| Target | Builds |
| --- | --- |
| `corelibs` | core libraries (libdispatch, libobjc2, tools-make, libs-base, libs-gui, libs-back) plus gershwin-system, gershwin-assets and the plistupdate hook |
| `workspace` | gershwin-workspace |
| `systempreferences` | gershwin-systempreferences |
| `eau-theme` | gershwin-eau-theme |
| `terminal` | gershwin-terminal |
| `textedit` | gershwin-textedit |
| `windowmanager` | gershwin-windowmanager |
| `components` | gershwin-components (Menu, DirectoryServices, LoginWindow, …) |

For example, build the core libraries once and then just (re)build the workspace:

```
cd /Developer
make corelibs
make workspace
```

## Skipping repositories during checkout

`checkout.sh` clones every repository the build needs. Set `SKIP_REPOS` to a
space- or comma-separated list of repository names to skip cloning/updating some
of them — handy when you provide a repository's sources yourself (for example a
CI checkout of the component under test, symlinked into `Library/Sources/`):

```
SKIP_REPOS="gershwin-workspace gershwin-terminal" /Developer/Library/Scripts/checkout.sh
```

## Building against a development or feature branch

By default `checkout.sh` clones each repository's default branch. Set `BRANCH`
to build against another branch instead — most commonly a `dev` branch holding
work in progress *before it lands in the default branch*:

```
BRANCH=dev /Developer/Library/Scripts/checkout.sh
```

`BRANCH` is generic — any branch name works — so it doubles as a tool for
testing a feature branch across repositories:

```
BRANCH=my-feature /Developer/Library/Scripts/checkout.sh
```

For each repository that **has** the named branch, it is cloned/checked out on
that branch; repositories **without** it fall back to their default branch, so a
partial rollout (where only some repos have the branch yet) just works. The run
logs which repository used the branch and prints a summary at the end. Leaving
`BRANCH` unset keeps the previous behaviour, and `BRANCH` can be combined with
`PINNED` and `SKIP_REPOS`.
