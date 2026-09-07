# relq `ON CONFLICT ... WHERE` spike

Date: 2026-09-02. Branch `cap/relq-conflict-where`, worktree
`/home/dubu/.cap-work/relq-conflict-where`. **Uncommitted** — nothing was
committed, pushed, or opened as a PR. `rqueue`/`transactions` was not touched.

Both gaps closed. The `DO UPDATE ... WHERE` gap (gap 2) closed cleanly. The
arbiter-predicate gap (gap 1) closed, but only after a correctness problem
that would have shipped a time-bomb — see [The one real design
compromise](#the-one-real-design-compromise). Full suite green, typecheck
clean.

## The API I landed

Both SQL predicates are spelled `.where(...)`, in the builder positions their
SQL clauses occupy, so a chain reads in the same order as the statement:

```python
(
    insert_into(jobs)
    .values(queue="emails", dedupe_key="welcome:7", state="pending")
    .on_conflict(jobs.queue, jobs.dedupe_key)
    .where(jobs.dedupe_key.is_not_null() & jobs.state.in_(("pending", "leased")))
    .do_update(updated_at=jobs.updated_at)
    .where(jobs.state.eq("pending"))
    .returning(jobs.id)
)
```

### Gap 1 — arbiter predicate

`ConflictBuilder.where(predicate: BooleanExpression) -> ConflictBuilder[Row_co, Returns]`
— `packages/relq-core/src/relq/dml.py:304`.

```python
insert_into(jobs).values(...).on_conflict(jobs.queue, jobs.dedupe_key).where(
    jobs.dedupe_key.is_not_null() & jobs.state.in_(("pending", "leased"))
).do_update(updated_at=jobs.updated_at)
```

Renders `on conflict ("queue", "dedupe_key") where (...) do update set ...`.

### Gap 2 — action predicate

`ConflictUpdateQuery.where(predicate: BooleanExpression) -> InsertQuery[Row_co, Returns]`
— `packages/relq-core/src/relq/dml.py:356`.

```python
insert_into(slots).values(...).on_conflict(slots.key).do_update(
    job_id=excluded(slots.job_id), acquired_at=transaction_timestamp(), ...
).where(slots.leased_until.lte(transaction_timestamp()))
```

`do_update(...)` now returns `ConflictUpdateQuery`
(`packages/relq-core/src/relq/dml.py:348`), a subclass of `InsertQuery` that
adds exactly this one method. That is a **breaking return-type change** to
`do_update`, taken deliberately per the brief:

- `do_update(**entries)` takes arbitrary column kwargs, so a `where=` keyword
  parameter would collide with any table that has a column named `where`. A
  distinct returned type has no such collision.
- The result is still a complete, executable `InsertQuery`, so existing
  `.do_update(...).returning(...)` / `.execute(...)` code is unaffected.
- Encoding "an update that may still be narrowed" as its own type is relq's
  own typestate idiom (`Returns`, `Bounded`, `ConflictBuilder`).
- Applying the predicate twice is therefore not expressible: `.where()` hands
  back a plain `InsertQuery`. No runtime guard needed; asserted at
  `tests/integration/sqlite/test_dml_contracts.py:164`.

The one sharp edge: `.where()` must come **before** `.returning()`, because
`returning()` returns a plain `InsertQuery`. That matches SQL's own clause
order, and is documented in `docs/dml.md`.

### One incidental signature change I had to make

`on_conflict` was `def on_conflict[T](self, *columns: Column[T])` — one
invariant `T` shared across every target column. `Column` is invariant, so
`on_conflict(jobs.queue, jobs.dedupe_key)` with `Column[str]` and
`Column[str | None]` **did not type-check**. That is exactly the shape a
partial unique index on a nullable column needs, so gap 1 was unusable
without fixing it. It is now overloaded per position for 0–4 columns, the
same way `from_select` and `returning` already are —
`packages/relq-core/src/relq/dml.py:166-187`. A 5+-column conflict target no
longer type-checks; that seemed a fair trade against `from_select`'s existing
4-column ceiling, but it is a real (tiny) surface reduction worth a look in
review.

## The one real design compromise

**The arbiter predicate renders inlined SQL constants, not bound parameters.**
Everything else in relq parameterizes.

PostgreSQL picks the arbiter index by proving the index's stored predicate
from the one in the statement, comparing parsed expression trees. A cached
**generic** plan leaves `$n` parameters unfolded, so a parameterized arbiter
predicate matches while the plan is custom and stops matching the moment
PostgreSQL switches to a generic plan — which it does after five executions
of a prepared statement, and asyncpg prepares every statement relq sends.

I measured this through the exact asyncpg path `relq-postgres` uses, against
PostgreSQL 18.4:

```
parameterized: FAILED on execution 6: InvalidColumnReferenceError:
  there is no unique or exclusion constraint matching the ON CONFLICT specification
constants: 12/12 executions succeeded
```

So a parameterized version would have passed a normal integration test and
then started failing in production partway through a worker's life. That is
the single most important finding of this spike.

The compromise is contained rather than general:

- Only the **arbiter** predicate inlines constants. The `DO UPDATE` action
  predicate is a plain runtime filter and stays fully parameterized
  (`"employees"."salary" < $3`), which the tests assert.
- Arbiter predicates go through a **separate, closed renderer**,
  `_compile_index_predicate` — `packages/relq-core/src/relq/_compiler/_render.py:219`.
  It accepts only columns, constants, comparisons, `IN`, `BETWEEN`, `IS`
  checks, `AND`, `OR` — roughly what PostgreSQL itself allows in an index
  predicate. Anything else raises at compile time instead of failing at the
  database.
- Constants are restricted to `str` / `int` / `bool` / `None` and escaped by
  `_constant` — `packages/relq-core/src/relq/_compiler/_render.py:264`.
  Strings use PostgreSQL's `E'...'` form with both `'` and `\` escaped, so the
  rendering does not depend on the session's `standard_conforming_strings`.
  This is a genuine (if narrow) departure from "no SQL text built from user
  values", and is the part of the diff I would most want a second opinion on.
- `excluded()` is rejected in the arbiter predicate (it describes stored rows,
  not the proposed one) and allowed in the action predicate —
  `packages/relq-core/src/relq/_compiler/validation.py:593`.

Regression guard: `test_arbiter_predicate_survives_a_cached_generic_plan`
(`tests/integration/postgres/test_conflict_predicates.py:115`) runs the dedupe
insert 12 times through asyncpg, well past the five-execution switch.

## Was gap 1 a deliberate exclusion?

No — it was already listed. `docs/design-boundaries.md` read "Conflict
predicates, named constraints, and PostgreSQL's `DO UPDATE ... WHERE` on
`on_conflict`" under **Not yet**, and "Not yet" is explicitly "gaps, not
commitments to never build them". "Conflict predicates" is gap 1. Both docs
are updated; named constraints as a conflict target remain out.

## Dialect scope

Conflict predicates are gated to PostgreSQL by a new
`Dialect.supports_conflict_predicates` flag
(`packages/relq-core/src/relq/_compiler/_model.py:15`,
`packages/relq-core/src/relq/_compiler/api.py:14`), enforced in validation
(`packages/relq-core/src/relq/_compiler/validation.py:351`), matching the
existing `supports_row_locking` precedent. Compiling either predicate for
SQLite raises `sqlite does not support ON CONFLICT predicates`. No SQLite
builder or compiler behaviour changed.

Worth knowing for later: **SQLite does in fact support both predicates** —
its upsert grammar has `ON CONFLICT (cols) WHERE <expr> DO UPDATE SET ...
WHERE <expr>`. The brief assumed otherwise. I kept the gate because the brief
scoped this PostgreSQL-only, but lifting it is a one-flag change plus SQLite
tests, not new machinery. (SQLite would also want the constant-inlining
question revisited; it has no generic-plan equivalent, so parameters there
are probably fine.)

## Static checking

`uv run basedpyright` (strict, `reportAny` / `reportExplicitAny` = error):
**0 errors, 0 warnings, 0 notes**, including the `tests/typing/good.py`
fixture, which I extended with the new chain and its result types
(`tests/typing/good.py:234-246`). `ruff check` and `ruff format --check`
clean. No `Any`, no casts, and no `# pyright: ignore` were needed anywhere in
the change.

## Architecture notes

Easier than expected:

- The AST/render/validate split did what it promises. Adding two `Node | None`
  fields to `ConflictNode` (`packages/relq-core/src/relq/_ast.py:412`) and one
  case each to render and validate was the whole structural change.
- Predicates reuse the existing `BooleanExpression` machinery unchanged —
  `.where()` on `ConflictBuilder` and `ConflictUpdateQuery` take the same type
  `UpdateQuery.where` / `DeleteQuery.where` already take, and go through the
  same `node_of` bridge. No second predicate representation.
- `ConflictNode` is not part of the `Node` union, so `walk`/`children` and the
  nullability analysis needed no changes at all.
- Column references already render fully qualified (`"jobs"."state"`), which
  PostgreSQL accepts in both the arbiter predicate and the `DO UPDATE` filter
  (verified directly).

Harder than expected:

- `new_query`'s overload chain resolves `type[ConflictUpdateQuery[...]]`
  against the `InsertQuery` overload first, silently widening the result. It
  needed its own overload ahead of that one —
  `packages/relq-core/src/relq/_query.py:44`.
- `validate_dml_sources` took a single `where: Node | None`; the conflict
  clause has two independent predicates. I widened it to
  `predicates: tuple[Node | None, ...]` (three call sites) rather than pass
  one predicate through a field meant for something else —
  `packages/relq-core/src/relq/_compiler/validation.py:558`.
- The `on_conflict` invariance problem above.

## Second problem found (not fixed — own task)

**`~predicate` renders invalid SQL.** `Predicate.__invert__` /
`NullablePredicate.__invert__` build `UnaryNode("not", operand)`, but
`_compile_node` renders `UnaryNode` postfix, so negation comes out as a
suffix:

```
>>> compile_postgres(select(t.a).from_(t).where(~t.a.eq(1))).sql
'select "t"."a" from "t" where (("t"."a" = $1) not)'
```

That is a syntax error in both PostgreSQL and SQLite. It is pre-existing and
untested — nothing in `tests/` exercises `~`. It is unrelated to this change,
so I left it alone; I also deliberately excluded `not` from the closed
arbiter-predicate renderer's operator set rather than inherit the bug.

## Files touched

Source, 13 files, +382 / −23 (of which tests and docs are +228).

| File | Δ | What |
| --- | --- | --- |
| `packages/relq-core/src/relq/_ast.py` | +10 | `ConflictNode.target_where` / `update_where` |
| `packages/relq-core/src/relq/dml.py` | +86/−7 | `ConflictBuilder.where`, `ConflictUpdateQuery`, `on_conflict` overloads |
| `packages/relq-core/src/relq/_compiler/_render.py` | +81/−1 | `_compile_index_predicate`, `_constant`, conflict rendering |
| `packages/relq-core/src/relq/_compiler/validation.py` | +37/−8 | dialect gate, predicate source/`excluded()` rules, `validate_dml_sources` signature |
| `packages/relq-core/src/relq/_query.py` | +11/−1 | `new_query` overload for `ConflictUpdateQuery` |
| `packages/relq-core/src/relq/_compiler/_model.py` | +1 | `supports_conflict_predicates` |
| `packages/relq-core/src/relq/_compiler/api.py` | +1 | enable it for PostgreSQL |
| `packages/relq-core/src/relq/__init__.py` | +2 | export `ConflictUpdateQuery` |
| `docs/dml.md` | +30/−2 | conflict-predicate section |
| `docs/design-boundaries.md` | +2/−2 | move the closed gaps out of "Not yet" |
| `tests/integration/postgres/test_conflict_predicates.py` | +221 (new) | 6 real-PostgreSQL tests |
| `tests/integration/sqlite/test_dml_contracts.py` | +81 | 2 compile/validation tests |
| `tests/integration/postgres/support.py` | +28/−1 | `jobs` and `slots` tables |
| `tests/typing/good.py` | +12/−1 | static-contract assertions |

## Tests

`tests/integration/postgres/test_conflict_predicates.py` — real PostgreSQL,
real row-state assertions, not SQL-string checks:

- `:93` arbiter predicate selects the partial unique index — the second
  insert conflicts and updates; after moving the row to `state='done'` (out
  of the index predicate) the *same statement* inserts a new row instead.
- `:115` survives a cached generic plan (the 12-execution guard above).
- `:139` without the arbiter predicate, the same conflict target raises
  `there is no unique or exclusion constraint matching the ON CONFLICT
  specification` — the predicate is load-bearing, not decorative.
- `:155` the `DO UPDATE ... WHERE` compare-and-swap: a live lease is left
  untouched and returns no rows; after expiry the identical statement takes
  the slot over.
- `:184` the contrast case — an unconditional `DO UPDATE` overwrites the live
  lease, which is what rqueue's named-concurrency-key exclusivity would lose.
- `:208` clause order in the rendered SQL, and SQLite rejection.

Runs:

- `uv run pytest --ignore=tests/integration/postgres` → **88 passed**
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed**
- `uv run basedpyright` → **0 errors, 0 warnings, 0 notes**
- `ruff check .` → clean; `ruff format` → clean

---

# Follow-up: `on_conflict` arity (task `relq-conflict-arity`)

Gate B's finding was right and the ceiling is now gone. `on_conflict` accepts
**unlimited, heterogeneously typed** conflict-target columns again, with zero
`Any`, zero `object` in the signature, zero casts and zero ignores. The 0–4
overload ladder is deleted.

## What the runtime actually needs from a column

Confirmed before designing anything (`packages/relq-core/src/relq/dml.py:57`,
`_target_column_names`): for each argument it does

1. `isinstance(column, Column)` — nominal, no type argument involved;
2. `expression_node(_expression(column))` → must be a `ColumnNode`;
3. reads `node.source` and `node.name`, and appends `node.name`.

That is **identity only**. Nothing downstream ever sees the column's value
type: `ConflictBuilder` stores `_columns: tuple[str, ...]` (`dml.py:286`) —
plain names — and `ConflictBuilder[Row_co, Returns]` carries only the insert's
own row/returning parameters. So the per-column type parameter in the old
signature was pure ceremony: it existed only so *some* `Column[X]` would be
accepted at each position.

## Why the old signature broke, reproduced

The pre-regression `def on_conflict[T](self, *columns: Column[T])` genuinely
could not express `(queue, dedupe_key)`. basedpyright 1.39.9, strict:

```
error: Argument of type "Column[str | None]" cannot be assigned to parameter
  "columns" of type "Column[T@old_style]"
  "Column[str | None]" is not assignable to "Column[str]"
    Type parameter "T@Column" is invariant, but "str | None" is not the same as "str"
```

`Column[T]` inherits `Expr(Expression, Generic[T])`, whose `T` is an explicitly
invariant legacy `TypeVar` with a standing `# noqa: UP046 -- expressions
require an invariant value parameter` (`expressions/core.py:76`). So the
invariance is deliberate and not negotiable here.

## The fix: a covariant nominal base

`packages/relq-core/src/relq/expressions/relations.py:31`

```python
class ConflictTarget[T_co = object](Expression):
    __slots__ = ()
```

used at `dml.py:173` as `def on_conflict(self, *columns: ConflictTarget) -> ...`.

Three things make it work:

- **Covariance.** `T_co` appears in no member, so under PEP 695 inference
  basedpyright makes it covariant and every `Column[X]` is a subtype of
  `ConflictTarget[object]`. Confirmed to be covariant and not merely bivariant:
  `ConflictTarget[object] = users.email` type-checks, while
  `ConflictTarget[int] = users.email` is rejected with *"Type parameter
  `T_co@ConflictTarget` is covariant, but `str` is not a subtype of `int`"*.
  That is the whole mechanism — nothing reads a member through the annotation,
  so the parameter is free to widen.
- **PEP 696 default (`= object`).** The parameter can be written bare as
  `ConflictTarget`, so the token `object` never appears in the public signature
  and strict mode does not fire `reportMissingTypeArgument`. Matches the
  existing `class Source[SqlRow_co = object]` idiom (`relations.py:21`).
- **Nominal.** `Column[T](ConflictTarget[T], Expr[T])`, so only real columns
  conform — see the gate-B follow-up below for why the first attempt at this
  used a `Protocol` and why that was wrong.

It does not degenerate into `object`: `str`, a `NullablePredicate`, a `Table`
instance, and a structural column lookalike are all still rejected at the call
site (see the new negative fixture). `from_select` deliberately keeps its overload ladder — there the
per-position parameters are load-bearing, since each target is checked against
the projection expression that feeds it.

(The first version of this used a structural `typing.Protocol` here, which gate
B correctly rejected. See "Gate B follow-up" below; the class above is the
corrected, nominal form.)

## PEP 646 does not solve this — confirmed, not assumed

Tested against basedpyright 1.39.9 rather than taken on faith:

| Attempt | Result |
| --- | --- |
| `def f[*Ts](*columns: Unpack[Ts])` | Compiles, but **accepts `f("not a column", 3)` with no error** — `TypeVarTuple` captures element types, it cannot bound them. |
| `def f[*Ts](*columns: Unpack[tuple[Column[Unpack[Ts]], ...]])` | `error: TypeVarTuple is not allowed in this context` |
| `def f[*Ts](*columns: Column[Unpack[Ts]])` | `error: TypeVarTuple is not allowed in this context` |

Mapping a `TypeVarTuple` element-wise through a generic (`Column[*Ts]`) is
higher-kinded and simply not expressible. The brief's claim holds.

## Prior art

Every mature library with this shape hits the same wall, and all of them pay
with `Any` — which this repo's `reportAny = "error"` forbids. That is the real
reason the covariant Protocol is the answer here rather than the usual one.

- **SQLAlchemy 2.0**, `dialects/_typing.py`:
  `_OnConflictIndexElementsT = Optional[Iterable[Union[Column[Any], str, roles.DDLConstraintColumnRole]]]`
  — used verbatim by `on_conflict_do_update`/`on_conflict_do_nothing` in both
  `dialects/postgresql/dml.py` and `dialects/sqlite/dml.py`. So: **arbitrary
  arity via a covariant `Iterable`, no per-element type checking, element type
  erased with `Any`.** It does not cap arity, and it does not try to type each
  position.
- **SQLAlchemy, the mechanism though**, is exactly the one used here —
  `sql/_typing.py` declares
  `_T_co = TypeVar("_T_co", bound=Any, covariant=True)` and
  `class _HasClauseElement(Protocol, Generic[_T_co])`, a **covariant Protocol**
  it accepts anywhere a heterogeneous column-like value is wanted. The idea is
  idiomatic; SQLAlchemy just also allows `Any` alongside it, and we don't.
- **attrs** (`src/attr/__init__.pyi`): `class Attribute(Generic[_T])` with an
  invariant `_T`, and every collection-of-attributes API erases it —
  `fields_dict(cls) -> dict[str, Attribute[Any]]`, `attribs: list[Attribute[Any]] | None`,
  and `def fields(cls) -> Any`. Pure `Any` erasure.
- **stdlib `dataclasses`** (typeshed `stdlib/dataclasses.pyi`):
  `class Field(Generic[_T])` invariant, `def fields(...) -> tuple[Field[Any], ...]`.
  Same erasure, in the standard library itself.
- **pydantic v2** (`pydantic/fields.py`): `class FieldInfo(_repr.Representation)`
  is **not generic at all** — it dropped the value type parameter outright, so
  `dict[str, FieldInfo]` is heterogeneous with no `Any`. That is the same move
  as ours taken to its limit; we keep `T_co` so `ConflictTarget[str]` stays
  expressible.
- **typeshed's own precedent for the trick** (`stdlib/typing.pyi`):
  `_T_co = TypeVar("_T_co", covariant=True)` for `Sequence`, `Iterable`,
  `Collection`; `_T = TypeVar("_T")` invariant for `MutableSequence`/`list`.
  Read-only positions are covariant precisely so an API can accept
  heterogeneous-but-related inputs that `list[T]` cannot. `ConflictTarget` is
  that, applied to a custom generic instead of a stdlib one — and it does
  transfer cleanly, because `Column`'s invariance comes from `Expr`'s type
  parameter, not from any contravariant member the Protocol would have to
  reproduce.

## Files touched

| File | Δ | What |
| --- | --- | --- |
| `packages/relq-core/src/relq/dml.py` | +15/−29 | `on_conflict` (`:173`) loses 5 overloads and the `*columns: object` impl signature |
| `packages/relq-core/src/relq/expressions/relations.py` | +26/−1 | `ConflictTarget` base (`:31`); `Column` inherits it (`:56`) |
| `packages/relq-core/src/relq/__init__.py`, `expressions/__init__.py` | +4 | export `ConflictTarget` |
| `tests/typing/good.py` | +36 | `Jobs` (`:248`), 2-column heterogeneous target (`:260`), 6-column target (`:268`) |
| `tests/typing/bad_conflict_target.py` + `.json` | +57 (new) | non-columns, structural lookalikes, and unconstructible base/subclasses rejected |
| `tests/test_typing_fixtures.py` | +8 | `test_conflict_targets_must_still_be_columns` (`:85`) |
| `tests/integration/sqlite/test_dml_contracts.py` | +25/−1 | `test_conflict_targets_have_no_arity_ceiling` (`:131`) |
| `docs/dml.md` | +10 | unlimited arity, and why `from_select` differs |

Nothing outside `on_conflict`'s typing moved. `_target_column_names` keeps its
`tuple[object, ...]` parameter (still shared with `from_select`), `Column`,
`Expr`, `ConflictBuilder`, `_query.py`, rqueue and transactions are untouched.

## Tests

- `tests/typing/good.py:260` — `(jobs.queue, jobs.dedupe_key)` where
  `dedupe_key: Column[str | None]`. This is the exact rqueue case, and the
  exact call the pre-regression signature rejected.
- `tests/typing/good.py:268` — six columns spanning
  `str`, `str | None`, `int`, `bool`, `float`, `bytes | None`; two past the old
  ceiling, and `assert_type(..., ConflictUpdateQuery[tuple[()], Literal[False]])`
  confirms the return type is unaffected.
- `tests/typing/bad_conflict_target.py` — `on_conflict("email")`,
  `on_conflict(users.id.eq(1))` and `on_conflict(users)` each raise
  `reportArgumentType`; asserted by `tests/test_typing_fixtures.py:85`.
- `tests/integration/sqlite/test_dml_contracts.py:131` — a real 5-column
  composite target compiles to
  `on conflict ("id", "amount", "occurred_at", "payload", "state") do nothing`,
  and `on_conflict("id")` still raises `TypeError` at runtime.

Runs (all from the worktree, all after the change):

- `uv run --locked --all-packages pytest --ignore=tests/integration/postgres`
  → **90 passed** (was 88; +2 new)
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed**,
  including all 6 pre-existing `test_conflict_predicates.py` tests unchanged
- `uv run --locked --all-packages basedpyright` → **0 errors, 0 warnings, 0 notes**
- `uv run --locked --all-packages ruff check .` → clean;
  `ruff format --check .` → 99 files already formatted

## Second problem found (not fixed, not in scope)

None new. The pre-existing `~` / `UnaryNode("not", ...)` postfix-rendering bug
recorded above is still there and still untouched.

---

## Gate B follow-up: nominal base, not a structural Protocol

Gate B was right, and I had disclosed the same gap as an accepted residual
rather than closing it. That was the wrong call: a structural `Protocol` made
the static contract **wider** than the runtime one, which is a soundness
regression against the overloads it replaced. `Column[A]` was a concrete class,
so passing a non-column was already a static error before the arity work; the
Protocol quietly gave that away.

### The gap, concretely

`_target_column_names` gates on `isinstance(column, Column)`
(`packages/relq-core/src/relq/dml.py:65`). Under the Protocol, this
type-checked clean and then raised at runtime:

```python
class PretendColumn:
    @property
    def python_type(self) -> TypeForm[str] | Callable[..., str]: return str
    def declared_name(self, attribute: str) -> str: return attribute

insert.on_conflict(PretendColumn())
# basedpyright: clean
# runtime:      TypeError: target and conflict arguments must be table columns
```

### The fix

`ConflictTarget` moved to `packages/relq-core/src/relq/expressions/relations.py:31`
and became a plain covariant generic base class, with `Column` inheriting it
(`relations.py:54`):

```python
class ConflictTarget[T_co = object]:
    __slots__ = ()


@dataclass(frozen=True, slots=True, init=False)
class Column[T](ConflictTarget[T], Expr[T]):
    ...
```

`dml.py` now imports it rather than declaring it, and `on_conflict`
(`dml.py:173`) is unchanged in shape: `*columns: ConflictTarget`.

Conformance is now **by inheritance**, so static and runtime agree exactly:

```
error: Argument of type "PretendColumn" cannot be assigned to parameter
  "columns" of type "ConflictTarget[object]" in function "on_conflict"
  "PretendColumn" is not assignable to "ConflictTarget[object]"
```

Verified at runtime too: `Column.__mro__` is
`Column -> ConflictTarget -> Expr -> Expression -> NodeValue -> Generic -> object`,
`ConflictTarget.__slots__ == ()` so there is no layout conflict with the
slotted `NodeValue`/`Column` dataclasses, and `isinstance(users.email,
ConflictTarget)` is `True`.

### Why nominal beat structural here

- **The runtime check is nominal.** `on_conflict` does not consume a set of
  members; it consumes a `Column`, and says so with `isinstance`. A structural
  type describes members, so it could only ever approximate that — and it
  approximated it from the unsafe side.
- **It cost nothing.** Nothing in `on_conflict` reads a member off its
  arguments through the annotation, so the Protocol's `python_type` /
  `declared_name` were never load-bearing; they existed purely to make
  structural matching land on `Column`. Deleting them loses no expressiveness,
  and the covariant `T_co` still does the real work: `Column[str]` and
  `Column[str | None]` both widen to `ConflictTarget[object]`, so unlimited
  heterogeneous arity is untouched.
- **It matches the precedent I cited, more honestly than the Protocol did.**
  `Sequence[T_co]` in typeshed is a nominal ABC; `list` conforms by inheriting
  `MutableSequence`, not by exposing the right method names. The covariance was
  the transferable part of that precedent; the structural dispatch was not, and
  I over-borrowed. (SQLAlchemy's `_HasClauseElement` *is* a Protocol, but it
  is genuinely duck-typed — it exists so third-party objects with
  `__clause_element__` participate. relq has no such extension point here.)

### Cost

`ConflictTarget` is now a public base class of the public `Column` and appears
in `on_conflict`'s signature, so it is exported from `relq` and
`relq.expressions` (`__init__.py:17`/`:136` and `:77`/`:92`). That is two lines
of new public surface; revert them if you would rather it stay private, at the
price of callers not being able to spell the type of a helper that forwards
conflict targets.

### Tests

- `tests/typing/bad_conflict_target.py` — the three original negatives
  (`"email"`, `users.id.eq(1)`, `users`) still raise `reportArgumentType`, and
  `:12`/`:35` add `PretendColumn`, the structural lookalike, now rejected
  **statically**. Asserted by `tests/test_typing_fixtures.py:85`.
- `tests/typing/good.py` (2-column and 6-column heterogeneous targets) and
  `tests/integration/sqlite/test_dml_contracts.py:131` (5-column composite,
  real compile) are unchanged and still pass, so the arity fix survived the
  conversion intact.

Runs, all re-done after the change:

- `uv run --locked --all-packages pytest --ignore=tests/integration/postgres`
  → **90 passed**
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed**
- `uv run --locked --all-packages basedpyright` → **0 errors, 0 warnings, 0 notes**
- `uv run --locked --all-packages ruff check .` → clean;
  `ruff format --check .` → 99 files already formatted

---

## Gate B, round two: the base itself had to be abstract

Same class of gap, one level up, and gate B was right to look again. Making
`ConflictTarget` a concrete exported class closed the *structural* hole and
opened a *nominal* one: `ConflictTarget()` constructed fine and satisfied
`*columns: ConflictTarget` statically, then died in `_target_column_names`
with the same `TypeError: target and conflict arguments must be table columns`.
Zero members made it trivially constructible.

### The fix

`packages/relq-core/src/relq/expressions/relations.py:32` — the base is now an
`abc.ABC` with one abstract method, which `Column` already implemented
(`relations.py:90`), so `Column` needed no new code:

```python
class ConflictTarget[T_co = object](ABC):
    __slots__ = ()

    @abstractmethod
    def declared_name(self, attribute: str) -> str: ...
```

Both halves close:

```
basedpyright: error: Cannot instantiate abstract class "ConflictTarget"
              (reportAbstractUsage)
runtime:      TypeError: Can't instantiate abstract class ConflictTarget
              without an implementation for abstract method 'declared_name'
```

`declared_name` was chosen over a synthetic marker because `Column` already
has it with a matching signature, and because "a conflict target can name
itself" is the one thing `on_conflict` actually cares about. It carries no
`T_co`, so variance is untouched — re-confirmed after the change that
`ConflictTarget[object] = users.email` passes and `ConflictTarget[int] =
users.email` still fails with *"Type parameter `T_co@ConflictTarget` is
covariant"*.

Runtime shape after the change: MRO is
`Column -> ConflictTarget -> ABC -> Expr -> Expression -> NodeValue -> Generic -> object`,
metaclass resolves to `ABCMeta` (Column's only other base chain uses plain
`type`, so there is no metaclass conflict), `__slots__` stays `()`, and
`@dataclass(frozen=True, slots=True)` still rebuilds `Column` correctly under
`ABCMeta`.

### Why this is the right stopping point

This is what typeshed's `Sequence` actually does, and it is a closer precedent
than the covariance alone: `Sequence` is an ABC you cannot instantiate, so
"is a `Sequence`" statically means "is something real that implements one".
Three attempts, three different ways the static type could be satisfied by
something the runtime rejects — structural members, then bare construction —
and only abstract-and-nominal makes the two sets identical.

### Tests

`tests/typing/bad_conflict_target.py` now carries five negatives, all firing:

| Line | Case | Rule |
| --- | --- | --- |
| `:28` | `on_conflict("email")` | `reportArgumentType` |
| `:29` | `on_conflict(users.id.eq(1))` | `reportArgumentType` |
| `:30` | `on_conflict(users)` | `reportArgumentType` |
| `:35` | `on_conflict(PretendColumn())` — structural lookalike | `reportArgumentType` |
| `:39` | `on_conflict(ConflictTarget())` — bare abstract base | `reportAbstractUsage` |

`tests/test_typing_fixtures.py:92` now asserts `reportAbstractUsage` alongside
`reportArgumentType`, so the abstractness cannot silently regress.

Runs, all re-done:

- `uv run --locked --all-packages pytest --ignore=tests/integration/postgres`
  → **90 passed**
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed**
- `uv run --locked --all-packages basedpyright` → **0 errors, 0 warnings, 0 notes**
- `uv run --locked --all-packages ruff check .` → clean;
  `ruff format --check .` → 99 files already formatted

---

## Round four: the seal is the right mechanism -- and the wall, stated plainly

Gate's third probe was correct again, and the ABC framing from round three was
wrong: an abstract base stops nothing, because anyone can subclass it and
implement whatever it demands. I've made the change gate asked for, because it
is genuinely better, and then hit a wall that I do not think is passable. Both
halves below.

### What changed (kept)

`packages/relq-core/src/relq/expressions/relations.py:31` -- `ConflictTarget`
now sits *inside* the `Expression` family instead of beside it, and the `ABC` /
`@abstractmethod` from round three are gone:

```python
class ConflictTarget[T_co = object](Expression):
    __slots__ = ()
```

`Column[T](ConflictTarget[T], Expr[T])` (`relations.py:56`) is unchanged in
shape. MRO linearizes cleanly, reaching `Expression`/`NodeValue` once through
both branches, and the metaclass is back to plain `type`:

```
Column -> ConflictTarget -> Expr -> Expression -> NodeValue -> Generic -> object
```

This is strictly better than the ABC: simpler (no metaclass, no abstract
member), and it reuses relq's own unforgeability mechanism -- the private
`_CONSTRUCTION_TOKEN` that `NodeValue.__init__` demands
(`packages/relq-core/src/relq/_node_value.py:12`, `:26`) -- instead of a second
one invented for this one parameter. Every probe from the previous three rounds
now fails at construction:

| Probe | Result |
| --- | --- |
| `ConflictTarget()` | `TypeError: NodeValue.__init__() missing 1 required positional argument: 'token'` |
| `ConflictTarget(object())` | `TypeError: relq values are created by relq builders, not constructors` |
| subclass implementing `declared_name`, constructed normally | `TypeError: ... missing 1 required positional argument: 'token'` |
| structural lookalike (no inheritance) | `reportArgumentType` at the call site |

### The wall

The token seals *normal* construction. It does not seal a subclass that
overrides `__init__` and simply declines to call `super().__init__`:

```python
class Evasive(ConflictTarget[str]):
    def __init__(self) -> None: pass
```

`Evasive()` constructs, type-checks clean under basedpyright strict (**0
errors**), and then fails `on_conflict`'s runtime gate. basedpyright exempts
`__init__` from override-compatibility checking, so there is no diagnostic to
lean on. `object.__new__(ConflictTarget)` does the same thing without even
needing a subclass.

**This is not closable by any choice of base class.** The static parameter type
has to be a supertype of both `Column[str]` and `Column[str | None]` for
unbounded heterogeneous arity to work at all; Python has no way to make a class
both inheritable-by-`Column` and un-inheritable by anyone else (`@final` is
static-only, and cannot be applied to a base of `Column` regardless). So the
static inhabitant set is *necessarily* a strict superset of `Column`'s.

### The finding that decides it: this hole predates the arity work entirely

`from_select` is untouched by any of this and still uses the original concrete
`Column[A]` overload ladder -- the shape gate cited as sound. It has the same
hole, and a worse failure mode:

```python
class SneakyColumn(Column[str]):
    def __init__(self) -> None: pass

insert_into(users).from_select(select(users.email).from_(users), SneakyColumn())
# basedpyright: 0 errors
# isinstance(SneakyColumn(), Column) is True -- it passes the nominal gate too
# runtime:  AttributeError: 'SneakyColumn' object has no attribute '_state'
```

So `Column[A]` never was airtight either. `isinstance(column, Column)` returns
`True` for it, so it sails *past* `_target_column_names`'s nominal check and
dies deeper, leaking an internal `AttributeError` rather than the clean
`TypeError` `on_conflict` produces. Measured against that pre-existing
baseline, `ConflictTarget` is not a regression on this axis — it is an
improvement, and the residue is a property of every `Column`-typed parameter in
relq, not of this change.

### Recommendation

Stop here. The remaining residue requires a caller to subclass a documented
relq base *and* deliberately override `__init__` to evade a constructor seal --
at which point they can do the same to `Column` itself, against any signature
in the library. Closing it for `on_conflict` alone would buy nothing while
`from_select`, `excluded()` and `returning()` stay open, and closing it
everywhere means changing the runtime gate repo-wide (checking the AST node
rather than the class), which is well outside this task and would want its own
review.

Recorded, not fixed: `from_select`'s `AttributeError` leak above is a real
(small) pre-existing defect and a candidate for its own task -- the nominal
`isinstance` gate lets a malformed value through to an internal attribute
access.

### Tests

`tests/typing/bad_conflict_target.py` now carries six negatives, all firing:

| Line | Case | Rule |
| --- | --- | --- |
| `:28` | `on_conflict("email")` | `reportArgumentType` |
| `:29` | `on_conflict(users.id.eq(1))` | `reportArgumentType` |
| `:30` | `on_conflict(users)` | `reportArgumentType` |
| `:35` | `on_conflict(PretendColumn())` -- structural lookalike | `reportArgumentType` |
| `:40` | `on_conflict(ConflictTarget())` -- bare base | `reportCallIssue` (missing token) |
| `:52` | `on_conflict(Faithful())` -- faithful subclass | `reportCallIssue` (missing token) |

`tests/test_typing_fixtures.py:93` asserts `reportArgumentType` and
`reportCallIssue`.

Runs, all re-done:

- `uv run --locked --all-packages pytest --ignore=tests/integration/postgres`
  → **90 passed**
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed**
- `uv run --locked --all-packages basedpyright` → **0 errors, 0 warnings, 0 notes**
- `uv run --locked --all-packages ruff check .` → clean;
  `ruff format --check .` → 99 files already formatted

# Follow-up: lowering the Python floor to 3.13 (task `relq-lower-floor`)

**Result: `requires-python = ">=3.13"` throughout, and the suite genuinely runs
there.** Full gate green on CPython 3.13.15, 3.14.4 and 3.15.0rc1.

The scout audit (`notes/relq/relq-python-floor.md`) named one blocker,
`typing.TypeForm`. That part was right, and `typing_extensions` closed it
cleanly. But the audit was a *source* audit -- it looked for 3.13--3.15 feature
*names* in the published source -- and relq's other two 3.14+ dependencies have
no names to find. They are semantic: code that is spelled identically on every
version and only *behaves* differently. Both were fatal at import time on 3.13,
and both are now fixed.

## Gap 0 (the known one): `typing.TypeForm`

`typing_extensions.TypeForm` is a true drop-in, verified rather than assumed.

Runtime, on 3.15.0rc1 with `typing_extensions` 4.16.0:

```python
>>> typing_extensions.TypeForm is typing.TypeForm
True
```

Statically, I ran the same 21 call shapes through basedpyright 1.39.9 twice --
once as `typing_extensions.TypeForm` at `pythonVersion = "3.13"`, once as
`typing.TypeForm` at `"3.15"` -- and diffed the full diagnostic output. It is
**byte-identical**, including the inferred type of every accepted form and the
exact wording of every rejection:

| Argument | Both spellings infer |
| --- | --- |
| `int`, `str`, `bytes`, `datetime.date` | the class |
| `Row` (`TypedDict`) | `Row` |
| `Shaped` (`Protocol`) | `Shaped` |
| `list[int]`, `dict[str, int]`, `tuple[int, ...]`, `Sequence[int]` | the alias |
| `Naive` (`NewType`) | `Any` bare; exact under an expected type |
| `type[int]` | `type` |
| `Literal["a","b"]`, `Annotated[int, "meta"]`, `None`, `str \| None`, `Alias` (PEP 695) | `reportArgumentType`, identical message |

Two things worth recording from that table. First, the scout's suggested
fallback of a `type`/`Any`-based spelling really would have lost precision:
`TypedDict`, `Protocol` and subscripted-generic arguments are all accepted here
and all rejected by `type[T]`, and relq's own schemas use them
(`column(list[RelqIntegrationState])` in the PostgreSQL snapshot). Second,
basedpyright 1.39.9 does **not** implement PEP 747's implicit conversion for
unions, aliases, `Annotated` or `None` -- `column(str | None)` is an error --
but it is equally an error under `typing.TypeForm` at 3.15. That is a
pre-existing checker limitation, unchanged by this work, not a regression.
(`Column[str | None]` is still reachable the way generated schemas already do
it: `dedupe_key: Column[str | None] = column(str)`.)

`typing-extensions>=4.16.0` is now a real dependency of `relq` (added with
`uv add --package relq typing-extensions`, not hand-edited), so the import is
unconditional -- no `sys.version_info` branch, since on 3.15 the name resolves
to the identical object anyway.

## Gap 1 (missed by the audit): relq relies on PEP 649

The audit noted that "3.14's deferred annotation behavior is not the same thing
as the `from __future__ import annotations` statements already present in some
relq files" -- correct, and then it drew the wrong conclusion. relq *depends*
on that deferred behavior. 85 annotations across seven modules are forward
references to names that do not exist yet when the annotation is evaluated:

```
$ ruff check .            # with target-version = "py313"
85 × F821 undefined name  (InsertQuery ×20, UpdateQuery ×14, DeleteQuery ×13,
                           WindowSpec ×9, FrameBoundary ×8, _SelectQuery ×7, ...)
 5 × TC004 move import out of type-checking block
```

```
$ python3.13 -c 'import relq'
  File ".../relq/_query.py", line 36, in <generic parameters of new_query>
    query_type: type[SelectQuery[SqlRow, Row]],
NameError: name 'SelectQuery' is not defined
```

basedpyright agreed once `pythonVersion` came down: **2389 errors**, essentially
all of them the `reportUndefinedVariable` cascade off those 85 sites.

Fix: `from __future__ import annotations` in the eight modules that needed it
(`dml.py`, `query.py`, `_query.py`, `expressions/analytics.py`,
`expressions/ordering.py`, `expressions/relations.py`, and both executor
`__init__.py`s). That is PEP 563, available since 3.7, and it is already the
repo's convention -- eight other modules carry it. It also dissolves the five
`TC004`s, because a `TYPE_CHECKING`-only import is legitimate in a stringified
annotation. Nothing resolves these annotations at runtime; the one place relq
does introspect (`rows.py`'s `get_type_hints`) resolves *user* row models
against their own module, untouched by this.

## Gap 2 (also missed): `@dataclass(slots=True)` rebuilds the class

**This section was wrong on first writing and is corrected here.** Gate A, Gate
B and the reviewer all independently found that the failure I described did not
reproduce on 3.13.15, the pinned floor interpreter, and they were right: my
original investigation ran on uv's managed **3.13.9**, and I wrote "before
Python 3.14" into the shipped code comments without re-checking that boundary
against the interpreter the task had actually pinned. The comments as committed
were a false technical claim. What follows is the re-investigation, bisected.

`slots=True` cannot add `__slots__` to an existing class, so `dataclasses`
builds a *replacement* class and copies the methods over. There are **two
separate CPython bugs** here, in different generated methods, with different
fix timelines -- which is why a single-version claim was never going to be
right.

**Bug A -- the `__class__` cell (`Column.__init__`).** `Column` is
`@dataclass(frozen=True, slots=True, init=False)` and its hand-written
`__init__` calls zero-argument `super()`, which reads a `__class__` cell still
pointing at the discarded class. Declaring *any* relq column fails:

```
$ PYTHONPATH=... python3.13.13 -c 'class Users(Table): id: Column[int] = column(int)'
  File ".../relq/expressions/relations.py", line 69, in __init__
    super().__init__(token)
    ^^^^^^^^^^^^^^^^
TypeError: super(type, obj): obj (instance of Column) is not an instance or
           subtype of type (Column).
```

**Bug B -- the frozen `__setattr__` closure (`NodeValue`).** `dataclasses`
generates the frozen `__setattr__` closing over `cls`, and the rebuild leaves
that closure on the discarded class. Every subclass assignment whose name is
not one of `NodeValue`'s own fields reaches it. Instantiating any table fails:

```
$ PYTHONPATH=... python3.14.4 -c 'Users("users")'
  File ".../relq/expressions/relations.py", line 101, in Table.__init__
    self.table_name = name
TypeError: super(type, obj): obj (instance of Users) is not an instance or
           subtype of type (NodeValue).
```

Bisected against the real relq classes, unmodified apart from the TypeForm and
`__future__` fixes needed to make the module import at all:

| Interpreter | Bug A (`Column.__init__`) | Bug B (`NodeValue.__setattr__`) |
| --- | --- | --- |
| 3.13.0, 3.13.5, 3.13.10, 3.13.13 | **FAIL** | **FAIL** |
| 3.13.14, 3.13.15 | ok | ok |
| 3.14.0, 3.14.2, 3.14.4 | ok | **FAIL** |
| 3.14.5, 3.14.7, 3.15.0rc1 | ok | ok |

Bug A was fixed in 3.13.14 and affects no 3.14 release. Bug B needed *two*
fixes -- 3.13.14 on the 3.13 branch and 3.14.5 on the 3.14 branch -- so its bad
range is 3.13.0--3.13.13 **and** 3.14.0--3.14.4. The two windows do not nest.

(Each bug is isolated in that table: bug A is `column(int)` with no `Table`
involved, bug B is a bare `Table("t")` with no `Column` involved. An earlier
version of this note claimed bug B was 3.14-only, because the first probe ran
both in one script and bug A aborted it before bug B could be reached on 3.13.) The reviewer's instinct -- drop the workaround and raise the floor to the
first patch that fixed it -- was the right instinct and I applied it, but it
does not survive the second bug: `>=3.13.14` still admits 3.14.0--3.14.4, and I
confirmed the reverted code crashing there under the full suite (9 collection
errors, `TypeError ... (instance of IntegrationUsers) ... (NodeValue)`). No
single `requires-python` lower bound expresses "3.13.14+ but not
3.14.0--3.14.4"; `>=3.14.5` would abandon the 3.13 line this task exists to
reach.

The workaround is therefore the *simpler* of the two options, not the more
defensive one, and it is what shipped:

- `Column.__init__` names the class: `super(Column, self).__init__(token)`. The
  global resolves to the class that survives and walks the same MRO everywhere.
- `NodeValue` declares `__slots__ = ("_state",)` by hand instead of asking for
  `slots=True`, so it is never rebuilt and the generated `__setattr__` closes
  over the real class. It stays a frozen dataclass, which matters: its `_state`
  field is inherited into `__dataclass_fields__` by `Column` and every query
  builder, so their `__repr__`/`__eq__`/`__hash__` are unchanged.
- Hand-written `__slots__` does not get the copy hooks `_add_slots` installs on
  frozen slotted dataclasses, and `Table.as_` uses `copy.copy`, so
  `__getstate__`/`__setstate__` are written out **exactly** as
  `_dataclass_getstate`/`_dataclass_setstate` would have generated them: the
  dataclass fields, nothing else. That is narrow -- state a subclass keeps
  outside the fields does not survive a copy, which is precisely why
  `Table.as_` re-sets `table_name` by hand afterwards, and why that hand-copy
  must stay. Matching the old behaviour bit for bit is the point: this task's
  job is the interpreter bug, and every attempt to also improve copy semantics
  here introduced a fresh regression (see the correction log).

With the workaround, the same probe is **OK on all of** 3.13.0, 3.13.5,
3.13.13, 3.13.14, 3.13.15, 3.14.0, 3.14.2, 3.14.4, 3.14.5, 3.14.7 and
3.15.0rc1 -- so `requires-python = ">=3.13"` is honest as written, with no
exclusions.

Residue, checked rather than assumed: observable `setattr` behaviour on relq
values is identical on 3.13 and 3.15, including one case that still fails --
`col.foo = 1` raises `TypeError: super(type, obj)...` on both, because
`Column` itself still uses `slots=True`. That is pre-existing, unchanged, and
unreachable through any valid operation (`Column` has `__slots__`, so the
attribute cannot exist).

## Metadata, tooling and pins

| File | Change |
| --- | --- |
| `pyproject.toml` (root) | `requires-python >=3.13`; `target-version = "py313"`; `pythonVersion = "3.13"` |
| `packages/relq-core/pyproject.toml` | `>=3.13`; description "Python 3.13+"; `dependencies = ["typing-extensions>=4.16.0"]` |
| `packages/relq-{sqlite,postgres,codegen}/pyproject.toml` | `>=3.13` |
| `uv.lock` | re-locked; `requires-python = ">=3.13"` |
| `mise.toml` / `mise.lock` | `python = "3.13.15"` (released, not an rc); lock regenerated across all seven platforms by `mise install` |
| `readme.md`, `docs/installation.md`, `relq/__init__.py` docstring | "Python 3.13+"; the "`relq` itself has no dependencies" sentence is now false and says `typing-extensions` instead |

`docs/releases/v0.0.1.md` still says 3.15 and is deliberately left alone: `v0.0.1`
is a tag that exists, and that note is the record of what actually shipped.

## CI: prove the floor, keep the ceiling

Both workflows now run a
`python-version: ["3.13.0", "3.13", "3.14.0", "3.14", "3.15.0-rc.1"]` matrix
with `fail-fast: false`, rather than swapping one hard-coded version for
another. Testing only 3.15 is what let all three of these gaps sit undetected
behind honest-looking metadata in the first place.

The two pinned *patch* releases are load-bearing and were added after review.
A bare `"3.13"` / `"3.14"` resolves to the newest patch in each line -- 3.13.15
and 3.14.7 today -- and both are past the dataclasses bugs in gap 2. On that
matrix the `_node_value.py` and `relations.py` workarounds could be deleted
outright and CI would stay green, which is precisely the blind spot that
produced the wrong claim this note had to correct. `3.13.0` and `3.14.0` are
the oldest interpreter in each supported line and each still carries one of the
two bugs, so they turn both workarounds into something CI actually enforces.
The newest-patch entries stay alongside them so current interpreters are not
left untested, and the rc covers the third annotation regime.

Two mechanical notes. `uv sync` is pinned to the matrix interpreter via
`UV_PYTHON: ${{ steps.python.outputs.python-path }}`; without it uv's default
`python-preference = "managed"` is free to pick any interpreter satisfying
`>=3.13` and the matrix proves nothing. And `release.yml` had to be split:
`verify-and-build` uploads a single named artifact, so it cannot itself be a
matrix job. It now `needs:` a new matrix `test` job and builds once on the
floor (the distributions are `py3-none-any`, so the build interpreter is
immaterial).

## Tests

`tests/typing/good.py` gains a block that pins the precision, so a future
narrowing of `TypeForm` to `type[T]` fails loudly instead of silently:

```python
class Coordinates(TypedDict):
    latitude: float
    longitude: float

class Readings(Table):
    samples: Column[list[int]] = column(list[int])
    place: Column[Coordinates] = column(Coordinates)

assert_type(column(list[int]), Column[list[int]])
assert_type(column(Coordinates), Column[Coordinates])
assert_type(output_column(Coordinates), Column[Coordinates])
readings = Readings("readings")
assert_type(
    select(readings.samples, readings.place).from_(readings),
    SelectQuery[tuple[list[int], Coordinates], tuple[list[int], Coordinates]],
)
```

Both forms are rejected by `type[T]` and accepted by `TypeForm[T]`; the
`select` assertion carries a `TypedDict` column all the way through to a query
row type. `Temporal` above it already pins the `NewType` forms.

I dropped two candidates after testing them rather than shipping them: a PEP 695
alias (`column(Alias)`) and a bare `column(NaiveDateTime)` without an expected
type. Both fail -- and both fail identically under `typing.TypeForm` at 3.15, so
they are checker limitations, not something this change should assert.

Verification, all of it actually executed:

- `mise run check` on **CPython 3.13.15** (the mise pin): format-check, lint,
  typecheck, 90 sqlite tests, 28 postgres tests, build + `check-install.sh`
  → **all green**
- `pytest --ignore=tests/integration/postgres` → **90 passed** on 3.13.0,
  3.14.0, 3.14.4 and 3.15.0rc1 -- 3.13.0 is the declared floor, and 3.13.0 /
  3.14.0 / 3.14.4 are the interpreters the unworkarounded form crashes on
- `scripts/test-postgres.sh` (ephemeral PostgreSQL 18.4) → **28 passed** on
  3.13.0, 3.14.0, 3.14.4 and 3.15.0rc1
- `basedpyright --pythonversion {3.13,3.14,3.15}` → **0 errors, 0 warnings,
  0 notes** at each
- `ruff check .` → clean; `ruff format --check .` → 99 files already formatted
- `scripts/check-install.sh` → both wheels install and run outside the
  workspace, `typing-extensions` resolving from PyPI as expected
- `pickle` and `copy.copy` of `count()`, `row_number().over()`, a `Column` and
  a `Table` → byte-identical to the pre-task `slots=True` build, on 3.13.0,
  3.14.0, 3.14.4 and 3.15.0rc1; pickles round-trip both directions between the
  pre-task and current builds

## Correction log

Six findings landed on this work across four review rounds. All were valid.
Five are fixed; one (the copy-hook widening) was attempted, found to regress
pickling, and reverted to the original behaviour by design.

1. **Gate A / Gate B / reviewer, on the `slots=True` comments.** The committed
   code comments said the failure occurred "before Python 3.14", which does not
   reproduce on 3.13.15. Cause: the original investigation ran on uv's managed
   3.13.9 and the boundary was never re-checked against the pinned interpreter.
   Corrected above with a bisected range, and the comments in
   `_node_value.py` and `relations.py:69` now name the exact windows
   (3.13.0--3.13.13 for bug A, 3.14.0--3.14.4 for bug B). The instruction that
   followed from the finding -- revert and raise the floor to `>=3.13.14` --
   was applied and then walked back, because doing so exposed bug B on
   3.14.0--3.14.4 under the full suite. Evidence for that reversal is the
   bisection table above; it is not a defence of the original text, which was
   wrong. The reviewer then reproduced both bugs independently from scratch --
   installing 3.13.0 and 3.14.4 and running the unmodified relq classes against
   them -- and confirmed the bisection, the corrected comments and the fix.
   Settled: the eight source lines ship and `requires-python` stays a clean
   `>=3.13`, in preference to a permanent
   `>=3.13.14,!=3.14.0,...,!=3.14.4` exclusion chain that every downstream
   consumer would have to carry.
2. **Gate B, on stale docs.** `packages/relq-core/src/relq/__init__.py:1` still
   said "Python 3.15+" and now says "Python 3.13+".
   `docs/releases/v0.0.1.md` deliberately still says 3.15: `v0.0.1` is a tag
   that exists, and that note records what actually shipped.
3. **CI could not have caught a regression of either fix.** The first matrix
   used bare `"3.13"` / `"3.14"`, which resolve to the newest patch in each
   line and are past both bugs. Added `3.13.0` and `3.14.0` -- the oldest
   interpreter in each supported line, each still carrying one of the two bugs
   -- so the workarounds are enforced rather than merely present. Full suite
   verified green on both before pinning them.

4. **Gate A round two, then Gate B round three, on the copy hooks --
   attempted, reverted, and now matching the original exactly.** Gate A asked
   the hooks to round-trip `__dict__` so `copy.copy` would keep non-field
   subclass state. I widened them; Gate B then found that capturing
   `self.__dict__` wholesale also captures `__orig_class__`, which the generic
   alias machinery sets, and **broke pickling of ordinary values**:

   ```
   pickle.dumps(count())              -> PicklingError: Can't pickle T:
   pickle.dumps(row_number().over())     it's not the same object as typing.T
   ```

   It was also incomplete in the other direction (subclass-declared
   `__slots__` still missed) and rejected old pickles. Reverted to fields-only
   -- exactly `_dataclass_getstate`/`_dataclass_setstate` -- and the
   `__dict__` regression test removed with it, since it asserted behaviour
   relq deliberately does not provide. `tests/compiler/` is back to zero diff.

   Verified byte-identical to the pre-task `slots=True` build on 3.13.15
   (pickle and copy of `count()`, `row_number().over()`, a `Column` and a
   `Table`, plus `as_`'s resulting name/reference), and pickles round-trip in
   **both** directions between the pre-task and current builds. Re-checked on
   3.13.0, 3.14.0, 3.14.4 and 3.15.0rc1.

   Two corrections to the round-two finding as filed, for the record:
   `dataclasses._dataclass_getstate` is `[getattr(self, f.name) for f in
   fields(self)]` on 3.13.15, 3.14.7 and 3.15.0rc1 -- it does not carry
   `__dict__` -- and an A/B run of the original `slots=True` `NodeValue`
   against the current one dropped the extra attribute identically. The
   narrow behaviour was never a divergence introduced here; `Table.as_`'s
   hand re-set of `table_name` was already load-bearing before this task
   existed, and stays that way. Gate A's suggested follow-up simplification
   (dropping that hand-copy as redundant) is therefore **not** applied -- it
   was only ever valid against the widened getstate that has now been
   reverted.
5. **Gate A round two, on the stated version range.** The `_node_value.py`
   comment scoped bug B to "3.14.0 through 3.14.4". It also reproduces on
   3.13.0--3.13.13, which the first bisection missed because the probe hit bug
   A first and aborted. Both windows are now stated in the comment, along with
   the note that `relations.py`'s narrower 3.13-only range for bug A is
   deliberate. Re-bisected with each bug isolated; table above.

6. **Gate A round two, on `docs/releases/v0.0.1.md`.** Checked rather than
   assumed, and the tag is genuinely published and immutable: `v0.0.1` is an
   annotated tag dated 2026-08-10 present on `origin`, and PyPI reports
   `relq` 0.0.1 with `requires_python = ">=3.15"`, uploaded 2026-08-10. The
   release note is an accurate record of what shipped and stays as written.
   Worth flagging for whoever releases this: the workspace packages are still
   at version `0.0.1` while now declaring `>=3.13`, so this work needs a
   version bump before it can be tagged -- `release.yml` verifies the tag
   against the distribution versions, and 0.0.1 is already taken on PyPI.
   Bumping is a release step, not part of this diff (the stack has its own
   `bump` commits for that).

## Second problems found (not fixed -- own tasks)

- **`Column.__setattr__` raises `TypeError`, not `FrozenInstanceError`.**
  `users.id.foo = 1` raises a raw `TypeError: super(type, obj)...` because
  `Column` still asks for `slots=True` and its generated accessor has the same
  stale-`cls` closure `NodeValue`'s hand-written layout avoids. Confirmed
  pre-existing on `cap/relq-conflict-arity` and on 3.15.0rc1, so not a floor
  regression. `Column`'s decorator is left alone here.
- **relq's frozen slotted values have incomplete copy/pickle semantics.**
  `copy.copy` and `pickle` carry the dataclass fields only, so any state a
  subclass keeps in `__dict__` or in its own `__slots__` is silently dropped.
  `Table.as_` only works because it re-sets `table_name` and `_alias` by hand
  immediately after copying. This is pre-existing and independent of any
  CPython version bug -- it is what `slots=True` generated all along -- and is
  plausibly the same root cause as the `Column.__setattr__` papercut above.
  Two attempts to fix it inside this task each introduced a regression (the
  second broke pickling of `count()` and `row_number().over()`), which is
  itself evidence that it wants its own task with its own test surface rather
  than a drive-by widening of the copy hooks.
