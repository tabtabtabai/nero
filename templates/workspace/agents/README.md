# Task-specific agents

Use subfolders here when you want **isolated context** for parallel or specialized work — for example a spike, a long-running refactor, or a dedicated exec-plan wave.

Suggested pattern:

```text
agents/<short-name>/
  README.md      # goal, scope, links to exec-plan or memory entries
  .agents/       # optional local notes
  notes.md       # scratchpad
```

The main workspace rules in `Agents.md` still apply. This directory is organizational, not a permission boundary.
