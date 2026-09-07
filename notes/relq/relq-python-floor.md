# relq Python floor report

Date of audit: 2026-09-02. Scope was the published source under
`packages/relq-core/src`, `packages/relq-sqlite/src`, `packages/relq-postgres/src`,
and `packages/relq-codegen/src`; tests were excluded. The repository was not
changed.

## Release-note baseline

I checked the official CPython release notes for [3.13](https://docs.python.org/3.13/whatsnew/3.13.html),
[3.14](https://docs.python.org/3.14/whatsnew/3.14.html), and the current
[3.15 release candidate](https://docs.python.org/3.15/whatsnew/3.15.html).
The following is the concrete version-gated inventory relevant to a source
audit (not an exhaustive list of every implementation optimization).

* Python 3.13: defined mutation semantics for `locals()` (PEP 667),
  experimental free-threaded CPython (PEP 703), the experimental JIT (PEP
  744), class annotation-scope improvements, type-parameter defaults (PEP
  696), `warnings.deprecated()` (PEP 702), `typing.ReadOnly` (PEP 705),
  `typing.TypeIs` (PEP 742), `dbm.sqlite3`, `copy.replace()`,
  `PythonFinalizationError`, and the enhanced `asyncio.as_completed()` API.
  It also removed the legacy PEP 594 modules, `lib2to3`/2to3, and the
  `typing.io` and `typing.re` namespaces.
* Python 3.14: deferred evaluation of annotations and the new `annotationlib`
  module (PEPs 649/749), `concurrent.interpreters` and
  `InterpreterPoolExecutor` (PEP 734), template string literals/t-strings and
  `string.templatelib` (PEP 750), unbracketed `except`/`except*` (PEP 758),
  restrictions on control flow in `finally` (PEP 765), the safe external
  debugger interface (PEP 768), standard-library Zstandard support via
  `compression.zstd` (PEP 784), and new asyncio process/task introspection.
* Python 3.15: explicit lazy imports (PEP 810), builtin `frozendict` (PEP
  814), builtin sentinel values (PEP 661), unpacking in comprehensions (PEP
  798), UTF-8 as the default encoding (PEP 686), package startup
  configuration files, typed extra items for `TypedDict` (PEP 728),
  `typing.TypeForm` (PEP 747), disjoint bases in the type system (PEP 800),
  and new profiling facilities. The release notes also cover free-threaded
  stable-ABI/C-API work and other interpreter changes.

These notes also make clear that 3.14's deferred annotation behavior is not
the same thing as the `from __future__ import annotations` statements already
present in some relq files; those statements are older and remain unchanged
in 3.14.

## Findings in published source

### Actual 3.15 feature use: `typing.TypeForm`

`TypeForm` was introduced in CPython 3.15 by PEP 747. It annotates values that
are themselves type expressions, such as `int`, `str | None`, or a
`TypedDict` class. Every occurrence is in
`packages/relq-core/src/relq/expressions/relations.py`:

* line 6: runtime import, `from typing import Self, TypeForm, cast, overload`
* line 35: `Column.__init__` annotation
* line 39: `Column.__set_name__`/related constructor annotation
* line 116: `output_column()` parameter annotation
* line 126: `column()` parameter annotation
* line 149: `_column()` parameter annotation

This is a genuine current 3.15 import requirement: `TypeForm` is imported from
`typing` at module import time. It is not merely a checker setting. However,
it is typing surface only. It does not affect query construction or execution,
and the module's use of `TypeForm` can be replaced with a 3.13-compatible
annotation strategy (for example a guarded/backported typing annotation or a
less precise `type`/`Any`-based spelling). The runtime accepts the same values;
the loss is only annotation precision. This looks like an afternoon
workaround, not an essential design dependency.

### Features checked and not found

There were no uses in the published source of t-strings, `annotationlib`,
`concurrent.interpreters`, `InterpreterPoolExecutor`, `compression.zstd`,
3.13 `TypeIs`/`ReadOnly`/`warnings.deprecated`, free-threading APIs, the JIT,
lazy-import syntax, `frozendict`, builtin sentinels, unpacking in
comprehensions, or any of the new 3.13--3.15 asyncio APIs. Existing uses of
`asyncio` are ordinary `asyncio.run()` and async generators.

The generated-code strings in `relq_codegen/render.py` mention
`TypedDict`, `Required`, `NotRequired`, `enum.StrEnum`, and dataclass slots.
Those are older features (3.11 or earlier), and generated text is not itself
a runtime use of a 3.13--3.15 feature.

### Modern syntax that does not establish a 3.15 floor

The source uses PEP 695 type statements and type-parameter syntax, for example
`type SourceNode = ...` at `packages/relq-core/src/relq/_ast.py:42` and
`def ...[T](...)` throughout core. PEP 695 is a Python 3.12 feature, not a
3.15 feature. The complete type-statement locations are:

* `packages/relq-core/src/relq/_ast.py`: 42, 262, 263, 374, 398, 435, 472
* `packages/relq-core/src/relq/_execution.py`: 14, 20
* `packages/relq-core/src/relq/rows.py`: 15, 16
* `packages/relq-core/src/relq/expressions/core.py`: 59, 60
* `packages/relq-codegen/src/relq_codegen/model.py`: 165, 215, 216

The generic declarations are likewise PEP 695/3.12 syntax; they occur in
`_node_value.py`, `_execution.py`, `_query.py`, `expressions/core.py`,
`expressions/relations.py`, `expressions/analytics.py`, `rows.py`, `query.py`,
`dml.py`, `_compiler/api.py`, and the SQLite/PostgreSQL executor modules.
Nothing in those declarations is a 3.13+ addition.

## Tooling/configuration-only assumptions

The root `pyproject.toml` has `requires-python = ">=3.15"` at line 4, while
all four package `pyproject.toml` files also declare `>=3.15`. Those are
metadata declarations, not evidence from source usage.

The development group at root `pyproject.toml:9-16` contains
`asyncpg-stubs`, `basedpyright`, `pytest`, `pytest-asyncio`, and `ruff`; none
is a language feature requiring 3.15 by this audit.

Tool settings explicitly target 3.15: `[tool.ruff] target-version = "py315"`
at lines 18-21 and `[tool.basedpyright] pythonVersion = "3.15"` at lines
23-27. These may need to be lowered independently if the project lowers its
declared floor, but they do not block a lower runtime requirement.

## Recommendation

As currently written, relq has one real 3.15 dependency: the `typing.TypeForm`
import and its annotations in `relq/expressions/relations.py` listed above.
Nothing makes 3.15 essential to relq's query-builder design. After replacing
that typing-only usage with a compatible spelling/backport, the published
source uses no feature newer than Python 3.12, so `requires-python = ">=3.13"`
is an honest recommendation and matches rqueue. `>=3.14` would also work,
but there is no source-based reason to exclude 3.13.

Therefore: do not lower the metadata alone while retaining the unguarded
`TypeForm` import; first make that small typing adjustment, then lower all
package/root metadata and tooling targets as a separate implementation task.
No source or configuration changes were made here.
