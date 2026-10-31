# shellcheck shell=bash
# deploy (detailed design 2.5). M1 runs the preflight only and leaves the host
# unchanged; the steps after it come in M2 and M3 (detailed design 16.1).

cmd_deploy() {
  parse_deploy_args "$@"
  check_root_gate
  check_platform_gate
  take_lock
  load_deploy_inputs
  run_preflight
  report_summary
  if [ "$VPS_COUNT_FAIL" -gt 0 ]; then
    printf '[x] 预检不通过，主机未改动\n' >&2
    exit "$VPS_EXIT_FAIL"
  fi
  printf '[x] 预检通过；之后的步骤在 M2 实现，主机未改动\n' >&2
  exit "$VPS_EXIT_FAIL"
}
