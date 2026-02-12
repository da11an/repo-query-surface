#!/usr/bin/env bash
# Configuration loader

APP_NAME="sample"
APP_VERSION="1.0.0"

load_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    fi
}

get_setting() {
    local key="$1"
    local default="$2"
    echo "${!key:-$default}"
}
