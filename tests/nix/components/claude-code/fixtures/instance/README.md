# claude-code test instance

The fixture instance of the claude-code component tests: the minimal
instance with `[components.claude-code]` enabled on both systems, a
fresh-mode and an adopt-mode profile. `versions.lock.json` holds the
framework sections only; tests merge the component seed into a copy, the way
`dotsteward init` does. `../cases` holds alternative `workstation.toml`
files passed as `config`.
