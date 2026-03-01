---
id: yaks.nvim-56de
title: Opening yak fails when detail already open
type: bug
priority: 2
created: '2026-02-28T19:53:49Z'
updated: '2026-03-01T02:44:41Z'
commit: 40b8809
---

It doesn't seem to happen all the time, but often does when navigating between parent/child yaks.
Here's a lua stacktrace:

E5108: Error executing lua: .../.local/share/nvim/lazy/yaks.nvim/lua/yaks/ui/detail.lua:467: Vim:E95: Buffer with this name already exists stack traceback:
[C]: in function 'nvim_buf_set_name'
.../.local/share/nvim/lazy/yaks.nvim/lua/yaks/ui/detail.lua:467: in function 'open' 
...el/.local/share/nvim/lazy/yaks.nvim/lua/yaks/ui/list.lua:601: in function <...el/.local/share/nvim/lazy/yaks.nvim/lua/yaks/ui/list.lua:598>
