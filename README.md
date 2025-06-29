# gershwin-build

This is intended for Gershwin developers only.  For more stable packaging use GhostBSD.

## Requirements

* FreeBSD or Arch Linux
* sudo
* git
* xorg

After installing and configuring the above requirements run the following as a regular user the first time to make sure all other requirements are met:

```
./bootstrap.sh
```

Then run the following as a regular user to checkout or update repos defined in the checkout.sh script

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