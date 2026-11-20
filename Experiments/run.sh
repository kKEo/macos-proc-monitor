#!/bin/zsh
# Build the probe binary if needed and run one probe: ./run.sh <probe> [args]
cd "$(dirname "$0")"
mkdir -p out
if [[ ! -x out/probe || Sys.swift -nt out/probe || load.swift -nt out/probe || probes.swift -nt out/probe ]]; then
  swiftc -O -swift-version 5 -parse-as-library Sys.swift load.swift probes.swift -o out/probe || exit 1
fi
exec out/probe "$@"
