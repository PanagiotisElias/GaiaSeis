#!/bin/sh
# Norcia 2016 (IT.CIT record) on the Timisoara shaking table, receiver TM0J13ROU.
# Wrapper of examples/shaking_table/run.sh; see examples/shaking_table/README.md.
EVENT=norcia_2016 exec sh "$(dirname "$0")/../shaking_table/run.sh"
