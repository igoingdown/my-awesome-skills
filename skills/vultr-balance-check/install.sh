#!/bin/bash
# Install dependencies for vultr-balance-check skill

set -e

echo "========================================"
echo "Installing vultr-balance-check dependencies"
echo "========================================"

# Check and install jq
if ! command -v jq &> /dev/null; then
    echo "⚠️  jq not found, installing..."
    if command -v brew &> /dev/null; then
        brew install jq
    else
        echo "❌ Error: brew not found"
        echo "Please install jq manually or install Homebrew first:"
        echo "  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
else
    echo "✅ jq found: $(jq --version)"
fi

echo ""
echo "========================================"
echo "✅ Installation complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Copy .env.example to .env:"
echo "   cp $(dirname "$0")/.env.example $(dirname "$0")/.env"
echo "2. Edit .env and fill in your Vultr API Key"
echo "3. Test the script:"
echo "   bash $(dirname "$0")/vultr_balance_check.sh"
echo ""
