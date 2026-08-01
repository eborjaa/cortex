## What & why


## Checklist
- [ ] `shellcheck lib/*.sh` clean (and `bash -n`)
- [ ] Bash 3.2 compatible (no `declare -A`, no bash-4isms)
- [ ] No personal data / hardcoded paths / channel IDs / keys in `bin/`,`lib/`,`templates/`
- [ ] Ships no Buzz code (orchestrates a user-installed `$BUZZ_REPO`)
- [ ] `cortex init` into a scratch dir + `cortex doctor` still work
- [ ] Docs / `templates/factory.config.example` updated if behavior changed
