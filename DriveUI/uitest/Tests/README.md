# UI Test harness

This directory is the canonical DriveUI UI test suite for the GNUstep test
framework.  It builds and runs every DriveUI UI test script (`*.uitest`)
found under `UITEST_SEARCH_DIRS` (see `TestInfo`).

The scripts themselves live in the `Tests/` directory of the repository that
owns the component they test:

- Workspace / Dock: `gershwin-workspace/Tests/`
- Menu.app / global menu: `gershwin-components/Menu/Tests/` (GTK tests under
  `heavy/`)
- UITest language: `Tests/control/control_flow.uitest` (here, with the harness)

The cross-repo driver `/Developer/Library/Sources/run-tests.sh` sets
`UITEST_SEARCH_DIRS` to every repository's `Tests/` directory automatically.

- Full documentation: `../../UITesting.md`
- The UITest language: `../../Executor.md`

```sh
gnustep-tests .                        # the control/ language test only
UITEST_SEARCH_DIRS=/Developer/Library/Sources/gershwin-workspace/Tests \
  gnustep-tests .                      # a specific repo's scripts
UI_TEST_LEVEL=full /Developer/Library/Sources/run-tests.sh   # everything
```
