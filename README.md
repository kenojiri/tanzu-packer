# Tanzu Packer
building offline TKG/TAP jumphost OVA by Hashicorp Packer

## Introduction
Hello to folks who has been forced to use VMware Tanzu products on an on-premise vSphere cloud that is not connected to the Internet.

This is a set of a shell script and a JSON file to build a VM template and OVF/OVA files on an internet-connected vSphere cloud. The OVF/OVA files can be transferred to your on-prem environment and used to run a jumphost VM with everything already in place to install Tanzu Kubernetes Grid (TKG), Tanzu Application Platform (TAP), and other useful tools.

## Requirements
- ~200GB free disk space
- Hashicorp Packer
- curl
- jq
- awk
- sed
- openssl
- tar
- vCenter access on an internet-connected vSphere cloud
- Docker Hub user account and access token
- VMware Customer Connect user account with EULA
- VMware Tanzu Network user account with EULA and UAA API TOKEN
- GitHub personal access key (optional, you may need this when you hit GitHub API rate limit)

## What are included in OVF/OVA files?
- Ubuntu 22.04 LTS server
- Docker
- TKG 2.2
  - to deploy Standalone Management Clusters and Workload Clusters
  - Photon 3 based Tanzu Kubernetes release OVAs
  - official Harbor OVA
  - kubectl and velero
- TAP 1.5
  - with buildservice full dependencies
  - with TAS adapter
  - Tanzu Developer Tools, Tanzu App Accelerator Extensions, TAP GUI Catalogs, and other things for Developer Experience
- tanzu CLI bundles for TKG and TAP
- Carvel tools, Helm, Kustomize, jq, yq, direnv, git, netcat, OpenJDK, and other useful commands
- Helm Charts and container images
  - Bitnami Minio
  - Bitnami PostgreSQL
  - Bitnami PostgreSQL HA
  - Bitnami Redis
  - Bitnami Nginx
  - Bitnami ArgoCD
  - AVI Multi-Cluster Kubernetes Operator (AMKO)
- handy Docker image
  - busybox
- Grype vulnarability databases

## Notes
- The built OVF/OVA files cannot be freely distributed. The End User Licenses of TKG and TAP should be agreed before downloading and using them.

## References
- https://developer.hashicorp.com/packer/plugins/builders/vsphere/vsphere-iso
- https://github.com/brandonleegit/PackerBuilds/tree/main/ubuntu2204
