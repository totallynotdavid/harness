# Skills

Captain stores external skills in `.claude/skills/`. They are regular tracked files.

Skill sources are defined in `config/skill-sources.tsv`. `cap skills sync` updates the source repos used by the skill commands.

Find and install a skill:

```sh
cap skills list mp
cap skills add mp/grilling
```

Check an installed skill against its source:

```sh
cap skills diff grilling
```

`cap skills add` copies the skill into `.claude/skills/` and records its source in `config/skill-snapshots.list`.

`cap skills diff` only shows changes. Updating an installed skill is a normal repo change and should be reviewed and committed.

Imported skills keep their original content. Captain's writing rules only apply to first-party files.
