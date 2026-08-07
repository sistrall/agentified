# shellcheck shell=bash
#
# Sourced from ~/.bashrc by the example's postCreateCommand, so every terminal
# says what to try. The bashrc line is a guarded `source` of this file rather
# than a copy of its contents — which is what makes deleting this one file
# enough to remove the banner, with no rebuild.
#
# Debian's stock .bashrc returns early for non-interactive shells, so this only
# ever greets a human.

printf '\n\033[1magentified example\033[0m — a coding agent behind a network boundary.\n'
printf '  \033[36m./demo.sh\033[0m               prove the boundary works (two seconds)\n'
printf '  \033[36magentified status\033[0m       what is allowed, and what is running\n'
printf '  \033[36msudo agentified verify\033[0m  the full assertion suite\n'
printf '  \033[90mdone with this? rm .devcontainer/welcome.sh\033[0m\n\n'
