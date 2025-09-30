# gershwin-build

This is intended for Gershwin developers only.  For more stable packaging with applied defaults use GhostBSD.

## Supported Operating Systems

* FreeBSD
* GhostBSD (requires `sudo pkg install -g 'GhostBSD*-dev'` for building)
* Arch Linux
* Debian

## Requirements for building

* sudo or root access
* git

## Building from source, installation and uninstallation

After installing, configuring the above requirements run the following commands to get the rest of the requirements for building:

```
git clone https://github.com/gershwin-desktop/gershwin-build.git && cd gershwin-build
```

```
sudo ./bootstrap.sh
```

```
./checkout.sh
```

To build and install Gershwin from sources run the following:

```
sudo make install
```

To remove Gershwin installed from sources run the following:

```
sudo make uninstall
```

## Requirements for usage

* xorg or xlibre

## Usage

After making sure usage requirements are met the following should be run as regular user to start Gershwin after logging in:

```
. /System/Library/Makefiles/GNUstep.sh
startx /System/Applications/GWorkspace.app/Gworkspace
```
## Additional Notes

> Note for users of `sudo`: You can avoid having to constantly use `sudo -E` flag to install apps you build by putting the following files into your `sudoers.d` directory
> ```
> # on FreeBSD
> sudo echo "Defaults env_keep += \"PATH GNUSTEP_MAKEFILES GNUSTEP_PATHS LD_LIBRARY_PATH DYLD_LIBRARY_PATH OBJC_RUNTIME OBJCFLAGS\"" > /usr/local/etc/sudoers.d/10_gershwin_env_keep
> sudo echo "Defaults secure_path=\"/System/Library/Tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" > /usr/local/etc/sudoers.d/10_gershwin_secure_path
> ```
