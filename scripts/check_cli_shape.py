"""Fail CI when fx's user-facing controls drift from the shape rules.

The check reads the real source rather than a model of it:

  env       every FX_* name in src/ is registered with a job and a stability,
            every other env var read by name is listed, and nothing is stale
  flags     flags are kebab-case and carry no value inside their name
  parsing   CLI code reads flags through cli_flags and the option lists help
            renders, so no command compares an argument with a flag by hand
  settings  settings keys are snake_case
  warnings  every profile-only key warns when a project .fx.json sets it

Known exceptions live in scripts/cli_shape_registry.json, each with the reason
and the finding that removes it. An exception that no longer matches anything
is reported as stale, so the list only shrinks.

Run from the repository root: python3 -m scripts.check_cli_shape
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REGISTRY = "scripts/cli_shape_registry.json"
COMMANDS = "src/builtins/commands.zig"
CLI_SURFACE = "src/core/cli/cli_surface.zig"
CLI_ASK = "src/core/cli/cli_ask.zig"
CONFIG_RUNTIME = "src/core/config/config_runtime.zig"

JOBS = {
    "setting-override",
    "credentials",
    "location",
    "integration",
    "diagnostics",
    "test",
    "internal",
    "experimental",
}
STABILITIES = {"stable", "experimental", "deprecated", "internal"}

KEBAB_FLAG = re.compile(r"^--[a-z0-9]+(?:-[a-z0-9]+)*$")
SHORT_FLAG = re.compile(r"^-[A-Za-z0-9]$")
SNAKE_KEY = re.compile(r"^[a-z][a-z0-9_]*$")
FX_LITERAL = re.compile(r'"(FX_[A-Z0-9_]+)"')
GETENV_LITERAL = re.compile(r'getenv\("([A-Za-z_][A-Za-z0-9_]*)"\)')
FLAG_LITERAL = re.compile(r'"(--?[A-Za-z0-9][A-Za-z0-9_<>-]*)=?"')
KEY_READ = re.compile(r'\.(?:get|getPtr|contains)\("([^"]+)"\)')
TOP_LEVEL_KEY_READ = re.compile(r'\broot\.object\.(?:get|getPtr|contains)\("([^"]+)"\)')
LIST_ENTRY = re.compile(r'^\s*"([A-Za-z0-9_]+)",')
TEST_START = re.compile(r"^\s*test\b")
HAND_COMPARE = re.compile(r'(?:eql|startsWith)\(u8,\s*[^,]+,\s*"(-{1,2}[A-Za-z][A-Za-z0-9-]*=?)"')
CLI_DIR = "src/core/cli"
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
CHAR = re.compile(r"'(?:\\.|[^'\\])+'")


@dataclass(frozen=True)
class Line:
    path: str
    number: int
    text: str
    code: str


@dataclass(frozen=True)
class Problem:
    path: str
    number: int
    check: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.number}: [{self.check}] {self.message}"


class ShapeSourceError(Exception):
    """The source no longer has the structure the check reads."""


def code_only(text: str) -> str:
    """Drop strings, character literals, and comments so braces can be counted."""
    if text.lstrip().startswith("\\\\"):
        return ""
    without_strings = CHAR.sub("' '", STRING.sub('""', text))
    return without_strings.split("//", 1)[0]


def non_test_lines(path: str, text: str) -> list[Line]:
    """Every line outside `test` blocks, which use odd arguments on purpose."""
    lines: list[Line] = []
    depth = 0
    in_test = False
    opened = False
    for number, raw in enumerate(text.splitlines(), 1):
        code = code_only(raw)
        if not in_test and TEST_START.match(raw):
            in_test, depth, opened = True, 0, False
        if in_test:
            depth += code.count("{") - code.count("}")
            opened = opened or depth > 0
            if opened and depth <= 0:
                in_test = False
            continue
        lines.append(Line(path, number, raw, code))
    return lines


def function_body(lines: list[Line], name: str) -> list[Line]:
    header = re.compile(rf"^\s*(?:pub\s+)?fn\s+{re.escape(name)}\s*\(")
    for index, line in enumerate(lines):
        if not header.match(line.text):
            continue
        depth = 0
        opened = False
        body: list[Line] = []
        for current in lines[index:]:
            body.append(current)
            depth += current.code.count("{") - current.code.count("}")
            opened = opened or depth > 0
            if opened and depth <= 0:
                return body
    raise ShapeSourceError(f"cannot find fn {name}")


def help_flags(lines: list[Line]) -> dict[str, Line]:
    """Flags named by `.flag` and flag-shaped `.usage` entries in a spec region."""
    flags: dict[str, Line] = {}
    entry = re.compile(r'\.(?:flag|usage) = "(-[^"]*)"')
    for line in lines:
        if "json_option" in line.code:
            flags.setdefault("--json", line)
        for match in entry.finditer(line.text):
            for part in match.group(1).split(", "):
                token = part.split(" ", 1)[0]
                if token != "--":
                    flags.setdefault(token, line)
    return flags


def parsed_flags(lines: list[Line]) -> dict[str, Line]:
    flags: dict[str, Line] = {}
    for line in lines:
        for match in FLAG_LITERAL.finditer(line.text):
            flags.setdefault(match.group(1), line)
    return flags


class Checker:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.problems: list[Problem] = []
        self.registry = json.loads((root / REGISTRY).read_text())
        self.exceptions = self.registry.get("exceptions", {})
        self.used_exceptions: set[tuple[str, str]] = set()
        self.cache: dict[str, list[Line]] = {}

    def lines(self, path: str) -> list[Line]:
        if path not in self.cache:
            self.cache[path] = non_test_lines(path, (self.root / path).read_text())
        return self.cache[path]

    def report(self, line: Line | None, check: str, message: str, path: str = REGISTRY) -> None:
        if line is None:
            self.problems.append(Problem(path, 1, check, message))
        else:
            self.problems.append(Problem(line.path, line.number, check, message))

    def excepted(self, kind: str, value: str) -> bool:
        if value in self.exceptions.get(kind, {}):
            self.used_exceptions.add((kind, value))
            return True
        return False

    def run(self) -> list[Problem]:
        self.check_env()
        self.check_flags()
        self.check_parsing()
        self.check_settings()
        for kind, entries in self.exceptions.items():
            for value in entries:
                if (kind, value) not in self.used_exceptions:
                    self.report(
                        None,
                        "registry",
                        f'exception {kind} "{value}" no longer matches anything; remove it',
                    )
        return self.problems

    def check_env(self) -> None:
        registered = self.registry.get("env", {})
        external = set(self.registry.get("external_env", []))
        not_env = self.registry.get("not_env", {})
        seen: dict[str, Line] = {}
        seen_external: dict[str, Line] = {}
        for source in sorted((self.root / "src").rglob("*.zig")):
            path = source.relative_to(self.root).as_posix()
            for line in self.lines(path):
                for match in FX_LITERAL.finditer(line.text):
                    seen.setdefault(match.group(1), line)
                for match in GETENV_LITERAL.finditer(line.text):
                    name = match.group(1)
                    if not name.startswith("FX_"):
                        seen_external.setdefault(name, line)
        for name in sorted(set(not_env) - set(seen)):
            self.report(None, "env", f"not_env lists {name}, which src/ no longer contains; remove it")
        for name, line in sorted(seen.items()):
            if name not in registered and name not in not_env:
                self.report(
                    line,
                    "env",
                    f"{name} is not in {REGISTRY}. Register it with a job and a "
                    "stability, or reuse an existing variable (shape rule S-7).",
                )
        for name, entry in sorted(registered.items()):
            if name not in seen:
                self.report(None, "env", f"{name} is registered but no longer appears in src/; remove it")
            if entry.get("job") not in JOBS:
                self.report(None, "env", f"{name} has job {entry.get('job')!r}; use one of {sorted(JOBS)}")
            if entry.get("stability") not in STABILITIES:
                self.report(
                    None,
                    "env",
                    f"{name} has stability {entry.get('stability')!r}; use one of {sorted(STABILITIES)}",
                )
        for name, line in sorted(seen_external.items()):
            if name not in external:
                self.report(
                    line,
                    "env",
                    f"{name} is read but is neither an FX_* variable nor listed in "
                    f"external_env in {REGISTRY}. fx's own variables use the FX_ prefix.",
                )
        for name in sorted(external - set(seen_external)):
            self.report(None, "env", f"external_env lists {name}, which src/ no longer reads; remove it")

    def check_flags(self) -> None:
        flags: dict[str, Line] = {}
        flags.update(help_flags(self.lines(COMMANDS)))
        for path in (CLI_SURFACE, CLI_ASK):
            for flag, line in parsed_flags(self.lines(path)).items():
                flags.setdefault(flag, line)
        for flag, line in sorted(flags.items()):
            if KEBAB_FLAG.match(flag) or SHORT_FLAG.match(flag):
                continue
            if self.excepted("flag_names", flag):
                continue
            self.report(
                line,
                "flags",
                f'"{flag}" must be kebab-case with no value inside the name; '
                "pass values as an argument (shape rule S-6)",
            )

    def check_parsing(self) -> None:
        """Commands read flags through cli_flags, from the lists help renders.

        Comparing an argument with a flag literal by hand is how flags used to
        slip past help, so each remaining comparison needs a listed reason.
        """
        allowed = self.registry.get("hand_parsed_flags", {})
        seen: set[str] = set()
        for source in sorted((self.root / CLI_DIR).glob("*.zig")):
            path = source.relative_to(self.root).as_posix()
            for line in self.lines(path):
                for match in HAND_COMPARE.finditer(line.text):
                    flag = match.group(1)
                    seen.add(flag)
                    if flag in allowed:
                        continue
                    self.report(
                        line,
                        "parsing",
                        f"{flag} is compared with an argument by hand. Add it to the "
                        f"command's option list in {COMMANDS} and read it through "
                        "cli_flags (shape rules S-6 and S-13), or list it in "
                        f"hand_parsed_flags in {REGISTRY} with the reason.",
                    )
        for flag in sorted(set(allowed) - seen):
            self.report(None, "registry", f'hand_parsed_flags lists "{flag}", which no CLI code compares; remove it')

    def check_settings(self) -> None:
        config = self.lines(CONFIG_RUNTIME)
        profile = function_body(config, "parseProfileOnlyFields")
        project = function_body(config, "parseProjectSafeFields")
        for line in profile + project:
            for match in KEY_READ.finditer(line.text):
                key = match.group(1)
                if SNAKE_KEY.match(key) or self.excepted("setting_keys", key):
                    continue
                self.report(line, "settings", f'settings key "{key}" must be snake_case (shape rule S-8)')
        warned = {
            match.group(1)
            for line in function_body(config, "isProfileOnlySettingKey")
            if (match := LIST_ENTRY.match(line.text))
        }
        if not warned:
            raise ShapeSourceError("cannot read the isProfileOnlySettingKey list")
        reported: set[str] = set()
        for line in profile:
            for match in TOP_LEVEL_KEY_READ.finditer(line.text):
                key = match.group(1)
                if key in warned or key in reported:
                    continue
                reported.add(key)
                self.report(
                    line,
                    "warnings",
                    f'"{key}" is profile-only, so a project .fx.json that sets it is '
                    "ignored. Add it to isProfileOnlySettingKey so the user is told.",
                )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root")
    args = parser.parse_args(argv)
    try:
        problems = Checker(args.root).run()
    except (OSError, ValueError, ShapeSourceError) as err:
        print(f"check_cli_shape: {err}", file=sys.stderr)
        return 2
    for problem in problems:
        print(problem.render())
    if problems:
        print(f"{len(problems)} shape problem(s). See .fx/skills/fx-cli-shape/SKILL.md.")
        return 1
    print("CLI shape: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
