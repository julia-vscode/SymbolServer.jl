ARG JULIA_VERSION=1
FROM julia:${JULIA_VERSION}

RUN groupadd -r julia && useradd --no-log-init -r -g julia julia

USER julia

ADD . /SymbolServer

RUN julia -e 'using Pkg; Pkg.update()'
