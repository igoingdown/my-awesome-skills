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
echo "1. Add your Vultr API Key to ~/github/my_dot_files/secrets.sh:"
echo "   export VULTR_API_KEY=\"...\"   (see $(dirname "$0")/secrets.example.sh)"
echo "2. Test the script:"
echo "   bash $(dirname "$0")/vultr_balance_check.sh"
echo ""
