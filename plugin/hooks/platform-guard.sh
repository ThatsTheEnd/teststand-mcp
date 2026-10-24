#!/bin/sh
# platform-guard.sh - SessionStart (startup) hook for NON-Windows hosts, POSIX sh.
#
# Prints ONE systemMessage saying the TestStand MCP server needs Windows with NI TestStand,
# and exits 0. It never blocks and is silent on every doubt: a uname that fails or prints
# nothing, and every Windows host (Git Bash, MSYS, Cygwin report MINGW*/MSYS*/CYGWIN*/
# Windows*), where platform-guard.ps1 speaks instead, so one station never gets two messages.
#
# The Windows checks (TestStand, Python, python-docx, Pillow, Edge/Chrome) live in
# platform-guard.ps1; this file needs nothing but sh, uname, tr and sed.

# Keeps printable ASCII only, then escapes backslash and double quote, so the value is safe
# inside a JSON string whatever it contains.
json_escape() {
    printf '%s' "$1" | LC_ALL=C tr -cd '\040-\176' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The one place that prints: a single JSON object with a systemMessage.
emit_system_message() {
    printf '{"systemMessage":"%s"}\n' "$(json_escape "$1")"
}

host_os=$(uname -s 2>/dev/null) || exit 0

case "$host_os" in
    '' | MINGW* | MSYS* | CYGWIN* | Windows*)
        exit 0
        ;;
esac

emit_system_message "TestStand MCP needs Windows with NI TestStand installed, but this host reports $host_os, so the teststand server cannot run here."
exit 0
