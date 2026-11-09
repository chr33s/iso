<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

@AGENTS.md

## Claude Code specifics

- `.claude/skills` is a symlink to [`.agents/skills/`](.agents/skills/), so
  the shared skills load directly (for example `/integration`). Run the shared
  `review` skill as `/my-review`.
- A `PreToolUse` hook gates `gh pr create` on the
  [`closeout-review`](.agents/skills/closeout-review/SKILL.md) skill.
