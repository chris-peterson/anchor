---
description: Run anchor's CLI — a generic two-path diff review, completions, and the PATH installer
argument-hint: "[diff <left> <right> [--title <text>] [--detail <label>=<value>]... | completions zsh [--install] | install-cli | --version | help]"
---

Run the anchor CLI with the user's arguments. With none, print the usage text.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/anchor" ${ARGUMENTS:-help}
```
