#!/bin/bash -l
SIGUL_PASS_FILE=/etc/sigul/sigul-pass

# Use values passed in from the calling workflow to create needed files
echo "$SIGUL_IP" "$SIGUL_URI" >> /etc/hosts
mkdir -p /etc/sigul
echo "$SIGUL_CONF" > /etc/sigul/client.conf

echo "$SIGUL_PASS" > $SIGUL_PASS_FILE

# Extract sigul config
cd "$HOME" || exit 1
gpg --batch --passphrase "${SIGUL_PASS}" -o sigul.tar.xz -d <<< "${SIGUL_PKI}"
tar Jxf sigul.tar.xz

# Any future use of $SIGUL_PASSWORD needs to have it null terminated
sed -i 's/$/\x0/' "${SIGUL_PASS_FILE}"

cd "$GITHUB_WORKSPACE" || exit 1
if [ "$SIGN_TYPE" = "sign-data" ]; then
    # Read lines from SIGN_OBJECT until we run out
    while read -r filename && [[ -n "$filename" ]]; do
        # If the object includes a wildcard, we need to parse the file list
        if [[ $filename =~ \* ]]; then
            for wcfile in $filename; do
                # Don't sign directories or symlinks
                if [[ ! -f $wcfile ]]; then
                    continue
                fi
                echo "Signing $wcfile"
                sigul --batch "$SIGN_TYPE" -o "$wcfile.asc" "$SIGUL_KEY_NAME" \
                    "$wcfile" < "${SIGUL_PASS_FILE}"
                chmod 644 "$wcfile.asc"
            done
        else
            echo "Signing $filename"
            sigul --batch "$SIGN_TYPE" -o "$filename.asc" "$SIGUL_KEY_NAME" \
                "$filename" < "${SIGUL_PASS_FILE}"
            chmod 644 "$filename.asc"
        fi
    done <<< "${SIGN_OBJECT}"
elif [ "$SIGN_TYPE" = "sign-git-tag" ]; then
    git remote add github "https://${GH_USER}:${GH_KEY}@github.com/${GITHUB_REPOSITORY}"
    git fetch --tags
    sigul --batch "$SIGN_TYPE" "$SIGUL_KEY_NAME" "$SIGN_OBJECT" < "${SIGUL_PASS_FILE}"
    git push -f github "$SIGN_OBJECT"
fi
