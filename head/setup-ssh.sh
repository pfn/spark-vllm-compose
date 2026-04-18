#!/bin/sh

if command -v ssh &> /dev/null; then
    echo "✅ SSH already installed"
else
    echo "⚙️  Installing SSH client..."
    apt update
    apt install -y openssh-client
    hash -r
    cp ~/.ssh/host_config ~/.ssh/config
    chmod 600 ~/.ssh/config

    if command -v ssh &> /dev/null; then
        echo "✅ SSH client installed successfully"
    else
        echo "❌ Installation failed"
        exit 1
    fi
fi
