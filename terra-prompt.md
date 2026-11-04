# Terra Runner development iteration

Work on one small, complete, verifiable task from this project's configured roadmap. Read the roadmap, progress file, current source, project instructions, and recent Git history before changing anything. If the roadmap declares an active or critical development path, select its first unchecked technical implementation item in the path's declared order; do not sort task IDs numerically or skip an explicitly inserted prerequisite. If a path item is blocked solely by an unavailable external legal, commercial, ownership or policy approval, record that blocker and continue with the next independent technical critical-path item. Do this only when the selected task does not explicitly name the blocked item as a prerequisite. Never invent, assume or mark an external approval as complete. If no path is declared, select the first independent unchecked technical item in document order. Do not claim a parent task complete until every prerequisite named in that roadmap item has verified evidence.

Keep the work inside the selected project directory. Do not touch Terra Runner, unrelated repositories, production systems, credentials, or provider billing settings.

Implement production-quality code using the project's existing architecture. Add or update focused tests, run the available verification, update the roadmap only for work actually completed, and append an honest progress note.

Review `git diff`, confirm no secrets were introduced, commit the completed change using the repository's conventions, and push only when the configured remote accepts it. Never force-push.

If no safe actionable task exists, report `NO_ACTIONABLE_TASKS` and make no speculative change. Finish after one logical iteration.
