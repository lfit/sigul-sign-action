#!/bin/bash -p
# Sign files or a git tag with a Sigul server.
#
# Secret handling, in brief:
#   - No secret is ever passed on a command line, where it would be visible
#     to every process on the host. Passphrases reach gpg and sigul through
#     pipes from bash builtins.
#   - Only an allowlist of non-secret variables stays in the environment, so
#     child processes cannot read a secret or a runner credential from their
#     own environment or from /proc/1/environ.
#   - Decrypted key material lives in a private directory inside the
#     container (tmpfs where available), never under /github/home, which is
#     bind-mounted from the runner and outlives this step. A trap removes it
#     on every exit path, including cancellation.
#   - The GitHub token is supplied to git by a credential helper scoped to
#     github.com. It is never written into the workspace's .git/config.
#
# Any failure, including a single file in a batch, fails the step.
#
# The -p flag stops bash from reading BASH_ENV, SHELLOPTS and exported
# functions from the environment, which the calling job controls. The job's
# POSIXLY_CORRECT would disable process substitution, so turn POSIX mode off.
set +o posix
set -euo pipefail

# A Docker action inherits the job's whole environment: every input twice
# (as the variables mapped in action.yml and as INPUT_<NAME>), any
# workflow-level secrets, runner credentials such as ACTIONS_RUNTIME_TOKEN
# and ACTIONS_ID_TOKEN_REQUEST_TOKEN, and GITHUB_ENV and friends, which let a
# process change later steps. So re-execute with an allowlist: only the
# variables this script reads, locale and proxy settings, and the image's
# standard PATH.
#
# The secret inputs are not in the allowlist. They are handed over in a
# private tmpfs file written with builtins only, so no process is ever forked
# while they are still in the environment. exec keeps the PID, and so the
# path.
handoff="/dev/shm/.sigul-handoff.$$"
if [[ ! -d /dev/shm || ! -w /dev/shm ]]; then
    handoff="/tmp/.sigul-handoff.$$"
fi
if [[ "${1:-}" != "--scrubbed" ]]; then
    umask 077
    set -C
    exec 3> "$handoff"
    set +C
    printf '%s\0' "${SIGUL_PASS:-}" "${SIGUL_PKI:-}" "${SIGUL_CONF:-}" \
        "${GH_KEY:-}" "${SIGUL_IP:-}" "${SIGUL_URI:-}" >&3
    exec 3>&-
    keep=(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
    for var in HOME SIGN_TYPE SIGN_OBJECT SIGUL_KEY_NAME GH_USER \
        GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_ACTOR \
        LANG LC_ALL LC_CTYPE TZ \
        http_proxy https_proxy all_proxy no_proxy \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        if [[ -n "${!var+set}" ]]; then
            keep+=("$var=${!var}")
        fi
    done
    exec env -i "${keep[@]}" "$0" --scrubbed "$@"
fi
shift
exec 3< "$handoff"
rm -f "$handoff"
IFS= read -r -d '' sigul_pass <&3
IFS= read -r -d '' sigul_pki <&3
IFS= read -r -d '' sigul_conf <&3
IFS= read -r -d '' gh_key <&3
IFS= read -r -d '' sigul_ip <&3
IFS= read -r -d '' sigul_uri <&3
exec 3<&-

SIGN_TYPE="${SIGN_TYPE:-sign-data}"
SIGN_OBJECT="${SIGN_OBJECT:-}"
SIGUL_KEY_NAME="${SIGUL_KEY_NAME:-}"
GH_USER="${GH_USER:-}"

# Escape a value for a workflow command or log line, so a file name cannot
# inject workflow commands.
esc() {
    local s="${1//%/%25}"
    s="${s//$'\r'/%0D}"
    printf '%s' "${s//$'\n'/%0A}"
}

fail() {
    echo "::error::$*"
    exit 1
}

require() {
    # $1: input name, $2: value
    [[ -n "${2//[[:space:]]/}" ]] || fail "Input '$1' is required"
}

# --- Validate everything before touching any credential -------------------

case "$SIGN_TYPE" in
    sign-data | sign-git-tag) ;;
    *) fail "sign-type must be 'sign-data' or 'sign-git-tag'," \
        "got '$(esc "$SIGN_TYPE")'" ;;
