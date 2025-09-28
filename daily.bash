#!/bin/bash
set -x
set -e
#VERSION="$1"

rm -rf vscode-linglong || true
git clone https://github.com/myml/vscode-linglong.git --depth 1
ll-builder build --skip-commit-output --skip-fetch-source -- sh -c "cat /packages.list /runtime/packages.list >> ./base_packages.list" || true
cd vscode-linglong

for file in linglong.yaml; do
    #sed -i "s#  version: .*#  version: ${VERSION}#" ../$file

    go run ./src/tools ../$file ../base_packages.list
    rm -rf ../base_packages.list
done
