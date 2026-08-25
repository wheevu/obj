---
id: JOSH-2026-0005
title: INCIDENT 0142 - the deploy that deployed nothing
date: 2026-05-18
type: incident
tags: debugging, software, ci
severity: moderate
status: resolved
---

INCIDENT 0142 - the deploy that deployed nothing.
The pipeline reported green.
The site reported 2019.
Somewhere between `upload-pages-artifact` and `deploy-pages`, the `dist/`
path had drifted and the action conscientiously published an empty victory.

Root cause: a copy step that quietly did nothing.
Resolution: point the artifact at the real `dist/` and watch the action upload
bytes instead of optimism.
