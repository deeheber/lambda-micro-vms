# MicroVM image definition. The platform builds this, runs the ready hook, and
# snapshots the running memory; every MicroVM then resumes from that snapshot.

# Base image: the managed al2023-minimal image. Its system OpenSSL is patched
# for snapshot safety (random state must not be shared between MicroVMs cloned
# from one snapshot).
FROM public.ecr.aws/lambda/microvms:al2023-minimal

# Node comes from dnf so it links the base image's patched system OpenSSL.
# Official Node builds bundle their own OpenSSL and would lose that guarantee.
RUN dnf install -y nodejs24 && dnf clean all

# Ports the servers read from the environment. Changing a port means editing
# these two lines AND config.env; deploy.sh and a verify command compare them.
ENV APP_PORT=8080
ENV HOOKS_PORT=9000

WORKDIR /opt/app

# Only src/ is copied: Node 24 runs .ts directly, so there is no build step.
COPY src/ ./src/

# Two ports: the app (reached through the MicroVM proxy) and the lifecycle hooks
# (called by the platform).
EXPOSE ${APP_PORT} ${HOOKS_PORT}

# Start both servers. The image build then calls the ready hook until it is 200.
CMD ["node", "src/main.ts"]
