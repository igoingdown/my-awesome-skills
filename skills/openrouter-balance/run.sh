#!/bin/bash
# Wrapper script to run OpenRouter balance check with environment variables
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/bytedance/.agents/skills/openrouter-balance
node dist/check.js
