# fx control-surface rules

The full rules behind SKILL.md, by mechanism. Each rule says whether the code follows it today or whether it describes the target. Design new work toward the target. Never present a target piece as if it already exists.

## Contents

1. [Mechanisms](#mechanisms)
2. [Names](#names)
3. [Precedence](#precedence)
4. [Commands](#commands)
5. [Flags](#flags)
6. [Settings](#settings)
7. [Env vars](#env-vars)
8. [Slash commands](#slash-commands)
9. [Output, errors, and exit codes](#output-errors-and-exit-codes)
10. [Experiments](#experiments)
11. [Stability and deprecation](#stability-and-deprecation)
12. [One source of truth](#one-source-of-truth)

## Mechanisms

| Mechanism | Job | Lasts for | Example |
|---|---|---|---|
| Subcommand | An action | One run | `fx ask`, `fx workspace add` |
| Argument | What the action works on | One run | `fx session <id>` |
| Global flag | Shape the whole launch, before the subcommand | One run | `fx --add-dir ../lib ask ...` |
| Command flag | Shape this command's run | One run | `fx ask --model x` |
| Profile setting | A personal standing preference | Until changed | `~/.fx/settings.json` |
| Profile workspace entry | A personal preference for one folder | Until changed | `workspaces["<path>"]` in the profile |
| Project setting | A team default, untrusted | The repo's life | `.fx.json` |
| Env var | Context from CI, wrappers, terminals, diagnostics, tests | The process and its children | `FX_TRACE=1` |
| Slash command | An action inside a running session | The session, or saved | `/model x` |
| State | Data fx writes for itself | Managed by fx | `~/.fx/sessions/` |
| Secret | Credentials | Managed separately | Keychain, `AI_GATEWAY_API_KEY` |
| Build option | Compiled-in features | The binary | `zig build -D...` |

## Names

- One concept has one name. Each surface writes it in its own case:

  | Surface | Case | Example |
  |---|---|---|
  | Setting key and JSON field | snake_case | `permission_mode` |
  | Flag | kebab-case | `--permission-mode` |
  | Env var | `FX_` plus upper snake case | `FX_PERMISSION_MODE` |
  | Slash command | `/` plus the setting or group name | `/permissions` |
  | libfx and ACP options | The host language's case | `permissionMode` |

- Values use the same words everywhere, in storage too. Permission mode is `ask`, `auto`, or `full-access`. Today full access is still saved as `yolo`; the target writes `full-access` and keeps reading `yolo`.
- Boolean env values accept `1`/`0`, `true`/`false`, `on`/`off`, and `yes`/`no`, trimmed and case-insensitive.
- Today `statusLine` is the one camelCase key. The target reads both and writes `status_line`.

## Precedence

Highest first:

1. Managed by an administrator. Reserved; not built yet.
2. A flag on this command.
3. An env var.
4. The profile's entry for this folder, `workspaces["<path>"]`.
5. The profile, `~/.fx/settings.json`.
6. The project's `.fx.json`, project-safe keys only.
7. The built-in default.

Run flags and env vars never save; setter commands do (see Flags). Every effective value should be able to report its layer. Today `fx status --json` reports `model_origin`; the target is `fx config list --show-origin` for every setting.

## Commands

- A command is a verb (`fx ask`, `fx upgrade`) or a noun plus a verb (`fx workspace add`, `fx session resume`).
- Plain `fx` with one argument that isn't a command starts a session with it as the first prompt: `fx "fix the login bug"`, as other coding agents' CLIs do. Launch flags may go before or after it. Several unquoted words fail and say to add quotes, and a word one or two edits from a command name, such as `stauts`, gets a suggestion instead. So every new command name is also a word that can no longer start a session; choose names people wouldn't type as a whole prompt.
- Group nouns are singular. Plural forms that already exist stay as aliases (`fx sessions`). The target adds `fx session list` as the full form.
- A command that only shows things never changes anything. A setter command, whose whole job is to change a setting, may save: `fx provider codex`, `fx teams`.
- Existing aliases stay: `credits`/`balance`, `/credits`/`/balance`, `/usage`/`/cost`, `/quit`/`/exit`, `/image`/`/img`, `fx sessions`.
- User aliases are planned as `alias.<name>` settings that work as `fx <name>` and `/<name>`. An alias never shadows a built-in command. Today `/alias` only reports that aliases aren't configurable.
- `fx foo` never runs an `fx-foo` program from `PATH`. Skills and MCP are the extension points.
- A hidden command is either internal, and labeled so in its spec, or deprecated. `fx replay` is hidden and labeled as a developer tool in its spec.
- A new top-level command needs a maintainer's explicit approval.

## Flags

- Long flags are kebab-case. Short flags are scarce and keep one meaning: `-h` help, `-v` version, `-c` continue, `-r` resume. A short flag means the same as its long form, so `-r` is the short form of `--resume`: with no value both open the session picker, `last` opens the newest session, and an ID opens that one (`--resume=<id>` works too). Because `-c` is taken, git's `-c key=value` can't be copied.
- `--x value` and `--x=value` both work on every command. The shared parser in `src/core/cli/cli_flags.zig` provides both.
- A boolean pairs `--x` with `--no-x`.
- When a flag repeats or conflicts, the last one wins, on every command. `--fast --no-fast` means Fast mode off; `--fast --ultrafast` means Ultra mode. Every command follows this.
- An enum is one flag that takes the value: `--permission-mode <ask|auto|full-access>`. Shortcut aliases stay: `--auto`, `--full-access`, `--yolo`, plus `--ask`. Plain `fx` and `fx ask` take the whole set; `fx acp` doesn't yet, and `fx pr` and `fx issue` take only `--auto`.
- Flags people bring from other agents get a pointer, not an alias: `fx -p` and `fx --print` fail with exit 2 and say to use `fx ask "<prompt>"`.
- No flag carries a value in its name. `--resume-<id>` was removed and fails with a hint naming `--resume <id>`.
- A flag that shapes a run affects only that run and never saves anything. A setter command saves what it changes, and its flags name what to save: `fx upgrade --channel dev` switches the channel for later upgrades too. Keep it that way rather than making `--channel` one-time: auto-upgrade reinstalls whenever the running build's channel differs from the saved one. A setter should print one line naming the value and the file; `fx upgrade --channel` doesn't yet.
- Agent-run flags form one shared set: `--model`, `--provider`, `--effort`, `--fast`/`--no-fast`, `--ultrafast`/`--no-ultrafast`, `--provider-order`, `--provider-strict`/`--no-provider-strict`, and `--permission-mode` with its shortcuts. Every command that runs the agent accepts the whole set after the subcommand: `fx ask`, `fx acp`, `fx pr`, `fx issue`, `fx session resume`. Plain `fx` takes them directly, as do `fx -c`, `fx -r`, and `fx --resume`. Today `fx acp` lacks most of the set.
- Before the subcommand go only launch-wide flags: `--add-dir`, `--no-additional-dirs`, `--context-limit`. Agent-run flags before a subcommand stay an error whose message shows the corrected command.
- An unknown or invalid flag fails with a message naming it. Every accepted flag appears in help unless its spec marks it internal. CI's `scripts/check_cli_shape.py` checks this for `fx ask` and the global launch flags; other commands aren't checked yet.

## Settings

- Keys are snake_case; nested groups are fine (`sound.turn_end`).
- `.fx.json` accepts only project-safe keys. Today they are `context`, `max_agent_steps`, `max_tool_result_bytes`, `provider_order`, and `provider_strict`, enforced by `parseProjectSafeFields` in `src/core/config/config_runtime.zig`. A new project-safe key needs a maintainer's approval, because anyone who can commit to a repo controls that file.
- A new profile-only key also goes in `isProfileOnlySettingKey`, the hand-kept list that warns when a project file sets it.
- Scope words are `--global` (the profile), `--workspace` (this folder's entry in the profile), and `--project` only for commands that write a committed file, such as `fx mcp` with `.mcp.json`. Today `fx mcp` uses `--project` and `--profile`, and `/allowlist` uses `local` and `user`.
- Planned: `fx config list|get|set|unset` with `--global`, `--workspace`, and `--show-origin`. `fx config` never writes committed files and never handles credentials. `set` and `unset` print one line on stderr naming the key, value, and file, and nothing on stdout. Unknown keys are ignored at startup, reported by `fx doctor` and `fx config list`, and rejected by `fx config get` and `set`.
- Slash commands that change a setting save to the profile and name the file in their confirmation.
- `fx mcp` stays the command for MCP servers.
- Unknown settings keys are ignored today, so a typo does nothing.

## Env vars

Each env var has one job and that job's namespace:

| Job | Namespace | Example |
|---|---|---|
| Override a setting for one process | `FX_<SETTING>`, same name and values as the setting | `FX_MODEL` |
| CI credentials | The provider's own name | `AI_GATEWAY_API_KEY` |
| Location of fx's home | `FX_HOME` (planned) | |
| Integration with the surroundings | `FX_<INTEGRATION>` | `FX_HERDR=0`, `FX_NO_OPEN_BROWSER=1` |
| Diagnostics | `FX_TRACE*`, `FX_RECORD*`, `FX_DEBUG_*` | `FX_TRACE=1` |
| Test hooks | `FX_TEST_*` | Today five prefixes are in use; new hooks use `FX_TEST_` |
| Unix standards | As defined | `NO_COLOR`, `TERM`, `HOME` |

- A setting gets a named env override only when CI jobs or wrapper scripts need it for a whole process tree. Every other setting is reachable through one generic per-run override in the spirit of `git -c key=value`. The override isn't built yet and its spelling isn't settled; `--config key=value` is the working name.
- An override uses the setting's name: `collapse_tool_calls` becomes `FX_COLLAPSE_TOOL_CALLS`, never an invented short name.
- No unprefixed names except Unix standards and third-party integrations' own variables, which are listed under `external_env` in `scripts/cli_shape_registry.json`.
- Every `FX_*` name in `src/` is registered in `scripts/cli_shape_registry.json` with its job and stability; the ones documented on fx.sh are `stable`. CI's `python3 -m scripts.check_cli_shape` fails on an unregistered or stale name.
- An env var shapes context. It never changes what a command does.
- Env vars documented on fx.sh are stable.
- Respect `NO_COLOR` and `TERM=dumb` on every output path, including the interactive session. Today only top-level help does.

## Slash commands

- A slash command that performs an action uses the CLI command's name and verbs: `/workspace add` matches `fx workspace add`.
- A slash command that changes a setting uses the setting's name and values: `/fast on` writes `fast_mode`. This follows vim, where `:set number` matches `set number` in `.vimrc`. `/model` is a picker for model and effort, which is an action.
- A toggle accepts explicit values as well as no argument: `/fast [on|off]`, like `/ultrafast [on|off|status]`.

## Output, errors, and exit codes

- Results go to stdout; progress and diagnostics go to stderr.
- Every command that prints data accepts `--json`. Failures share one shape: `{"kind": ..., "error": ..., "code": ...}`, as `fx session last --json` already does.
- JSON fields are only added. If a shape must change, the new shape is opt-in behind a versioned flag such as `--json=v2`, following git's `--porcelain=v2`. Don't add a `schema_version` field. Commands such as `fx status`, `fx sessions`, and `fx session` already name their JSON shape with `kind`.
- Exit codes: 0 for success, 1 when the work fails, 2 when the command line is wrong. `output_contracts.usage_exit_code` is the 2.
- An error says what happened, which input caused it, and what to do, and suggests the closest match for a typo. A flag error names the flag and the closest documented flag, such as `fx status: unknown flag --jsno (did you mean --json?)`. A mistyped command or global flag gets the same: `fx stauts` suggests `status`, and `fx --modle` suggests `--model`.
- fx never prompts without a terminal. It fails with a message naming the flag that avoids the prompt.

## Experiments

- Each experiment is a setting under `experimental`, such as `experimental.sessions_v2`, off by default.
- Users change it like any setting: `fx config set experimental.<name> true` (planned), an Experimental section in `/settings`, the settings file, or the generic override.
- No experiment gets its own flag or env var. `--sessions-v2` and `FX_SESSIONS_V2` keep working, with a warning, until that experiment ends.
- Experiments are profile-only. A project's `.fx.json` can't turn one on.

## Stability and deprecation

- Every public control carries one label: stable, experimental, deprecated, or internal.
- During the cleanup, stable means `fx ask --json` fields, ACP behavior, and env vars documented on fx.sh. Everything else may change with a changelog entry. From 1.0, everything documented on fx.sh is stable.
- A renamed or removed stable control keeps working with a warning that names its replacement for at least two releases and at least 30 days, whichever is later.

## One source of truth

- The command specs in `src/builtins/commands.zig` drive both help and parsing: each command's `OptionDoc` list is what `cli_flags.Parser` reads. The target adds value types, placement, and stability to those entries so completion and the fx.sh tables can come from the same lists.
- The target adds a settings registry: key, type, default, scopes, project-safe or not, env var, flag, slash command, JSON field, libfx and ACP name, stability. Parsing, help, the fx.sh tables, `fx completion <shell>`, a JSON Schema for settings files, and libfx and ACP names all come from it.
- CI is to fail when code reads an `FX_*` env var, accepts a flag, or parses a setting that the registries don't list.
- A new top-level command, a new stable env var, or a new project-safe setting needs a maintainer's explicit approval in the PR.
