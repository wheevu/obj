---
title: The deploy that deployed nothing
date: 2026-05-18
tags: software, debugging
---

The deploy that deployed nothing.
The pipeline reported green.
The site reported 2019.
Somewhere between `upload-pages-artifact` and `deploy-pages`, the `dist/` path had drifted and the action conscientiously published an empty victory.

Root cause: a copy step that quietly did nothing.
Fix: point the artifact at the real `dist/` and watch the action upload bytes instead of optimism.
