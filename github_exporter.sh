#!/usr/bin/env bash

set -Eeo pipefail

dependencies=(awk cat curl date gzip jq)
for program in "${dependencies[@]}"; do
    command -v "$program" >/dev/null 2>&1 || {
        echo >&2 "Couldn't find dependency: $program. Aborting."
        exit 1
    }
done

AWK=$(command -v awk)
CAT=$(command -v cat)
CURL=$(command -v curl)
DATE=$(command -v date)
GZIP=$(command -v gzip)
JQ=$(command -v jq)

if [[ "${RUNNING_IN_DOCKER}" ]]; then
    source "/app/github_exporter.conf"
elif [[ -f $CREDENTIALS_DIRECTORY/creds ]]; then
    #shellcheck source=/dev/null
    source "$CREDENTIALS_DIRECTORY/creds"
else
    source "./github_exporter.conf"
fi

[[ -z "${INFLUXDB_HOST}" ]] && echo >&2 "INFLUXDB_HOST is empty. Aborting" && exit 1
[[ -z "${INFLUXDB_API_TOKEN}" ]] && echo >&2 "INFLUXDB_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${ORG}" ]] && echo >&2 "ORG is empty. Aborting" && exit 1
[[ -z "${BUCKET}" ]] && echo >&2 "BUCKET is empty. Aborting" && exit 1
[[ -z "${GITHUB_TOKEN}" ]] && echo >&2 "GITHUB_TOKEN is empty. Aborting" && exit 1

INFLUXDB_URL="https://$INFLUXDB_HOST/api/v2/write?precision=s&org=$ORG&bucket=$BUCKET"

GH_URL="https://api.github.com"
GH_API_VERSION="X-GitHub-Api-Version: 2022-11-28"
RATE_LIMIT="/rate_limit"
USER_ENDPOINT="/user"
ORGS_ENDPOINT="/orgs"
REPOS_ENDPOINT="/repos"
CLONES_ENDPOINT="/traffic/clones"
PATHS_ENDPOINT="/traffic/popular/paths"
REFERRALS_ENDPOINT="/traffic/popular/referrers"
VIEWS_ENDPOINT="/traffic/views"
STARGAZERS_ENDPOINT="/stargazers"
FORKS_ENDPOINT="/forks"

gh_limit=$(
    $CURL --silent --fail --show-error --compressed \
        --header "Accept: application/vnd.github+json" \
        --header "$GH_API_VERSION" \
        --header "Authorization: Bearer $GITHUB_TOKEN" \
        "${GH_URL}${RATE_LIMIT}"
)

gh_limit_remaining=$(echo $gh_limit | $JQ ".rate.remaining")

if [[ $gh_limit_remaining -lt 10 ]]; then
    printf "Github API rate limit close to be reached:\n Remaining: %s\nAborting\n" "$gh_limit_remaining" >&2
    exit 1
fi

gh_repos_json=$(
    $CURL --silent --fail --show-error --compressed \
        --header "Accept: application/vnd.github+json" \
        --header "$GH_API_VERSION" \
        --header "Authorization: Bearer $GITHUB_TOKEN" \
        "${GH_URL}${USER_ENDPOINT}${REPOS_ENDPOINT}"
)

gh_repos=$(echo $gh_repos_json | $JQ --raw-output ".[] | select(select(.fork | not) or select(.disabled | not) or select(.archived | not) or select(.visibility != \"private\")) | .full_name")

for gh_repo in $gh_repos; do

    clones_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${CLONES_ENDPOINT}"
    )

    clones_stats=$(
        echo $clones_json |
            $JQ --raw-output ".clones | .[] | [ \"$gh_repo\", .count, .uniques, (.timestamp | fromdate)] | @tsv" |
            $AWK '{printf "github_stats_clones,repo=%s count=%s,uniques=%s %s\n", $1, $2, $3, $4}'
    )

    paths_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${PATHS_ENDPOINT}"
    )

    paths_stats=$(
        echo $paths_json |
            $JQ --raw-output ".[] | [ \"$gh_repo\", .path, .count, .uniques, $($DATE +%s)] | @tsv" |
            $AWK '{printf "github_stats_paths,repo=%s,path=%s count=%s,uniques=%s %s\n", $1, $2, $3, $4, $5}'
    )

    referrals_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${REFERRALS_ENDPOINT}"
    )

    referrals_stats=$(
        echo $referrals_json |
            $JQ --raw-output ".[] | [ \"$gh_repo\", .referrer, .count, .uniques, $($DATE +%s)] | @tsv" |
            $AWK '{printf "github_stats_referrals,repo=%s,referrer=%s count=%s,uniques=%s %s\n", $1, $2, $3, $4, $5}'
    )

    views_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${VIEWS_ENDPOINT}"
    )

    views_stats=$(
        echo $views_json |
            $JQ --raw-output ".views | .[] | [ \"$gh_repo\", .count, .uniques, (.timestamp | fromdate)] | @tsv" |
            $AWK '{printf "github_stats_views,repo=%s count=%s,uniques=%s %s\n", $1, $2, $3, $4}'
    )

    stars_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${STARGAZERS_ENDPOINT}"
    )

    stars_stats=$(
        echo $stars_json |
            $JQ --raw-output "[ \"$gh_repo\", length, $($DATE +%s)] | @tsv" |
            $AWK '{printf "github_stats_stars,repo=%s count=%s %s\n", $1, $2, $3, $4}'
    )

    forks_json=$(
        $CURL --silent --fail --show-error --compressed \
            --header "Accept: application/vnd.github+json" \
            --header "$GH_API_VERSION" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            "${GH_URL}${REPOS_ENDPOINT}/${gh_repo}${FORKS_ENDPOINT}"
    )

    forks_stats=$(
        echo $forks_json |
            $JQ --raw-output "[ \"$gh_repo\", length, $($DATE +%s)] | @tsv" |
            $AWK '{printf "github_stats_forks,repo=%s count=%s %s\n", $1, $2, $3, $4}'
    )

    gh_stats=$(
        $CAT <<END_HEREDOC
$clones_stats
$paths_stats
$referrals_stats
$views_stats
$stars_stats
$forks_stats
END_HEREDOC
    )

    echo "$gh_stats" | $GZIP |
        $CURL --silent --fail --show-error \
            --request POST "${INFLUXDB_URL}" \
            --header 'Content-Encoding: gzip' \
            --header "Authorization: Token $INFLUXDB_API_TOKEN" \
            --header "Content-Type: text/plain; charset=utf-8" \
            --header "Accept: application/json" \
            --data-binary @-
done
