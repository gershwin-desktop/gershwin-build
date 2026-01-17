# gershwin-build

This is intended for Gershwin developers only.  For more stable packaging with applied defaults use GhostBSD.

## Supported Operating Systems

* FreeBSD
* GhostBSD (requires `sudo pkg install -g 'GhostBSD*-dev'` for building)
* Arch Linux
* Artix (Arch Linux without systemd)
* Debian
* Devuan (Debian without systemd)

## Requirements for building

* sudo or root access
* git

## Building from source, installation and uninstallation

After installing, configuring the above requirements run the following commands:

```
#  Get the rest of the requirements for building
git clone https://github.com/gershwin-desktop/gershwin-build.git && cd gershwin-build
sudo ./bootstrap.sh
./checkout.sh
# Build and install Gershwin from sources
sudo make install
```

To remove Gershwin installed from sources run the following:

```
sudo make uninstall
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


## Additional Notes

> Note for users of `sudo`: You can avoid having to constantly use `sudo -E` flag to instal GNUstep apps you build by putting the following files into your `sudoers.d` directory
> ```
> # on FreeBSD
> sudo echo "Defaults env_keep += \"PATH GNUSTEP_MAKEFILES GNUSTEP_PATHS LD_LIBRARY_PATH DYLD_LIBRARY_PATH OBJC_RUNTIME OBJCFLAGS\"" > /usr/local/etc/sudoers.d/10_gershwin_env_keep
> sudo echo "Defaults secure_path=\"/System/Library/Tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" > /usr/local/etc/sudoers.d/10_gershwin_secure_path
> ```

## Optional libraries
* libdbus for waiting for the Global Menu to appear and for implementing the FileManager1 service that lets, e.g., web browsers, open the file manager to show the downloaded files
* libsquashfs for AppImage icons

## Binaries

* https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-build/data/system/artifacts/FreeBSD/14/amd64/
* https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-build/data/system/artifacts/ArchLinux/x86_64/
* https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-build/data/system/artifacts/Debian/x86_64/
