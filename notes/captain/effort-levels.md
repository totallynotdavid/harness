# Reasoning-effort levels by harness

Research date: 2026-09-02.

This report describes the installed tools, not a proposed Captain change. The
Captain source was left unchanged.

## Captain's actual model mapping

`config/captain.conf` defines these Codex profiles:

| Profile | Harness | Model passed to harness |
| --- | --- | --- |
| `rival` | Codex | `-`, so Codex chooses its configured default |
| `luna` | Codex | `gpt-5.6-luna` |

`codex doctor` reports the configured default model as `gpt-5.6-sol`. Therefore
that is the model currently backing `rival` on this machine.

`bin/cap-spawn` currently invokes Codex as `codex [--model NAME]
--dangerously-bypass-approvals-and-sandbox PROMPT`. It invokes Claude as
`claude [--model NAME] $CAP_WORKER_FLAGS PROMPT`.

## Codex

### Installed version and config

```text
$ codex --version
codex-cli 0.152.0
```

The installed `~/.codex/config.toml` contains:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
```

`codex --help`, `codex exec --help`, and `codex doctor --help` document the
generic override:

```text
-c, --config <key=value>
    Override a configuration value that would otherwise be loaded from
    `~/.codex/config.toml`.
```

`codex exec --help` does not expose a dedicated reasoning-effort option. The
relevant key is exactly `model_reasoning_effort`.

`codex debug --help` exposes only `models`, `app-server`, and `prompt-input`.
There is no config-schema or config-dump command. `codex debug models
--bundled` does expose the bundled model catalog, including per-model
`default_reasoning_level` and `supported_reasoning_levels`.

### Locally advertised levels

The bundled catalog reports:

| Model | Default | Supported levels |
| --- | --- | --- |
| `gpt-5.6-sol` (`rival`) | `low` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-5.6-luna` (`luna`) | `medium` | `low`, `medium`, `high`, `xhigh`, `max` |

Thus `ultra` is supported by the current default Codex model but not by
`gpt-5.6-luna`. Neither selected model advertises `minimal` in this local
catalog.

The catalog is stronger evidence for this installation than generic examples
or the Rust enum. The shipped Codex source enum also contains `none`,
`minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and `ultra`, plus a custom
string variant. The model catalog determines which of those levels a specific
model advertises.

### Unsupported-value behavior

No model request was made for this research, so server-side behavior for an
unsupported effort is unconfirmed. This avoids spending a paid run.

The local parser does not provide fail-closed validation. These safe probes all
exited successfully and produced no stderr, including the unsupported values:

```text
$ codex exec --strict-config --help -c 'model_reasoning_effort="minimal"'
=> exit 0
$ codex exec --strict-config --help -c 'model_reasoning_effort="nonsense"'
=> exit 0
$ codex exec --strict-config --help -c 'model_reasoning_effort=""'
=> exit 0
```

This only proves that `--help` short-circuits before a model call and that the
CLI accepts the override syntactically. It does not prove that the service
accepts `nonsense`, or that it clamps an effort to a model-supported level.
The source's custom-string parser and the per-model catalog suggest that
Captain should validate against the selected model's advertised set if it
wants predictable behavior.

`codex doctor` succeeded:

```text
19 ok · 1 idle · 1 notes · 0 warn · 0 fail ok
```

### Authoritative documentation

The [Codex configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json)
defines `model_reasoning_effort` as the `ReasoningEffort` configuration key.
The [Codex source type](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/openai_models.rs)
shows the generic values and the custom-string fallback. OpenAI's [Codex
guidance](https://github.com/openai/codex/blob/main/codex-rs/skills/src/assets/samples/openai-docs/references/prompting-guide.md)
uses `low`, `medium`, `high`, `xhigh`, and `max` in its current guidance.
The installed bundled catalog remains the source for the two local model
sets above.

## Claude Code

### Installed version and direct CLI support

```text
$ claude --version
2.1.258 (Claude Code)
```

`claude --help` directly documents a non-interactive-launch-compatible flag:

```text
--effort <level>  Effort level for the current session
                  (low, medium, high, xhigh, max)
```

The same installed binary contains and recognizes the environment variable
name `CLAUDE_CODE_EFFORT_LEVEL`. The official documentation confirms that it
accepts `low`, `medium`, `high`, `xhigh`, `max`, or `auto`, and takes precedence
over configured effort settings. `--effort` is session-scoped. `max` is
session-only unless supplied through the environment variable.

Effort is adaptive reasoning control, not a manually specified thinking-token
budget. The official model table currently lists effort support for Opus 4.7,
Opus 4.6, and Sonnet 4.6. It does not list Haiku. Therefore the Captain
aliases `opus` and `sonnet` are plausible supported targets only when they
resolve to those supported model generations; no effort support should be
assumed for the `haiku` profile from the evidence collected here.

When a requested level is above the active model's supported maximum, the
official documentation says Claude Code falls back to the highest supported
level at or below the requested level. For example, `xhigh` becomes `high` on
models that support only through `high`. This is documented behavior, unlike
the untested Codex server behavior.

### Fast mode

`/fast` is an interactive command. `claude --help` has no `--fast` or
`--thinking-budget` flag. The official documentation describes fast mode as a
separate, faster API configuration for the Opus model, not a reasoning-effort
level.

Fast mode can be enabled non-interactively through settings passed at launch,
for example with Claude's existing `--settings` option and a settings JSON
containing `{"fastMode":true}`. The documented persistent setting is
`fastMode: true`. The documented environment variable
`CLAUDE_CODE_DISABLE_FAST_MODE=1` disables fast mode; no documented
environment variable enables it. Fast mode availability, target Opus version,
pricing, and organization permissions are separate concerns from effort.

The [Claude Code model configuration documentation](https://code.claude.com/docs/en/model-config)
documents `--effort`, model-dependent levels, fallback behavior, and
`CLAUDE_CODE_EFFORT_LEVEL`. The [environment-variable documentation](https://code.claude.com/docs/en/env-vars)
documents the environment override and `CLAUDE_CODE_DISABLE_THINKING`.
The [fast-mode documentation](https://code.claude.com/docs/en/fast-mode)
documents `/fast`, `fastMode`, and the distinction between fast mode and effort.

## Design-relevant conclusions

1. Codex has one exact config key, `model_reasoning_effort`, but its valid
   levels are model-dependent. For this Captain configuration, `ultra` must
   not be sent to `gpt-5.6-luna`; `gpt-5.6-sol` does advertise it.
2. The Codex CLI's generic config parser does not safely reject arbitrary
   effort strings before a model request. A Captain-level validation policy is
   needed if invalid input must fail clearly.
3. Claude has a real `--effort` flag and a real
   `CLAUDE_CODE_EFFORT_LEVEL` environment override usable by scripted launches.
4. Claude's effort scale is not identical to Codex's scale. `xhigh` and `max`
   exist in the Claude CLI, but model support differs and `max` has special
   session semantics.
5. `/fast` should not be treated as an effort level. It is interactive as a
   command, with non-interactive settings support and a documented disable-only
   environment variable.

## Findings outside the requested design question

No separate Captain bug was found. The installed Codex CLI reports that
version `0.152.1` is available while `0.152.0` is installed. This is an
environment update notice, not an effort-level behavior finding, and is left
as a separate operational concern rather than folded into the design.
