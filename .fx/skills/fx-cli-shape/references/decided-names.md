# Decided names

Names the maintainers already settled. Reuse them; don't add another spelling. "Planned" means not built yet: design toward it, but don't tell users to run it.

## Resume

| Spelling | Opens | Status |
|---|---|---|
| `fx -c`, `fx --continue` | The session you last worked in interactively | Keep |
| `fx -r [last\|<id>]`, `fx --resume [last\|<id>]` | One flag in short and long form. With no value, the session picker, the same list as `/resume`. `last` opens the newest saved session, and an ID opens that one | Keep |
| `fx session resume [last\|<id>]` | The newest saved session (also with no value), or an exact one | Keep |
| `fx ask --resume <last\|id>` | Same, for one-shot runs | Keep |
| `/resume` | Inside a session | Keep |
| `fx --resume-last`, `fx --resume-<id>`, hidden `fx resume`, the `--id <id>` forms, `fx ask --resume-id`, `--resume --last` | Duplicates of the above | Removed. Each fails with exit 2 and names its replacement. `fx resume <id> --upgrade-relaunch` stays as the internal restart after an upgrade |

"Newest" includes sessions `fx ask` created; "where I left off" doesn't, because `fx ask` never records the remembered session.

## Permission mode

| Surface | Name |
|---|---|
| Setting | `permission_mode`: `ask`, `auto`, or `full-access` (legacy `yolo` is read, never written) |
| Flag | `--permission-mode <mode>` (planned), with aliases `--ask` (planned), `--auto`, `--full-access`, `--yolo` |
| Env var | `FX_PERMISSION_MODE` |
| Slash command | `/permissions [ask\|auto\|full-access\|reset]` |
| Read-only view | `fx permissions` |

## Scopes

| Word | Means |
|---|---|
| `--global` | The profile, `~/.fx/settings.json` |
| `--workspace` | This folder's entry in the profile |
| `--project` | A committed file in the repo, only for commands that write one (`fx mcp` and `.mcp.json`) |

`fx mcp --profile` becomes an alias of `--global`. The mapping for `/allowlist local` and `user` is still to be checked.

## Settings and their surfaces

| Concept | Name |
|---|---|
| Settings command | `fx config list\|get` with `--global`, `--workspace`, `--show-origin`; `set\|unset` planned |
| Generic per-run override | Working name `--config key=value` (planned; spelling not settled) |
| Sound | `sound.turn_end`, `sound.attention_required`, `sound.max` (today `notifications.*`, still read); `/sound on\|off\|max` and `FX_SOUND` are presets for the group |
| Status line | `status_line.*` (today `statusLine`, still read) |
| Experiments | `experimental.<name>`, for example `experimental.sessions_v2` |
| Home | `FX_HOME` (planned; default `~/.fx`) |
| Test hooks | `FX_TEST_*` |
| Release channel | `update_channel`; `fx upgrade --channel <name>` saves it, the way a setter command does |
| Save a default model | Today `/model` in a session saves it to the profile. Planned: `fx config set model <id>` |
| User aliases | `alias.<name>` (planned) |

## Accounts

| Concept | Name |
|---|---|
| Sign in, including pasting an AI Gateway key | `fx login [vercel\|codex\|grok]` |
| `fx setup`, `/setup` | Being folded into `fx login`; don't give "setup" a new meaning |
| Choose the active provider | `fx provider <name>`, `/provider` |

## Other

| Concept | Name |
|---|---|
| Shell completion | `fx completion bash\|zsh\|fish` (planned) |
| MCP servers | `fx mcp` (stays the command) |
| Usage and spend | `fx usage`, `/usage` (`/cost`) |
| In-session token and turn statistics | `/stats` |
| Exit codes | 0 success, 1 failure, 2 usage error |
| Start a session with a first prompt | `fx "<prompt>"`, one quoted argument; after a resume target, `fx -c "<prompt>"` or `fx -r <id\|last> "<prompt>"` |
| Run one request and exit | `fx ask "<prompt>"`; `-p` and `--print` only point to it |
| Versioned JSON | `--json=v2` when a shape must change |
