# A Saxo login in the cluster: a Job from the saxo-refresh CronJob (its image, Secret and token volume) that runs
# `saxo-sync login`, once without a URL for the address to log in at, once with the URL the browser landed on
{
  writeShellApplication,
  kubectl,
  jq,
}:
writeShellApplication {
  name = "saxo-login";
  runtimeInputs = [
    kubectl
    jq
  ];
  text = ''
    ns=''${SAXO_NAMESPACE:-ghostfolio}
    run() {
      local job
      job=saxo-login-$(date +%s)
      kubectl -n "$ns" create job "$job" --from=cronjob/saxo-refresh --dry-run=client -o json |
        jq --args '.spec.template.spec.containers[0].args = ["login"] + $ARGS.positional' "$@" |
        kubectl -n "$ns" create -f - >/dev/null
      for _ in $(seq 60); do
        [[ -n $(kubectl -n "$ns" get "job/$job" -o jsonpath='{.status.succeeded}{.status.failed}') ]] && break
        sleep 2
      done
      kubectl -n "$ns" logs "job/$job"
      kubectl -n "$ns" delete job "$job" --wait=false >/dev/null
    }
    if [[ $# -eq 0 ]]; then
      run
      printf '\nThen: saxo-login '"'"'<the URL the browser landed on>'"'"'\n'
    else
      run "$1"
    fi
  '';
}
