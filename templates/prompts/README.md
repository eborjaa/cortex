# Hand-written prompt fallbacks (optional)

By default Cortex **renders** each agent's system prompt from the vault
(`synapse render <agent> <hub> --profile <profile>`) — set per agent in `factory.config`. That keeps
an agent's behaviour defined in Synapse, not duplicated here.

Drop a `<agent>.system.md` in this folder only if you want to **override** the rendered prompt for
that agent, and set `PROMPT_SOURCE=file` (globally) in `factory.config`. Otherwise leave it empty.
