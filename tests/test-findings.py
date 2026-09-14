#!/usr/bin/env python3
"""test-findings - assert cap gate accepts a review only when it covers the diff,
and computes the verdict a reader would compute from its findings.

A review that states a verdict with nothing behind it is the failure this
guards: a 39-turn review whose whole report was "GATE: FAIL" was once recorded
as a result. Each case is a report shape, and each must be accepted or
refused for the reason given.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BIN = os.path.join(ROOT, "bin")
sys.path.insert(0, BIN)
import caplib  # noqa: E402

tree = tempfile.mkdtemp()
subprocess.run(["git", "init", "-q", tree], check=True)
os.makedirs(os.path.join(tree, "bin"))
with open(os.path.join(tree, "bin", "tool.sh"), "w") as fh:
    fh.write("#!/bin/sh\necho one\necho two\n")
with open(os.path.join(tree, "README.md"), "w") as fh:
    fh.write("readme\n")
changed = ["README.md", "bin/tool.sh"]

failures = []


def block(report):
    return "Review notes.\n\n```json\n" + json.dumps(report) + "\n```\n"


def case(name, text, *, accepted, verdict=None, problem=None):
    report, error = caplib.findings_block(text)
    problems = [error] if error else caplib.validate_findings(report, changed, tree)
    if accepted and problems:
        failures.append(f"{name}: refused a valid report: {problems}")
        return
    if not accepted:
        if not problems:
            failures.append(f"{name}: accepted a report it should refuse")
        elif problem and not any(problem in p for p in problems):
            failures.append(f"{name}: refused for {problems}, want a reason mentioning {problem!r}")
        return
    got = caplib.verdict(report)
    if got != verdict:
        failures.append(f"{name}: verdict {got}, want {verdict}")


checked_all = [
    {"file": "README.md", "note": "wording matches the command it documents"},
    {"file": "bin/tool.sh", "note": "both echo lines run under sh"},
]

case("clean pass", block({"findings": [], "checked": checked_all}), accepted=True, verdict="PASS")
case(
    "major fails",
    block({"findings": [{"file": "bin/tool.sh", "line": 2, "severity": "major", "confidence": "confirmed", "claim": "prints one where the caller parses two"}], "checked": checked_all[:1]}),
    accepted=True,
    verdict="FAIL",
)
case(
    "blocker fails",
    block({"findings": [{"file": "bin/tool.sh", "line": None, "severity": "blocker", "confidence": "confirmed", "claim": "the script exits before it writes anything"}], "checked": checked_all}),
    accepted=True,
    verdict="FAIL",
)
case(
    "minor passes",
    block({"findings": [{"file": "README.md", "line": 1, "severity": "minor", "confidence": "confirmed", "claim": "readme is a single lowercase word"}], "checked": checked_all}),
    accepted=True,
    verdict="PASS",
)
# A report that quotes the expected shape before giving its own real block
# is read by its last block.
case(
    "quoted shape first",
    block({"findings": [], "checked": []}) + "\nMy report:\n" + block({"findings": [], "checked": checked_all}),
    accepted=True,
    verdict="PASS",
)

case("bare verdict", "GATE: FAIL\n", accepted=False, problem="no ```json block")
case("bare pass", "Looks good.\n\nGATE: PASS\n", accepted=False, problem="no ```json block")
case("unparseable", "```json\n{findings: []}\n```\n", accepted=False, problem="does not parse")
case("empty review", block({"findings": [], "checked": []}), accepted=False, problem="neither findings nor checked")
case("partial coverage", block({"findings": [], "checked": checked_all[:1]}), accepted=False, problem="bin/tool.sh")
case(
    "hollow notes",
    block({"findings": [], "checked": [{"file": "README.md", "note": "ok"}, {"file": "bin/tool.sh", "note": "fine"}]}),
    accepted=False,
    problem="note must say",
)
case(
    "invented file",
    block({"findings": [{"file": "src/app.py", "line": 3, "severity": "major", "confidence": "confirmed", "claim": "this file does not exist here"}], "checked": checked_all}),
    accepted=False,
    problem="not a file in this worktree",
)
case(
    "line past end",
    block({"findings": [{"file": "bin/tool.sh", "line": 40, "severity": "major", "confidence": "confirmed", "claim": "a line the file does not have"}], "checked": checked_all}),
    accepted=False,
    problem="past the end",
)
case(
    "unknown severity",
    block({"findings": [{"file": "bin/tool.sh", "line": 2, "severity": "critical", "confidence": "confirmed", "claim": "severity outside the scale"}], "checked": checked_all}),
    accepted=False,
    problem="severity must be",
)
case(
    "suspected major is advice",
    block({"findings": [{"file": "bin/tool.sh", "line": 2, "severity": "major", "confidence": "suspected", "claim": "the command may fail in an unavailable environment"}], "checked": checked_all[:1]}),
    accepted=True,
    verdict="PASS",
)
case("not an object", "```json\n[]\n```\n", accepted=False, problem="must be an object")

# A gate miss is a failing finding on bytes an earlier round passed while
# covering that file. Changed bytes, a minor finding, or a file the passing
# round never covered is not a miss.
spec = importlib.util.spec_from_loader("cap_ledger", importlib.machinery.SourceFileLoader("cap_ledger", os.path.join(BIN, "cap-ledger")))
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)


def round_(label, verdict, files, checked, findings=()):
    return {"label": label, "profile": "p", "commit": "c" * 40, "verdict": verdict, "files": files, "checked": [{"file": f, "note": "n n n"} for f in checked], "findings": list(findings)}


major = {"file": "bin/tool.sh", "line": 2, "severity": "major", "confidence": "confirmed", "claim": "a real defect here", "id": "f1"}
minor = dict(major, severity="minor", id="f2")
passed = round_("B", "PASS", {"bin/tool.sh": "h1"}, ["bin/tool.sh"])
checks = [
    ("same bytes", [passed, round_("A", "FAIL", {"bin/tool.sh": "h1"}, [], [major])], 1),
    ("changed bytes", [passed, round_("A", "FAIL", {"bin/tool.sh": "h2"}, [], [major])], 0),
    ("minor only", [passed, round_("A", "PASS", {"bin/tool.sh": "h1"}, [], [minor])], 0),
    ("not covered", [round_("B", "PASS", {"bin/tool.sh": "h1"}, ["README.md"]), round_("A", "FAIL", {"bin/tool.sh": "h1"}, [], [major])], 0),
    ("fail before pass", [round_("A", "FAIL", {"bin/tool.sh": "h1"}, [], [major]), passed], 0),
]
for name, records, want in checks:
    got = len(ledger.misses(records))
    if got != want:
        failures.append(f"ledger {name}: {got} miss(es), want {want}")

# A failed ledger commit leaves its written entry for the next run.
hub = tempfile.mkdtemp()
os.makedirs(os.path.join(hub, "cases", "p"))
book = os.path.join(hub, "cases", "p", "conventions.md")
with open(book, "w") as fh:
    fh.write("# p\n\n## Gate-miss ledger\n")
git_env = dict(os.environ, GIT_AUTHOR_NAME="lint", GIT_AUTHOR_EMAIL="lint@lint", GIT_COMMITTER_NAME="lint", GIT_COMMITTER_EMAIL="lint@lint")
subprocess.run(["git", "init", "-q", hub], check=True)
subprocess.run(["git", "-C", hub, "add", "-A"], check=True)
subprocess.run(["git", "-C", hub, "commit", "-qm", "init"], check=True, env=git_env)
os.environ.update(git_env)
caplib.HOME = hub
lines = [ledger.entry("t", passed, round_("A", "FAIL", {}, [], [major]), major)]
ledger.append(book, lines)
open(os.path.join(hub, ".git", "index.lock"), "w").close()
try:
    ledger.commit(book, "t", lines)
    failures.append("ledger commit: a failed commit returned")
except caplib.CapError:
    pass
os.remove(os.path.join(hub, ".git", "index.lock"))
retry = (ledger.append(book, lines), ledger.commit(book, "t", lines), ledger.commit(book, "t", lines))
if retry != ([], 1, 0):
    failures.append(f"ledger retry: (appended, committed, committed again) = {retry}, want ([], 1, 0)")
shutil.rmtree(hub, ignore_errors=True)

shutil.rmtree(tree, ignore_errors=True)
if failures:
    for f in failures:
        print(f"test-findings: {f}", file=sys.stderr)
    sys.exit(1)
print("test-findings: reports are accepted only with coverage, and verdicts follow findings")
