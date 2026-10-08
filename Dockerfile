FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    bash \
    coreutils \
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
    && yes | unminimize \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
