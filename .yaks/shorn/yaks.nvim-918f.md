---
id: yaks.nvim-918f
title: Align list view fields
type: feature
priority: 2
created: '2026-03-01T02:37:45Z'
updated: '2026-03-01T02:47:49Z'
commit: 40b8809
---

List view fields get misaligned for a couple of reasons:
- Because ids aren't all the same length.
- And children are indented.

I think it would be a lot easier to read if we did a little extra work upfront to ensure the fields
are horizontally aligned.
