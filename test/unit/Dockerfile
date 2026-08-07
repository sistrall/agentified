# Unit-test runner: Debian-based on purpose, so the shell, sed, awk and sort
# under test are the same implementations that ship in a real devcontainer.
# (An Alpine/busybox runner would pass tests that fail in production.)
FROM debian:bookworm-slim

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends bats shellcheck ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /code
ENTRYPOINT ["bats"]
CMD ["--print-output-on-failure", "--recursive", "test/unit"]
