#!/bin/bash
set -e

if [ -n "$GIT_USER_NAME" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi
if [ -n "$GITHUB_TOKEN" ]; then
    # Rewrite all github.com HTTPS URLs to embed the token
    git config --global url."https://oauth2:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

exec "$@"
