# Commands

Every command below exists in the stand-in CLI of the self-tests.

```bash
DOTSTEWARD_ASSUME_YES=1 dotsteward rebuild --profile main --switch
timeout 60 dotsteward update status --json > status.json
if dotsteward e2e --keep-going --json; then echo green; fi
dotsteward --instance "$PWD" gate --scope update \
  --force
(cd "$PWD" && dotsteward update prepare --scope=update --official-sources-only) 2>&1
```

Text outside a fenced block is not a command: dotsteward gate --not-a-flag.

```text
# A comment is not a command: dotsteward gate --not-a-flag
nix flake update dotsteward --commit-lock-file
dotsteward <command> --help
```

~~~
dotsteward gate --expected-base "$base"
~~~
