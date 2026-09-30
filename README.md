# Sigul-sign action

This action is used to sign build artifacts and git tags using a Sigul server.

> [!NOTE]
> This action is in maintenance mode and receives security fixes only. New
> work belongs in its replacement,
> [lfreleng-actions/sigul-sign-action](https://github.com/lfreleng-actions/sigul-sign-action).

# Usage

Pin the action to a full commit SHA rather than a tag.

### Sign an object that is available in the workspace

```yaml
- uses: lfit/sigul-sign-action@<commit-sha> # v1.x.y
  with:
      sign-type: "sign-data"
      sign-object: artifacts/mypackage.tar.gz
      sigul-key-name: "my-release-key"
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# This produces artifacts/mypackage.tar.gz.asc next to the signed file.
- uses: actions/upload-artifact@<commit-sha> # v4.x.y
  with:
      name: Signatures
      path: artifacts/mypackage.tar.gz.asc
```

### Sign multiple objects in the workspace

```yaml
- uses: lfit/sigul-sign-action@<commit-sha> # v1.x.y
  with:
      sign-type: "sign-data"
      sign-object: |
          file.tar.gz
          artifacts/my-file.jar
          docs/*.md
      sigul-key-name: "my-release-key"
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# Each signature is written next to its file, with ".asc" appended, for
# example "artifacts/my-file.jar.asc".
- uses: actions/upload-artifact@<commit-sha> # v4.x.y
  with:
      name: Signatures
      path: |
          *.asc
          artifacts/*.asc
          docs/*.asc
```

### Sign a git tag

```yaml
- uses: lfit/sigul-sign-action@<commit-sha> # v1.x.y
  with:
      sign-type: "sign-git-tag"
      sign-object: "v1.1" # Unsigned annotated tag in repo
      sigul-key-name: "my-release-key"
      gh-user: automation-username
      gh-key: ${{ secrets.GHA_TOKEN }}
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}
```

The tag must be an annotated tag. It is first fetched, without credentials,
from `https://github.com/<repository>`; a tag found there replaces the local
one, as `git fetch --tags` did in earlier releases. Otherwise the local tag in
the workspace is signed. The signed tag is recorded in the workspace and
force-pushed to `refs/tags/<tag>` on `https://github.com/<repository>`,
replacing the unsigned tag there.

The workspace must be a standard checkout with a `.git` directory. No git
command runs against it: the workspace's git configuration and hooks are
never used, so they cannot run code alongside the signing credentials.

## Failure behaviour

The step fails if any signing operation fails. With several files, every
file is still attempted, each failure is reported, and no signature is left
behind for a file that failed. The step also fails when:

-   an entry without a wildcard is not a regular file;
-   no file was signed at all;
-   `sign-type` is not recognised;
-   an input that the selected operation needs is empty: `sign-object`,
    `sigul-key-name`, `sigul-pass` and `sigul-pki`, plus `gh-key` for
    `sign-git-tag`;
-   `sign-object` is not a valid tag name for `sign-git-tag`.

Blank lines in `sign-object` are ignored. A wildcard entry that matches no
files produces a warning.

## Credential handling

-   No secret is passed on a command line.
-   Decrypted key material is kept in a private directory inside the action's
    container, in memory where possible, and removed when the step ends,
    including on failure or cancellation. Nothing is written to the runner's
    home directory.
-   `gh-key` is supplied to git only for `https://github.com`, only for the
    duration of the push, and only through a private file that the step
    removes. It is not stored in the repository's configuration, nor passed
    in any process's arguments or environment. The push ignores the job's
    git environment, apart from proxy settings.

## Inputs

## `sign-type`

The type of signing to do, either `"sign-data"` or `"sign-git-tag"`.
Default `"sign-data"`

## `sign-object`

**Required** The file or git tag to sign.

For `sign-data`, give one path per line. A line containing `*` is expanded
as a shell wildcard, and only regular files among the matches are signed.
Each signature is written to the signed file's path with `.asc` appended.

## `sigul-ip`

**Required** The IP address of the sigul server being used.

## `sigul-uri`

**Required** The URI of the sigul server. This is used with the IP address to
create a hosts file entry for the server.

## `sigul-conf`

**Required** The sigul config file.

## `sigul-key-name`

**Required** The key name on the server to utilize.

## `sigul-pass`

**Required** The password for the sigul connection (this should be specific to
the key name being used). Only its first line is used.

## `sigul-pki`

**Required** PKI info for the sigul connection. This expected to be stored in a
GPG armor file, encrypted using the above sigul-pass.

## `gh-user`

For git tag signing, the action requires a user to push the signed tag as.
Default: the `github.actor` of the workflow run.

## `gh-key`

A token for the user specified in `gh-user`. **Required** for
`sign-git-tag`. Do not pass it for `sign-data`, which does not use it.
