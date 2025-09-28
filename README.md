# gershwin-build

This is intended for Gershwin developers only.  For more stable packaging with applied defaults use GhostBSD.

## Supported Operating Systems

* FreeBSD
* GhostBSD (requires `sudo pkg install -g 'GhostBSD*-dev'`)
* Arch Linux

## Requirements for building

* sudo or root access
* git

## Building

After installing and configuring the above requirements run the following as a regular user the first time to make sure all other requirements are met:

```
sudo ./bootstrap.sh
```

Then run the following as a regular user to checkout or update repos defined in the checkout.sh script

```
sudo ./checkout.sh
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

Then run the following as a regular user or source in shell profile:

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
