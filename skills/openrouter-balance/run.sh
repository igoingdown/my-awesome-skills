#!/bin/bash
# Wrapper script to run OpenRouter balance check with environment variables
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"
node dist/check.js
