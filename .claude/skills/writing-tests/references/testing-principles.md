# Testing principles

Mature repositories tend to share a small set of testing principles across languages:

- Put behavior tests in a test directory with a shared helper or the language's native
  runner. Keep static policy checks separate from tests that exercise behavior.
- Start from the observable contract. Name the input, result, failure mode, and state that
  must remain true. Reproduce a bug before changing its implementation when the defect can
  be isolated.
- Choose the smallest test layer that proves the contract. Use static checks for source
  policy, unit tests for pure logic, public interface tests for wiring, and focused
  integration tests at external boundaries.
- Give each test isolated state. Use temporary directories, databases, homes, repositories,
  or containers as appropriate. Fix timestamps and environment values. Avoid network access,
  global configuration, unbounded processes, and sleeps used to create ordering.
- Replace external systems with deterministic fakes at the boundary. The fake should expose
  the behavior the code depends on, and the test should verify the request made to it when
  that request is part of the contract.
- Exercise accepted and rejected inputs. Assert the result, error, logs, exit status, and
  durable state that callers can observe.
- Make the full suite easy to run in CI and a focused test easy to run while developing.
  Keep successful output concise and preserve useful failure output.
- Give every custom static scanner a negative fixture or mutation. A scanner that only passes
  against the current source has not shown that it can catch the defect it claims to prevent.
- Prefer the repository's existing test framework when it provides meaningful isolation,
  assertions, reporting, or parallelism. A small direct runner is appropriate when the suite
  is small and a framework would add ceremony without improving the proof.

Git, nvm, and rbenv illustrate these principles with top-level test directories, shared
helpers, temporary roots, fake commands, focused suites, and CI matrices that exercise
portability. Bats and ShellSpec are useful shell options. The same design applies to Python,
JavaScript, Java, Go, Rust, and other ecosystems through their native tools.

Captain should run the project's declared check command. It should not need to understand the
private test framework or the layout of an individual project's tests.
