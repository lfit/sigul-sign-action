# The sigul client image is built and published from the releng/sigul-docker
# project on gerrit.linuxfoundation.org (docker.io/lfreleng/sigul). Basing this
# action on that image keeps the CentOS 7 / sigul install logic in a single
# place instead of duplicating it here.
#
# Pinned by digest for reproducibility. Human-readable tag: 0.2.0
FROM docker.io/lfreleng/sigul@sha256:e9e1b58f0c0096c1de93dbc6ac885877f13bc6d8398f66386f34d3b7717c8f50

LABEL maintainer="<eball@linuxfoundation.org>"

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
