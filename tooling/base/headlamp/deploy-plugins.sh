#!/bin/sh

PLUGIN_DIR=/build/plugins

deploy_plugin() {
    mkdir -p "$PLUGIN_DIR/$1"
    wget "$2/main.js" -O "$PLUGIN_DIR/$1/main.js"
    wget "$2/package.json" -O "$PLUGIN_DIR/$1"/package.json
    wget "$2/info.txt" -O "$PLUGIN_DIR/$1"/info.txt
}

deploy_plugin kubescape-plugin https://github.com/Kubebeam/kubescape-headlamp-plugin/releases/download/latest
deploy_plugin kyverno-plugin https://github.com/Kubebeam/kyverno-headlamp-plugin/releases/download/latest
deploy_plugin flux-plugin https://github.com/mgalesloot/headlamp-flux-plugin-release/releases/download/latest


deploy_headlamp_standard_plugin() {
    mkdir -p "$PLUGIN_DIR/$1"
    wget "https://github.com/headlamp-k8s/plugins/releases/download/$2" -O "/tmp/$1".gz
    tar xvf /tmp/"$1".gz -C "$PLUGIN_DIR/$1" --strip-components=1
}

deploy_headlamp_standard_plugin opencost-plugin opencost-0.1.2/headlamp-k8s-opencost-0.1.2.tar.gz
deploy_headlamp_standard_plugin app-catalog-plugin app-catalog-0.3.0/app-catalog-0.3.0.tar.gz
deploy_headlamp_standard_plugin plugin-catalog-plugin plugin-catalog-0.1.0/headlamp-k8s-plugin-catalog-0.1.0.tar.gz
