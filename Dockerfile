# The sigul client image is built and published from the releng/sigul-docker
# project on gerrit.linuxfoundation.org (docker.io/lfreleng/sigul). Basing this
# action on that image keeps the CentOS 7 / sigul install logic in a single
# place instead of duplicating it here.
#
# Pinned by digest for reproducibility. Human-readable tag: 0.1.0
FROM docker.io/lfreleng/sigul@sha256:e8b958a6e5ba3ee6334c0244e9fbe0881248133e97bc77236a176baa5d219cbd

LABEL maintainer="<eball@linuxfoundation.org>"

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
