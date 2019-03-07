#!/bin/sh -l

export GOPATH=/go

GO="/usr/local/go/bin/go"
MOLE_SRC_PATH=${GOPATH}/src/github.com/${GITHUB_REPOSITORY}
COV_PROFILE=${GITHUB_WORKSPACE}/coverage.out
COV_REPORT=${GITHUB_WORKSPACE}/mole-coverage.html
JSON='{ "message": "{{MESSAGE}}", "committer": { "name": "Mole Bot", "email": "davrodpin+molebot@gmail.com" }, "content": "{{CONTENT}}" }'

log() {
  level="$1"
  message="$2"

  [ -z "$level" ] || [ -z "$message" ] && return 1

  printf "`date +%Y-%m-%dT%H:%M:%S%z`\t%s\t%s\n" "${level}" "${message}"

  return 0
}


mole_wksp() {
  log "info" "Creating Go workspace at ${GOPATH}"

  mkdir -p ${MOLE_SRC_PATH} && \
    cp -a $GITHUB_WORKSPACE/* ${MOLE_SRC_PATH} || return 1

  return 0
}

download_report() {
  commit="$1"

  [ -z "$commit" ] && return 1

  resp=`curl --silent --show-error -X POST https://content.dropboxapi.com/2/files/download \
    --header "Authorization: Bearer ${DROPBOX_TOKEN}" \
    --header "Dropbox-API-Arg: {\"path\": \"/reports/${commit}/mole-coverage.html\"}"`

  error=`printf "%s\n" "$resp" | jq 'select(.error != null) | .error' 2> /dev/null`
  [ -n "$error" ] && {
    log "debug" "${resp}"
    return 1
  }

  printf "%s\n" "${resp}"

  return 0
}

cov_diff() {
  prev="$1"

  [ ! -f "$COV_REPORT" ] && {
    log "error" "coverage diff can't be computed: report file is missing: ${COV_REPORT}"
    return 1
  }

  prev_report=`download_report "${prev}"`
  [ $? -ne 0 ] && {
    log "warn" "coverage diff can't be computed: report could not be donwloaded for ${prev}"
    printf "%s\n" "${prev_report}"
    return 2
  }

  curr_stats=`cat ${COV_REPORT} | grep "<option value=" | sed -n 's/[[:blank:]]\{0,\}<option value="file[0-9]\{1,\}">\(.\{1,\}\) (\([0-9.]\{1,\}\)%)<\/option>/\1,\2/p'`
  prev_stats=`echo "${prev_report}" | grep "<option value=" | sed -n 's/[[:blank:]]\{0,\}<option value="file[0-9]\{1,\}">\(.\{1,\}\) (\([0-9.]\{1,\}\)%)<\/option>/\1,\2/p'`

  [ -z "$curr_stats" ] || [ -z "$prev_stats" ] && {
    log "error" "could not extract the code coverage numbers from ${COV_REPORT} and/or ${prev}"
    return 1
  }

  for stats1 in `printf "%s\n" "$curr_stats"`
  do
    mod1=`printf "%s\n" "$stats1" | awk -F, '{print $1}'`
    cov1=`printf "%s\n" "$stats1" | awk -F, '{print $2}'`
    diff=0

    for stats2 in `printf "%s\n" "$prev_stats"`
    do
      mod2=`printf "%s\n" "$stats2" | awk -F, '{print $1}'`
      cov2=`printf "%s\n" "$stats2" | awk -F, '{print $2}'`

      [ "$mod1" = "$mod2" ] && {
        diff=`printf "%s - %s\n" "$cov1" "$cov2" | bc`
        break
      }
    done

    printf "[mod=%s, cov=%s]\n" "$mod1" "$diff"
  done

  return 0
}

publish() {
  local_path="$1"
	remote_path="$2"

  [ -z "$local_path" ] || [ -z "$remote_path" ] && {
    log "error" "could not publish new report ${local_path} to ${remote_path}"
    return 1
  }

	resp=`curl --silent --show-error -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer ${DROPBOX_TOKEN}" \
    --header "Dropbox-API-Arg: {\"path\":\"${remote_path}\", \"mode\":\"overwrite\", \"mute\":true}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @${local_path}`

  error=`printf "%s\n" "$resp" | jq 'select(.error != null) | .error'`
  [ -n "$error" ] && {
    log "error" "could not publish report ${local_path}"
    printf "%s\n" "$resp" | jq '.'
    return 1
  }

  resp=`curl --silent --show-error -X POST https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings \
    --header "Authorization: Bearer ${DROPBOX_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"path\": \"${remote_path}\",\"settings\": {\"requested_visibility\": \"public\"}}"`

  printf "%s\n" "$resp" | grep -q 'Error in call' && {
    log "error" "report was published but could not create public link for ${remote_path}: ${resp}"
    return 1
  }

  link=`printf "%s" "$resp" | jq '.url' | sed 's/"//g'`

  report_url="http://htmlpreview.github.io/?${link}&raw=1"
  log "info" "coverage report available at ${report_url}"

  return 0
}

mole_test() {
  prev_commit_id=`jq '.before' ${GITHUB_EVENT_PATH} | sed 's/"//g' | cut -c-7`
  commit_id=`jq '.after' ${GITHUB_EVENT_PATH} | sed 's/"//g' | cut -c-7`

  mole_wksp || return 1

  ## TEST

  log "info" "running mole's tests and generating coverage profile for ${commit_id}"
  $GO test github.com/${GITHUB_REPOSITORY}/... -v -race -coverprofile=${COV_PROFILE} -covermode=atomic || return 1

  $GO tool cover -html=${COV_PROFILE} -o ${COV_REPORT} || {
    log "error" "error generating coverage report"
    return 1
  }

  log "info" "looking for code formatting issues on mole@${commit_id}" || return 1
  fmt=`$GO fmt github.com/${GITHUB_REPOSITORY}/... | sed 's/\n/ /p'`
  retcode=$?

  if [ -n "$fmt" ]
  then
    log "error" "the following files do not follow the Go formatting convention: ${fmt}"
    return ${retcode}
  else
    log "info" "all source code files are following the formatting Go convention"
  fi

  log "info" "comparing code coverage between ${commit_id} and ${prev_commit_id}"
  cov_diff "$prev_commit_id"
  [ $? -eq 1 ] && return 1

  ## PUBLISH COV REPORT

  log "info" "publishing new coverage report for commit ${commit_id}"
  publish "${COV_REPORT}" "/reports/${commit_id}/mole-coverage.html"

  return 0
}

mole_test
