#!/bin/bash

docker buildx build --platform linux/amd64 --platform linux/arm64 -f Dockerfile.sandbox -t containifyci/claude-code --push . 