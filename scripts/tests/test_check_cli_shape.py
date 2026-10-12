from __future__ import annotations

import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

from scripts import check_cli_shape


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

COMMANDS = """\
pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--model <id>",
        .description = "Override the model",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off",
    },
};

const specs = .{
    .{
        .kind = .ask,
        .token = "ask",
        .options = &.{
            .{ .flag = "--model <id>", .description = "Override the model" },
            json_option,
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
    },
};
"""

CLI_SURFACE = """\
fn parseGlobalLaunchArgs(args: []const []const u8) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--model")) {}
        if (std.mem.eql(u8, arg, "--fast") or std.mem.eql(u8, arg, "--no-fast")) {}
    }
}
"""

CLI_ASK = """\
fn parseOptionsWithStdin(args: []const []const u8) void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {}
        if (std.mem.eql(u8, arg, "--model")) {}
        if (std.mem.startsWith(u8, arg, "--model=")) {}
        if (std.mem.eql(u8, arg, "--json")) {}
    }
}

test "tests may use odd arguments" {
    _ = "--Weird_Flag";
    _ = "FX_ONLY_IN_TESTS";
    _ = .{ .text = "}" };
}
"""

CONFIG_RUNTIME = """\
fn isProfileOnlySettingKey(key: []const u8) bool {
    const keys = [_][]const u8{
        "model",
    };
    _ = keys;
    _ = key;
    return false;
}

fn parseProfileOnlyFields(root: std.json.Value) void {
    if (root.object.get("model")) |value| {
        _ = value;
    }
}

fn parseProjectSafeFields(root: std.json.Value) void {
    if (root.object.get("max_agent_steps")) |value| {
        _ = value;
    }
}
"""

ENV = """\
const model = io_mod.getenv("FX_MODEL");
const home = io_mod.getenv("HOME");
"""


def registry() -> dict:
    return {
        "env": {"FX_MODEL": {"job": "setting-override", "stability": "stable"}},
        "not_env": {},
        "external_env": ["HOME"],
        "exceptions": {"flag_names": {}, "undocumented_flags": {}, "setting_keys": {}},
    }


class CheckCliShapeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.files = {
            check_cli_shape.COMMANDS: COMMANDS,
            check_cli_shape.CLI_SURFACE: CLI_SURFACE,
            check_cli_shape.CLI_ASK: CLI_ASK,
            check_cli_shape.CONFIG_RUNTIME: CONFIG_RUNTIME,
            "src/env.zig": ENV,
        }
        self.registry = registry()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_check(self) -> list[check_cli_shape.Problem]:
        for path, text in self.files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        registry_path = self.root / check_cli_shape.REGISTRY
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        registry_path.write_text(json.dumps(self.registry))
        return check_cli_shape.Checker(self.root).run()

    def edit(self, path: str, old: str, new: str) -> None:
        self.assertIn(old, self.files[path])
        self.files[path] = self.files[path].replace(old, new, 1)

    def assertOnly(self, problems: list[check_cli_shape.Problem], check: str, fragment: str) -> None:
        self.assertEqual(1, len(problems), [problem.render() for problem in problems])
        self.assertEqual(check, problems[0].check)
        self.assertIn(fragment, problems[0].message)

    def test_clean_tree_passes_and_test_blocks_are_ignored(self) -> None:
        self.assertEqual([], self.run_check())

    def test_unregistered_env_var_fails(self) -> None:
        self.files["src/env.zig"] += 'const extra = io_mod.getenv("FX_FAST_DIFF");\n'
        problems = self.run_check()
        self.assertOnly(problems, "env", "FX_FAST_DIFF is not in")
        self.assertEqual(("src/env.zig", 3), (problems[0].path, problems[0].number))

    def test_env_name_read_through_a_constant_still_counts(self) -> None:
        self.files["src/env.zig"] += 'const name = "FX_HIDDEN";\nconst value = io_mod.getenv(name);\n'
        self.assertOnly(self.run_check(), "env", "FX_HIDDEN is not in")

    def test_not_env_literal_is_accepted_and_stale_entries_fail(self) -> None:
        self.files["src/env.zig"] += 'const service = "FX_KEYCHAIN_SERVICE";\n'
        self.registry["not_env"] = {"FX_KEYCHAIN_SERVICE": "keychain service name"}
        self.assertEqual([], self.run_check())
        self.registry["not_env"]["FX_GONE"] = "no longer used"
        self.assertOnly(self.run_check(), "env", "not_env lists FX_GONE")

    def test_stale_and_malformed_env_entries_fail(self) -> None:
        self.registry["env"]["FX_GONE"] = {"job": "test", "stability": "internal"}
        self.assertOnly(self.run_check(), "env", "FX_GONE is registered but no longer appears")
        del self.registry["env"]["FX_GONE"]
        self.registry["env"]["FX_MODEL"]["job"] = "setting"
        self.assertOnly(self.run_check(), "env", "FX_MODEL has job 'setting'")

    def test_unprefixed_env_var_fails_unless_listed(self) -> None:
        self.files["src/env.zig"] += 'const legacy = io_mod.getenv("FLASH_SYNC_UPDATES");\n'
        self.assertOnly(self.run_check(), "env", "FLASH_SYNC_UPDATES is read but is neither")
        self.registry["external_env"].append("FLASH_SYNC_UPDATES")
        self.assertEqual([], self.run_check())
        self.registry["external_env"].append("NOT_READ")
        self.assertOnly(self.run_check(), "env", "external_env lists NOT_READ")

    def test_flag_names_must_be_kebab_case(self) -> None:
        self.edit(check_cli_shape.COMMANDS, '"--model <id>", .description', '"--noColor", .description')
        self.edit(check_cli_shape.CLI_ASK, '"--model")', '"--noColor")')
        self.edit(check_cli_shape.CLI_ASK, '"--model=")', '"--noColor=")')
        self.assertOnly(self.run_check(), "flags", '"--noColor" must be kebab-case')

    def test_value_inside_flag_name_fails_until_excepted_and_exception_goes_stale(self) -> None:
        self.edit(
            check_cli_shape.COMMANDS,
            '.usage = "--fast, --no-fast"',
            '.usage = "--fast, --no-fast, --resume-<id>"',
        )
        self.assertOnly(self.run_check(), "flags", '"--resume-<id>" must be kebab-case')
        self.registry["exceptions"]["flag_names"]["--resume-<id>"] = "being removed"
        self.assertEqual([], self.run_check())
        self.edit(check_cli_shape.COMMANDS, ", --resume-<id>", "")
        self.assertOnly(self.run_check(), "registry", 'flag_names "--resume-<id>" no longer matches')

    def test_undocumented_ask_flag_fails(self) -> None:
        self.edit(check_cli_shape.CLI_ASK, '"--json")) {}', '"--json")) {}\n        if (std.mem.eql(u8, arg, "--verbose")) {}')
        problems = self.run_check()
        self.assertOnly(problems, "help", "ask accepts --verbose")
        self.registry["exceptions"]["undocumented_flags"]["ask --verbose"] = "internal"
        self.assertEqual([], self.run_check())

    def test_undocumented_global_flag_fails(self) -> None:
        self.edit(
            check_cli_shape.CLI_SURFACE,
            '"--model")) {}',
            '"--model")) {}\n        if (std.mem.eql(u8, arg, "--provider-order")) {}',
        )
        self.assertOnly(self.run_check(), "help", "global accepts --provider-order")

    def test_settings_keys_must_be_snake_case(self) -> None:
        self.edit(check_cli_shape.CONFIG_RUNTIME, '"model",\n', '"model",\n        "statusLine",\n')
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n',
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n    _ = root.object.get("statusLine");\n',
        )
        self.assertOnly(self.run_check(), "settings", '"statusLine" must be snake_case')
        self.registry["exceptions"]["setting_keys"]["statusLine"] = "being renamed"
        self.assertEqual([], self.run_check())

    def test_profile_only_key_without_project_warning_fails(self) -> None:
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n',
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n    _ = root.object.get("auto_compact_percent");\n',
        )
        problems = self.run_check()
        self.assertOnly(problems, "warnings", '"auto_compact_percent" is profile-only')
        self.assertEqual((check_cli_shape.CONFIG_RUNTIME, 11), (problems[0].path, problems[0].number))

    def test_project_safe_keys_need_no_profile_warning(self) -> None:
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            '"max_agent_steps"',
            '"max_tool_result_bytes"',
        )
        self.assertEqual([], self.run_check())

    def test_missing_parser_is_a_source_error(self) -> None:
        self.edit(check_cli_shape.CLI_ASK, "fn parseOptionsWithStdin(", "fn parseOptionsRenamed(")
        self.run_check_files_only()
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = check_cli_shape.main(["--root", str(self.root)])
        self.assertEqual(2, code)
        self.assertIn("cannot find fn parseOptionsWithStdin", stderr.getvalue())

    def run_check_files_only(self) -> None:
        try:
            self.run_check()
        except check_cli_shape.ShapeSourceError:
            pass

    def test_real_tree_passes(self) -> None:
        problems = check_cli_shape.Checker(REPO_ROOT).run()
        self.assertEqual([], [problem.render() for problem in problems])


if __name__ == "__main__":
    unittest.main()
