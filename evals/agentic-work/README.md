# Agentic-work quality probes

Small deterministic Python tasks for comparing lead-only and specialist-enabled runs,
diagnostics, and context retention. Python 3 is the only fixture dependency. These are
development probes, not Terminal-Bench substitutes or a held-out benchmark.

- `cross-module-pagination`: inspect a public function and helper, repair pagination and
  invalid-input behavior, preserve a fixture, and add regression tests.
- `verification-tail`: repair a config parser after a noisy smoke test, preserve that test,
  cover cases the smoke test omits, and add regression tests.

Checks independently exercise the implementation, including boundary cases; an untouched
fixture and a smoke-only repair must fail. Checks require a regression-test file but do
not treat its existence as proof of useful coverage or that the model ran it. Inspect the
transcript for actual verification commands and test quality. A child report, tool count,
final success statement or zero exit code from an unrelated command never establishes a pass.
No check requires delegation; direct and delegated solutions can both pass.

See [the specialist experiment](../ab/agents-specialists/README.md) for paired human-run
commands. Keep model, effort, budget, packs and diagnostics/context settings fixed while
testing roles. Evaluate those other controls separately. Use different tasks for held-out
confirmation; these fixtures and their checks are public and can be tuned against.
