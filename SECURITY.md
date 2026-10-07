# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private
vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue for a security
problem.

Include what you found, how to reproduce it and the impact you expect. You
will get an acknowledgement, and a fix is released as soon as it is ready.

## Supported versions

Only the latest release receives security fixes. An instance pins one
framework release; the `dotsteward-update` skill upgrades it after reading
the release notes.

## Scope

dotsteward runs on your own machine with your own privileges, and some steps
ask for administrator rights (installing Nix, system packages, the login
shell). Reports about these steps, about the privacy scanner missing personal
data or secrets, and about anything that could leak data from a private
instance into a public repository are especially welcome.

Personal data or a secret found in the framework repository itself is a
security problem too: report it the same way, without repeating the data in
public. [docs/privacy.md](docs/privacy.md) describes the safeguards that
should have stopped it.