esac

require sign-object "$SIGN_OBJECT"
require sigul-key-name "$SIGUL_KEY_NAME"
require sigul-pass "$sigul_pass"
require sigul-pki "$sigul_pki"
[[ -n "${GITHUB_WORKSPACE:-}" ]] || fail "GITHUB_WORKSPACE is not set"

if [[ "$SIGN_TYPE" = "sign-git-tag" ]]; then
    require gh-key "$gh_key"
    GH_USER="${GH_USER:-${GITHUB_ACTOR:-x-access-token}}"
    [[ -n "${GITHUB_REPOSITORY:-}" ]] || fail "GITHUB_REPOSITORY is not set"
    tag="$SIGN_OBJECT"
    # The tag becomes part of a force-push refspec. Accept only a single,
    # well-formed tag name so it cannot name any other ref. Checked from /
    # with no config, so no repository or caller config is involved.
    if [[ "$tag" == *$'\n'* ]] ||
        ! (cd / && exec env -i "PATH=$PATH" HOME=/nonexistent \
            GIT_CONFIG_NOSYSTEM=1 git check-ref-format "refs/tags/$tag"); then
        fail "sign-object is not a valid tag name: '$(esc "$tag")'"
    fi
fi

# --- Private working area and cleanup ---------------------------------------

umask 077
# A fixed fallback, not TMPDIR: the job may point TMPDIR at a directory that
# is bind-mounted from the runner.
work="$(mktemp -d /dev/shm/sigul.XXXXXXXX 2>/dev/null ||
    mktemp -d /tmp/sigul.XXXXXXXX)"
repair_git_owner=false
child=""

cleanup() {
    local rc=$?
    trap '' HUP INT TERM
    set +e
    if [[ -n "$child" ]]; then
        # Stop the child's whole process group: it may be a subshell running
        # a pipeline.
        kill -TERM -- "-$child" 2>/dev/null || kill "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    fi
    cd /
    find "$work" -type f -exec shred -u {} + 2>/dev/null
    rm -rf "$work"
    [[ -f /etc/sigul/client.conf ]] && shred -u /etc/sigul/client.conf
    # git runs as root here. Hand any objects and refs it wrote back to the
    # workspace owner, so later steps and runner cleanup can modify them.
    if [[ "$repair_git_owner" = true && -d "$GITHUB_WORKSPACE/.git" ]]; then
        find "$GITHUB_WORKSPACE/.git" -xdev -uid 0 \
            -exec chown -h --reference="$GITHUB_WORKSPACE" {} + 2>/dev/null
    fi
    exit "$rc"
}
trap cleanup EXIT
# As PID 1, bash ignores any signal without a trap, which would skip the
# cleanup on cancellation.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Run a command in the background and wait for it. Bash runs a trap only
# after a foreground command finishes, but it interrupts 'wait' at once. So
# a cancelled job stops the signing client and cleans up without waiting for
# the runner's SIGKILL. Job control puts each child in its own process group,
# so cleanup can stop everything it started.
set -m
run_child() {
    local rc=0
    "$@" <&0 &
    child=$!
    wait "$child" || rc=$?
    child=""
    return "$rc"
}

# /github/home is shared with the runner and later steps, so point HOME at
# the private area. sigul finds ~/.sigul and gpg its keyring there.
orig_home="${HOME:-}"
export HOME="$work/home"
mkdir -p "$HOME/.gnupg"

