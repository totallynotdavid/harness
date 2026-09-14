---
name: writing-tests
description: Design and implement deterministic tests for software repositories across languages and layers. Use when adding regression coverage, reorganizing a test harness, or deciding whether a check tests behavior or only source shape.
---

# Writing Tests

Start with the observable contract. Name the input, result, failure mode, and state that must remain true. Reproduce a bug before changing its implementation when the defect can be isolated.

Choose the smallest layer that proves the contract:

- Use the language's compiler, type checker, formatter, linter, and focused static checks
  for syntax and source policies.
- Test pure parsing and state transitions at their seam.
- Test public functions, modules, services, or commands through their real interface when
  wiring, exit status, output, or durable state matter.
- Use one integration test at each external boundary. Replace network services, databases,
  queues, clocks, filesystems, processes, and account APIs with deterministic fakes or
  adapters where the contract permits it.

Tests must be independent. Give each test a temporary home, repository, and state root. Set
fixed timestamps and environment values. Avoid network access, global user configuration,
unbounded processes, and sleeps used to create ordering. Inject a clock or write explicit
timestamps when time is part of the contract.

Exercise both accepted and rejected inputs. Assert exit status, stdout, stderr, and durable
state when they are part of the interface. Prefer an actual command path over calling an
internal helper directly when the command's wiring is the risk.

Keep behavior tests in a test directory with a shared runner or the project's native test
runner. Support the full suite and focused selection. Keep static policy checks separate. A
check that scans source must have a fixture or mutation proving that it detects the defect it
claims to prevent; otherwise it only proves that today's source happens to pass.

Use the repository's aggregate test command as the acceptance gate. Keep test output concise
on success and preserve the captured output on failure. Add a test for every fixed defect,
but group tests by current subsystem and contract instead of naming them after incidents.

Use the repository's native test framework when it provides useful fixtures, assertions,
isolation, reporting, or parallelism. Examples include pytest or unittest for Python, the
standard test runner for JavaScript or TypeScript, JUnit for Java, and Bats or ShellSpec for
shell. Keep a small direct runner when it is clearer and the repository has no need for a
framework. Do not add a framework only to wrap a one-command fixture.

Read [references/testing-principles.md](references/testing-principles.md) when choosing a
harness shape or migrating checks into behavior tests.
