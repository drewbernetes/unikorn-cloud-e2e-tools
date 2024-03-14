#!/bin/bash
set -euxo pipefail

sudo apt-get install -y yamllint

yamllint -d relaxed .
