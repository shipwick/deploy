#!/usr/bin/env bash
# Runs a Shipwick deployment from a GitHub Actions workflow.
#
# action.yml passes every input as an INPUT_* variable (see its env: block):
#
#   INPUT_URL         the agent's URL                               required
#   INPUT_TOKEN       a deploy token                                required
#   INPUT_IMAGE       --image                                       optional
#   INPUT_FILE        -f, one path per line                         default deploy.yaml
#   INPUT_APPLICATIONS  names out of a shipwick.yaml, by line or space  optional, shipwick 0.8.0+
#   INPUT_ENV_FILE    --env-file, one path per line                 optional
#   INPUT_VERSION     release tag of the CLI, e.g. v0.3.1           default: latest release
#   INPUT_NO_WAIT     "true" adds --no-wait                         optional
#   INPUT_CHECK_ONLY  "true" stops after `shipwick --version`       for testing
#
# The CLI is downloaded from the release's assets and refused unless its SHA-256
# matches the release's checksums.txt. It is installed under RUNNER_TEMP and
# put on GITHUB_PATH so later steps of the job can run `shipwick` as well.
#
# Outputs (GITHUB_OUTPUT): version, url — parsed from the CLI's final lines;
# empty when the deployment did not finish here (--no-wait) or failed.

set -euo pipefail

REPO="shipwick/shipwick"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# The token is a secret. GitHub masks values that come from `secrets.*`; this
# covers a token that arrived any other way, before anything else is printed.
if [ -n "${INPUT_TOKEN:-}" ]; then
    echo "::add-mask::$INPUT_TOKEN"
fi

is_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

check_only=false
if is_true "${INPUT_CHECK_ONLY:-}"; then check_only=true; fi

if [ "$check_only" = false ]; then
    [ -n "${INPUT_URL:-}" ] || die "The input 'url' is required: the URL of your Shipwick agent, such as https://agent.example.com."
    [ -n "${INPUT_TOKEN:-}" ] || die "The input 'token' is required. Create one with 'shipwick token create ci --role deploy' and store it as a repository secret."
fi

# --- which binary --------------------------------------------------------------

case "${RUNNER_OS:-$(uname -s)}" in
    Linux|linux) os="linux" ;;
    macOS|Darwin|darwin) os="darwin" ;;
    Windows|MINGW*|MSYS*|CYGWIN*) die "Windows runners are not supported; run this action on ubuntu-latest or macos-latest." ;;
    *) die "Unsupported runner operating system: ${RUNNER_OS:-$(uname -s)}." ;;
esac
case "${RUNNER_ARCH:-$(uname -m)}" in
    X64|x86_64|amd64) arch="amd64" ;;
    ARM64|aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported runner architecture: ${RUNNER_ARCH:-$(uname -m)}." ;;
esac
asset="shipwick_${os}_${arch}"

# --- which release ---------------------------------------------------------------

# The tag comes from the redirect of releases/latest rather than from the API:
# the API is rate-limited per address, and runners share addresses.
tag="${INPUT_VERSION:-}"
if [ -z "$tag" ]; then
    location="$(curl -fsS --proto '=https' --tlsv1.2 --retry 3 -o /dev/null -w '%{redirect_url}' \
        "https://github.com/$REPO/releases/latest")" \
        || die "Could not find the latest Shipwick release at https://github.com/$REPO/releases."
    tag="${location##*/}"
    case "$tag" in
        v[0-9]*) ;;
        *) die "Could not work out the latest release from https://github.com/$REPO/releases/latest (got '$location'). Set the 'version' input to a release tag." ;;
    esac
fi
case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "The input 'version' must be a release tag such as v0.3.1, not '$tag'." ;;
esac
base="https://github.com/$REPO/releases/download/$tag"

# The names of the applications to deploy. They become arguments of the CLI,
# so each must be an application's name and nothing that reads as a flag.
applications=()
for name in ${INPUT_APPLICATIONS:-}; do
    case "$name" in
        ""|-*|*[!a-z0-9-]*) die "The input 'applications' takes application names such as 'api', one per line or separated by spaces, not '$name'." ;;
    esac
    applications+=("$name")
done
if [ "${#applications[@]}" -gt 0 ]; then
    # shipwick deploy takes names from 0.8.0 on; an older one would answer
    # with its usage.
    minor="${tag#v}"; major="${minor%%.*}"; minor="${minor#*.}"; minor="${minor%%.*}"
    if [ "$major" = 0 ] && [ "$minor" -lt 8 ]; then
        die "The input 'applications' needs shipwick 0.8.0 or later; this run uses $tag. Remove the 'version' input, or set it to v0.8.0 or later."
    fi
fi

# --- download and verify -----------------------------------------------------------

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

download() { # download URL DEST
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"
}

download "$base/checksums.txt" "$work/checksums.txt" \
    || die "Could not download $base/checksums.txt. Is $tag a published release of $REPO?"
download "$base/$asset" "$work/shipwick" \
    || die "Could not download $base/$asset."

expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1 }' "$work/checksums.txt")"
[ -n "$expected" ] || die "checksums.txt of $tag has no entry for $asset."
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/shipwick" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "$work/shipwick" | awk '{print $1}')"
fi
[ "$expected" = "$actual" ] \
    || die "Checksum mismatch for $asset of $tag: expected $expected, got $actual. Nothing was installed."

# --- install -----------------------------------------------------------------------

bin_dir="${RUNNER_TEMP:-$(mktemp -d)}/shipwick"
mkdir -p "$bin_dir"
mv "$work/shipwick" "$bin_dir/shipwick"
chmod 0755 "$bin_dir/shipwick"
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$bin_dir" >> "$GITHUB_PATH"
fi
echo "Installed shipwick $tag ($asset), verified against the release's checksums."

if [ "$check_only" = true ]; then
    "$bin_dir/shipwick" --version
    exit 0
fi

# --- deploy --------------------------------------------------------------------------

args=(deploy)
[ -z "${INPUT_IMAGE:-}" ] || args+=(--image "$INPUT_IMAGE")
# One path per line; blank lines and surrounding whitespace are ignored.
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] || args+=(-f "$line")
done <<< "${INPUT_FILE:-deploy.yaml}"
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] || args+=(--env-file "$line")
done <<< "${INPUT_ENV_FILE:-}"
if is_true "${INPUT_NO_WAIT:-}"; then args+=(--no-wait); fi
if [ "${#applications[@]}" -gt 0 ]; then args+=("${applications[@]}"); fi

# stdout goes through tee so the outputs can be read off it afterwards; the
# CLI sees a pipe and prints plain text. stderr (warnings) passes straight
# through. pipefail keeps the CLI's exit code as the step's.
log="$work/deploy.log"
SHIPWICK_AGENT_URL="$INPUT_URL" SHIPWICK_AGENT_TOKEN="$INPUT_TOKEN" \
    "$bin_dir/shipwick" "${args[@]}" | tee "$log"

# The summary the CLI ends with:
#
#   my-api 1.4.2  deployed in 6.1s
#   2/2 replicas healthy
#   https://api.example.com
#
# With several applications the outputs describe the last one: a URL counts
# only when it follows that application's own summary line. --no-wait prints
# no summary, and then both stay empty.
version="$(awk '/^[^ ]+ [^ ]+  deployed in / { v = $2 } END { print v }' "$log")"
url="$(awk '/^[^ ]+ [^ ]+  deployed in / { u = "" } /^https:\/\/[^ ]+$/ { u = $0 } END { print u }' "$log")"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$version"
        echo "url=$url"
    } >> "$GITHUB_OUTPUT"
fi
