# The sigul client image is built and published from the releng/sigul-docker
# project on gerrit.linuxfoundation.org (docker.io/lfreleng/sigul). Basing this
# action on that image keeps the CentOS 7 / sigul install logic in a single
# place instead of duplicating it here.
#
# Pinned by digest for reproducibility. Human-readable tag: 0.2.1
FROM docker.io/lfreleng/sigul@sha256:52773d955ce179b5091b2fb495d95fa584e39380083d7c8449b111627fd02753

LABEL maintainer="<eball@linuxfoundation.org>"

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
