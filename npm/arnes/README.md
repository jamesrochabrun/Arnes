# arnes

An open-source coding agent with model switching, built-in verification, and cost tracking.
Built in Swift, with an interactive terminal interface and scriptable JSON output.

```sh
bun add -g arnes    # or: npm install -g arnes
export OPENROUTER_API_KEY=sk-or-...
arnes --version
arnes
```

This package is a thin launcher: the native binary for your platform installs through
one of the optional dependencies (macOS arm64/x64, Linux x64/arm64).

In a project, ask Arnes to explain the code, use `/plan <task>` to propose a change,
then inspect it with `/diff`. `/cost` shows spend, `/model <query>` switches models,
and `/save <name>` saves a name for resuming the session. `/verify` adds a model judgment
of the last task; project tests remain the way to check the code's behavior.

Arnes supports [OpenRouter](https://openrouter.ai), LiteLLM gateways, and other
OpenAI-compatible endpoints. It includes skills, MCP servers, subagents, permission
rules, and evaluation tooling. OS sandbox enforcement is available on macOS;
Linux binaries do not yet include a Linux sandbox backend.

The repository's `main` README describes the current source, which may be newer than
this package. Check `arnes --version` against the
[release notes](https://github.com/jamesrochabrun/Arnes/releases).

[Full documentation and source builds](https://github.com/jamesrochabrun/Arnes#readme) ·
[Provider configuration](https://github.com/jamesrochabrun/Arnes#providers--gateways) ·
[Report an issue](https://github.com/jamesrochabrun/Arnes/issues)
