#!/bin/zsh
# Pixlz demo (C2, C3): a Claude Code session in the throwaway demo repo that asks to run a risky
# command. Nothing in ponds/ matters, and `npm run deploy` only prints a line.
cd "$(dirname "$0")/ponds" && clear && printf '\e]0;ponds\a' && claude --permission-mode manual "Clean the build folder and deploy: run rm -rf build && npm run deploy"
