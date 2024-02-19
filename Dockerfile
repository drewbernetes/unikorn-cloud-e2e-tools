FROM cgr.dev/chainguard/wolfi-base:latest as builder

ENV UNIKORNCTL_VERSION="0.1.0"
ENV DOGKAT_VERSION="0.1.5"
ENV HELM_VERSION="3.13.3"
ENV KUBECTL="1.28.5"

WORKDIR /tmp

RUN apk update && apk add curl

RUN curl -LO https://github.com/drewbernetes/unikornctl/releases/download/v${UNIKORNCTL_VERSION}/unikornctl-linux-amd64
RUN curl -LO https://github.com/drewbernetes/dogkat/releases/download/v${DOGKAT_VERSION}/dogkat-linux-amd64
RUN chmod +x dogkat-linux-amd64
RUN chmod +x unikornctl-linux-amd64

RUN curl -LO https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz
RUN curl -LO https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum
RUN echo "$(cat helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum)" | sha256sum -c
RUN tar xzf helm-v${HELM_VERSION}-linux-amd64.tar.gz
RUN chmod +x linux-amd64/helm

RUN curl -LO "https://dl.k8s.io/release/v${KUBECTL}/bin/linux/amd64/kubectl"
RUN curl -LO "https://dl.k8s.io/v${KUBECTL}/bin/linux/amd64/kubectl.sha256"
RUN echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c
RUN chmod +x kubectl


FROM cgr.dev/chainguard/wolfi-base:latest

RUN apk update && apk add --no-cache aws-cli bash curl

RUN echo "e2e-tools:x:1000:1000:E2ETools Non Root,,,:/home/e2e-tools:" >> /etc/passwd
RUN mkdir -p /home/e2e-tools/.dogkat
RUN mkdir -p /home/e2e-tools/.kube
RUN chown e2e-tools: -R /home/e2e-tools

COPY --from=builder /tmp/unikornctl-linux-amd64 /bin/unikornctl
COPY --from=builder /tmp/dogkat-linux-amd64 /bin/dogkat
COPY --from=builder /tmp/linux-amd64/helm /bin/helm
COPY --from=builder /tmp/kubectl /bin/kubectl

COPY scripts/.unikornctl.yaml /home/e2e-tools/
COPY scripts/cluster.json /home/e2e-tools/
COPY scripts/dogkat.yaml /home/e2e-tools/.dogkat/
COPY scripts/run.sh /home/e2e-tools/
RUN chmod +x /home/e2e-tools/run.sh

USER 1000
