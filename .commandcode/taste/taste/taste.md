# Taste
- Stages files explicitly by name only; never uses `git add .` or `git add -A`. Confidence: 0.9
- Never runs destructive git/history commands (`git reset --hard`, `git clean`, broad deletion) and never discards uncommitted work without asking first. Confidence: 0.9
- Wants a git rollback point (commit of current state) saved before making any changes, so work can always be rolled back. Confidence: 0.85
- Prefers delegating work to parallel subagents (e.g. testing, searching, decoding tasks) — both to keep the main context lean and to reach completion faster; explicitly asks for agents to be used when the assistant works solo. Confidence: 0.9
- Expects results to be verified by actually building and running the code — never claiming an outcome from code that was not built and executed. Confidence: 0.7
- Wants the assistant to keep working autonomously through successive blockers until the overall goal is finished, rather than pausing to report and check in. Confidence: 0.8