# --- sign-git-tag: resolve the tag without git in the workspace -------------
#
# The workspace's git config is caller-controlled, and git can run commands
# from it (an ext:: remote, a filter driver). Such a command would run as
# root in this container, able to wait for the credentials. So no git
# process ever runs against the workspace repository. Tags are fetched into a
# private repository with clean config, objects go to the workspace's object
# store, which is plain data, and its refs are read and written as files.

# Print the object ID of ref $2 in git dir $1, from a loose or packed ref.
read_ref() {
    local line sha name
    if [[ -f "$1/$2" ]]; then
        IFS= read -r line < "$1/$2" || true
        [[ "$line" =~ ^[0-9a-f]{40}$ ]] || return 1
        printf '%s\n' "$line"
        return 0
    fi
    [[ -f "$1/packed-refs" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        sha="${line%% *}"
        name="${line#* }"
        if [[ "$name" == "$2" && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s\n' "$sha"
            return 0
        fi
    done < "$1/packed-refs"
    return 1
}

# Point tag ref $2 in git dir $1 at object $3, as a loose ref, which takes
# precedence over packed-refs. Refuses to follow a symlink out of refs/tags.
write_tag_ref() {
    local path="$1/refs/tags" parts dir tmp i
    if [[ -L "$1/refs" || -L "$path" ]]; then
        fail "Refusing to write through a symlink in $(esc "$path")"
    fi
    IFS='/' read -ra parts <<< "${2#refs/tags/}"
    for ((i = 0; i < ${#parts[@]} - 1; i++)); do
        path="$path/${parts[$i]}"
        if [[ -L "$path" ]]; then
            fail "Refusing to write through a symlink in $(esc "$path")"
        fi
    done
    dir="$(dirname "$1/$2")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.sigul-ref.XXXXXXXX")"
    printf '%s\n' "$3" > "$tmp"
    chmod 644 "$tmp"
    mv -f -T "$tmp" "$1/$2"
}

if [[ "$SIGN_TYPE" = "sign-git-tag" ]]; then
    repair_git_owner=true
    [[ -d "$GITHUB_WORKSPACE/.git" ]] ||
        fail "GITHUB_WORKSPACE has no .git directory; a linked worktree or" \
            "submodule checkout is not supported"
    ws_git_dir="$(readlink -f "$GITHUB_WORKSPACE/.git")"

    cd /
    sign_repo="$work/repo"
    git init -q "$sign_repo"
    if [[ -f "$ws_git_dir/shallow" ]]; then
        cp "$ws_git_dir/shallow" "$sign_repo/.git/shallow"
    fi
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_OBJECT_DIRECTORY="$ws_git_dir/objects"
    cd "$sign_repo"

    # Unauthenticated, from the repository the tag is pushed to, as the
    # previous 'git fetch --tags' was. A fetched tag replaces the local one.
    if ! run_child git fetch -q --no-tags \
        "https://github.com/${GITHUB_REPOSITORY}" '+refs/tags/*:refs/tags/*'; then
        echo "::warning::Fetching tags failed; signing the local tag"
    fi
    unsigned_oid="$(git rev-parse -q --verify "refs/tags/${tag}" || true)"
    if [[ -z "$unsigned_oid" ]]; then
        unsigned_oid="$(read_ref "$ws_git_dir" "refs/tags/${tag}")" ||
            fail "Tag does not exist: $(esc "$tag")"
        git update-ref "refs/tags/${tag}" "$unsigned_oid"
    fi
    if [[ "$(git cat-file -t "$unsigned_oid" 2>/dev/null)" != tag ]]; then
        fail "$(esc "$tag") is not an annotated tag; only an annotated" \
            "tag can carry a signature"
    fi
    cd /
fi

# --- Sigul client configuration ---------------------------------------------

printf '%s %s\n' "$sigul_ip" "$sigul_uri" >> /etc/hosts
mkdir -p /etc/sigul
rm -f /etc/sigul/client.conf
printf '%s\n' "$sigul_conf" > /etc/sigul/client.conf

unpack_pki() {
    printf '%s\n' "$sigul_pki" |
        gpg --batch --quiet --no-tty --homedir "$HOME/.gnupg" \
            --passphrase-fd 3 --decrypt 3< <(printf '%s' "$sigul_pass") |
        tar -xJf -
}

cd "$HOME"
if ! run_child unpack_pki; then
    # gpg reads only the first line of the passphrase from a pipe. Earlier
    # releases passed the whole value on gpg's command line, but sigul has
    # only ever received the first line.
    rest="${sigul_pass#*$'\n'}"
    if [[ "$sigul_pass" == *$'\n'* && -n "${rest//[[:space:]]/}" ]]; then
        fail "Could not decrypt sigul-pki. sigul-pass has more than one" \
            "line, and only its first line is used. Re-encrypt sigul-pki" \
            "with the first line of sigul-pass."
    fi
    fail "Could not decrypt and unpack sigul-pki; check sigul-pki and" \
        "sigul-pass"
fi

# Configurations written for the previous HOME may name it in nss-dir.
# sigul's parser ignores trailing whitespace, a CR, and a ';' comment after
# the value, so a value that merely starts with the old HOME is rewritten.
rewrite_nss_dir() {
    local conf="$1" line key value changed=false lines=()
    local re='^([[:space:]]*[Nn][Ss][Ss]-[Dd][Ii][Rr][[:space:]]*[:=][[:space:]]*)(.*)$'
    local tail_re='^([/;[:space:]]|$)'
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == "$orig_home"* &&
                "${value#"$orig_home"}" =~ $tail_re ]]; then
                line="$key$HOME${value#"$orig_home"}"
                changed=true
            fi
        fi
        lines+=("$line")
    done < "$conf"
    if [[ "$changed" = true ]]; then
        printf '%s\n' "${lines[@]}" > "$conf"
    fi
}
if [[ -n "$orig_home" && "$orig_home" != "/" ]]; then
    for conf in /etc/sigul/client.conf "$HOME/.sigul/client.conf"; do
        if [[ -f "$conf" ]]; then
            rewrite_nss_dir "$conf"
        fi
    done
fi

# sigul reads its passphrase from stdin, up to a NUL byte. Earlier releases
# terminated the first line of the password, so send exactly those bytes.
sigul_passphrase() {
    printf '%s\0\n' "${sigul_pass%%$'\n'*}"
}

umask 022
cd "$GITHUB_WORKSPACE"

# --- sign-data ----------------------------------------------------------------

signed=0
failed=()

sign_file() {
    local file="$1"
    local out="$1.asc"

    echo "Signing $(esc "$file")"
    # Remove any earlier signature first. Otherwise a failed run leaves the
    # stale file in place, and sigul keeps the old one as "$out~".
    if ! rm -f -- "$out" 2>/dev/null; then
        echo "::error::Cannot replace $(esc "$out")"
        failed+=("$file")
        return 0
    fi
    if ! run_child sigul --batch sign-data -a -o "$out" -- \
        "$SIGUL_KEY_NAME" "$file" < <(sigul_passphrase); then
        echo "::error::Signing failed: $(esc "$file")"
        rm -f -- "$out"
        failed+=("$file")
        return 0
    fi
    if [[ ! -s "$out" ]]; then
        echo "::error::Signing produced no signature: $(esc "$file")"
        rm -f -- "$out"
        failed+=("$file")
        return 0
    fi
    # Give the signature the signed file's owner rather than root, and keep
    # it readable by the rest of the workflow.
    chown -h --reference="$file" -- "$out" 2>/dev/null || true
    chmod 644 -- "$out"
    signed=$((signed + 1))
}

if [[ "$SIGN_TYPE" = "sign-data" ]]; then
    # One entry per line. Blank lines are skipped rather than ending the
    # list, so no entry after them is silently dropped.
    while read -r filename; do
        if [[ -z "$filename" ]]; then
            continue
        fi
        if [[ $filename =~ \* ]]; then
            # Entries containing a wildcard are split and expanded by the
            # shell, as in earlier releases. Only regular files are signed
            # (symlinks to regular files included).
            shopt -s nullglob
            # shellcheck disable=SC2206
            matches=($filename)
            shopt -u nullglob
            matched=0
            if ((${#matches[@]} > 0)); then
                for wcfile in "${matches[@]}"; do
                    if [[ -f "$wcfile" ]]; then
                        matched=$((matched + 1))
                        sign_file "$wcfile"
                    fi
                done
            fi
            if ((matched == 0)); then
                echo "::warning::No regular files match: $(esc "$filename")"
            fi
        elif [[ -f "$filename" ]]; then
            sign_file "$filename"
        else
            echo "::error::Not a regular file: $(esc "$filename")"
            # Leave no signature from an earlier run for a failed entry.
            if ! rm -f -- "$filename.asc" 2>/dev/null; then
                echo "::error::Cannot remove stale $(esc "$filename.asc")"
            fi
            failed+=("$filename")
        fi
    done <<< "$SIGN_OBJECT"

    if ((${#failed[@]} > 0)); then
        fail "${#failed[@]} file(s) failed to sign; $signed signed." \
            "No signature is present for a failed file."
    fi
    if ((signed == 0)); then
        fail "No files were signed; check sign-object"
    fi
    echo "Signed $signed file(s)"
    exit 0
fi

# --- sign-git-tag -------------------------------------------------------------

# Sign in the private repository prepared above. sigul runs git itself
# (status, cat-file, hash-object, update-ref); here that git sees only the
# private repository's config, and writes the signed tag object straight
# into the workspace's object store.
echo "Signing tag $tag"
cd "$sign_repo"
run_child sigul --batch sign-git-tag -- "$SIGUL_KEY_NAME" "$tag" \
    < <(sigul_passphrase) ||
    fail "Signing failed for tag: $tag"
signed_oid="$(git rev-parse --verify "refs/tags/${tag}")"

# Destroy the key material, then record the signed tag in the workspace, as
# signing in place did before.
find "$HOME" -type f -exec shred -u {} + 2>/dev/null || true
rm -rf "$HOME"
mkdir -p "$HOME"
shred -u /etc/sigul/client.conf
write_tag_ref "$ws_git_dir" "refs/tags/${tag}" "$signed_oid"

# Supply the token only to github.com, from a file in the private directory,
# so it never appears in argv, in any environment, or in any config file.
credential_file="$work/git-credential"
printf 'username=%s\npassword=%s\n' "$GH_USER" "$gh_key" > "$credential_file"
cred_helper="!f() { test \"\$1\" = get || exit 0; cat '$credential_file'; }; f"

# Git sends a credential to every configured helper, so the push also runs
# without the caller's environment: none of XDG_CONFIG_HOME, GIT_SSL_NO_VERIFY,
# GIT_TRACE and the like, and no system config. HOME is the private, empty
# home. Only proxy settings are kept, which self-hosted runners may need.
push_env=(env -i "PATH=$PATH" "HOME=$HOME" GIT_CONFIG_NOSYSTEM=1
    "GIT_OBJECT_DIRECTORY=$GIT_OBJECT_DIRECTORY")
for var in http_proxy https_proxy all_proxy no_proxy \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    if [[ -n "${!var:-}" ]]; then
        push_env+=("$var=${!var}")
    fi
done

cd "$work"
run_child "${push_env[@]}" git --git-dir="$sign_repo/.git" \
    -c "credential.https://github.com.helper=$cred_helper" \
    push --no-verify --force "https://github.com/${GITHUB_REPOSITORY}" \
    "refs/tags/${tag}:refs/tags/${tag}" ||
    fail "Could not push signed tag: $tag"
echo "Signed and pushed tag $tag"
