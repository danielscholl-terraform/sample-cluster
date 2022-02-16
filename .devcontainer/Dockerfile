# [Choice] Debian / Ubuntu version (use Debian 11/9, Ubuntu 18.04/21.04 on local arm64/Apple Silicon): debian-11, debian-10, debian-9, ubuntu-21.04, ubuntu-20.04, ubuntu-18.04
ARG VARIANT=debian-11
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}
WORKDIR /src

# [Optional] Uncomment this section to install additional OS packages.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
  && apt-get -y install --no-install-recommends direnv

RUN apt-get update \
  && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc
