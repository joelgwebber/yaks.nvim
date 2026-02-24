---
id: yaks.nvim-a93e
title: Support markdown rendering in yak descriptions
type: feature
priority: 2
created: '2026-02-21T01:32:33Z'
updated: '2026-02-20T12:00:00Z'
---

# Overview
We use markdown a fair amount already, but it just renders as **raw text** in view mode.

## Details
Support these patterns:
- **Bold text** for emphasis
- *Italic text* and _underscored italic_
- `inline code` for identifiers
- [link text](https://example.com) for URLs

* Asterisk list items too

See `highlight_description()` for the implementation.
