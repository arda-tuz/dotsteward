# apt-policy: maintenance

Notes for `dotsteward-update` and for a change of the component.

## Pins

None: the component is the text of its system files, part of the framework. A new release of
the framework that changes a file reaches a machine with its next `dotsteward upgrade` (the sudo
window writes the files that differ) or `dotsteward install --profile PROFILE --component
apt-policy`.

## A change of the drop-in

Keep the keys that unattended-upgrades reads and the E2E hook checks in step: a key the drop-in
sets is one the hook reads with `apt-config`, on the apt of every supported Ubuntu release
(`tests/container`, scenario `apt-policy`).
