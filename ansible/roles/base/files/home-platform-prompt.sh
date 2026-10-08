# Home platform shell prompt (Bill, 2026-10-08): user@host, working directory and git branch, in colour, on
# every Linux box we set up (NUCs via Ansible's base role, the hub via compose/aws/host/install.sh, a Linux
# workstation per docs/new-machine-setup.md). Installed as /etc/profile.d/home-platform-prompt.sh.
# Two copies, kept identical: ansible/roles/base/files/ and compose/aws/host/.

# Interactive shells only.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac

# The current git branch, or nothing outside a repository.
parse_git_branch() {
  git branch --show-current 2>/dev/null
}

PS1='\[\e[1;31m\]\u\[\e[1;37m\]@\[\e[1;32m\]\h\[\e[1;34m\]\w\[\e[0m\] \[\e[1;31m\][$(parse_git_branch)]\[\e[1;34m\]>\[\e[0m\]'

# PuTTY doesn't set it, and Claude Code and btop fall back to fewer colours without it (docs/new-machine-setup.md).
export COLORTERM=truecolor
