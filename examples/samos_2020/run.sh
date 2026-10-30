#!/bin/sh
# Samos 2020 (HL.TNSA record) on the Timisoara shaking table, receiver TM0J13ROU.
# Wrapper of examples/shaking_table/run.sh; see examples/shaking_table/README.md.
EVENT=samos_2020 exec sh "$(dirname "$0")/../shaking_table/run.sh"
