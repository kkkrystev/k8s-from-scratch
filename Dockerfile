FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    bash \
    coreutils \
    jq \
    socat \
    util-linux \
    procps \
    iproute2 \
    iputils-ping \
    psmisc \
    man-db \
    manpages \
    less \
    vim-tiny \
    curl \
    ca-certificates \
    strace \
    xz-utils \
    netcat-openbsd \
    && yes | unminimize \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
