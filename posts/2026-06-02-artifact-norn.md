---
id: JOSH-2026-0006
title: ARTIFACT 0311 - norn
date: 2026-06-02
type: artifact
tags: cpp, concurrency, software
language: C++
status: alive
classification: software / concurrency
known_hazards: memory reclamation
repo: https://github.com/josh/norn
---

ARTIFACT 0311 - `norn`, a small C++ concurrency runtime built around
task stealing and a hand-rolled scheduler. It exists because I wanted to
understand how work actually moves between threads without trusting a
black box to do it for me.

It is *alive*, which in this catalogue means: still compiles, still
taught me something this quarter, still has at least one bug I have not
found. The known hazard is the usual one - memory reclamation under
concurrent access - and the current answer is hazard pointers, not
garbage collection. The repository is public; the warranty is not.
