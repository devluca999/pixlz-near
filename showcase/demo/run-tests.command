#!/bin/zsh
# Pixlz demo (C1): the throwaway demo repo's tests, in Terminal.
cd "$(dirname "$0")/ponds" && clear && printf '\e]0;ponds\a' && printf '\e[1m$ swift test\e[0m\n' && swift test 2>&1 | grep -v "^\[" 
