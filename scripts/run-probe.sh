#!/bin/zsh
# Launch the bundled executable through LaunchServices so macOS uses its app identity.
set -euo pipefail
umask 077

oneshot_root="${0:A:h:h}"
oneshot_caller="$(pwd -P)"
oneshot_bundle="$oneshot_root/.build/OneShot Probe.app"
oneshot_wait_seconds=120
oneshot_wait_explicit=false

if [[ "${1-}" == "--wait-seconds" ]]; then
  if (( $# < 2 )) || [[ "$2" != <1-3600> ]]; then
    print -u2 "run-probe: --wait-seconds requires an integer from 1 to 3600."
    exit 64
  fi
  oneshot_wait_seconds="$2"
  oneshot_wait_explicit=true
  shift 2
fi
if [[ "${1-}" == "--" ]]; then shift; fi
if (( $# == 0 )); then set -- help; fi
oneshot_command="$1"
if [[ "$oneshot_command" == "authorize" && "$oneshot_wait_explicit" == false ]]; then
  oneshot_wait_seconds=360
fi
for oneshot_argument in "$@"; do
  case "$oneshot_argument" in
    --completion-file|--completion-file=*|--working-directory|--working-directory=*)
      print -u2 "run-probe: $oneshot_argument is reserved for the launcher."
      exit 64
      ;;
  esac
done
if [[ ! -x "$oneshot_bundle/Contents/MacOS/oneshot" ]]; then
  print -u2 "run-probe: build the app first with $oneshot_root/scripts/build-probe.sh"
  exit 69
fi

oneshot_evidence="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/oneshot-run.XXXXXXXX")"
oneshot_evidence="${oneshot_evidence:A}"
oneshot_stdout="$oneshot_evidence/stdout.log"
oneshot_stderr="$oneshot_evidence/stderr.log"
oneshot_receipt="$oneshot_evidence/receipt.json"
oneshot_launch_stdout="$oneshot_evidence/launch.stdout.log"
oneshot_launch_stderr="$oneshot_evidence/launch.stderr.log"
: > "$oneshot_stdout"
: > "$oneshot_stderr"
print -u2 "OneShot run evidence: $oneshot_evidence"
trap 'print -u2 "run-probe: interrupted; the app was not terminated. Evidence: $oneshot_evidence"; exit 130' INT
trap 'print -u2 "run-probe: stopped waiting; the app was not terminated. Evidence: $oneshot_evidence"; exit 143' TERM

# Do not use -W: a fast-exiting process can make open report GetProcessPID(-616).
# Even without -W, the CLI receipt, rather than open's exit code, is authoritative.
oneshot_launch_code=0
if /usr/bin/open -n -g -a "$oneshot_bundle" --stdout "$oneshot_stdout" --stderr "$oneshot_stderr" \
    --args "$@" --working-directory "$oneshot_caller" --completion-file "$oneshot_receipt" \
    > "$oneshot_launch_stdout" 2> "$oneshot_launch_stderr"; then
  oneshot_launch_code=0
else
  oneshot_launch_code=$?
fi
oneshot_deadline=$(( SECONDS + oneshot_wait_seconds ))
while [[ ! -f "$oneshot_receipt" ]]; do
  if (( SECONDS >= oneshot_deadline )); then
    /bin/cat "$oneshot_stdout"
    /bin/cat "$oneshot_stderr" >&2
    /bin/cat "$oneshot_launch_stderr" >&2
    print -u2 "run-probe: no completion receipt within $oneshot_wait_seconds seconds (open exit $oneshot_launch_code)."
    print -u2 "The app may still be running; no process was killed and no capture was retried. Evidence: $oneshot_evidence"
    exit 124
  fi
  /bin/sleep 0.2
done

oneshot_schema="$(/usr/bin/plutil -extract schemaVersion raw -expect integer -o - "$oneshot_receipt" 2>/dev/null)" || oneshot_schema=""
oneshot_receipt_command="$(/usr/bin/plutil -extract command raw -expect string -o - "$oneshot_receipt" 2>/dev/null)" || oneshot_receipt_command=""
oneshot_exit_code="$(/usr/bin/plutil -extract exitCode raw -expect integer -o - "$oneshot_receipt" 2>/dev/null)" || oneshot_exit_code=""
if [[ "$oneshot_schema" != 1 || "$oneshot_receipt_command" != "$oneshot_command" || "$oneshot_exit_code" != <0-255> ]]; then
  /bin/cat "$oneshot_stdout"
  /bin/cat "$oneshot_stderr" >&2
  print -u2 "run-probe: invalid completion receipt; command result is unknown. Evidence: $oneshot_evidence"
  exit 125
fi

/bin/cat "$oneshot_stdout"
/bin/cat "$oneshot_stderr" >&2
if (( oneshot_launch_code != 0 )); then
  print -u2 "run-probe: open returned $oneshot_launch_code; using verified CLI completion exit $oneshot_exit_code."
fi
exit "$oneshot_exit_code"
